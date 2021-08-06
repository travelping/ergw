%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_test_lib).

-compile({parse_transform, cut}).

-define(ERGW_NO_IMPORTS, true).

-export([lib_init_per_group/1,
	 lib_end_per_group/1,
	 update_app_config/3,
	 load_config/1,
	 init_apps/1]).
-export([meck_init/1,
	 meck_init_hut_handle_request/1,
	 meck_reset/1,
	 meck_unload/1,
	 meck_validate/1]).
-export([init_seq_no/2,
	 gtp_context/1, gtp_context/2, gtp_context/3,
	 gtp_context_inc_seq/1,
	 gtp_context_inc_restart_counter/1,
	 gtp_context_new_teids/1, gtp_context_new_teids/3,
	 make_error_indication_report/1]).
-export([start_gtpc_server/1, start_gtpc_server/2,
	 stop_gtpc_server/1, stop_gtpc_server/0,
	 wait_for_all_sx_nodes/0, reconnect_all_sx_nodes/0, stop_all_sx_nodes/0,
	 make_gtp_socket/1, make_gtp_socket/2,
	 send_pdu/2, send_pdu/3,
	 send_recv_pdu/2, send_recv_pdu/3, send_recv_pdu/4,
	 recv_pdu/2, recv_pdu/3, recv_pdu/4]).
-export([gtpc_server_init/2]).
-export([pretty_print/1]).
-export([set_cfg_value/3, add_cfg_value/3]).
-export([outstanding_requests/0, wait4tunnels/1, wait4contexts/1,
	 active_contexts/0, hexstr2bin/1]).
-export([match_metric/7, get_metric/4]).
-export([has_ipv6_test_config/0]).
-export([query_usage_report/1]).
-export([match_map/4, maps_key_length/2, maps_recusive_merge/2]).
-export([init_ets/1]).
-export([set_online_charging/1, set_apn_key/2, load_aaa_answer_config/1, set_path_timers/1]).
-export([plmn/2, cgi/2, cgi/4, sai/2, sai/4, rai/3, rai/4,
	 tai/2, tai/3, ecgi/2, ecgi/3, lai/2, lai/3,
	 macro_enb/2, macro_enb/3, ext_macro_enb/2, ext_macro_enb/3]).

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

ets_owner() ->
    receive
	stop ->
	    exit(normal);
	_ ->
	    ets_owner()
    end.

init_ets(Config) ->
    Pid = spawn(fun ets_owner/0),
    TabId = ets:new(?MODULE, [set, public, named_table, {heir, Pid, []}]),
    ets:insert(TabId, [{{?MODULE, seq_no}, 1},
		       {restart_counter, 1},
		       {teid, 1}]),
    [{table, TabId}, {table_owner, Pid} | Config].

lib_init_per_group(Config0) ->
    {_, AppCfg} = lists:keyfind(app_cfg, 1, Config0),   %% let it crash if undefined

    Config = init_ets(Config0),
    [application:load(App) || App <- [cowboy, ergw_core, ergw_aaa]],
    meck_init(Config),
    load_config(AppCfg),
    {ok, _} = application:ensure_all_started(ergw_core),
    ergw_cluster:wait_till_ready(),
    ok = ergw_cluster:start([{enabled, false}]),
    ergw_cluster:wait_till_running(),

    init_apps(AppCfg),

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
    {ok, AppsCfg} = application:get_env(ergw_aaa, apps),
    [{aaa_cfg, AppsCfg} |Config].

lib_end_per_group(Config) ->
    meck_unload(Config),
    ok = ergw_test_sx_up:stop('pgw-u01'),
    ok = ergw_test_sx_up:stop('pgw-u02'),
    ok = ergw_test_sx_up:stop('sgw-u'),
    ok = ergw_test_sx_up:stop('tdf-u'),
    ?config(table_owner, Config) ! stop,
    [application:stop(App) || App <- [ranch, cowboy, ergw_core, ergw_aaa, ergw_cluster]],
    ok.

init_apps(AppCfg) ->
    init_app(ergw_aaa, fun ergw_aaa_init/1, AppCfg),
    init_app(ergw_core, fun ergw_core_init/1, AppCfg),
    ok.

clear_app_env(App)
  when App =:= ergw_core;
       App =:= ergw_aaa ->
    [application:unset_env(App, Par) || {Par, _} <- application:get_all_env(App)];
clear_app_env(_) ->
    ok.

load_config(AppCfg) when is_list(AppCfg) ->
    lists:foreach(
      fun({App, _}) when App =:= ergw_core; App =:= ergw_aaa ->
	      clear_app_env(App),
	      ok;
	 ({App, Settings}) when is_list(Settings) ->
	      clear_app_env(App),
	      lists:foreach(
		fun({logger, V})
		      when App =:= kernel, is_list(V) ->
			lists:foreach(
			  fun({handler, HandlerId, Module, HandlerConfig})
				when is_map(HandlerConfig)->
				  case logger:update_handler_config(HandlerId, HandlerConfig) of
				      {error, {not_found, cth_log_redirect}} ->
					  ok;
				      {error, {not_found, _}} ->
					  logger:add_handler(HandlerId, Module, HandlerConfig);
				      Other ->
					  Other
				  end,
				  ok;
			     (Cfg) ->
				  ct:fail("unknown logger config  ~p", [Cfg])
			  end, V),
			ok;
		   ({K,V}) ->
			application:set_env(App, K, V)
		end, Settings);
	 ({App, Settings}) when is_map(Settings) ->
	      clear_app_env(App),
	      maps:foreach(fun(K,V) -> application:set_env(App, K, V) end, Settings)
      end, AppCfg),
    ok.

merge_config(Opts, Config) ->
    lists:ukeymerge(1, lists:keysort(1, Opts), lists:keysort(1, Config)).

group_config(ipv4, Config) ->
    Opts = [{localhost, ?LOCALHOST_IPv4},
	    {ue_ip, ?LOCALHOST_IPv4},
	    {client_ip, ?CLIENT_IP_IPv4},
	    {test_gsn, ?TEST_GSN_IPv4},
	    {proxy_gsn, ?PROXY_GSN_IPv4},
	    {final_gsn, ?FINAL_GSN_IPv4},
	    {final_gsn_2, ?FINAL_GSN2_IPv4},
	    {sgw_u_sx, ?SGW_U_SX_IPv4},
	    {pgw_u01_sx, ?PGW_U01_SX_IPv4},
	    {pgw_u02_sx, ?PGW_U02_SX_IPv4},
	    {tdf_u_sx, ?TDF_U_SX_IPv4}],
    merge_config(Opts, Config);
group_config(ipv6, Config) ->
    Opts = [{localhost, ?LOCALHOST_IPv6},
	    {ue_ip, ?LOCALHOST_IPv6},
	    {client_ip, ?CLIENT_IP_IPv6},
	    {test_gsn, ?TEST_GSN_IPv6},
	    {proxy_gsn, ?PROXY_GSN_IPv6},
	    {final_gsn, ?FINAL_GSN_IPv6},
	    {final_gsn_2, ?FINAL_GSN2_IPv6},
	    {sgw_u_sx, ?SGW_U_SX_IPv6},
	    {pgw_u01_sx, ?PGW_U01_SX_IPv6},
	    {pgw_u02_sx, ?PGW_U02_SX_IPv6},
	    {tdf_u_sx, ?TDF_U_SX_IPv6}],
    merge_config(Opts, Config).


update_app_cfgkey({Fun, CfgKey}, Config) ->
    fun(X) -> Fun(X, proplists:get_value(CfgKey, Config)) end;
update_app_cfgkey(CfgKey, Config)
  when is_atom(CfgKey) ->
    proplists:get_value(CfgKey, Config);
update_app_cfgkey(CfgKey, Config)
  when is_list(CfgKey) ->
    lists:map(fun(K) -> update_app_cfgkey(K, Config) end, CfgKey).

update_app_config(Group, CfgUpd, Config0) ->
    Config = group_config(Group, Config0),
    AppCfg0 = proplists:get_value(app_cfg, Config),
    AppCfg1 =
	lists:foldl(
	  fun({AppKey, CfgKey}, AppCfg) ->
		  set_cfg_value([ergw_core] ++ AppKey, update_app_cfgkey(CfgKey, Config), AppCfg)
	  end, AppCfg0, CfgUpd),
    CoreCfg = validate_core_config(proplists:get_value(ergw_core, AppCfg1)),
    AppCfg = lists:keystore(ergw_core, 1, AppCfg1, {ergw_core, CoreCfg}),
    lists:keystore(app_cfg, 1, Config, {app_cfg, AppCfg}).


init_app(App, Fun, Cfg) ->
    Config = proplists:get_value(App, Cfg),
    Fun(ergw_core_config:to_map(Config)).

ergw_core_init(Config) ->
    Init = [node, wait_till_running, path_management, node_selection,
	    sockets, upf_nodes, handlers, ip_pools, apns, charging, proxy_map],
    lists:foreach(ergw_core_init(_, Config), Init).

ergw_core_init(node, #{node := Node}) ->
    ergw_core:start_node(Node);
ergw_core_init(wait_till_running, _) ->
    ergw_core:wait_till_running();
ergw_core_init(path_management, #{path_management := NodeSel}) ->
    ok = ergw_core:setopts(path_management, NodeSel);
ergw_core_init(node_selection, #{node_selection := NodeSel}) ->
    ok = ergw_core:setopts(node_selection, NodeSel);
ergw_core_init(sockets, #{sockets := Sockets}) ->
    maps:map(fun ergw_core:add_socket/2, Sockets);
ergw_core_init(upf_nodes, #{upf_nodes := UP}) ->
    ergw_core:setopts(sx_defaults, maps:get(default, UP, #{})),
    maps:map(fun ergw_core:add_sx_node/2, maps:get(nodes, UP, #{}));
ergw_core_init(handlers, #{handlers := Handlers}) ->
    maps:map(fun ergw_core:add_handler/2, Handlers);
ergw_core_init(ip_pools, #{ip_pools := Pools}) ->
    maps:map(fun ergw_core:add_ip_pool/2, Pools);
ergw_core_init(apns, #{apns := APNs}) ->
    maps:map(fun ergw_core:add_apn/2, APNs);
ergw_core_init(charging, #{charging := Charging}) ->
    Init = [rules, rulebase, profile],
    lists:foreach(ergw_charging_init(_, Charging), Init);
ergw_core_init(proxy_map, #{proxy_map := Map}) ->
    ok = ergw_core:setopts(proxy_map, Map);
ergw_core_init(_, _) ->
    ok.

ergw_charging_init(rules, #{rules := Rules}) ->
    maps:map(fun ergw_core:add_charging_rule/2, Rules);
ergw_charging_init(rulebase, #{rulebase := RuleBase}) ->
    maps:map(fun ergw_core:add_charging_rulebase/2, RuleBase);
ergw_charging_init(profiles, #{profiles := Profiles}) ->
    maps:map(fun ergw_core:add_charging_profile/2, Profiles);
ergw_charging_init(_, _) ->
    ok.

%% copied from ergw_aaa test suites
ergw_aaa_init(Config) ->
    Init = [product_name, rate_limits, handlers, services, functions, apps],
    lists:foreach(ergw_aaa_init(_, Config), Init).

ergw_aaa_init(product_name, #{product_name := PN0}) ->
    PN = ergw_aaa_config:validate_option(product_name, PN0),
    ergw_aaa:setopt(product_name, PN),
    PN;
ergw_aaa_init(rate_limits, #{rate_limits := Limits0}) ->
    Limits1 = maps:with([default], Limits0),
    Limits = maps:merge(Limits1, maps:get(peers, Limits0, #{})),
    lists:foreach(ergw_aaa:setopt(rate_limit, _), maps:to_list(Limits));
ergw_aaa_init(handlers, #{handlers := Handlers0}) ->
    Handlers = ergw_aaa_config:validate_options(
		 fun ergw_aaa_config:validate_handler/2, Handlers0, []),
    maps:map(fun ergw_aaa:add_handler/2, Handlers),
    Handlers;
ergw_aaa_init(services, #{services := Services0}) ->
    Services = ergw_aaa_config:validate_options(
		 fun ergw_aaa_config:validate_service/2, Services0, []),
    maps:map(fun ergw_aaa:add_service/2, Services),
    Services;
ergw_aaa_init(functions, #{functions := Functions0}) ->
    Functions = ergw_aaa_config:validate_options(
		  fun ergw_aaa_config:validate_function/2, Functions0, []),
    maps:map(fun ergw_aaa:add_function/2, Functions),
    Functions;
ergw_aaa_init(apps, #{apps := Apps0}) ->
    Apps = ergw_aaa_config:validate_options(fun ergw_aaa_config:validate_app/2, Apps0, []),
    maps:map(fun ergw_aaa:add_application/2, Apps),
    Apps;
ergw_aaa_init(_K, _) ->
    ct:pal("AAA Init: ~p", [_K]),
    ok.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

%% make sure that our test config passes validation before applying it
validate_core_config(Config) ->
    ergw_core_config:validate_options(fun validate_option/2, Config, []).

validate_option(node, Value) when ?is_opts(Value) ->
    ergw_core:validate_options(Value);
validate_option(sockets, Value) when ?is_opts(Value) ->
    ergw_core_config:validate_options(fun ergw_socket:validate_options/2, Value, []);
validate_option(handlers, Value) when ?non_empty_opts(Value) ->
    ergw_core_config:validate_options(fun ergw_context:validate_options/2, Value, []);
validate_option(node_selection, Values) when ?is_opts(Values) ->
    ergw_node_selection:validate_options(Values);
validate_option(upf_nodes, Values) when ?is_opts(Values) ->
    ergw_core_config:validate_options(fun validate_upf_nodes/2, Values, [{default, #{}}, {nodes, #{}}]);
validate_option(ip_pools, Value) when ?is_opts(Value) ->
    ergw_core_config:validate_options(fun ergw_ip_pool:validate_options/2, Value, []);
validate_option(apns, Value) when ?is_opts(Value) ->
    ergw_core_config:validate_options(fun ergw_apn:validate_options/1, Value, []);
validate_option(charging, Opts) ->
    ergw_core_config:validate_options(fun validate_charging_options/2, Opts, []);
validate_option(proxy_map, Opts) ->
    gtp_proxy_ds:validate_options(Opts);
validate_option(path_management, Opts) when ?is_opts(Opts) ->
    gtp_path:validate_options(Opts);
validate_option(metrics, Opts) ->
    ergw_prometheus:validate_options(Opts);
validate_option(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

validate_upf_nodes(default, Values) ->
    ergw_sx_node:validate_defaults(Values);
validate_upf_nodes(nodes, Nodes) ->
    ergw_core_config:validate_options(
      fun ergw_sx_node:validate_options/2, Nodes, []);
validate_upf_nodes(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

validate_charging_options(profiles, Profiles) ->
    ergw_core_config:validate_options(fun ergw_charging:validate_profile/2, Profiles, []);
validate_charging_options(rules, Rules) ->
    ergw_core_config:validate_options(fun ergw_charging:validate_rule/2, Rules, []);
validate_charging_options(rulebase, RuleBase) ->
    ergw_core_config:validate_options(fun ergw_charging:validate_rulebase/2, RuleBase, []).

%%%===================================================================
%%% Meck functions for fake the GTP sockets
%%%===================================================================

meck_modules() ->
    [ergw_sx_socket, ergw_gtp_c_socket, ergw_aaa_session, ergw_gsn_lib,
     ergw_pfcp_context, ergw_proxy_lib, gtp_context].

meck_init_hut_handle_request(Hut) ->
    meck:expect(Hut, handle_request,
		fun(ReqKey, Request, Resent, State, Data) ->
			try
			    meck:passthrough([ReqKey, Request, Resent, State, Data])
			catch
			    throw:#ctx_err{} = CtxErr ->
				meck:exception(throw, CtxErr)
			end
		end).

meck_init(Config) ->
    ok = meck:new(meck_modules(), [passthrough, no_link]),
    ok = meck:expect(ergw_aaa_session, init,
		     fun(Arg) ->
			     try
				 meck:passthrough([Arg])
			     catch
				 exit:normal ->
				     meck:exception(exit, normal)
			     end
		     end),
    ok = meck:expect(gtp_context, init,
		     fun(Arg, Data) ->
			     try
				 meck:passthrough([Arg, Data])
			     catch
				 exit:normal ->
				     meck:exception(exit, normal)
			     end
		     end),
    ok = meck:expect(gtp_context, port_message,
		     fun(Request, Msg) ->
			     try
				 meck:passthrough([Request, Msg])
			     catch
				 throw:Err ->
				     meck:exception(throw, Err)
			     end
		     end),

    {_, Hut} = lists:keyfind(handler_under_test, 1, Config),   %% let it crash if HUT is undefined
    ok = meck:new(Hut, [passthrough, no_link, non_strict]),
    ok = meck_init_hut_handle_request(Hut).

meck_reset(Config) ->
    meck:reset([proplists:get_value(handler_under_test, Config) | meck_modules()]).

meck_unload(Config) ->
    meck:unload([proplists:get_value(handler_under_test, Config) | meck_modules()]).

meck_validate(Config) ->
    lists:foreach(fun meck_validate_mod/1,
		  [proplists:get_value(handler_under_test, Config) | meck_modules()]).

meck_validate_mod(Mod) ->
    case meck:validate(Mod) of
	true -> ok;
	false ->
	    ct:pal("Meck Validate Failed for ~p~nHistory: ~200p~n", [Mod, meck:history(Mod)]),
	    ct:fail({meck_invalid, Mod})
    end.

%%%===================================================================
%%% GTP entity and context function
%%%===================================================================

init_seq_no(Counter, SeqNo) ->
    ets:insert(?MODULE, {{Counter, seq_no}, SeqNo}).

gtp_context(Config) ->
    gtp_context(?MODULE, Config).

gtp_context(Counter, Config) ->
    gtp_context(Counter, proplists:get_value(client_ip, Config), Config).

gtp_context(Counter, ClientIP, Config) ->
    GtpC = #gtpc{
	      counter = Counter,
	      restart_counter =
		  ets:update_counter(?MODULE, restart_counter, 1) band 16#ff,
	      seq_no =
		  ets:update_counter(?MODULE, {Counter, seq_no}, 1) band 16#7fffff,

	      socket = make_gtp_socket(0, ClientIP),

	      ue_ip = {undefined, undefined},

	      local_ip = ClientIP,
	      remote_ip = proplists:get_value(test_gsn, Config),

	      rat_type = 1
	     },
    gtp_context_new_teids(GtpC).

gtp_context_inc_seq(#gtpc{counter = Counter} = GtpC) ->
    GtpC#gtpc{seq_no =
		  ets:update_counter(?MODULE, {Counter, seq_no}, 1) band 16#7fffff}.

gtp_context_inc_restart_counter(GtpC) ->
    GtpC#gtpc{restart_counter =
		  ets:update_counter(?MODULE, restart_counter, 1) band 16#ff}.

gtp_context_new_teids(GtpC) ->
    GtpC#gtpc{
      local_control_tei =
	  ets:update_counter(?MODULE, teid, 1) band 16#ffffffff,
      local_data_tei =
	  ets:update_counter(?MODULE, teid, 1) band 16#ffffffff
     }.

gtp_context_new_teids(Base, N, GtpC) ->
    TEID = Base + N,
    GtpC#gtpc{
      local_control_tei = TEID band 16#ffffffff,
      local_data_tei = TEID band 16#ffffffff
     }.


make_error_indication_report(#gtpc{local_data_tei = TEI, local_ip = IP}) ->
    make_error_indication_report(IP, TEI);
make_error_indication_report(#bearer{local = #fq_teid{ip = IP},
				     remote = #fq_teid{teid = TEI}}) ->
    make_error_indication_report(IP, TEI).

f_teid(TEID, {_,_,_,_} = IP) ->
    #f_teid{teid = TEID, ipv4 = ergw_inet:ip2bin(IP)};
f_teid(TEID, {_,_,_,_,_,_,_,_} = IP) ->
    #f_teid{teid = TEID, ipv6 = ergw_inet:ip2bin(IP)}.

make_error_indication_report(IP, TEI) ->
    IEs =
	[#report_type{erir = 1},
	 #error_indication_report{
	    group = [f_teid(TEI, IP)]}],
    Req = #pfcp{version = v1, type = session_report_request, seid = 0, ie = IEs},
    pfcp_packet:encode(Req#pfcp{seq_no = 0}),
    Req.

%%%===================================================================
%%% I/O and socket functions
%%%===================================================================

%% GTP-C default port (2123) handler
gtpc_server_init(Owner, Config) when is_list(Config) ->
    gtpc_server_init(Owner, proplists:get_value(client_ip, Config));

gtpc_server_init(Owner, IP) when is_tuple(IP) ->
    process_flag(trap_exit, true),

    CntlS = make_gtp_socket(?GTP2c_PORT, IP),

    proc_lib:init_ack(Owner, {ok, self()}),
    gtpc_server_loop(Owner, CntlS).

gtpc_server_loop(Owner, CntlS) ->
    case recv_pdu(CntlS, undefined, infinity, fun(Reason) -> Reason end) of
	#gtp{} = Msg ->
	    Owner ! {self(), Msg},
	    gtpc_server_loop(Owner, CntlS);

	{'EXIT', _From, _Reason} ->
	    gen_udp:close(CntlS),
	    ok;

	Other ->
	    ct:pal("Gtpc Server got ~p", [Other]),
	    Owner ! {self(), Other},
	    gtpc_server_loop(Owner, CntlS)
    end.

start_gtpc_server(Config) ->
    start_gtpc_server(Config, gtpc_client_server).

start_gtpc_server(Config, Name) ->
    {ok, Pid} = proc_lib:start_link(?MODULE, gtpc_server_init, [self(), Config]),
    register(Name, Pid),
    Pid.

wait_for_all_sx_nodes() ->
    SxNodes = supervisor:which_children(ergw_sx_node_sup),
    sx_nodes_up(length(SxNodes), 20),
    ok.

reconnect_all_sx_nodes() ->
    SxNodes = supervisor:which_children(ergw_sx_node_sup),
    [ergw_sx_node:test_cmd(Pid, reconnect) || {_, Pid, _, _} <- SxNodes, is_pid(Pid)],
    timer:sleep(10),
    sx_nodes_up(length(SxNodes), 20),
    ok.

stop_all_sx_nodes() ->
    SxNodes = supervisor:which_children(ergw_sx_node_sup),
    [ergw_sx_node:test_cmd(Pid, stop) || {_, Pid, _, _} <- SxNodes, is_pid(Pid)],
    stop_all_sx_nodes(supervisor:which_children(ergw_sx_node_sup)).

stop_all_sx_nodes([]) ->
    ok;
stop_all_sx_nodes(_) ->
    timer:sleep(10),
    stop_all_sx_nodes(supervisor:which_children(ergw_sx_node_sup)).

stop_gtpc_server() ->
    stop_gtpc_server(gtp_client_server).

stop_gtpc_server(Name) ->
    case whereis(Name) of
	Pid when is_pid(Pid) ->
	    unlink(Pid),
	    exit(Pid, shutdown);
	_ ->
	    ok
    end.

sx_nodes_up(_N, 0) ->
    Got = ergw_sx_node_reg:available(),
    Expected = supervisor:which_children(ergw_sx_node_sup),
    ct:fail("Sx nodes failed to come up~nExpected ~p~nGot ~p",
	    [Expected, Got]);
sx_nodes_up(N, Cnt) ->
    case ergw_sx_node_reg:available() of
	Nodes when map_size(Nodes) =:= N ->
	    ok;
	_Nodes ->
	    ct:sleep(100),
	    sx_nodes_up(N, Cnt - 1)
    end.

make_gtp_socket(Config) ->
    make_gtp_socket(?GTP2c_PORT, Config).

make_gtp_socket(Port, IP) when is_tuple(IP) ->
    {ok, S} = gen_udp:open(Port, [{ip, IP}, {active, false}, binary,
				  {reuseaddr, true}, {recbuf, 8388608}]),
    S;
make_gtp_socket(Port, Config) when is_list(Config) ->
    make_gtp_socket(Port, proplists:get_value(client_ip, Config)).

send_pdu(#gtpc{socket = S, remote_ip = IP}, Msg) ->
    send_pdu(S, IP, Msg).

send_pdu(S, IP, Port, Msg) when is_port(S) ->
    Data = gtp_packet:encode(Msg),
    ok = gen_udp:send(S, IP, Port, Data).

send_pdu(S, #gtpc{remote_ip = IP}, Msg) when is_port(S) ->
    send_pdu(S, IP, ?GTP2c_PORT, Msg);
send_pdu(S, IP, Msg) when is_port(S) ->
    send_pdu(S, IP, ?GTP2c_PORT, Msg);
send_pdu(S, Peer, Msg) when is_pid(S) ->
    S ! {send, Peer, Msg}.

send_recv_pdu(GtpC, Msg) ->
    send_recv_pdu(GtpC, Msg, ?TIMEOUT).

send_recv_pdu(#gtpc{socket = S} = GtpC, Msg, Timeout) ->
    send_pdu(GtpC, Msg),
    recv_pdu(S, Msg#gtp.seq_no, Timeout).

send_recv_pdu(#gtpc{socket = S} = GtpC, Msg, Timeout, Fail) ->
    send_pdu(GtpC, Msg),
    recv_pdu(S, Msg#gtp.seq_no, Timeout, Fail).

recv_pdu(S, Timeout) ->
    recv_pdu(S, undefined, Timeout).

recv_pdu(S, SeqNo, Timeout) ->
    recv_pdu(S, SeqNo, Timeout, fun(Reason) -> ct:fail(Reason) end).

recv_pdu(#gtpc{socket = S}, SeqNo, Timeout, Fail) ->
    recv_pdu(S, SeqNo, Timeout, Fail);
recv_pdu(_, _SeqNo, Timeout, Fail) when Timeout =< 0 ->
    recv_pdu_fail(Fail, timeout);
recv_pdu(S, SeqNo, Timeout, Fail) ->
    Now = erlang:monotonic_time(millisecond),
    recv_active(S),
    receive
	{udp, S, IP, _InPortNo, Response} ->
	    recv_pdu_msg(Response, Now, S, IP, SeqNo, Timeout, Fail);
	{S, #gtp{seq_no = SeqNo} = Msg}
	  when is_integer(SeqNo) ->
	    Msg;
	{S, #gtp{} = Msg}
	  when SeqNo =:= undefined ->
	    Msg;
	{'EXIT', _From, _Reason} = Exit ->
	    recv_pdu_fail(Fail, Exit);
	{send, Peer, Msg} ->
	    send_pdu(S, Peer, Msg),
	    recv_pdu(S, SeqNo, update_timeout(Timeout, Now), Fail)
    after Timeout ->
	    recv_pdu_fail(Fail, timeout)
    end.

recv_active(S) when is_pid(S) ->
    ok;
recv_active(S) ->
    inet:setopts(S, [{active, once}]).

update_timeout(infinity, _At) ->
    infinity;
update_timeout(Timeout, At) ->
    Timeout - (erlang:monotonic_time(millisecond) - At).

recv_pdu_msg(Response, At, S, IP, SeqNo, Timeout, Fail) ->
    case gtp_packet:decode(Response) of
	#gtp{type = echo_request} = Msg ->
	    Resp = Msg#gtp{type = echo_response, ie = []},
	    send_pdu(S, IP, Resp),
	    recv_pdu(S, SeqNo, update_timeout(Timeout, At), Fail);
	#gtp{seq_no = SeqNo} = Msg
	  when is_integer(SeqNo) ->
	    Msg;
	#gtp{} = Msg
	  when SeqNo =:= undefined ->
	    Msg;
	#gtp{} = Msg ->
	    recv_pdu_fail(Fail, {unexpected, Msg})
    end.

recv_pdu_fail(Fail, Why) when is_function(Fail) ->
    Fail(Why);
recv_pdu_fail(Fail, Why) ->
    {Fail, Why}.

%%%===================================================================
%%% Record formating
%%%===================================================================

pretty_print(Record) ->
    io_lib_pretty:print(Record, fun pretty_print/2).

pretty_print(gtp, N) ->
    N = record_info(size, gtp) - 1,
    record_info(fields, gtp);
pretty_print(gtpc, N) ->
    N = record_info(size, gtpc) - 1,
    record_info(fields, gtpc);
pretty_print(_, _) ->
    no.

%%%===================================================================
%%% Config manipulation
%%%===================================================================

set_cfg_value(Key, Value) when is_function(Value) ->
    Value(Key);
set_cfg_value(Key, Value) ->
    {Key, Value}.

map_cfg_update(Key, {K, V}, Config) ->
    maps:put(K, V, maps:remove(Key, Config)).

set_cfg_value([{Key, Pos}], Value, Config) when is_list(Config), is_integer(Pos) ->
    Tuple = lists:keyfind(Key, 1, Config),
    lists:keystore(Key, 1, Config, setelement(Pos, Tuple, set_cfg_value(Key, Value)));
set_cfg_value([{Key, Pos}], Value, Config) when is_map(Config), is_integer(Pos) ->
    maps:update_with(Key, setelement(Pos, _, set_cfg_value(Key, Value)), Config);

set_cfg_value([{K, V}], Value, Config) when is_list(Config) ->
    lists:map(
	  fun(#{K := V1} = Item) when V1 =:= V -> set_cfg_value(Item, Value);
	     (Item) -> Item end, Config);

set_cfg_value([Pos], Value, Config) when is_integer(Pos), is_list(Config) ->
    {H, [_|T]} = lists:split(Pos - 1, Config),
    H ++ [Value] ++ T;
set_cfg_value([Key], Value, Config) when is_list(Config) ->
    Cnf = lists:filter(
	    fun(X) when is_tuple(X) -> element(1, X) =/= Key;
	       (X) -> X =/= Key
	    end, Config),
    L = lists:keystore(Key, 1, Cnf, set_cfg_value(Key, Value)),
    ct:pal("L: ~p", [L]),
    L;
set_cfg_value([Key], Value, Config) when is_map(Config) ->
    map_cfg_update(Key, set_cfg_value(Key, Value), Config);

set_cfg_value([{Key, Pos} | T], Value, Config) when is_list(Config), is_integer(Pos) ->
    Tuple = lists:keyfind(Key, 1, Config),
    lists:keystore(Key, 1, Config,
		   setelement(Pos, Tuple, set_cfg_value(T, Value, element(Pos, Tuple))));
set_cfg_value([{Key, Pos} | T], Value, Config) when is_map(Config), is_integer(Pos) ->
    maps:update_with(
      Key,
      fun(Tuple) ->
	      setelement(Pos, Tuple, set_cfg_value(T, Value, element(Pos, Tuple)))
      end, Config);

set_cfg_value([Pos | Next], Value, Config) when is_integer(Pos), is_list(Config) ->
    {H, [Cfg|T]} = lists:split(Pos - 1, Config),
    H ++ [set_cfg_value(Next, Value, Cfg)] ++ T;
set_cfg_value([{K, V} | T], Value, Config) when is_list(Config) ->
    lists:map(
      fun(#{K := V1} = Item) when V1 =:= V -> set_cfg_value(T, Value, Item);
	 (Item) -> Item end, Config);

set_cfg_value([Pos | T], Value, Config)
  when is_integer(Pos), is_tuple(Config) ->
    setelement(Pos, Config, set_cfg_value(T, Value, element(Pos, Config)));

set_cfg_value([H | T], Value, Config) when is_list(Config) ->
    Prop = proplists:get_value(H, Config, []),
    lists:keystore(H, 1, Config, {H, set_cfg_value(T, Value, Prop)});

set_cfg_value([H | T], Value, Config) when is_map(Config) ->
    Prop = maps:get(H, Config, #{}),
    maps:put(H, set_cfg_value(T, Value, Prop), Config).

add_cfg_value([Key], Value, Config) when is_list(Config) ->
    [{Key, Value} | Config];
add_cfg_value([Key], Value, Config) when is_map(Config) ->
    maps:put(Key, Value, Config);
add_cfg_value([H | T], Value, Config) when is_list(Config) ->
    Prop = proplists:get_value(H, Config, []),
    lists:keystore(H, 1, Config, {H, add_cfg_value(T, Value, Prop)});
add_cfg_value([H | T], Value, Config) when is_map(Config) ->
    Prop = maps:get(H, Config, #{}),
    maps:put(H, add_cfg_value(T, Value, Prop), Config).

%%%===================================================================
%%% Retrieve outstanding request from gtp_context_reg
%%%===================================================================

outstanding_requests() ->
    Ms = ets:fun2ms(fun({Key, _} = Obj) when element(1, Key) == 'request' -> Obj end),
    ets:select(gtp_context_reg, Ms).

wait4tunnels(Cnt) ->
    case [X || X = #{tunnels := T} <- ergw_api:peer(all), T /= 0] of
	[] -> ok;
	Other ->
	    if Cnt > 100 ->
		    ct:sleep(100),
		    wait4tunnels(Cnt - 100);
	       true ->
		    ct:fail("timeout, waiting for tunnels to terminate, left over ~p", [Other])
	    end
    end.

wait4contexts(Cnt) ->
    case active_contexts() of
	0 -> ok;
	Other ->
	    if Cnt > 100 ->
		    ct:sleep(100),
		    wait4contexts(Cnt - 100);
	       true ->
		    ct:fail("timeout, waiting for contexts to be deleted, left over ~p", [Other])
	    end
    end.

active_contexts() ->
    Key = gtp_context:socket_teid_key(#socket{type = 'gtp-c', _ = '_'}, '_'),
    length(lists:usort(gtp_context_reg:select(Key))).

%%%===================================================================
%% hexstr2bin from otp/lib/crypto/test/crypto_SUITE.erl
%%%===================================================================
hexstr2bin(S) ->
    list_to_binary(hexstr2list(S)).

hexstr2list([X,Y|T]) ->
    [mkint(X)*16 + mkint(Y) | hexstr2list(T)];
hexstr2list([]) ->
    [].
mkint(C) when $0 =< C, C =< $9 ->
    C - $0;
mkint(C) when $A =< C, C =< $F ->
    C - $A + 10;
mkint(C) when $a =< C, C =< $f ->
    C - $a + 10.

%%%===================================================================
%%% Metric helpers
%%%===================================================================


match_metric(Type, Name, LabelValues, Expected, File, Line, Cnt) ->
    case get_metric(Type, Name, LabelValues, undefined) of
	Expected ->
	    ok;
	_ when Cnt > 0 ->
	    ct:sleep(100),
	    match_metric(Type, Name, LabelValues, Expected, File, Line, Cnt - 1);
	Actual ->
	    ct:pal("METRIC VALUE MISMATCH(~s:~b)~nExpected: ~p~nActual:   ~p~n",
		   [File, Line, Expected, Actual]),
	    error(badmatch)
    end.

get_metric(Type, Name, LabelValues, Default) ->
    case Type:value(Name, LabelValues) of
	undefined -> Default;
	Value -> Value
    end.

%%%===================================================================
%%% IPv6
%%%===================================================================

has_ipv6_test_config() ->
    try
	{ok, IfList} = inet:getifaddrs(),
	Lo = proplists:get_value("lo", IfList),
	V6 = [X || {addr, X = {16#fd96, 16#dcd2, 16#efdb, 16#41c3,_,_,_,_}} <- Lo],
	ct:pal("V6: ~p", [V6]),
	length(V6) >= 4
    catch
	_:_ ->
	    false
    end.

%%%===================================================================
%%% PFCP
%%%===================================================================

query_usage_report(PCtx) ->
    Req = #pfcp{
	     version = v1,
	     type = session_modification_request,
	     ie = [#query_urr{group = [#urr_id{id = 1}]}]
	    },
    case ergw_sx_node:call(PCtx, Req) of
	#pfcp{type = session_modification_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} = IEs} ->
	    ?LOG(warning, "Gn/Gp: got OK Query response: ~s",
			  [pfcp_packet:pretty_print(IEs)]),
	    ergw_aaa_session:to_session(
	      gtp_context:usage_report_to_accounting(
		maps:get(usage_report_smr, IEs, undefined)));
	_Other ->
	    ?LOG(warning, "Gn/Gp: got unexpected Query response: ~p",
			  [_Other]),
	    #{}
    end.

%%%===================================================================
%%% Helpers
%%%===================================================================

match_map(Match, Map, File, Line) ->
    maps:fold(
      fun(Key, Expected, R) ->
	      case maps:is_key(Key, Map) of
		  true ->
		      Actual = maps:get(Key, Map),
		      case erlang:match_spec_test({Actual, ok}, [{{Expected, '$1'}, [], ['$1']}], table) of
			  {ok, ok, _, _} ->
			      R andalso true;
			  {ok, false, _, _} ->
			      ct:pal("MISMATCH(~s:~b, ~p)~nExpected: ~p~nActual:   ~p~n",
				     [File, Line, Key, Expected, Actual]),
			      false
		      end;
		  _ ->
		      ct:pal("MAP KEY MISSING(~s:~b, ~p)~n", [File, Line, Key]),
		      false
	      end
      end, true, Match) orelse error(badmatch),
    ok.

maps_key_length(Key, Map) when is_map(Map) ->
    case maps:get(Key, Map, undefined) of
	X when is_list(X) -> length(X);
	X when is_tuple(X) -> 1;
	_ -> 0
    end.

%%%===================================================================
%%% Config Tweaking Helpers
%%%===================================================================

maps_recusive_merge(Key, Value, Map) ->
    maps:update_with(Key, fun(V) -> maps_recusive_merge(V, Value) end, Value, Map).

maps_recusive_merge(M1, M2)
  when is_map(M1) andalso is_map(M1) ->
    maps:fold(fun maps_recusive_merge/3, M1, M2);
maps_recusive_merge(_, New) ->
    New.

cfg_get_value([], Cfg) ->
    Cfg;
cfg_get_value([H|T], Cfg) when is_map(Cfg) ->
    cfg_get_value(T, maps:get(H, Cfg));
cfg_get_value([H|T], Cfg) when is_list(Cfg) ->
    cfg_get_value(T, proplists:get_value(H, Cfg)).

load_aaa_answer_config(AnswerCfg) ->
    Cfg0 = ergw_aaa:get_application(default),
    [Session] = cfg_get_value([init], Cfg0),
    Answers = [{Proc, [Session#{answer => Answer}]} || {Proc, Answer} <- AnswerCfg],
    UpdCfg = ergw_core_config:to_map(Answers),
    Cfg = maps_recusive_merge(Cfg0, UpdCfg),
    ok = set_aaa_config(apps, default, Cfg).

set_aaa_config(Key, Name, Opts) ->
    M = application:get_env(ergw_aaa, Key, #{}),
    application:set_env(ergw_aaa, Key, maps:put(Name, Opts, M)).

set_online_charging([], true, Cfg)
  when is_map(Cfg) ->
    maps:put('Online', [1], Cfg);
set_online_charging([], _, Cfg)
  when is_map(Cfg) ->
    maps:remove('Online', Cfg);
set_online_charging([], _, Cfg) ->
    Cfg;

set_online_charging(['_'|Next], Set, Cfg) when is_map(Cfg) ->
    maps:map(fun(_, V) -> set_online_charging(Next, Set, V) end, Cfg);
set_online_charging([Key|Next], Set, Cfg) when is_map(Cfg) ->
    Cfg#{Key => set_online_charging(Next, Set, maps:get(Key, Cfg))}.

set_online_charging(Set) ->
    {ok, Cfg0} = ergw_core_config:get([charging_rule], undefined),
    Cfg = set_online_charging(['_'], Set, Cfg0),
    ok = ergw_core_config:put(charging_rule, Cfg).

%% Set APN key data
set_apn_key(Key, Value) ->
    {ok, APNs0} = ergw_core_config:get([apns], undefined),
    Upd = fun(_APN, Val_map) -> maps:put(Key, Value, Val_map) end,
    APNs = maps:map(Upd, APNs0),
    ok = ergw_core_config:put(apns, APNs).

% Set Timers for Path management
set_path_timers(SetTimers) ->
    {ok, Timers} = ergw_core_config:get([path_management], undefined),
    NewTimers = maps_recusive_merge(Timers, SetTimers),
    ok = ergw_core_config:put(path_management, NewTimers).

%%%===================================================================
%%% common helpers for location data types
%%%===================================================================

plmn(CC, NC) ->
    MCC = iolist_to_binary(io_lib:format("~3..0b", [CC])),
    S = itu_e212:mcn_size(MCC),
    MNC = iolist_to_binary(io_lib:format("~*..0b", [S, NC])),
    {MCC, MNC}.

cgi(CC, NC, LAC, CI) ->
    #cgi{plmn_id = plmn(CC, NC), lac = LAC, ci = CI}.

cgi(CC, NC) ->
    cgi(CC, NC, rand:uniform(16#ffff), rand:uniform(16#ffff)).

sai(CC, NC, LAC, SAC) ->
    #sai{plmn_id = plmn(CC, NC), lac = LAC, sac = SAC}.

sai(CC, NC) ->
    sai(CC, NC, rand:uniform(16#ffff), rand:uniform(16#ffff)).

rai(CC, NC, LAC, RAC) ->
    #rai{plmn_id = plmn(CC, NC), lac = LAC, rac = RAC}.

rai(v1, CC, NC) ->
    rai(CC, NC, rand:uniform(16#ffff), (rand:uniform(16#ff) bsl 8) bor 16#ff);
rai(v2, CC, NC) ->
    rai(CC, NC, rand:uniform(16#ffff), rand:uniform(16#ffff)).

tai(CC, NC, TAC) ->
    #tai{plmn_id = plmn(CC, NC), tac = TAC}.

tai(CC, NC) ->
    tai(CC, NC, rand:uniform(16#ffff)).

ecgi(CC, NC, ECI) ->
    #ecgi{plmn_id = plmn(CC, NC), eci = ECI}.

ecgi(CC, NC) ->
    ecgi(CC, NC, rand:uniform(16#fffffff)).

lai(CC, NC, LAC) ->
    #lai{plmn_id = plmn(CC, NC), lac = LAC}.

lai(CC, NC) ->
    lai(CC, NC, rand:uniform(16#ffff)).

macro_enb(CC, NC, MeNB) ->
    #macro_enb{plmn_id = plmn(CC, NC), id = MeNB}.

macro_enb(CC, NC) ->
    macro_enb(CC, NC, rand:uniform(16#fffff)).

ext_macro_enb(CC, NC, EMeNB) ->
    #ext_macro_enb{plmn_id = plmn(CC, NC), id = EMeNB}.

ext_macro_enb(CC, NC) ->
    ext_macro_enb(CC, NC, rand:uniform(16#1fffff)).
