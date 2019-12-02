-module(ra_log_reader).

-compile(inline_list_funcs).

-export([
         init/3,
         close/1,
         update_segments/2,
         handle_log_update/3,
         segment_refs/1,
         update_first_index/2,
         read/3,
         fetch_term/2,
         emit/2,
         num_open_segments/1
         ]).

-include("ra.hrl").

-define(STATE, ?MODULE).

%% TODO: these could be captured in a record
-define(METRICS_OPEN_MEM_TBL_POS, 3).
-define(METRICS_CLOSED_MEM_TBL_POS, 4).
-define(METRICS_SEGMENT_POS, 5).

%% holds static or rarely changing fields
-record(cfg, {uid :: ra_uid(),
              directory :: file:filename()}).

-type segment_ref() :: {From :: ra_index(), To :: ra_index(),
                        File :: string()}.
-record(?STATE, {cfg :: #cfg{},
                 first_index = 0 :: ra_index(),
                 segment_refs = [] :: [segment_ref()],
                 open_segments = ra_flru:new(1, fun flru_handler/1) :: ra_flru:state()
                }).

-opaque state() :: #?STATE{}.

-export_type([
              state/0
              ]).

%% PUBLIC

init(UId, MaxOpen, SegRefs) ->
    #?STATE{cfg = #cfg{uid = UId,
                       directory = ra_env:server_data_dir(UId)},
            open_segments = ra_flru:new(MaxOpen, fun flru_handler/1),
            segment_refs = SegRefs}.

close(#?STATE{open_segments = Open}) ->
    _ = ra_flru:evict_all(Open),
    ok.

update_segments(NewSegmentRefs,
                #?STATE{open_segments = Open0,
                        segment_refs = SegmentRefs0} = State) ->
    SegmentRefs = compact_seg_refs(NewSegmentRefs ++ SegmentRefs0),
    %% check if any of the updated segrefs refer to open segments
    %% we close these segments so that they can be re-opened with updated
    %% indexes if needed
    Open = lists:foldl(fun ({_, _, F}, Acc0) ->
                               case ra_flru:evict(F, Acc0) of
                                   {_, Acc} -> Acc;
                                   error -> Acc0
                               end
                       end, Open0, SegmentRefs),
    State#?MODULE{segment_refs = SegmentRefs,
                  open_segments = Open}.

handle_log_update(_FirstIdx, SegRefs,
                  #?STATE{open_segments = Open0} = State) ->
    Open = ra_flru:evict_all(Open0),
    State#?MODULE{segment_refs = SegRefs,
                  open_segments = Open}.

update_first_index(Idx, #?STATE{segment_refs = SegRefs0,
                                open_segments = OpenSegs0} = State) ->
    case lists:partition(fun({_, To, _}) when To > Idx -> true;
                            (_) -> false
                         end, SegRefs0) of
        {_, []} ->
            {State, []};
        {Active, Obsolete} ->
            ObsoleteKeys = [element(3, O) || O <- Obsolete],
            % close any open segments
            OpenSegs = lists:foldl(fun (K, OS0) ->
                                           case ra_flru:evict(K, OS0) of
                                               {_, OS} -> OS;
                                               error -> OS0
                                           end
                                   end, OpenSegs0, ObsoleteKeys),
            {State#?STATE{open_segments = OpenSegs,
                          first_index = Idx,
                          segment_refs = Active},
             Obsolete}
    end.

emit(Pids, #?STATE{cfg = #cfg{uid = UId},
                   first_index = Idx,
                   segment_refs = SefRefs}) ->
    [{send_msg, P, {ra_log_update, UId, Idx, SefRefs},
      [ra_event, local]} || P <- Pids].


segment_refs(#?STATE{segment_refs = SegmentRefs}) ->
    SegmentRefs.

-spec read(ra_index(), ra_index(), state()) ->
    {[log_entry()], Metrics :: list(), state()}.
read(From, To, #?STATE{cfg = #cfg{uid = UId}} = State)
  when From =< To ->
    % 2. Check ra_log_open_mem_tables
    % 3. Check ra_log_closed_mem_tables in turn
    % 4. Check on disk segments in turn
    case open_mem_tbl_take(UId, {From, To}, [], []) of
        {Entries1, MetricOps, undefined} ->
            % ok = update_metrics(UId, MetricOps),
            {Entries1, MetricOps, State};
        {Entries1, MetricOps1, Rem1} ->
            case closed_mem_tbl_take(UId, Rem1, MetricOps1, Entries1) of
                {Entries2, MetricOps, undefined} ->
                    % ok = update_metrics(UId, MetricOps),
                    {Entries2, MetricOps, State};
                {Entries2, MetricOps2, {S, E} = Rem2} ->
                    case catch segment_take(State, Rem2, Entries2) of
                        {Open, undefined, Entries} ->
                            MOp = {?METRICS_SEGMENT_POS, E - S + 1},
                            % ok = update_metrics(UId,
                            %                     [MOp | MetricOps2]),
                            {Entries, [MOp | MetricOps2],
                             State#?MODULE{open_segments = Open}}
                    end
            end
    end;
read(_From, _To, State) ->
    {[], [], State}.



fetch_term(Idx, #?STATE{cfg = #cfg{uid = UId}} = State0) ->
    case ets:lookup(ra_log_open_mem_tables, UId) of
        [{_, From, To, Tid}] when Idx >= From andalso Idx =< To ->
            Term = ets:lookup_element(Tid, Idx, 2),
            {Term, State0};
        _ ->
            case closed_mem_table_term_query(Idx, UId) of
                undefined ->
                    segment_term_query(Idx, State0);
                Term ->
                    {Term, State0}
            end
    end.

-spec num_open_segments(state()) -> non_neg_integer().
num_open_segments(#?MODULE{open_segments = OpenSegs}) ->
    ra_flru:size(OpenSegs).

%% LOCAL

segment_term_query(Idx, #?MODULE{segment_refs = SegRefs,
                                 cfg = #cfg{directory = Dir},
                                 open_segments = OpenSegs} = State) ->
    {Result, Open} = segment_term_query0(Idx, SegRefs, OpenSegs, Dir),
    {Result, State#?MODULE{open_segments = Open}}.

segment_term_query0(Idx, [{From, To, Filename} | _], Open0, Dir)
  when Idx >= From andalso Idx =< To ->
    case ra_flru:fetch(Filename, Open0) of
        {ok, Seg, Open} ->
            Term = ra_log_segment:term_query(Seg, Idx),
            {Term, Open};
        error ->
            AbsFn = filename:join(Dir, Filename),
            {ok, Seg} = ra_log_segment:open(AbsFn, #{mode => read}),
            Term = ra_log_segment:term_query(Seg, Idx),
            {Term, ra_flru:insert(Filename, Seg, Open0)}
    end;
segment_term_query0(Idx, [_ | Tail], Open, Dir) ->
    segment_term_query0(Idx, Tail, Open, Dir);
segment_term_query0(_Idx, [], Open, _) ->
    {undefined, Open}.

open_mem_tbl_take(Id, {Start0, End}, MetricOps, Acc0) ->
    case ets:lookup(ra_log_open_mem_tables, Id) of
        [{_, TStart, TEnd, Tid}] ->
            {Entries, Count, Rem} = mem_tbl_take({Start0, End}, TStart, TEnd,
                                                 Tid, 0, Acc0),
            {Entries, [{?METRICS_OPEN_MEM_TBL_POS, Count} | MetricOps], Rem};
        [] ->
            {Acc0, MetricOps, {Start0, End}}
    end.

closed_mem_tbl_take(Id, {Start0, End}, MetricOps, Acc0) ->
    case closed_mem_tables(Id) of
        [] ->
            {Acc0, MetricOps, {Start0, End}};
        Tables ->
            {Entries, Count, Rem} =
            lists:foldl(fun({_, _, TblSt, TblEnd, Tid}, {Ac, Count, Range}) ->
                                mem_tbl_take(Range, TblSt, TblEnd,
                                             Tid, Count, Ac)
                        end, {Acc0, 0, {Start0, End}}, Tables),
            {Entries, [{?METRICS_CLOSED_MEM_TBL_POS, Count} | MetricOps], Rem}
    end.

mem_tbl_take(undefined, _TblStart, _TblEnd, _Tid, Count, Acc0) ->
    {Acc0, Count, undefined};
mem_tbl_take({_Start0, End} = Range, TblStart, _TblEnd, _Tid, Count, Acc0)
  when TblStart > End ->
    % optimisation to bypass request that has no overlap
    {Acc0, Count, Range};
mem_tbl_take({Start0, End}, TblStart, TblEnd, Tid, Count, Acc0)
  when TblEnd >= End ->
    Start = max(TblStart, Start0),
    Entries = lookup_range(Tid, Start, End, Acc0),
    Remainder = case Start =:= Start0 of
                    true ->
                        % the range was fully covered by the mem table
                        undefined;
                    false ->
                        {Start0, Start-1}
                end,
    {Entries, Count + (End - Start + 1), Remainder};
mem_tbl_take({Start0, End}, TblStart, TblEnd, Tid, Count, Acc0)
  when TblEnd < End ->
    %% defensive case - truncate the read to end at table end
    mem_tbl_take({Start0, TblEnd}, TblStart, TblEnd, Tid, Count, Acc0).

lookup_range(Tid, Start, Start, Acc) ->
    [Entry] = ets:lookup(Tid, Start),
    [Entry | Acc];
lookup_range(Tid, Start, End, Acc) when End > Start ->
    [Entry] = ets:lookup(Tid, End),
    lookup_range(Tid, Start, End-1, [Entry | Acc]).


segment_take(#?STATE{segment_refs = [],
                     open_segments = Open},
             _Range, Entries0) ->
    {Open, undefined, Entries0};
segment_take(#?STATE{segment_refs = [{_From, SEnd, _Fn} | _] = SegRefs,
                     open_segments = OpenSegs,
                     cfg = #cfg{directory = Dir}},
             {RStart, REnd}, Entries0) ->
    Range = {RStart, min(SEnd, REnd)},
    lists:foldl(
      fun(_, {_, undefined, _} = Acc) ->
              %% we're done reading
              throw(Acc);
         ({From, _, _}, {_, {_, End}, _} = Acc)
           when From > End ->
              Acc;
         ({From, To, Fn}, {Open0, {Start0, End}, E0})
           when To >= End ->
              {Seg, Open} =
                  case ra_flru:fetch(Fn, Open0) of
                      {ok, S, Open1} ->
                          {S, Open1};
                      error ->
                          AbsFn = filename:join(Dir, Fn),
                          case ra_log_segment:open(AbsFn, #{mode => read}) of
                              {ok, S} ->
                                  {S, ra_flru:insert(Fn, S, Open0)};
                              {error, Err} ->
                                  exit({ra_log_failed_to_open_segment, Err,
                                        AbsFn})
                          end
                  end,

              % actual start point cannot be prior to first segment
              % index
              Start = max(Start0, From),
              Num = End - Start + 1,
              Entries = ra_log_segment:read_cons(Seg, Start, Num,
                                                 fun binary_to_term/1,
                                                 E0),
              Rem = case Start of
                        Start0 -> undefined;
                        _ ->
                            {Start0, Start-1}
                    end,
              {Open, Rem, Entries}
      end, {OpenSegs, Range, Entries0}, SegRefs).

flru_handler({_, Seg}) ->
    _ = ra_log_segment:close(Seg),
    ok.

closed_mem_tables(Id) ->
    case ets:lookup(ra_log_closed_mem_tables, Id) of
        [] ->
            [];
        Tables ->
            lists:sort(fun (A, B) ->
                               element(2, A) > element(2, B)
                       end, Tables)
    end.

closed_mem_table_term_query(Idx, Id) ->
    case closed_mem_tables(Id) of
        [] ->
            undefined;
        Tables ->
            closed_mem_table_term_query0(Idx, Tables)
    end.

closed_mem_table_term_query0(_Idx, []) ->
    undefined;
closed_mem_table_term_query0(Idx, [{_, _, From, To, Tid} | _Tail])
  when Idx >= From andalso Idx =< To ->
    ets:lookup_element(Tid, Idx, 2);
closed_mem_table_term_query0(Idx, [_ | Tail]) ->
    closed_mem_table_term_query0(Idx, Tail).

compact_seg_refs(SegRefs) ->
    lists:reverse(
      lists:foldl(fun ({_, _, File} = S, Acc) ->
                          case lists:any(fun({_, _, F}) when F =:= File ->
                                                 true;
                                            (_) -> false
                                         end, Acc) of
                              true -> Acc;
                              false -> [S | Acc]
                          end
                  end, [], SegRefs)).
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

open_mem_tbl_take_test() ->
    _ = ets:new(ra_log_open_mem_tables, [named_table]),
    Tid = ets:new(test_id, []),
    true = ets:insert(ra_log_open_mem_tables, {test_id, 3, 7, Tid}),
    Entries = [{3, 2, "3"}, {4, 2, "4"},
               {5, 2, "5"}, {6, 2, "6"},
               {7, 2, "7"}],
    % seed the mem table
    [ets:insert(Tid, E) || E <- Entries],

    {Entries, _, undefined} = open_mem_tbl_take(test_id, {3, 7}, [], []),
    EntriesPlus8 = Entries ++ [{8, 2, "8"}],
    {EntriesPlus8, _, {1, 2}} = open_mem_tbl_take(test_id, {1, 7}, [],
                                                  [{8, 2, "8"}]),
    {[{6, 2, "6"}], _, undefined} = open_mem_tbl_take(test_id, {6, 6}, [], []),
    {[], _, {1, 2}} = open_mem_tbl_take(test_id, {1, 2}, [], []),

    ets:delete(Tid),
    ets:delete(ra_log_open_mem_tables),

    ok.

closed_mem_tbl_take_test() ->
    _ = ets:new(ra_log_closed_mem_tables, [named_table, bag]),
    Tid1 = ets:new(test_id, []),
    Tid2 = ets:new(test_id, []),
    M1 = erlang:unique_integer([monotonic, positive]),
    M2 = erlang:unique_integer([monotonic, positive]),
    true = ets:insert(ra_log_closed_mem_tables, {test_id, M1, 5, 7, Tid1}),
    true = ets:insert(ra_log_closed_mem_tables, {test_id, M2, 8, 10, Tid2}),
    Entries1 = [{5, 2, "5"}, {6, 2, "6"}, {7, 2, "7"}],
    Entries2 = [{8, 2, "8"}, {9, 2, "9"}, {10, 2, "10"}],
    % seed the mem tables
    [ets:insert(Tid1, E) || E <- Entries1],
    [ets:insert(Tid2, E) || E <- Entries2],

    {Entries1, _, undefined} = closed_mem_tbl_take(test_id, {5, 7}, [], []),
    {Entries2, _, undefined} = closed_mem_tbl_take(test_id, {8, 10}, [], []),
    {[{9, 2, "9"}], _, undefined} = closed_mem_tbl_take(test_id, {9, 9},
                                                        [], []),
    ok.

-endif.