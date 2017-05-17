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
-export([gtp_context/0,
	 gtp_context_inc_seq/1,
	 gtp_context_inc_restart_counter/1,
	 gtp_context_new_teids/1]).
-export([make_gtp_socket/1,
	 send_pdu/2,
	 send_recv_pdu/2, send_recv_pdu/3,
	 recv_pdu/2, recv_pdu/3, recv_pdu/4]).
-export([pretty_print/1]).

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
    ets:insert(TabId, [{seq_no, 1},
		       {restart_counter, 1},
		       {teid, 1}]),
    [{table, TabId}, {table_owner, Pid} | Config].

lib_init_per_suite(Config0) ->
    {_, AppCfg} = lists:keyfind(app_cfg, 1, Config0),   %% let it crash if undefined

    Config = init_ets(Config0),
    [application:load(App) || App <- [lager, ergw, ergw_aaa]],
    meck_init(Config),
    load_config(AppCfg),
    {ok, _} = application:ensure_all_started(ergw),
    ok = meck:wait(gtp_dp, start_link, '_', ?TIMEOUT),
    Config.

lib_end_per_suite(Config) ->
    meck_unload(Config),
    ?config(table_owner, Config) ! stop,
    [application:stop(App) || App <- [lager, ergw, ergw_aaa]],
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
    ok = meck:new(gtp_dp, [non_strict, no_link]),
    ok = meck:expect(gtp_dp, start_link,
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
    ok = meck:expect(gtp_dp, send, fun(_GtpPort, _IP, _Port, _Data) -> ok end),
    ok = meck:expect(gtp_dp, get_id, fun(_GtpPort) -> self() end),
    ok = meck:expect(gtp_dp, create_pdp_context, fun(_Context, _Args) -> ok end),
    ok = meck:expect(gtp_dp, update_pdp_context, fun(_Context, _Args) -> ok end),
    ok = meck:expect(gtp_dp, delete_pdp_context, fun(_Context, _Args) -> ok end),

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
    meck:reset(gtp_dp),
    meck:reset(gtp_socket),
    meck:reset(proplists:get_value(handler_under_test, Config)).

meck_unload(Config) ->
    meck:unload(gtp_dp),
    meck:unload(gtp_socket),
    meck:unload(proplists:get_value(handler_under_test, Config)).

meck_validate(Config) ->
    ?equal(true, meck:validate(gtp_dp)),
    ?equal(true, meck:validate(gtp_socket)),
    ?equal(true, meck:validate(proplists:get_value(handler_under_test, Config))).

%%%===================================================================
%%% GTP entity and context function
%%%===================================================================

gtp_context() ->
    GtpC = #gtpc{
	      restart_counter =
		  ets:update_counter(?MODULE, restart_counter, 1) rem 256,
	      seq_no =
		  ets:update_counter(?MODULE, seq_no, 1) rem 16#800000
	     },
    gtp_context_new_teids(GtpC).

gtp_context_inc_seq(GtpC) ->
    GtpC#gtpc{seq_no =
		  ets:update_counter(?MODULE, seq_no, 1) rem 16#800000}.

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

%%%===================================================================
%%% I/O and socket functions
%%%===================================================================

make_gtp_socket(_Config) ->
    {ok, S} = gen_udp:open(?GTP2c_PORT, [{ip, ?CLIENT_IP}, {active, false},
					 binary, {reuseaddr, true}]),
    S.

send_pdu(S, Msg) ->
    Data = gtp_packet:encode(Msg),
    ok = gen_udp:send(S, ?TEST_GSN, ?GTP2c_PORT, Data).

send_recv_pdu(S, Msg) ->
    send_recv_pdu(S, Msg, ?TIMEOUT).

send_recv_pdu(S, Msg, Timeout) ->
    send_pdu(S, Msg),
    recv_pdu(S, Msg#gtp.seq_no, Timeout).

recv_pdu(S, Timeout) ->
    recv_pdu(S, undefined, Timeout).

recv_pdu(S, SeqNo, Timeout) ->
    recv_pdu(S, SeqNo, Timeout, fun(Reason) -> ct:fail(Reason) end).

recv_pdu(_, _SeqNo, Timeout, Fail) when Timeout =< 0 ->
    recv_pdu_fail(Fail, timeout);
recv_pdu(S, SeqNo, Timeout, Fail) ->
    Now = erlang:monotonic_time(millisecond),
    case gen_udp:recv(S, 4096, Timeout) of
	{ok, {?TEST_GSN, _, Response}} ->
	    recv_pdu_msg(Response, Now, S, SeqNo, Timeout, Fail);
	{error, Error} ->
	    recv_pdu_fail(Fail, Error);
	Unexpected ->
	    recv_pdu_fail(Fail, Unexpected)
    end.

recv_pdu_msg(Response, At, S, SeqNo, Timeout, Fail) ->
    ct:pal("Msg: ~s", [pretty_print((catch gtp_packet:decode(Response)))]),
    case gtp_packet:decode(Response) of
	#gtp{type = echo_request} = Msg ->
	    Resp = Msg#gtp{type = echo_response, ie = []},
	    send_pdu(S, Resp),
	    NewTimeout = Timeout - (erlang:monotonic_time(millisecond) - At),
	    recv_pdu(S, SeqNo, NewTimeout, Fail);
	#gtp{seq_no = SeqNo} = Msg
	  when is_integer(SeqNo) ->
	    Msg;

	Msg ->
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
