%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_test_lib).

-define(ERGW_NO_IMPORTS, true).

-export([lib_init_per_suite/1,
	 lib_end_per_suite/1,
	 load_config/1]).
-export([meck_init/1,
	 meck_reset/1,
	 meck_unload/1,
	 meck_validate/1]).
-export([init_seq_no/2,
	 gtp_context/0, gtp_context/1,
	 gtp_context_inc_seq/1,
	 gtp_context_inc_restart_counter/1,
	 gtp_context_new_teids/1,
	 make_error_indication_report/1]).
-export([start_gtpc_server/1, stop_gtpc_server/1,
	 make_gtp_socket/1, make_gtp_socket/2,
	 send_pdu/2,
	 send_recv_pdu/2, send_recv_pdu/3, send_recv_pdu/4,
	 recv_pdu/2, recv_pdu/3, recv_pdu/4]).
-export([pretty_print/1]).
-export([set_cfg_value/3, add_cfg_value/3]).
-export([outstanding_requests/0, wait4tunnels/1, hexstr2bin/1]).

-include("ergw_test_lib.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
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
    [application:load(App) || App <- [lager, cowboy, ergw, ergw_aaa]],
    meck_init(Config),
    load_config(AppCfg),
    {ok, _} = application:ensure_all_started(ergw),
    lager_common_test_backend:bounce(debug),
    ok = meck:wait(ergw_sx, start_link, '_', ?TIMEOUT),
    Config.

lib_end_per_suite(Config) ->
    meck_unload(Config),
    ?config(table_owner, Config) ! stop,
    [application:stop(App) || App <- [lager, ranch, cowboy, ergw, ergw_aaa]],
    ok.

load_config(AppCfg) ->
    lists:foreach(fun({App, Settings}) ->
			  ct:pal("App: ~p, S: ~p", [App, Settings]),
			  lists:foreach(fun({K,V}) ->
						ct:pal("App: ~p, K: ~p, V: ~p", [App, K, V]),
						application:set_env(App, K, V)
					end, Settings)
		  end, AppCfg),
    ok.

%%%===================================================================
%%% Meck functions for fake the GTP sockets
%%%===================================================================

meck_init(Config) ->
    ok = meck:new(ergw_sx, [non_strict, no_link]),
    ok = meck:expect(ergw_sx, start_link,
		     fun({Name, _SocketOpts}) ->
			     RCnt =
				 ets:update_counter(?MODULE, restart_counter, 1) rem 256,
			     GtpPort = #gtp_port{name = Name,
						 type = 'gtp-u',
						 pid = self(),
						 ip = ?LOCALHOST,
						 restart_counter = RCnt},
			     gtp_socket_reg:register(Name, GtpPort),
			     {ok, self()}
		     end),
    ok = meck:expect(ergw_sx, validate_options, fun(Values) -> Values end),
    ok = meck:expect(ergw_sx, send, fun(_GtpPort, _IP, _Port, _Data) -> ok end),
    ok = meck:expect(ergw_sx, get_id, fun(_GtpPort) -> self() end),
    ok = meck:expect(ergw_sx, call, fun(Context, _Request, _IEs) -> Context end),

    ok = meck:new(gtp_socket, [passthrough, no_link]),

    {_, Hut} = lists:keyfind(handler_under_test, 1, Config),   %% let it crash if HUT is undefined
    ok = meck:new(Hut, [passthrough, no_link]),
    ok = meck:expect(Hut, handle_request,
		     fun(ReqKey, Request, Resent, State) ->
			     try
				 meck:passthrough([ReqKey, Request, Resent, State])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end).

meck_reset(Config) ->
    meck:reset(ergw_sx),
    meck:reset(gtp_socket),
    meck:reset(proplists:get_value(handler_under_test, Config)).

meck_unload(Config) ->
    meck:unload(ergw_sx),
    meck:unload(gtp_socket),
    meck:unload(proplists:get_value(handler_under_test, Config)).

meck_validate(Config) ->
    ?equal(true, meck:validate(ergw_sx)),
    ?equal(true, meck:validate(gtp_socket)),
    ?equal(true, meck:validate(proplists:get_value(handler_under_test, Config))).

%%%===================================================================
%%% GTP entity and context function
%%%===================================================================

init_seq_no(Counter, SeqNo) ->
    ets:insert(?MODULE, {{Counter, seq_no}, SeqNo}).

gtp_context() ->
    gtp_context(?MODULE).

gtp_context(Counter) ->
    GtpC = #gtpc{
	      counter = Counter,
	      restart_counter =
		  ets:update_counter(?MODULE, restart_counter, 1) rem 256,
	      seq_no =
		  ets:update_counter(?MODULE, {Counter, seq_no}, 1) rem 16#800000
	     },
    gtp_context_new_teids(GtpC).

gtp_context_inc_seq(#gtpc{counter = Counter} = GtpC) ->
    GtpC#gtpc{seq_no =
		  ets:update_counter(?MODULE, {Counter, seq_no}, 1) rem 16#800000}.

gtp_context_inc_restart_counter(GtpC) ->
    GtpC#gtpc{restart_counter =
		  ets:update_counter(?MODULE, restart_counter, 1) rem 256}.

gtp_context_new_teids(GtpC) ->
    GtpC#gtpc{
      local_control_tei =
	  ets:update_counter(?MODULE, teid, 1) rem 16#100000000,
      local_data_tei =
	  ets:update_counter(?MODULE, teid, 1) rem 16#100000000
     }.

make_error_indication_report(#gtpc{local_data_tei = TEI,
				   remote_data_tei = SEID}) ->
    IEs = #{report_type => [error_indication_report],
	    error_indication_report =>
		[#{remote_f_teid =>
		       #f_teid{ipv4 = ?CLIENT_IP, teid = TEI}
		  }]
	   },
    {SEID, session_report_request, IEs}.

%%%===================================================================
%%% I/O and socket functions
%%%===================================================================

%% GTP-C default port (2123) handler
gtpc_server_init(Owner, Config) ->
    process_flag(trap_exit, true),

    CntlS = make_gtp_socket(Config),
    gtpc_server_loop(Owner, CntlS).

gtpc_server_loop(Owner, CntlS) ->
    case recv_pdu(CntlS, infinity) of
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
    Owner = self(),
    spawn_link(fun() -> gtpc_server_init(Owner, Config) end).

stop_gtpc_server(Pid) ->
    unlink(Pid),
    exit(Pid, normal).

make_gtp_socket(Config) ->
    make_gtp_socket(?GTP2c_PORT, Config).

make_gtp_socket(Port, _Config) ->
    {ok, S} = gen_udp:open(Port, [{ip, ?CLIENT_IP}, {active, false},
					 binary, {reuseaddr, true}]),
    S.

send_pdu(S, Msg) when is_pid(S) ->
    S ! {send, Msg};
send_pdu(S, Msg) ->
    Data = gtp_packet:encode(Msg),
    ok = gen_udp:send(S, ?TEST_GSN, ?GTP2c_PORT, Data).

send_recv_pdu(S, Msg) ->
    send_recv_pdu(S, Msg, ?TIMEOUT).

send_recv_pdu(S, Msg, Timeout) ->
    send_pdu(S, Msg),
    recv_pdu(S, Msg#gtp.seq_no, Timeout).

send_recv_pdu(S, Msg, Timeout, Fail) ->
    send_pdu(S, Msg),
    recv_pdu(S, Msg#gtp.seq_no, Timeout, Fail).

recv_pdu(S, Timeout) ->
    recv_pdu(S, undefined, Timeout).

recv_pdu(S, SeqNo, Timeout) ->
    recv_pdu(S, SeqNo, Timeout, fun(Reason) -> ct:fail(Reason) end).

recv_pdu(_, _SeqNo, Timeout, Fail) when Timeout =< 0 ->
    recv_pdu_fail(Fail, timeout);
recv_pdu(S, SeqNo, Timeout, Fail) ->
    Now = erlang:monotonic_time(millisecond),
    recv_active(S),
    receive
	{udp, S, ?TEST_GSN, _InPortNo, Response} ->
	    recv_pdu_msg(Response, Now, S, SeqNo, Timeout, Fail);
	{udp, _Socket, _IP, _InPortNo, _Packet} = Unexpected ->
	    recv_pdu_fail(Fail, Unexpected);
	{S, #gtp{seq_no = SeqNo} = Msg}
	  when is_integer(SeqNo) ->
	    Msg;
	{S, #gtp{} = Msg}
	  when SeqNo =:= undefined ->
	    Msg;
	{'EXIT', _From, _Reason} = Exit ->
	    recv_pdu_fail(Fail, Exit);
	{send, Msg} ->
	    send_pdu(S, Msg),
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

recv_pdu_msg(Response, At, S, SeqNo, Timeout, Fail) ->
    ct:pal("Msg: ~s", [pretty_print((catch gtp_packet:decode(Response)))]),
    case gtp_packet:decode(Response) of
	#gtp{type = echo_request} = Msg ->
	    Resp = Msg#gtp{type = echo_response, ie = []},
	    send_pdu(S, Resp),
	    recv_pdu(S, SeqNo, update_timeout(Timeout, At), Fail);
	#gtp{seq_no = SeqNo} = Msg
	  when is_integer(SeqNo) ->
	    Msg;
	#gtp{} = Msg
	  when SeqNo =:= undefined ->
	    Msg
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

set_cfg_value([Key], Value, Config) when is_boolean(Value) ->
    lists:keystore(Key, 1, proplists:delete(Key, Config), {Key, Value});
set_cfg_value([Key], Value, Config) ->
    lists:keystore(Key, 1, Config, {Key, Value});
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
