%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_path_db_vnode).

-behaviour(riak_core_vnode).

%% API
-export([start_vnode/1, ping/0, ping/1, get/1, put/2, all/0, restart_counter/2]).

%% riak_core_vnode callbacks
-export([init/1,
	 terminate/2,
	 handle_command/3,
	 is_empty/1,
	 delete/1,
	 handle_handoff_command/3,
	 handoff_starting/2,
	 handoff_cancelled/1,
	 handoff_finished/2,
	 handle_handoff_data/2,
	 encode_handoff_item/2,
	 handle_overload_command/3,
	 handle_overload_info/2,
	 handle_coverage/4,
	 handle_exit/3]).

-compile({no_auto_import,[put/2]}).
-ignore_xref([start_vnode/1, ping/0, ping/1]).
-ignore_xref([get/2, put/3, delete/2, delete/3, all/1]).

-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").

-record(state, {partition, tid}).

-define(N, 3).
-define(W, 2).
-define(TIMEOUT, 5000).

-define(VMASTER, gtp_path_db_vnode_master).
-define(SERVICE, ergw).

%%%===================================================================
%%% API
%%%===================================================================

start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

ping() ->
    ping(term_to_binary(os:timestamp())).

ping(Key) ->
    DocIdx = riak_core_util:chash_key({<<"path">>, Key}),
    % ask for 1 vnode index to send this request to, change N to get more
    % vnodes, for example for replication
    N = 1,
    PrefList = riak_core_apl:get_primary_apl(DocIdx, N, ?SERVICE),
    [{IndexNode, _Type}] = PrefList,
    riak_core_vnode_master:sync_spawn_command(IndexNode, ping, ?VMASTER).

get(Key) ->
    RKey = key(Key),
    run_quorum(RKey, {get, Key}, #{}).

put(Key, Value) ->
    RKey = key(Key),
    run_quorum(RKey, {put, Key, Value}, #{}).

%% delete(Key) ->
%%     RKey = key(Key),
%%     run_quorum(RKey, {delete, Key}, #{}).

%% delete(Key, Value) ->
%%     RKey = key(Key),
%%     run_quorum(RKey, {delete, Key, Value}, #{}).

restart_counter(Key, Value) ->
    RKey = key(Key),
    run_quorum(RKey, {restart_counter, Key, Value}, #{}).

all() ->
    run_coverage(all, #{}).

%%%===================================================================
%%% riak_core_vnode callbacks
%%%===================================================================

init([Partition]) ->
    TID = ets:new(?MODULE, [set, {write_concurrency, false}, {read_concurrency, false}]),
    {ok, #state{partition = Partition, tid = TID}}.

%% Sample command: respond to a ping
handle_command(ping, _Sender, State) ->
    {reply, {pong, node(), State#state.partition}, State};

handle_command({get, Key}, _Sender, State) ->
    Location = {State#state.partition, node()},
    Res = case ets:lookup(State#state.tid, {Key}) of
	      [] -> {error, not_found};
	      [{_, V}] -> {ok, V}
	  end,
    {reply, {Location, Res}, State};

handle_command({put, Key, Value}, _Sender, State) ->
    Location = {State#state.partition, node()},
    put(Key, Value, State),
    {reply, {Location, ok}, State};

handle_command({delete, Key}, _Sender, State) ->
    Location = {State#state.partition, node()},
    true = ets:delete(State#state.tid, {Key}),
    {reply, {Location, ok}, State};

handle_command({delete, Key, Value}, _Sender, State) ->
    Location = {State#state.partition, node()},
    true = ets:delete_object(State#state.tid, {{Key}, Value}),
    {reply, {Location, ok}, State};

handle_command({restart_counter, Key, Value}, _Sender, State) ->
    Location = {State#state.partition, node()},
    Obj = ets:lookup(State#state.tid, {Key}),
    Res = cas_restart_counter(Key, Value, Obj, State),
    {reply, {Location, Res}, State};

handle_command(Message, _Sender, State) ->
    logger:warning("unhandled_command ~p", [Message]),
    {noreply, State}.

handle_handoff_command(?FOLD_REQ{foldfun = FoldFun, acc0 = Acc0}, _Sender, State) ->
    logger:info("fold req ~p", [State#state.partition]),
    KvFoldFun = fun ({Key, Val}, AccIn) ->
			logger:info("fold fun ~p: ~p", [Key, Val]),
			FoldFun(Key, Val, AccIn)
		end,
    AccFinal = ets:foldl(KvFoldFun, Acc0, State#state.tid),
    {reply, AccFinal, State};

handle_handoff_command(Message, _Sender, State) ->
    logger:warning("handoff command ~p, ignoring", [Message]),
    {noreply, State}.

handoff_starting(TargetNode, State) ->
    logger:info("handoff starting ~p: ~p", [State#state.partition, TargetNode]),
    {true, State}.

handoff_cancelled(State) ->
    logger:info("handoff cancelled ~p", [State#state.partition]),
    {ok, State}.

handoff_finished(TargetNode, State) ->
    logger:info("handoff finished ~p: ~p", [State#state.partition, TargetNode]),
    {ok, State}.

handle_handoff_data(Bin, State) ->
    Data = binary_to_term(Bin),
    logger:info("handoff data received ~p", [Data]),
    true = ets:insert(State#state.tid, Data),
    {reply, ok, State}.

encode_handoff_item(Key, Value) ->
    term_to_binary({Key, Value}).

is_empty(State) ->
    IsEmpty = (ets:first(State#state.tid) =:= '$end_of_table'),
    logger:info("is_empty ~p: ~p", [State#state.partition, IsEmpty]),
    {IsEmpty, State}.

delete(State) ->
    logger:info("delete ~p", [State#state.partition]),
    true = ets:delete(State#state.tid),
    {ok, State#state{tid = undefined}}.

handle_overload_command(_, _, _) ->
    ok.

handle_overload_info(_, _Idx) ->
    ok.

handle_coverage(all, _KeySpaces, _Sender, State) ->
    Res = ets:tab2list(State#state.tid),
    {reply, Res, State};
handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

bin(V) when is_binary(V) -> V;
bin(V) -> term_to_binary(V).

key(Key) ->
    {<<"path">>, bin(Key)}.

run_quorum(Key, Command, Opts0) ->
    Opts = maps:merge(#{w => ?W, wait_timeout_ms => ?TIMEOUT}, Opts0),
    N = maps:get(n, Opts, ?N),
    ReqId = make_ref(),
    riak_core_quorum_statem:quorum_request(Key, Command, N, ?SERVICE, ?VMASTER,
					   Opts#{ref => ReqId, from => self()}),
    receive
	{ReqId, Val} -> Val
    end.

run_coverage(Command, Opts0) ->
    Defaults = #{pvc => 3, vnode_selector => allup, wait_timeout_ms => ?TIMEOUT},
    Opts = maps:merge(Defaults, Opts0),
    N = maps:get(n, Opts, ?N),
    riak_core_coverage_statem:coverage_request(Command, N, ?SERVICE, ?VMASTER, Opts).

node_down(_Key) ->
    ok.

put(Key, Value, #state{tid = TID}) ->
    ets:insert(TID, {{Key}, Value}).

cas_restart_counter(Key, Counter, [], State) ->
    Obj = #{restart_counter => undefined, state => init},
    cas_restart_counter_4(Key, Counter, Obj, State);
cas_restart_counter(Key, Counter, [{_, Obj}], State) ->
    cas_restart_counter_4(Key, Counter, Obj, State).

cas_restart_counter_4(Key, Counter, Obj, State) ->
    case update_restart_counter(Counter, Obj) of
	no ->
	    {ok, Counter};
	{initial, New} ->
	    put(Key, Obj#{restart_counter => Counter}, State),
	    {ok, New};
	{peer_restart, New} ->
	    put(Key, Obj#{restart_counter => Counter}, State),
	    node_down(Key),
	    {ok, New}
    end.

%% 3GPP TS 23.007, Sect. 18 GTP-C-based restart procedures:
%%
%% The GTP-C entity that receives a Recovery Information Element in an Echo Response
%% or in another GTP-C message from a peer, shall compare the received remote Restart
%% counter value with the previous Restart counter value stored for that peer entity.
%%
%%   - If no previous value was stored the Restart counter value received in the Echo
%%     Response or in the GTP-C message shall be stored for the peer.
%%
%%   - If the value of a Restart counter previously stored for a peer is smaller than
%%     the Restart counter value received in the Echo Response message or the GTP-C
%%     message, taking the integer roll-over into account, this indicates that the
%%     entity that sent the Echo Response or the GTP-C message has restarted. The
%%     received, new Restart counter value shall be stored by the receiving entity,
%%     replacing the value previously stored for the peer.
%%
%%   - If the value of a Restart counter previously stored for a peer is larger than
%%     the Restart counter value received in the Echo Response message or the GTP-C message,
%%     taking the integer roll-over into account, this indicates a possible race condition
%%     (newer message arriving before the older one). The received new Restart counter value
%%     shall be discarded and an error may be logged

-define(SMALLER(S1, S2), ((S1 < S2 andalso (S2 - S1) < 128) orelse (S1 > S2 andalso (S1 - S2) > 128))).

update_restart_counter(Counter, #{restart_counter := undefined}) ->
    {initial, Counter};
update_restart_counter(Counter, #{restart_counter := Counter}) ->
    no;
update_restart_counter(New, #{restart_counter := Old})
  when ?SMALLER(Old, New) ->
    {peer_restart, New};
update_restart_counter(New, #{restart_counter := Old})
  when not ?SMALLER(Old, New) ->
    no.
