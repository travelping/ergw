%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_test_lib).

-define(ERGW_NO_IMPORTS, true).

-export([lib_init_per_suite/1,
	 lib_end_per_suite/1,
	 update_app_config/3,
	 load_config/1]).
-export([meck_init/1,
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
-export([outstanding_requests/0, wait4tunnels/1, hexstr2bin/1]).
-export([match_metric/7, get_metric/4]).
-export([has_ipv6_test_config/0]).
-export([query_usage_report/2]).
-export([match_map/4, maps_key_length/2]).
-export([init_ets/1]).

-include("ergw_test_lib.hrl").
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

lib_init_per_suite(Config0) ->
    {_, AppCfg} = lists:keyfind(app_cfg, 1, Config0),   %% let it crash if undefined

    Config = init_ets(Config0),
    [application:load(App) || App <- [cowboy, ergw, ergw_aaa, dhcp]],
    meck_init(Config),
    load_config(AppCfg),
    {ok, _} = application:ensure_all_started(ergw),

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

lib_end_per_suite(Config) ->
    meck_unload(Config),
    ok = ergw_test_sx_up:stop('pgw-u01'),
    ok = ergw_test_sx_up:stop('pgw-u02'),
    ok = ergw_test_sx_up:stop('sgw-u'),
    ok = ergw_test_sx_up:stop('tdf-u'),
    ?config(table_owner, Config) ! stop,
    [application:stop(App) || App <- [ranch, cowboy, ergw, ergw_aaa, dhcp]],
    ok.

load_config(AppCfg) ->
    lists:foreach(
      fun({App, Settings}) ->
	      lists:foreach(
		fun({logger, V})
		      when App =:= kernel, is_list(V) ->
			lists:foreach(
			  fun({handler, HandlerId, _Module, HandlerConfig})
				when is_map(HandlerConfig)->
				  logger:update_handler_config(HandlerId, HandlerConfig);
			     (Cfg) ->
				  ct:fail("unknown logger config  ~p", [Cfg])
			  end, V),
			ok;
		   ({K,V}) ->
			application:set_env(App, K, V)
		end, Settings)
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
		  set_cfg_value([ergw] ++ AppKey, update_app_cfgkey(CfgKey, Config), AppCfg)
	  end, AppCfg0, CfgUpd),
    ergw_config:validate_config(proplists:get_value(ergw, AppCfg1)),
    lists:keystore(app_cfg, 1, Config, {app_cfg, AppCfg1}).

%%%===================================================================
%%% Meck functions for fake the GTP sockets
%%%===================================================================

meck_init(Config) ->
    ok = meck:new(ergw_sx_socket, [passthrough, no_link]),
    ok = meck:new(ergw_gtp_c_socket, [passthrough, no_link]),
    ok = meck:new(ergw_aaa_session, [passthrough, no_link]),
    ok = meck:new(ergw_gsn_lib, [passthrough, no_link]),
    ok = meck:expect(ergw_gsn_lib, select_vrf,
		     fun(NodeCaps, APN) ->
			     try
				 meck:passthrough([NodeCaps, APN])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),
    ok = meck:expect(ergw_gsn_lib, select_upf,
		     fun(Candidates, Context) ->
			     try
				 meck:passthrough([Candidates, Context])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),
    ok = meck:new(ergw_proxy_lib, [passthrough, no_link]),

    {_, Hut} = lists:keyfind(handler_under_test, 1, Config),   %% let it crash if HUT is undefined
    ok = meck:new(Hut, [passthrough, no_link, non_strict]),
    ok = meck:expect(Hut, handle_request,
		     fun(ReqKey, Request, Resent, State, Data) ->
			     try
				 meck:passthrough([ReqKey, Request, Resent, State, Data])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end).

meck_reset(Config) ->
    meck:reset(ergw_sx_socket),
    meck:reset(ergw_gtp_c_socket),
    meck:reset(ergw_aaa_session),
    meck:reset(ergw_gsn_lib),
    meck:reset(ergw_proxy_lib),
    meck:reset(proplists:get_value(handler_under_test, Config)).

meck_unload(Config) ->
    meck:unload(ergw_sx_socket),
    meck:unload(ergw_gtp_c_socket),
    meck:unload(ergw_aaa_session),
    meck:unload(ergw_gsn_lib),
    meck:unload(ergw_proxy_lib),
    meck:unload(proplists:get_value(handler_under_test, Config)).

meck_validate(Config) ->
    ?equal(true, meck:validate(ergw_sx_socket)),
    ?equal(true, meck:validate(ergw_gtp_c_socket)),
    ?equal(true, meck:validate(ergw_aaa_session)),
    ?equal(true, meck:validate(ergw_gsn_lib)),
    ?equal(true, meck:validate(ergw_proxy_lib)),
    ?equal(true, meck:validate(proplists:get_value(handler_under_test, Config))).

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
make_error_indication_report(#context{local_data_endp = #gtp_endp{ip = IP},
				      remote_data_teid = #fq_teid{teid = TEI}}) ->
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
	    ct:sleep(50),
	    sx_nodes_up(N, Cnt - 1)
    end.

make_gtp_socket(Config) ->
    make_gtp_socket(?GTP2c_PORT, Config).

make_gtp_socket(Port, IP) when is_tuple(IP) ->
    {ok, S} = gen_udp:open(Port, [{ip, IP}, {active, false}, binary, {reuseaddr, true}]),
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

set_cfg_value([Key], Value, Config) when is_boolean(Value) ->
    lists:keystore(Key, 1, proplists:delete(Key, Config), set_cfg_value(Key, Value));
set_cfg_value([{Key, Pos}], Value, Config) ->
    Tuple = lists:keyfind(Key, 1, Config),
    lists:keystore(Key, 1, Config, setelement(Pos, Tuple, set_cfg_value(Key, Value)));
set_cfg_value([Key], Value, Config) ->
    lists:keystore(Key, 1, Config, set_cfg_value(Key, Value));
set_cfg_value([{Key, Pos} | T], Value, Config) ->
    Tuple = lists:keyfind(Key, 1, Config),
    lists:keystore(Key, 1, Config,
		   setelement(Pos, Tuple, set_cfg_value(T, Value, element(Pos, Tuple))));
set_cfg_value([Pos | T], Value, Config)
  when is_integer(Pos), is_tuple(Config) ->
    setelement(Pos, Config, set_cfg_value(T, Value, element(Pos, Config)));
set_cfg_value([H | T], Value, Config) ->
    Prop = proplists:get_value(H, Config, []),
    lists:keystore(H, 1, Config, {H, set_cfg_value(T, Value, Prop)}).

add_cfg_value([Key], Value, Config) ->
    ct:pal("Cfg: ~p", [[{Key, Value} | Config]]),
    [{Key, Value} | Config];
add_cfg_value([H | T], Value, Config) ->
    Prop = proplists:get_value(H, Config, []),
    lists:keystore(H, 1, Config, {H, add_cfg_value(T, Value, Prop)}).

%%%===================================================================
%%% Retrieve outstanding request from gtp_context_reg
%%%===================================================================

outstanding_requests() ->
    ets:match_object(gtp_context_reg, {{'_', {'_', '_', '_', '_', '_'}}, '_'}).

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

query_usage_report(Context, PCtx) ->
    Req = #pfcp{
	     version = v1,
	     type = session_modification_request,
	     ie = [#query_urr{group = [#urr_id{id = 1}]}]
	    },
    case ergw_sx_node:call(PCtx, Req, Context) of
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
