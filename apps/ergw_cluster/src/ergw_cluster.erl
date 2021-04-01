%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_cluster).

-behavior(gen_statem).

-compile({parse_transform, do}).

%% API
-export([start_link/0, start/1,
	 validate_options/1,
	 get_ra_node_id/0,
	 wait_till_ready/0,
	 is_ready/0]).

-ignore_xref([start_link/0, validate_options/1]).

-ifdef(TEST).
-export([start/2, wait_till_running/0, is_running/0]).
-endif.

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).

start(Config) ->
    start(Config, infinity).

start(Config, Timeout) ->
    Cnf = validate_options(Config),
    gen_statem:call(?SERVER, {start, Cnf}, Timeout).

wait_till_ready() ->
    ok = gen_statem:call(?SERVER, wait_till_ready, infinity).

is_ready() ->
    gen_statem:call(?SERVER, is_ready).

-ifdef(TEST).
wait_till_running() ->
    ok = gen_statem:call(?SERVER, wait_till_running, infinity).

is_running() ->
    gen_statem:call(?SERVER, is_running).
-endif.

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
%%% gen_statem callbacks
%%%===================================================================

callback_mode() -> [handle_event_function].

init([]) ->
    process_flag(trap_exit, true),
    Now = erlang:monotonic_time(),

    Pid = proc_lib:spawn_link(fun startup/0),
    {ok, startup, #{init => Now, startup => Pid}}.

handle_event({call, From}, wait_till_ready, State, _Data)
  when State =:= ready; State =:= running ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, _From}, wait_till_ready, _State, _Data) ->
    {keep_state_and_data, [postpone]};

handle_event({call, From}, wait_till_running, running, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, _From}, wait_till_running, _State, _Data) ->
    {keep_state_and_data, [postpone]};

handle_event({call, From}, is_ready, State, _Data) ->
    Reply = {reply, From, State == ready orelse State == running},
    {keep_state_and_data, [Reply]};

handle_event({call, From}, is_running, State, _Data) ->
    Reply = {reply, From, State == running},
    {keep_state_and_data, [Reply]};

handle_event({call, From}, {start, Config}, ready, Data) ->
    application:set_env([{ergw_cluster, maps:to_list(Config)}]),
    start_cluster(Config),
    {next_state, running, Data#{config => Config}, [{reply, From, ok}]};
handle_event({call, From}, {start, _}, running, _) ->
    {keep_state_and_data, [{reply, From, {error, already_started}}]};
handle_event({call, _}, {start, _}, _State, _) ->
    {keep_state_and_data, [postpone]};

handle_event(info, {'EXIT', Pid, ok}, startup,
	     #{init := Now, startup := Pid} = Data) ->
    ?LOG(info, "ergw_core: ready to process requests, cluster started in ~w ms",
	 [erlang:convert_time_unit(erlang:monotonic_time() - Now, native, millisecond)]),
    {next_state, ready, maps:remove(startup, Data)};

handle_event(info, {'EXIT', Pid, Reason}, startup, #{startup := Pid}) ->
    ?LOG(critical, "cluster support failed to start with ~0p", [Reason]),
    {stop, {shutdown, Reason}};

handle_event(Event, Info, _State, _Data) ->
    ?LOG(error, "~p: ~w: handle_event(~p, ...): ~p", [self(), ?MODULE, Event, Info]),
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    stop_cluster(),
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

startup() ->
    %% undocumented, see stdlib's shell.erl
    case init:notify_when_started(self()) of
	started ->
	    ok;
	_ ->
	    init:wait_until_started()
    end,
    exit(ok).

start_cluster(Config) ->
    %% borrowed from riak_core:standard_join
    {ok, MyRing} = riak_core_ring_manager:get_raw_ring(),
    Singleton = ([node()] =:= riak_core_ring:all_members(MyRing)),
    ?LOG(info, "CLUSTER: ring members: ~p", [riak_core_ring:all_members(MyRing)]),

    do([error_m ||
	   case Singleton of
	       true  -> do_start_cluster(Config);
	       false -> ok
	   end,
	   start_raft()
       ]).

stop_cluster() ->
    leave_ra_cluster(10),
    ok.

do_start_cluster(#{enabled := true, seed_nodes := SeedNodes, initial_timeout := Timeout}) ->
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
do_start_cluster(_) ->
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
    application:get_env(ergw_cluster, ra_node_id, '$ra-ergw-cluster').

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
