%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_cluster).

-compile({parse_transform, do}).

%% API
-export([validate_options/1, start/0, stop/0, get_ra_node_id/0]).

-include_lib("kernel/include/logger.hrl").

%%====================================================================
%% API
%%====================================================================

start() ->
    %% borrowed from riak_core:standard_join
    {ok, MyRing} = riak_core_ring_manager:get_raw_ring(),
    Singleton = ([node()] =:= riak_core_ring:all_members(MyRing)),
    ?LOG(info, "CLUSTER: ring members: ~p", [riak_core_ring:all_members(MyRing)]),

    do([error_m ||
	   case Singleton of
	       true  -> start(application:get_env(ergw_core, cluster, #{}));
	       false -> ok
	   end,
	   start_raft()
       ]).

stop() ->
    leave_ra_cluster(10),
    ok.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(ClusterDefaults, [{enabled, false},
			  {initial_timeout, 60 * 1000},
			  {release_cursor_every, 0},
			  {seed_nodes, {erlang, nodes, [known]}}]).

validate_options(Values) ->
    ergw_core_config:validate_options(fun validate_option/2, Values, ?ClusterDefaults).

validate_option(enabled, Value) when is_boolean(Value) ->
    Value;
validate_option(initial_timeout, Value)
  when is_integer(Value), Value > 0 ->
    Value;
validate_option(release_cursor_every, Value)
  when is_integer(Value) ->
    Value;
validate_option(seed_nodes, {M, F, A} = Value)
  when is_atom(M), is_atom(F), is_list(A) ->
    Value;
validate_option(seed_nodes, Nodes) when is_list(Nodes) ->
    lists:foreach(
      fun(Node) when is_atom(Node) -> ok;
	 (Node) ->
	      throw({error, {options, {seed_nodes, Node}}})
      end, Nodes),
    Nodes;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% Internal functions
%%%===================================================================

start(#{enabled := true, seed_nodes := SeedNodes, initial_timeout := Timeout}) ->
    case net_kernel:epmd_module() of
	k8s_epmd ->
	    {ok, _} = application:ensure_all_started(k8s_dist),
	    ok;
	_ ->
	    ok
    end,

    Nodes = get_nodes(SeedNodes) -- [node()],
    Now = erlang:monotonic_time(millisecond),
    Deadline = Now + Timeout,

    do([error_m ||
	   Node <- wait_for_nodes(Nodes, Now, Deadline),
	   join(Node)
       ]);
start(_) ->
    ok.

wait_for_nodes(_Nodes, Now, Deadline)
  when Now > Deadline ->
    ?LOG(info, "RIAK cluster startup timed out, aborting"),
    {error, timeout};
wait_for_nodes(Nodes, _, Deadline) ->
    case lists:filter(fun(Node) -> net_adm:ping(Node) =:= pong end, Nodes) of
	[] ->
	    ?LOG(info, "CLUSTER: no other nodes up"),
	    timer:sleep(100),
	    Now = erlang:monotonic_time(millisecond),
	    wait_for_nodes(Nodes, Now, Deadline);
	UpNodes ->
	    ?LOG(info, "CLUSTER: UpNodes: ~p", [UpNodes]),
	    {ok, hd(lists:usort(UpNodes))}
    end.

get_nodes(Nodes) when is_list(Nodes) ->
    Nodes;
get_nodes({M, F, A} = MFA) ->
    try erlang:apply(M, F, A) of
	Nodes when is_list(Nodes) ->
	    Nodes;
	Other ->
	    ?LOG(debug, #{where => get_nodes, type => error, mfa => MFA, return => Other}),
	    []
    catch
	Class:Error:St ->
	    ?LOG(debug, #{where => get_nodes, type => error, mfa => MFA,
			  class => Class, error => Error, stack => St}),
	    []
    end.

join(Node) ->
    case riak_core:join(Node) of
	{error,node_still_starting} ->
	    timer:sleep(100),
	    join(Node);
	{error, unable_to_get_join_ring} ->
	    timer:sleep(100),
	    join(Node);
	{error, not_single_node} ->
	    ok;
	ok ->
	    plan_and_commit()
    end.

plan_and_commit() ->
    {ok, MyRing} = riak_core_ring_manager:get_raw_ring(),
    MembersJoining = ([] =/= riak_core_ring:members(MyRing, [joining])),

    case riak_core_claimant:plan() of
	{ok, [], []} when MembersJoining ->
	    timer:sleep(100),
	    plan_and_commit();
	{ok, _, _} ->
	    commit();
	{error, ring_not_ready} ->
	    timer:sleep(100),
	    plan_and_commit();
	{error, _} = Error ->
	    Error
    end.

commit() ->
    case riak_core_claimant:commit() of
	ok ->
	    ok;
	{error, nothing_planned} ->
	    %% other node was faster with commit
	    ok;
	{error, plan_changed} ->
	    %% try again
	    timer:sleep(100),
	    plan_and_commit();
	{error, ring_not_ready} ->
	    timer:sleep(100),
	    commit();
	Other ->
	    ?LOG(info, "cluster join failed with ~0p, aborting", [Other]),
	    Other
    end.

%%%===================================================================
%%% RAFT cluster
%%%===================================================================

get_ra_node_id() ->
    case persistent_term:get(ra_node_id, undefined) of
	undefined ->
	    NodeId = ergw_core:get_node_id(),
	    Id = binary_to_atom(
		   iolist_to_binary(
		     io_lib:format("$ra-~s", [NodeId]))),
	    persistent_term:get(ra_node_id, Id),
	    Id;
	RaId ->
	    RaId
    end.

start_ra_cluster(cluster, ClusterId, Machine, ServerId) ->
    ra:start_cluster(ClusterId, Machine, [ServerId]);
start_ra_cluster(server, ClusterId, Machine, ServerId) ->
    ra:start_server(ClusterId, ServerId, Machine, []).

start_ra_cluster(Mode, ServerId) ->
    ServerId = {get_ra_node_id(), node()},
    ClusterId = ergw_core,
    Config = #{},
    Machine = {module, ergw_global, Config},

    case start_ra_cluster(Mode, ClusterId, Machine, ServerId) of
	{ok, _, _} -> ok;
	Other      -> Other
    end.

join_ra_cluster(Leader) ->
    ServerId = {get_ra_node_id(), node()},
    do([error_m ||
	   start_ra_cluster(server, ServerId),
	   add_ra_member(Leader, ServerId),
	   gtp_config:sync()
       ]).

add_ra_member(Leader, ServerId) ->
    case ra:add_member(Leader, ServerId) of
	{error, cluster_change_not_permitted} ->
	    timer:sleep(100),
	    add_ra_member(Leader, ServerId);
	{ok, _, _} ->
	    ok;
	Other      -> Other
    end.

leave_ra_cluster(0) ->
    {error, timeout};
leave_ra_cluster(Cnt) ->
    NodeId = get_ra_node_id(),
    case whereis(NodeId) of
	Pid when is_pid(Pid) ->
	    case (catch ra:leave_and_delete_server({NodeId, node()})) of
		ok ->
		    ok;
		{error, Error} when Error == noproc; Error == cluster_change_not_permitted ->
		    timer:sleep(100),
		    leave_ra_cluster(Cnt - 1);
		{'EXIT',_} ->
		    timer:sleep(100),
		    leave_ra_cluster(Cnt - 1);
		Other ->
		    ?LOG(error, "ra leave failed with ~p", [Other]),
		    Other
	    end;
	_ ->
	    ok
    end.

query_ra_cluster() ->
    ServerIds =
	[X || {ok, {NId, _} = X} <- erpc:multicall(nodes(), fun() -> {get_ra_node_id(), node()} end), is_atom(NId)],
    query_ra_cluster(ServerIds).

query_ra_cluster([]) ->
    standalone;
query_ra_cluster([H|T]) ->
    case ra:members(H) of
	{ok, _Members, Leader} ->
	    {ok, Leader};
	_ ->
	    query_ra_cluster(T)
    end.

start_raft() ->
    global:trans({'$ergw', self()}, fun start_raft_sync/0).

start_raft_sync() ->
    case query_ra_cluster() of
	{ok, Leader} ->
	    join_ra_cluster(Leader);
	_ ->
	    do([error_m ||
		   start_ra_cluster(cluster, {get_ra_node_id(), node()}),
		   gtp_config:init()
	       ])
    end.
