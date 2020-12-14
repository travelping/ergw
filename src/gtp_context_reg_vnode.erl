%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_reg_vnode).

-behaviour(riak_core_vnode).

%% API
-export([start_vnode/1, ping/0, ping/1, get/1]).

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

-ignore_xref([start_vnode/1, ping/0, ping/1, get/1]).

-record(state, {partition}).

-define(N, 3).
-define(W, 2).
-define(TIMEOUT, 5000).

-define(VMASTER, gtp_context_reg_vnode_master).
-define(SERVICE, ergw).

%%%===================================================================
%%% API
%%%===================================================================

start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

ping() ->
    ping(term_to_binary(os:timestamp())).

ping(Key) ->
    DocIdx = riak_core_util:chash_key({<<"ping">>, Key}),
    % ask for 1 vnode index to send this request to, change N to get more
    % vnodes, for example for replication
    N = 1,
    PrefList = riak_core_apl:get_primary_apl(DocIdx, N, ?SERVICE),
    [{IndexNode, _Type}] = PrefList,
    riak_core_vnode_master:sync_spawn_command(IndexNode, ping, ?VMASTER).

get(Key) ->
    DocIdx = riak_core_util:chash_key(Key),
    logger:info("Primary APL: ~p", [riak_core_apl:get_primary_apl(DocIdx, ?N, ?SERVICE)]),
    logger:info("APL: ~p", [riak_core_apl:get_apl(DocIdx, ?N, ?SERVICE)]),

    run_quorum(Key, get, #{}).

%%%===================================================================
%%% riak_core_vnode callbacks
%%%===================================================================

init([Partition]) ->
    {ok, #state {partition = Partition}}.

%% Sample command: respond to a ping
handle_command(ping, _Sender, State) ->
    {reply, {pong, node(), State#state.partition}, State};

handle_command(get, _Sender, State) ->
    {reply, {pong, node(), State#state.partition}, State};

handle_command(Message, _Sender, State) ->
    logger:warning("unhandled_command ~p", [Message]),
    {noreply, State}.

handle_handoff_command(_Message, _Sender, State) ->
    {noreply, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(_Data, State) ->
    {reply, ok, State}.

encode_handoff_item(_ObjectName, _ObjectValue) ->
    <<>>.

handle_overload_command(_, _, _) ->
    ok.

handle_overload_info(_, _Idx) ->
    ok.

is_empty(State) ->
    {true, State}.

delete(State) ->
    {ok, State}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

run_quorum(Key, Command, Opts0) ->
    Opts = maps:merge(#{w => ?W, wait_timeout_ms => ?TIMEOUT}, Opts0),
    N = maps:get(n, Opts, ?N),
    ReqId = make_ref(),
    riak_core_quorum_statem:quorum_request(Key, Command, N, ?SERVICE, ?VMASTER,
					   Opts#{ref => ReqId, from => self()}),
    receive
	{ReqId, Val} -> Val
    end.
