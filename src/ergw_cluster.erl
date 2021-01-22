%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_cluster).

%% API
-export([validate_options/1, start/0]).

-include_lib("kernel/include/logger.hrl").

%%====================================================================
%% API
%%====================================================================

start() ->
    %% borrowed from riak_core:standard_join
    {ok, MyRing} = riak_core_ring_manager:get_raw_ring(),
    Singleton = ([node()] =:= riak_core_ring:all_members(MyRing)),
    ?LOG(info, "CLUSTER: ring members: ~p", [riak_core_ring:all_members(MyRing)]),

    case Singleton of
	true  -> start(application:get_env(ergw, cluster, #{}));
	false -> ok
    end.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(ClusterDefaults, [{enabled, false},
			  {initial_timeout, 60 * 1000},
			  {seed_nodes, {erlang, nodes, [known]}}]).

validate_options(Values) ->
    ergw_config:validate_options(fun validate_option/2, Values, ?ClusterDefaults, map).

validate_option(enabled, Value) when is_boolean(Value) ->
    Value;
validate_option(initial_timeout, Value)
  when is_integer(Value), Value > 0 ->
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
    Nodes = get_nodes(SeedNodes) -- [node()],
    Now = erlang:monotonic_time(millisecond),
    Deadline = Now + Timeout,
    case wait_for_nodes(Nodes, Now, Deadline) of
	{error, timeout} = Error ->
	    ?LOG(info, "cluster startup timed out, aborting"),
	    Error;
	{ok, Node} ->
	    join(Node);
	{error, _} = Error ->
	    ?LOG(info, "cluster startup failed with ~0p, aborting", [Error]),
	    Error
    end;
start(_) ->
    ok.

wait_for_nodes(_Nodes, Now, Deadline)
  when Now > Deadline ->
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
