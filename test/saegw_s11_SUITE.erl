%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(saegw_s11_SUITE).

-compile([export_all, nowarn_export_all, {parse_transform, lager_transform}]).

-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_saegw_test_lib.hrl").

-define(TIMEOUT, 2000).
-define(HUT, saegw_s11).				%% Handler Under Test

%%%===================================================================
%%% API
%%%===================================================================

-define(TEST_CONFIG,
	[
	 {lager, [{colored, true},
		  {error_logger_redirect, true},
		  %% force lager into async logging, otherwise
		  %% the test will timeout randomly
		  {async_threshold, undefined},
		  {handlers, [{lager_console_backend, [{level, info}]}]}
		 ]},

	 {ergw, [{dp_handler, '$meck'},
		 {sockets,
		  [{irx, [{type, 'gtp-c'},
			  {ip,	?TEST_GSN},
			  {reuseaddr, true}
			 ]},
		   {grx, [{type, 'gtp-u'},
			  {node, 'gtp-u-node@localhost'},
			  {name, 'grx'}]}
		  ]},

		 {vrfs,
		  [{upstream, [{pools,	[{{10, 180, 0, 1}, {10, 180, 255, 254}, 32},
					 {{16#8001, 0, 0, 0, 0, 0, 0, 0}, {16#8001, 0, 0, 16#FFFF, 0, 0, 0, 0}, 64}
					]},
			       {'MS-Primary-DNS-Server', {8,8,8,8}},
			       {'MS-Secondary-DNS-Server', {8,8,4,4}},
			       {'MS-Primary-NBNS-Server', {127,0,0,1}},
			       {'MS-Secondary-NBNS-Server', {127,0,0,1}}
			      ]}
		  ]},

		 {handlers,
		  [{s11, [{handler, ?HUT},
			  {sockets, [irx]},
			  {data_paths, [grx]},
			  {aaa, [{'Username',
				  [{default, ['IMSI', <<"/">>, 'IMEI', <<"/">>, 'MSISDN', <<"@">>, 'APN']}]}]}
			 ]}
		  ]},

		 {sx_socket,
		  [{node, 'ergw'},
		   {name, 'ergw'},
		   {ip, {127,0,0,1}}]},

		 {apns,
		  [{?'APN-EXAMPLE', [{vrf, upstream}]},
		   {[<<"APN1">>], [{vrf, upstream}]}
		  ]}
		]},
	 {ergw_aaa, [{ergw_aaa_provider, {ergw_aaa_mock, [{shared_secret, <<"MySecret">>}]}}]}
	]).


suite() ->
    [{timetrap,{seconds,30}}].

init_per_suite(Config0) ->
    Config = [{handler_under_test, ?HUT},
	      {app_cfg, ?TEST_CONFIG}
	      | Config0],

    lib_init_per_suite(Config).

end_per_suite(Config) ->
    ok = lib_end_per_suite(Config),
    ok.

all() ->
    [invalid_gtp_pdu,
     create_session_request_missing_ie,
     create_session_request_aaa_reject,
     create_session_request_invalid_apn,
     create_session_request_accept_new,
     create_session_request_resend,
     delete_session_request_resend,
     modify_bearer_request_ra_update,
     modify_bearer_request_tei_update,
     modify_bearer_command,
     modify_bearer_command_timeout,
     modify_bearer_command_congestion,
     delete_bearer_request,
     requests_invalid_teid,
     commands_invalid_teid,
     delete_bearer_request_resend,
     unsupported_request,
     create_session_overload
    ].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    meck_reset(Config).

init_per_testcase(create_session_request_aaa_reject, Config) ->
    init_per_testcase(Config),
    ok = meck:new(ergw_aaa_session, [passthrough, no_link]),
    ok = meck:expect(ergw_aaa_session,authenticate,
		     fun(_Session, _SessionOpts) ->
			     {fail, []}
		     end),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == delete_bearer_request_resend;
       TestCase == modify_bearer_command_timeout ->
    init_per_testcase(Config),
    ok = meck:expect(gtp_socket, send_request,
		     fun(GtpPort, DstIP, DstPort, _T3, _N3,
			 #gtp{type = Type} = Msg, CbInfo)
			   when Type == delete_bearer_request;
				Type == update_bearer_request ->
			     %% reduce timeout to 1 second and 2 resends
			     %% to speed up the test
			     meck:passthrough([GtpPort, DstIP, DstPort, 1000, 2, Msg, CbInfo]);
			(GtpPort, DstIP, DstPort, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([GtpPort, DstIP, DstPort, T3, N3, Msg, CbInfo])
		     end),
    Config;
init_per_testcase(create_session_overload, Config) ->
    init_per_testcase(Config),
    jobs:modify_queue(create, [{max_size, 0}]),
    jobs:modify_regulator(rate, create, {rate,create,1}, [{limit,1}]),
    Config;
init_per_testcase(_, Config) ->
    init_per_testcase(Config),
    Config.

end_per_testcase(create_session_request_aaa_reject, Config) ->
    meck:unload(ergw_aaa_session),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == delete_bearer_request_resend;
       TestCase == modify_bearer_command_timeout ->
    ok = meck:delete(gtp_socket, send_request, 7),
    Config;
end_per_testcase(create_session_overload, Config) ->
    jobs:modify_queue(create, [{max_size, 10}]),
    jobs:modify_regulator(rate, create, {rate,create,1}, [{limit,100}]),
    Config;
end_per_testcase(_, Config) ->
    Config.

%%--------------------------------------------------------------------
invalid_gtp_pdu() ->
    [{doc, "Test that an invalid PDU is silently ignored"
      " and that the GTP socket is not crashing"}].
invalid_gtp_pdu(Config) ->
    S = make_gtp_socket(Config),
    gen_udp:send(S, ?TEST_GSN, ?GTP2c_PORT, <<"TESTDATA">>),

    ?equal({error,timeout}, gen_udp:recv(S, 4096, ?TIMEOUT)),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_missing_ie() ->
    [{doc, "Check that Create Session Request IE validation works"}].
create_session_request_missing_ie(Config) ->
    S = make_gtp_socket(Config),

    create_session(missing_ie, S),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_aaa_reject() ->
    [{doc, "Check AAA reject return on Create Session Request"}].
create_session_request_aaa_reject(Config) ->
    S = make_gtp_socket(Config),

    create_session(aaa_reject, S),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_invalid_apn() ->
    [{doc, "Check invalid APN return on Create Session Request"}].
create_session_request_invalid_apn(Config) ->
    S = make_gtp_socket(Config),

    create_session(invalid_apn, S),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_accept_new() ->
    [{doc, "Check the accept_new = false can block new session"}].
create_session_request_accept_new(Config) ->
    S = make_gtp_socket(Config),

    ?equal(ergw:system_info(accept_new, false), true),
    create_session(overload, S),
    ?equal(ergw:system_info(accept_new, true), false),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_resend() ->
    [{doc, "Check that a retransmission of a Create Session Request works"}].
create_session_request_resend(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, Msg, Response} = create_session(S),
    ?equal(Response, send_recv_pdu(S, Msg)),

    delete_session(S, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_session_request_resend() ->
    [{doc, "Check that a retransmission of a Delete Session Request works"}].
delete_session_request_resend(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_session(S),
    {_, Msg, Response} = delete_session(S, GtpC),
    ?equal(Response, send_recv_pdu(S, Msg)),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_request_ra_update() ->
    [{doc, "Check Modify Bearer Routing Area Update"}].
modify_bearer_request_ra_update(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, _, _} = modify_bearer(ra_update, S, GtpC1),
    delete_session(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_request_tei_update() ->
    [{doc, "Check Modify Bearer with TEID update (e.g. SGW change)"}].
modify_bearer_request_tei_update(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, _, _} = modify_bearer(tei_update, S, GtpC1),
    delete_session(S, GtpC2),

    SMR0 = meck:capture(first, ergw_sx, call,
			['_', #pfcp{type = session_modification_request, _='_'}], 2),
    SMR = pfcp_packet:to_map(SMR0),
    #{update_far :=
      #update_far{
	 group =
	 #{update_forwarding_parameters :=
	   #update_forwarding_parameters{group = UFP}}}} = SMR#pfcp.ie,
    ?match(#sxsmreq_flags{sndem = 1}, maps:get(sxsmreq_flags, UFP)),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_command() ->
    [{doc, "Check Modify Bearer Command"}].
modify_bearer_command(Config) ->
    Cntl = start_gtpc_server(Config),
    S = make_gtp_socket(0, Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, Req0} = modify_bearer_command(simple, S, GtpC1),

    Req1 = recv_pdu(S, Req0#gtp.seq_no, ?TIMEOUT, ok),
    validate_response(modify_bearer_command, simple, Req1, GtpC2),
    Response = make_response(Req1, simple, GtpC2),
    send_pdu(S, Response),

    ?equal({ok, timeout}, recv_pdu(S, Req1#gtp.seq_no, ?TIMEOUT, ok)),
    ?equal([], outstanding_requests()),

    delete_session(S, GtpC2),
    stop_gtpc_server(Cntl),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_command_timeout() ->
    [{doc, "Check Modify Bearer Command"}].
modify_bearer_command_timeout(Config) ->
    Cntl = start_gtpc_server(Config),
    S = make_gtp_socket(0, Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, Req0} = modify_bearer_command(simple, S, GtpC1),

    Req1 = recv_pdu(S, Req0#gtp.seq_no, ?TIMEOUT, ok),
    validate_response(modify_bearer_command, simple, Req1, GtpC2),
    ?equal(Req1, recv_pdu(S, 5000)),
    ?equal(Req1, recv_pdu(S, 5000)),

    Req2 = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Req2),
    ?equal(Req2, recv_pdu(Cntl, 5000)),
    ?equal(Req2, recv_pdu(Cntl, 5000)),

    stop_gtpc_server(Cntl),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_command_congestion() ->
    [{doc, "Check Modify Bearer Command"}].
modify_bearer_command_congestion(Config) ->
    Cntl = start_gtpc_server(Config),
    S = make_gtp_socket(0, Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, Req0} = modify_bearer_command(simple, S, GtpC1),

    Req1 = recv_pdu(S, Req0#gtp.seq_no, ?TIMEOUT, ok),
    validate_response(modify_bearer_command, simple, Req1, GtpC2),
    Resp1 = make_response(Req1, apn_congestion, GtpC2),
    send_pdu(S, Resp1),

    Req2 = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Req2),
    Resp2 = make_response(Req2, simple, GtpC2),
    send_pdu(Cntl, Resp2),

    ?equal({ok, timeout}, recv_pdu(S, Req2#gtp.seq_no, ?TIMEOUT, ok)),
    ?equal([], outstanding_requests()),

    stop_gtpc_server(Cntl),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
requests_invalid_teid() ->
    [{doc, "Check invalid TEID's for a number of request types"}].
requests_invalid_teid(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, _, _} = modify_bearer(invalid_teid, S, GtpC1),
    {GtpC3, _, _} = delete_session(invalid_teid, S, GtpC2),
    delete_session(S, GtpC3),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
commands_invalid_teid() ->
    [{doc, "Check invalid TEID's for a number of command types"}].
commands_invalid_teid(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, _, _} = modify_bearer_command(invalid_teid, S, GtpC1),
    delete_session(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_bearer_request() ->
    [{doc, "Check PGW initiated bearer shutdown"},
     {timetrap,{seconds,60}}].
delete_bearer_request(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_session(S),

    Context = gtp_context_reg:lookup_key(#gtp_port{name = irx}, {imsi, ?'IMSI', 5}),
    true = is_pid(Context),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Context)} end),

    Request = recv_pdu(S, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(S, Response),

    receive
	{req, {ok, request_accepted}} ->
	    ok;
	{req, Other} ->
	    ct:fail(Other)
    after ?TIMEOUT ->
	      ct:fail(timeout)
    end,

    wait4tunnels(?TIMEOUT),
    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_bearer_request_resend() ->
    [{doc, "Check resend of PGW initiated bearer shutdown"},
     {timetrap,{seconds,60}}].
delete_bearer_request_resend(Config) ->
    S = make_gtp_socket(Config),

    {_, _, _} = create_session(S),

    Context = gtp_context_reg:lookup_key(#gtp_port{name = irx}, {imsi, ?'IMSI', 5}),
    true = is_pid(Context),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Context)} end),

    Request = recv_pdu(S, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request),
    ?equal(Request, recv_pdu(S, 5000)),
    ?equal(Request, recv_pdu(S, 5000)),

    receive
	{req, {error, timeout}} ->
	    ok
    after ?TIMEOUT ->
	      ct:fail(timeout)
    end,

    wait4tunnels(?TIMEOUT),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
unsupported_request() ->
    [{doc, "Check that unsupported requests are silently ignore and don't get stuck"}].
unsupported_request(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_session(S),
    Request = make_request(unsupported, simple, GtpC),

    ?equal({error,timeout}, send_recv_pdu(S, Request, ?TIMEOUT, error)),
    ?equal([], outstanding_requests()),

    delete_session(S, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_overload() ->
    [{doc, "Check that the overload protection works"}].
create_session_overload(Config) ->
    S = make_gtp_socket(Config),

    create_session(overload, S),

    meck_validate(Config),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
