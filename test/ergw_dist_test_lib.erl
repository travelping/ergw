%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_dist_test_lib).

-compile([{parse_transform, cut}]).

-define(ERGW_NO_IMPORTS, true).

-export([init_per_suite/1,
	 end_per_suite/1,
	 init_per_group/1,
	 end_per_group/1,
	 node_init_per_group/2,
	 node_end_per_group/2,
	 random_node/2,
	 random_node/4,
	 foreach_node/2,
	 foreach_node/4,
	 gtp_context_node/2]).
%%-export([wait_for_all_sx_nodes/0, reconnect_all_sx_nodes/1, stop_all_sx_nodes/0]
-export([reconnect_all_sx_nodes/1]).
-export([node_reconnect_all_sx_nodes/1]).
-export([match_dist_metric/9, match_metric/5]).
-export([wait4contexts/2]).

-include("ergw_test_lib.hrl").
-include_lib("stdlib/include/ms_transform.hrl").
-include_lib("kernel/include/logger.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").

-define(TIMEOUT, 2000).


%%%===================================================================
%%% Init/End helper
%%%===================================================================

mk_node_id(Id) ->
    binary_to_atom(
      iolist_to_binary(
	io_lib:format("node~w@127.0.0.1", [Id]))).

start_node({_Id, NodeName}) ->
    %% need to set the code path so the same modules are available in the slave
    CodePath = code:get_path(),
    PathFlag = "-pa " ++ lists:concat(lists:join(" ", CodePath)),
    Opts = [{monitor_master, true},
	    {erl_flags, PathFlag}],
    {ok, _} = ct_slave:start(NodeName, Opts),
    ok.

stop_node({_Id, NodeName}) ->
    ct_slave:stop(NodeName).

random_node(Config, Fun) ->
    Nodes = proplists:get_value(nodes, Config),
    {_, Node} = lists:nth(rand:uniform(length(Nodes)), Nodes),
    erpc:call(Node, Fun).

random_node(Config, Module, Function, Args) ->
    Nodes = proplists:get_value(nodes, Config),
    {_, Node} = lists:nth(rand:uniform(length(Nodes)), Nodes),
    erpc:call(Node, Module, Function, Args).

foreach_node(Config, Fun) ->
    Nodes = proplists:get_value(nodes, Config),
    ReqIds = [erpc:send_request(Node, fun() -> Fun(Id) end) || {Id, Node} <- Nodes],
    [erpc:wait_response(ReqId, infinity) || ReqId <- ReqIds].

foreach_node(Config, Module, Function, Args) ->
    Nodes = proplists:get_value(nodes, Config),
    ReqIds = [erpc:send_request(Node, Module, Function, [Id | Args]) ||
		 {Id, Node} <- Nodes],
    [erpc:wait_response(ReqId, infinity) || ReqId <- ReqIds].

init_per_suite(Config) ->
    NodeCnt = proplists:get_value(node_count, Config, 3),
    Nodes = [{Id, mk_node_id(Id)} || Id <- lists:seq(0, NodeCnt - 1)],
    lists:foreach(fun start_node/1, Nodes),

    %% needed because of rebar3 parse transform for ct:pal
    case code:ensure_loaded(cthr) of
	{module, _} ->
	    {Module, Binary, Filename} = code:get_object_code(cthr),
	    {_, NodeNames} = lists:unzip(Nodes),
	    erpc:multicall(NodeNames, code, load_binary, [Module, Filename, Binary]),
	    ok;
	_ ->
	    ok
    end,
    [{nodes, Nodes} | Config].

end_per_suite(Config) ->
    Nodes = proplists:get_value(nodes, Config, []),
    lists:foreach(fun stop_node/1, Nodes),
    ok.

build_cluster(Config) ->
    Nodes = proplists:get_value(nodes, Config),
    [Us|NodeNames] = [X || {_, X} <- Nodes],
    JoinRes = plists:map(fun (Node) -> join_cluster(10, Us, Node) end, NodeNames),
    ?match([], lists:filter(fun(X) -> X /= ok end, JoinRes)),
    ok = build_cluster_commit(10, Us).

join_cluster(0, _, _) ->
    {error, timeout};
join_cluster(Cnt, Us, Node) ->
    erpc:call(Node, application, which_applications, []),
    case (catch erpc:call(Node, riak_core, join, [Us])) of
	ok ->
	    ok;
	{error, node_still_starting} ->
	    ct:sleep(50),
	    join_cluster(Cnt - 1, Us, Node);
	Other ->
	    Other
    end.

build_cluster_commit(0, _Us) ->
    {error, timeout};
build_cluster_commit(Cnt, Us) ->
    Fun = fun() ->
		  riak_core_claimant:plan(),
		  riak_core_claimant:commit()
	  end,
    case erpc:call(Us, Fun) of
	{error, _} = _Err ->
	    ct:sleep(10),
	    build_cluster_commit(Cnt - 1, Us);
	ok -> ok
    end.

node_init_per_group(Id, Config) ->
    {_, AppCfg} = lists:keyfind(app_cfg, 1, Config),   %% let it crash if undefined

    [application:load(App) || App <- [cowboy, ergw, ergw_aaa, riak_core]],
    ergw_test_lib:load_config(per_node_config(Id, AppCfg)),
    {ok, _} = application:ensure_all_started(ergw),

    L1 = [{A, application:get_all_env(A)} || A <- [kernel, riak_core, ergw, ergw_aaa]],
    M1 = #{node => node()},
    maps:merge(M1, maps:from_list(L1)),

    ergw:wait_till_ready(),

    {ok, AppsCfg} = application:get_env(ergw_aaa, apps),
    {{aaa_cfg, Id}, AppsCfg}.

node_end_per_group(_Id, _Config) ->
    [application:stop(App) || App <- [ranch, cowboy, ergw, ergw_aaa, riak_core]],
    ok.

init_per_group(Config) ->
    {_, _} = lists:keyfind(app_cfg, 1, Config),   %% let it crash if undefined

    case proplists:get_value(upf, Config, true) of
	true ->
	    {ok, _} = ergw_test_sx_up:start('pgw-u01', proplists:get_value(pgw_u01_sx, Config)),
	    {ok, _} = ergw_test_sx_up:start('pgw-u02', proplists:get_value(pgw_u02_sx, Config)),
	    {ok, _} = ergw_test_sx_up:start('sgw-u', proplists:get_value(sgw_u_sx, Config)),
	    {ok, _} = ergw_test_sx_up:start('tdf-u', proplists:get_value(tdf_u_sx, Config));
	_ ->
	    ok = ergw_test_sx_up:stop('pgw-u01'),
	    ok = ergw_test_sx_up:stop('pgw-u02'),
	    ok = ergw_test_sx_up:stop('sgw-u'),
	    ok = ergw_test_sx_up:stop('tdf-u')
    end,

    NodeInit = foreach_node(Config, ?MODULE, node_init_per_group, [Config]),
    build_cluster(Config),
    MasterCfg = ergw_test_lib:init_ets(Config),

    lists:foldl(
      fun({response, {K, _} = KV}, Acc) ->
	      lists:keystore(K, 1, Acc, KV)
      end, MasterCfg, NodeInit).

end_per_group(Config) ->
    ok = ergw_test_sx_up:stop('pgw-u01'),
    ok = ergw_test_sx_up:stop('pgw-u02'),
    ok = ergw_test_sx_up:stop('sgw-u'),
    ok = ergw_test_sx_up:stop('tdf-u'),

    foreach_node(Config, ?MODULE, node_end_per_group, [Config]),
    ?config(table_owner, Config) ! stop,
    ok.

%%%===================================================================

-define(NODE_OPTS, [%%{[riak_core, ring_state_dir], riak_node_dir},
		    {[kernel, logger, '_', config, file], log},
		    {[riak_core, handoff_ip], ip},
		    {[ergw, node_id], node_id},
		    {[ergw, sockets, '_', ip], ip}
		   ]).

make_ip(Id, {A, B, C, D}) ->
    {A, B, C, D + Id};
make_ip(Id, {A, B, C, D, E, F, G, H}) ->
    {A, B, C, D, E, F, G, H + Id}.

gen_per_node_opt(_, log, V) ->
    lists:flatten(
      io_lib:format("~s.~s", ([node(), V])));
gen_per_node_opt(_, riak_node_dir, _) ->
    filename:join([".", "data", node()]);
gen_per_node_opt(Id, node_id, V) ->
    lists:flatten(
      io_lib:format("node~2.10.0w.~s", [Id, V]));
gen_per_node_opt(Id, ip, IP) ->
    make_ip(Id, IP).

cfg_update_with(Key, Fun, M) when is_map(M), is_map_key(Key, M) ->
    maps:update_with(Key, Fun, M);
cfg_update_with(Key, Fun, L) when is_list(L) ->
    lists:keystore(Key, 1, L, {Key, Fun(proplists:get_value(Key, L))});
cfg_update_with(_, _, V) ->
    V.

per_node_opt(Id, Type, [Key], Cfg) ->
    cfg_update_with(Key, gen_per_node_opt(Id, Type, _), Cfg);
per_node_opt(Id, Type, ['_'|T], Cfg) when is_map(Cfg) ->
    maps:map(
      fun(_K, V) -> per_node_opt(Id, Type, T, V) end, Cfg);
per_node_opt(Id, Type, ['_'|T], Cfg) when is_list(Cfg) ->
    lists:map(
      fun({K, V}) -> {K, per_node_opt(Id, Type, T, V)};
	 ({K1, K2, K3, V}) -> {K1, K2, K3, per_node_opt(Id, Type, T, V)}
      end, Cfg);
per_node_opt(Id, Type, [H|T], Cfg) ->
    cfg_update_with(H, per_node_opt(Id, Type, T, _), Cfg).

per_node_opt(Id, {Path, Type}, Cfg) ->
    per_node_opt(Id, Type, Path, Cfg).

per_node_config(Id, AppCfg) ->
    lists:foldl(per_node_opt(Id, _, _), AppCfg, ?NODE_OPTS).

node_reconnect_all_sx_nodes(_Id) ->
    SxNodes = supervisor:which_children(ergw_sx_node_sup),
    [ergw_sx_node:test_cmd(Pid, reconnect) || {_, Pid, _, _} <- SxNodes, is_pid(Pid)],
    timer:sleep(10),
    sx_nodes_up(length(SxNodes), 20),
    ok.

sx_nodes_up(_N, 0) ->
    Got = ergw_sx_node_reg:available(),
    Expected = supervisor:which_children(ergw_sx_node_sup),
    {error, #{node => node(), expected => Expected, got => Got}};
sx_nodes_up(N, Cnt) ->
    case ergw_sx_node_reg:available() of
	Nodes when map_size(Nodes) =:= N ->
	    ok;
	_Nodes ->
	    timer:sleep(50),
	    sx_nodes_up(N, Cnt - 1)
    end.

reconnect_all_sx_nodes(Config) ->
    foreach_node(Config, ?MODULE, node_reconnect_all_sx_nodes, []),
    ok.

%%%===================================================================
%%% Metric helpers
%%%===================================================================

match_dist_metric(Type, Name, LabelValues, Cond, Expected, File, Line, Cnt, Config) ->
    Nodes = proplists:get_value(nodes, Config),
    {_, NodeNames} = lists:unzip(Nodes),
    Res = erpc:multicall(NodeNames, ergw_dist_test_lib, match_metric,
		       [Type, Name, LabelValues, Expected, Cnt]),
    Fails = lists:filter(fun(X) -> X /= {ok, ok} end, Res),
    case Cond of
	all when length(Fails) =:= 0 -> ok;
	any when length(Fails) =/= length(Nodes) ->
	    ok;
	one when length(Nodes) - length(Fails) =:= 1 ->
	    ok;
	none when length(Fails) =:= length(Nodes) ->
	    ok;
	_ ->
	    ct:pal("METRIC VALUE MISMATCH(~s:~b)~nExpected: ~p~nFails:   ~p~n",
		   [File, Line, Expected, Fails]),
	    error(badmatch)
    end.

match_metric(Type, Name, LabelValues, Expected, Cnt) ->
    case get_metric(Type, Name, LabelValues, undefined) of
	Expected ->
	    ok;
	_ when Cnt > 0 ->
	    timer:sleep(10),
	    match_metric(Type, Name, LabelValues, Expected, Cnt - 1);
	Actual ->
	    {error, #{node => node(), actual => Actual}}
    end.

get_metric(Type, Name, LabelValues, Default) ->
    case Type:value(Name, LabelValues) of
	undefined -> Default;
	Value -> Value
    end.

%%%===================================================================
%%% GTP entity and context function
%%%===================================================================

gtp_context_node(Id, #gtpc{remote_ip = IP} = GtpC) ->
    GtpC#gtpc{remote_ip = make_ip(Id, IP)}.

%%%===================================================================
%%% Retrieve outstanding request from gtp_context_reg
%%%===================================================================

wait4contexts(Cnt) ->
    case ergw_test_lib:active_contexts() of
	0 -> ok;
	Actual ->
	    if Cnt > 100 ->
		    timer:sleep(10),
		    wait4contexts(Cnt - 10);
	       true ->
		    {error, #{node => node(), actual => Actual}}
	    end
    end.

wait4contexts(Cnt, Config) ->
    Nodes = proplists:get_value(nodes, Config),
    {_, NodeNames} = lists:unzip(Nodes),
    Res = erpc:multicall(NodeNames, fun() -> wait4contexts(Cnt) end),
    Fails = lists:filter(fun(X) -> X /= {ok, ok} end, Res),
    case Fails of
	[] -> ok;
	_ ->
	    ct:fail("timeout, waiting for contexts to be deleted, left over ~p", [Fails])
    end.
