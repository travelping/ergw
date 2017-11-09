%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_proxy_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("../include/ergw.hrl").
-include("../include/gtp_proxy_ds.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_ggsn_test_lib.hrl").

-define(TIMEOUT, 2000).
-define(HUT, ggsn_gn_proxy).			%% Handler Under Test

%%%===================================================================
%%% API
%%%===================================================================

-define(TEST_CONFIG_MULTIPLE_PROXY_SOCKETS,
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
			  {ip,  ?TEST_GSN},
			  {reuseaddr, true}
			 ]},
		   {grx, [{type, 'gtp-u'},
			  {node, 'gtp-u-node@localhost'},
			  {name, 'grx'}
			 ]},
		   {'proxy-irx', [{type, 'gtp-c'},
				  {ip,  ?PROXY_GSN},
				  {reuseaddr, true}
				 ]},
		   {'proxy-grx', [{type, 'gtp-u'},
				  {node, 'gtp-u-proxy@vlx161-tpmd'},
				  {name, 'proxy-grx'}
				 ]},
		   {'remote-irx', [{type, 'gtp-c'},
				   {ip,  ?FINAL_GSN},
				   {reuseaddr, true}
				  ]},
		   {'remote-grx', [{type, 'gtp-u'},
				   {node, 'gtp-u-node@localhost'},
				   {name, 'remote-grx'}
				  ]}
		  ]},

		 {vrfs,
		  [{example, [{pools,  [{{10, 180, 0, 1}, {10, 180, 255, 254}, 32},
					{{16#8001, 0, 0, 0, 0, 0, 0, 0},
					 {16#8001, 0, 0, 16#FFFF, 0, 0, 0, 0}, 64}
				       ]},
			      {'MS-Primary-DNS-Server', {8,8,8,8}},
			      {'MS-Secondary-DNS-Server', {8,8,4,4}},
			      {'MS-Primary-NBNS-Server', {127,0,0,1}},
			      {'MS-Secondary-NBNS-Server', {127,0,0,1}}
			     ]}
		  ]},

		 {handlers,
		  %% proxy handler
		  [{gn, [{handler, ?HUT},
			 {sockets, [irx]},
			 {data_paths, [grx]},
			 {proxy_sockets, ['proxy-irx']},
			 {proxy_data_paths, ['proxy-grx']},
			 {ggsn, ?FINAL_GSN},
			 {contexts,
			  [{<<"ams">>,
			    [{proxy_sockets, ['proxy-irx']},
			     {proxy_data_paths, ['proxy-grx']}]}]}
			]},
		   %% remote GGSN handler
		   {gn, [{handler, ggsn_gn},
			 {sockets, ['remote-irx']},
			 {data_paths, ['remote-grx']},
			 {aaa, [{'Username',
				 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
			]}
		  ]},

		 {apns,
		  [{?'APN-PROXY', [{vrf, example}]}
		  ]},

		 {proxy_map,
		  [{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
		   {imsi, [{?'IMSI', {?'PROXY-IMSI', ?'PROXY-MSISDN'}}
			  ]}
		  ]}			     ]},
	 {ergw_aaa, [{ergw_aaa_provider, {ergw_aaa_mock, [{shared_secret, <<"MySecret">>}]}}]}
	]).

-define(TEST_CONFIG_SINGLE_PROXY_SOCKET,
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
			  {ip,  ?TEST_GSN},
			  {reuseaddr, true}
			 ]},
		   {grx, [{type, 'gtp-u'},
			  {node, 'gtp-u-node@localhost'},
			  {name, 'grx'}
			 ]},
		   {'remote-irx', [{type, 'gtp-c'},
				   {ip,  ?FINAL_GSN},
				   {reuseaddr, true}
				  ]},
		   {'remote-grx', [{type, 'gtp-u'},
				   {node, 'gtp-u-node@localhost'},
				   {name, 'remote-grx'}
				  ]}
		  ]},

		 {vrfs,
		  [{example, [{pools,  [{{10, 180, 0, 1}, {10, 180, 255, 254}, 32},
					{{16#8001, 0, 0, 0, 0, 0, 0, 0},
					 {16#8001, 0, 0, 16#FFFF, 0, 0, 0, 0}, 64}
				       ]},
			      {'MS-Primary-DNS-Server', {8,8,8,8}},
			      {'MS-Secondary-DNS-Server', {8,8,4,4}},
			      {'MS-Primary-NBNS-Server', {127,0,0,1}},
			      {'MS-Secondary-NBNS-Server', {127,0,0,1}}
			     ]}
		  ]},

		 {handlers,
		  %% proxy handler
		  [{gn, [{handler, ?HUT},
			 {sockets, [irx]},
			 {data_paths, [grx]},
			 {proxy_sockets, ['irx']},
			 {proxy_data_paths, ['grx']},
			 {ggsn, ?FINAL_GSN},
			 {contexts,
			  [{<<"ams">>,
			    [{proxy_sockets, ['irx']},
			     {proxy_data_paths, ['grx']}]}]}
			]},
		   %% remote GGSN handler
		   {gn, [{handler, ggsn_gn},
			 {sockets, ['remote-irx']},
			 {data_paths, ['remote-grx']},
			 {aaa, [{'Username',
				 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
			]}
		  ]},

		 {apns,
		  [{?'APN-PROXY', [{vrf, example}]}
		  ]},

		 {proxy_map,
		  [{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
		   {imsi, [{?'IMSI', {?'PROXY-IMSI', ?'PROXY-MSISDN'}}
			  ]}
		  ]}			     ]},
	 {ergw_aaa, [{ergw_aaa_provider, {ergw_aaa_mock, [{shared_secret, <<"MySecret">>}]}}]}
	]).

suite() ->
    [{timetrap,{seconds,30}}].

init_per_suite(Config0) ->
    [{handler_under_test, ?HUT} | Config0].

end_per_suite(_Config) ->
    ok.

init_per_group(single_proxy_interface, Config0) ->
    Config = lists:keystore(app_cfg, 1, Config0,
			    {app_cfg, ?TEST_CONFIG_SINGLE_PROXY_SOCKET}),
    lib_init_per_suite(Config);
init_per_group(_Group, Config0) ->
    Config = lists:keystore(app_cfg, 1, Config0,
			    {app_cfg, ?TEST_CONFIG_MULTIPLE_PROXY_SOCKETS}),
    lib_init_per_suite(Config).

end_per_group(_Group, Config) ->
    ok = lib_end_per_suite(Config),
    ok.

%% groups() ->
%%     [{single_proxy_interface, [], [path_restart]}].

%% all() ->
%%     [{group, single_proxy_interface}].

groups() ->
    [{single_proxy_interface, [], all_tests()},
     {multiple_proxy_interface, [], all_tests()}].

all() ->
    [{group, single_proxy_interface},
     {group, multiple_proxy_interface}].

all_tests() ->
    [invalid_gtp_pdu,
     create_pdp_context_request_missing_ie,
     create_pdp_context_request_accept_new,
     path_restart, path_restart_recovery,
     simple_pdp_context_request,
     create_pdp_context_request_resend,
     delete_pdp_context_request_resend,
     delete_pdp_context_request_timeout,
     error_indication_sgsn2ggsn,
     error_indication_ggsn2sgsn,
     request_fast_resend,
     update_pdp_context_request_ra_update,
     update_pdp_context_request_tei_update,
     ggsn_update_pdp_context_request,
     ms_info_change_notification_request_with_tei,
     ms_info_change_notification_request_without_tei,
     ms_info_change_notification_request_invalid_imsi,
     proxy_context_selection,
     proxy_context_invalid_selection,
     proxy_context_invalid_mapping,
     proxy_context_version_restricted,
     invalid_teid,
     delete_pdp_context_requested,
     delete_pdp_context_requested_resend,
     delete_pdp_context_requested_invalid_teid,
     delete_pdp_context_requested_late_response,
     create_pdp_context_overload,
     unsupported_request,
     cache_timeout].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    meck_reset(Config).

init_per_testcase(path_restart, Config) ->
    init_per_testcase(Config),
    ok = meck:new(gtp_path, [passthrough, no_link]),
    Config;
init_per_testcase(delete_pdp_context_request_timeout, Config) ->
    init_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    ok = meck:expect(ggsn_gn, handle_request,
		     fun(ReqKey, #gtp{type = delete_pdp_context_request}, _Resent, State) ->
			     gtp_context:request_finished(ReqKey),
			     {noreply, State};
			(ReqKey, Msg, Resent, State) ->
			     meck:passthrough([ReqKey, Msg, Resent, State])
		     end),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == delete_pdp_context_requested_resend;
       TestCase == delete_pdp_context_requested_invalid_teid;
       TestCase == delete_pdp_context_requested_late_response ->
    init_per_testcase(Config),
    ok = meck:expect(gtp_socket, send_request,
		     fun(GtpPort, DstIP, DstPort, _T3, _N3,
			 #gtp{type = delete_pdp_context_request} = Msg, CbInfo) ->
			     %% reduce timeout to 1 second and 2 resends
			     %% to speed up the test
			     meck:passthrough([GtpPort, DstIP, DstPort, 1000, 2, Msg, CbInfo]);
			(GtpPort, DstIP, DstPort, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([GtpPort, DstIP, DstPort, T3, N3, Msg, CbInfo])
		     end),
    Config;
init_per_testcase(request_fast_resend, Config) ->
    init_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    ok = meck:expect(ggsn_gn, handle_request,
		     fun(Request, Msg, Resent, State) ->
			     if Resent -> ok;
				true   -> ct:sleep(1000)
			     end,
			     meck:passthrough([Request, Msg, Resent, State])
		     end),
    Config;
init_per_testcase(simple_pdp_context_request, Config) ->
    init_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    Config;
init_per_testcase(ggsn_update_pdp_context_request, Config) ->
    %% our GGSN does not send update_bearer_request, so we have to fake them
    init_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    ok = meck:expect(ggsn_gn, handle_call,
		     fun(update_context, From, #{context := Context} = State) ->
			     ergw_ggsn_test_lib:ggsn_update_context(From, Context),
			     {noreply, State};
			(Request, From, State) ->
			     meck:passthrough([Request, From, State])
		     end),
    ok = meck:expect(ggsn_gn, handle_response,
		     fun(From, #gtp{type = update_pdp_context_response}, _Request, State) ->
			     gen_server:reply(From, ok),
			     {noreply, State};
			(From, Response, Request, State) ->
			     meck:passthrough([From, Response, Request, State])
		     end),
    Config;
init_per_testcase(create_pdp_context_overload, Config) ->
    init_per_testcase(Config),
    jobs:modify_queue(create, [{max_size, 0}]),
    jobs:modify_regulator(rate, create, {rate,create,1}, [{limit,1}]),
    Config;
init_per_testcase(cache_timeout, Config) ->
    case os:getenv("CI_RUN_SLOW_TESTS") of
	"true" ->
	    init_per_testcase(Config),
	    Config;
	_ ->
	    {skip, "slow tests run only on CI"}
    end;
init_per_testcase(_, Config) ->
    init_per_testcase(Config),
    Config.

end_per_testcase(path_restart, Config) ->
    meck:unload(gtp_path),
    Config;
end_per_testcase(delete_pdp_context_request_timeout, Config) ->
    ok = meck:unload(ggsn_gn),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == delete_pdp_context_requested_resend;
       TestCase == delete_pdp_context_requested_invalid_teid;
       TestCase == delete_pdp_context_requested_late_response ->
    ok = meck:delete(gtp_socket, send_request, 7),
    Config;
end_per_testcase(request_fast_resend, Config) ->
    ok = meck:unload(ggsn_gn),
    Config;
end_per_testcase(simple_pdp_context_request, Config) ->
    meck:unload(ggsn_gn),
    Config;
end_per_testcase(ggsn_update_pdp_context_request, Config) ->
    meck:unload(ggsn_gn),
    Config;
end_per_testcase(create_pdp_context_overload, Config) ->
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
    gen_udp:send(S, ?TEST_GSN, ?GTP1c_PORT, <<"TESTDATA">>),

    ?equal({error,timeout}, gen_udp:recv(S, 4096, ?TIMEOUT)),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_missing_ie() ->
    [{doc, "Check that Create Session Request IE validation works"}].
create_pdp_context_request_missing_ie(Config) ->
    S = make_gtp_socket(Config),

    create_pdp_context(missing_ie, S),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_accept_new() ->
    [{doc, "Check the accept_new = false can block new connections"}].
create_pdp_context_request_accept_new(Config) ->
    S = make_gtp_socket(Config),

    ?equal(ergw:system_info(accept_new, false), true),
    create_pdp_context(overload, S),
    ?equal(ergw:system_info(accept_new, true), false),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_restart() ->
    [{doc, "Check that Create PDP Context Request works and "
           "that a Path Restart terminates the session"}].
path_restart(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_pdp_context(S),

    %% simulate patch restart to kill the PDP context
    Echo = make_request(echo_request, simple,
			gtp_context_inc_seq(
			  gtp_context_inc_restart_counter(GtpC))),
    send_recv_pdu(S, Echo),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_restart_recovery() ->
    [{doc, "Check that Create PDP Context Request works and "
           "that a Path Restart terminates the session"}].
path_restart_recovery(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_pdp_context(S),

    %% create 2nd session with new restart_counter (simulate SGSN restart)
    {GtpC2, _, _} = create_pdp_context('2nd', S, gtp_context_inc_restart_counter(GtpC1)),

    [?match(#{tunnels := 1}, X) || X <- ergw_api:peer(all)],

    delete_pdp_context(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
simple_pdp_context_request() ->
    [{doc, "Check simple Create PDP Context, Delete PDP Context sequence"}].
simple_pdp_context_request(Config) ->
    S = make_gtp_socket(Config),

    init_seq_no(?MODULE, 16#8000),
    GtpC0 = gtp_context(?MODULE),

    {GtpC1, _, _} = create_pdp_context(S, GtpC0),
    delete_pdp_context(S, GtpC1),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    GtpRecMatch = #gtp{type = create_pdp_context_request, _ = '_'},
    P = meck:capture(first, ?HUT, handle_request, ['_', GtpRecMatch, '_', '_'], 2),
    ?match(#gtp{seq_no = SeqNo} when SeqNo >= 16#8000, P),

    V = meck:capture(first, ggsn_gn, handle_request, ['_', GtpRecMatch, '_', '_'], 2),
    %% ct:pal("V: ~s", [ergw_test_lib:pretty_print(V)]),
    ?match(
       #gtp{ie = #{
	      {access_point_name, 0} :=
		  #access_point_name{apn = ?'APN-PROXY'},
	      {international_mobile_subscriber_identity, 0} :=
		  #international_mobile_subscriber_identity{imsi = ?'PROXY-IMSI'},
	      {ms_international_pstn_isdn_number, 0} :=
		  #ms_international_pstn_isdn_number{
		     msisdn = {isdn_address,1,1,1, ?'PROXY-MSISDN'}}}}, V),
    ?match(#gtp{seq_no = SeqNo} when SeqNo < 16#8000, V),

    ?equal([], outstanding_requests()),
    ok.

%%--------------------------------------------------------------------
duplicate_pdp_context_request() ->
    [{doc, "Check the a new incomming request for the same IMSI terminates the first"}].
duplicate_pdp_context_request(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_pdp_context(S),

    %% create 2nd PDP context with the same IMSI
    {GtpC2, _, _} = create_pdp_context(S),

    [?match(#{tunnels := 1}, X) || X <- ergw_api:peer(all)],

    delete_pdp_context(not_found, S, GtpC1),
    delete_pdp_context(S, GtpC2),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_resend() ->
    [{doc, "Check that a retransmission of a Create PDP Context Request works"}].
create_pdp_context_request_resend(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, Msg, Response} = create_pdp_context(S),
    ?equal(Response, send_recv_pdu(S, Msg)),
    ?equal([], outstanding_requests()),

    delete_pdp_context(S, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_pdp_context_request_resend() ->
    [{doc, "Check that a retransmission of a Delete PDP Context Request works"}].
delete_pdp_context_request_resend(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_pdp_context(S),
    {_, Msg, Response} = delete_pdp_context(S, GtpC),
    ?equal(Response, send_recv_pdu(S, Msg)),
    ?equal([], outstanding_requests()),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_pdp_context_request_timeout() ->
    [{doc, "Check that a Delete PDP Context Request terminates the "
           "proxy session even when the final GSN fails"}].
delete_pdp_context_request_timeout(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_pdp_context(S),
    Context = gtp_context_reg:lookup_key(#gtp_port{name = 'remote-irx'},
					 {imsi, ?'PROXY-IMSI', 5}),
    true = is_pid(Context),

    Request = make_request(delete_pdp_context_request, simple, GtpC),

    %% simulate retransmissions
    ?equal({error,timeout}, send_recv_pdu(S, Request, ?TIMEOUT, error)),
    ?equal({error,timeout}, send_recv_pdu(S, Request, ?TIMEOUT, error)),
    ?equal({error,timeout}, send_recv_pdu(S, Request, ?TIMEOUT, error)),

    %% killing the GGSN context
    exit(Context, kill),

    wait4tunnels(20000),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
error_indication_sgsn2ggsn() ->
    [{doc, "Check the a GTP-U error indication terminates the session"}].
error_indication_sgsn2ggsn(Config) ->
    S = make_gtp_socket(Config),

    {_, _, Port} = lists:keyfind(grx, 1, gtp_socket_reg:all()),
    {GtpC, _, _} = create_pdp_context(S),

    gtp_context:session_report(Port, make_error_indication_report(GtpC)),

    ct:sleep(100),
    delete_pdp_context(not_found, S, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
error_indication_ggsn2sgsn() ->
    [{doc, "Check the a GTP-U error indication terminates the session"}].
error_indication_ggsn2sgsn(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_pdp_context(S),

    CtxPid = gtp_context_reg:lookup_key(#gtp_port{name = 'irx'},
					{imsi, ?'IMSI', 5}),
    true = is_pid(CtxPid),
    #{proxy_context := Ctx} = gtp_context:info(CtxPid),

    CtxPid ! make_error_indication_report(Ctx),

    Request = recv_pdu(S, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(S, Response),

    ct:sleep(100),
    delete_pdp_context(not_found, S, GtpC),

    Context = gtp_context_reg:lookup_key(#gtp_port{name = 'remote-irx'},
					 {imsi, ?'PROXY-IMSI', 5}),
    true = is_pid(Context),
    %% killing the GGSN context
    exit(Context, kill),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
request_fast_resend() ->
    [{doc, "Check that a retransmission that arrives before the original "
      "request was processed works"}].
request_fast_resend(Config) ->
    S = make_gtp_socket(Config),
    Send = fun(Type, SubType, GtpCin) ->
		   GtpC = gtp_context_inc_seq(GtpCin),
		   Request = make_request(Type, SubType, GtpC),
		   send_pdu(S, Request),
		   Response = send_recv_pdu(S, Request),
		   validate_response(Type, SubType, Response, GtpC)
	   end,

    GtpC0 = gtp_context(),

    GtpC1 = Send(create_pdp_context_request, simple, GtpC0),
    ?equal(timeout, recv_pdu(S, -1, 100, fun(Why) -> Why end)),

    GtpC2 = Send(ms_info_change_notification_request, simple, GtpC1),
    ?equal(timeout, recv_pdu(S, -1, 100, fun(Why) -> Why end)),

    GtpC3 = Send(ms_info_change_notification_request, without_tei, GtpC2),
    ?equal(timeout, recv_pdu(S, -1, 100, fun(Why) -> Why end)),

    ?equal([], outstanding_requests()),

    delete_pdp_context(S, GtpC3),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(3, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),
    ?match(3, meck:num_calls(ggsn_gn, handle_request, ['_', '_', true, '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
update_pdp_context_request_ra_update() ->
    [{doc, "Check Update PDP Context with Routing Area Update"}].
update_pdp_context_request_ra_update(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_pdp_context(S),
    {GtpC2, _, _} = update_pdp_context(ra_update, S, GtpC1),
    ?equal([], outstanding_requests()),
    delete_pdp_context(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
update_pdp_context_request_tei_update() ->
    [{doc, "Check Update PDP Context with TEID update (e.g. SGSN change)"}].
update_pdp_context_request_tei_update(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_pdp_context(S),
    {GtpC2, _, _} = update_pdp_context(tei_update, S, GtpC1),
    ?equal([], outstanding_requests()),
    delete_pdp_context(S, GtpC2),

    SMR = meck:capture(first, ergw_sx, call, [#context{apn = ?'APN-EXAMPLE', _='_'},
					      session_modification_request, '_'], 3),
    FAR = hd(maps:get(update_far, SMR)),
    SxSMReqFlags = maps:get(sxsmreq_flags, FAR, []),
    ?equal(false, proplists:get_bool(sndem, SxSMReqFlags)),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
ms_info_change_notification_request_with_tei() ->
    [{doc, "Check Ms_Info_Change Notification request with TEID"}].
ms_info_change_notification_request_with_tei(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_pdp_context(S),
    {GtpC2, _, _} = ms_info_change_notification(simple, S, GtpC1),
    ?equal([], outstanding_requests()),
    delete_pdp_context(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
ms_info_change_notification_request_without_tei() ->
    [{doc, "Check Ms_Info_Change Notification request without TEID "
           "include IMEI and IMSI instead"}].
ms_info_change_notification_request_without_tei(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_pdp_context(S),
    {GtpC2, _, _} = ms_info_change_notification(without_tei, S, GtpC1),
    ?equal([], outstanding_requests()),
    delete_pdp_context(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
ms_info_change_notification_request_invalid_imsi() ->
    [{doc, "Check Ms_Info_Change Notification request without TEID "
           "include a invalid IMEI and IMSI instead"}].
ms_info_change_notification_request_invalid_imsi(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_pdp_context(S),
    {GtpC2, _, _} = ms_info_change_notification(invalid_imsi, S, GtpC1),
    ?equal([], outstanding_requests()),
    delete_pdp_context(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
proxy_context_selection() ->
    [{doc, "Check that the proxy context selection works"}].
proxy_context_selection(Config) ->
    ok = meck:new(gtp_proxy_ds, [passthrough]),
    meck:expect(gtp_proxy_ds, map,
		fun(ProxyInfo) ->
			proxy_context_selection_map(ProxyInfo, <<"ams">>)
		end),

    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_pdp_context(S),
    ?equal([], outstanding_requests()),
    delete_pdp_context(S, GtpC),

    meck:unload(gtp_proxy_ds),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
proxy_context_invalid_selection() ->
    [{doc, "Check that the proxy context selection works"}].
proxy_context_invalid_selection(Config) ->
    ok = meck:new(gtp_proxy_ds, [passthrough]),
    meck:expect(gtp_proxy_ds, map,
		fun(ProxyInfo) ->
			proxy_context_selection_map(ProxyInfo, <<"undefined">>)
		end),

    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_pdp_context(S),
    ?equal([], outstanding_requests()),
    delete_pdp_context(S, GtpC),

    meck:unload(gtp_proxy_ds),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
proxy_context_invalid_mapping() ->
    [{doc, "Check rejection of a session when the proxy selects failes"}].
proxy_context_invalid_mapping(Config) ->
    ok = meck:new(gtp_proxy_ds, [passthrough]),
    meck:expect(gtp_proxy_ds, map,
		fun(_ProxyInfo) -> {error, not_found} end),

    S = make_gtp_socket(Config),

    {_, _, _} = create_pdp_context(invalid_mapping, S),
    ?equal([], outstanding_requests()),

    meck:unload(gtp_proxy_ds),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
proxy_context_version_restricted() ->
    [{doc, "Check GTP version restriction on proxy contexts"}].
proxy_context_version_restricted(Config) ->
    ok = meck:new(gtp_proxy_ds, [passthrough]),
    meck:expect(gtp_proxy_ds, map,
		fun(ProxyInfo) ->
			{ok, ProxyInfo#proxy_info{ggsns = [#proxy_ggsn{restrictions = [{v1, false}]}]}}
		end),

    S = make_gtp_socket(Config),

    {_, _, _} = create_pdp_context(version_restricted, S),
    ?equal([], outstanding_requests()),

    meck:unload(gtp_proxy_ds),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
invalid_teid() ->
    [{doc, "Check invalid TEID's for a number of request types"}].
invalid_teid(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_pdp_context(S),
    {GtpC2, _, _} = delete_pdp_context(invalid_teid, S, GtpC1),
    {GtpC3, _, _} = update_pdp_context(invalid_teid, S, GtpC2),
    {GtpC4, _, _} = ms_info_change_notification(invalid_teid, S, GtpC3),
    ?equal([], outstanding_requests()),
    delete_pdp_context(S, GtpC4),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_pdp_context_requested() ->
    [{doc, "Check GGSN initiated Delete PDP Context"}].
delete_pdp_context_requested(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_pdp_context(S),

    Context = gtp_context_reg:lookup_key(#gtp_port{name = 'remote-irx'},
					 {imsi, ?'PROXY-IMSI', 5}),
    true = is_pid(Context),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Context)} end),

    Request = recv_pdu(S, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
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
delete_pdp_context_requested_resend() ->
    [{doc, "Check resend of GGSN initiated Delete PDP Context"}].
delete_pdp_context_requested_resend(Config) ->
    S = make_gtp_socket(Config),

    {_, _, _} = create_pdp_context(S),

    Context = gtp_context_reg:lookup_key(#gtp_port{name = 'remote-irx'},
					 {imsi, ?'PROXY-IMSI', 5}),
    true = is_pid(Context),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Context)} end),

    Request = recv_pdu(S, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    ?equal(Request, recv_pdu(S, 5000)),
    ?equal(Request, recv_pdu(S, 5000)),

    receive
	{req, {error, timeout}} ->
	    ok
    after ?TIMEOUT ->
	    ct:fail(timeout)
    end,

    ?match([_], outstanding_requests()),
    wait4tunnels(20000),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_pdp_context_requested_invalid_teid() ->
    [{doc, "Check error response of GGSN initiated Delete PDP Context with invalid TEID"}].
delete_pdp_context_requested_invalid_teid(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_pdp_context(S),

    Context = gtp_context_reg:lookup_key(#gtp_port{name = 'remote-irx'},
					 {imsi, ?'PROXY-IMSI', 5}),
    true = is_pid(Context),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Context)} end),

    Request = recv_pdu(S, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),

    Response = make_response(Request, invalid_teid, GtpC),
    send_pdu(S, Response),

    receive
	{req, {ok, context_not_found}} ->
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
delete_pdp_context_requested_late_response() ->
    [{doc, "Check a answer folling a resend of GGSN initiated Delete PDP Context"}].
delete_pdp_context_requested_late_response(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_pdp_context(S),

    Context = gtp_context_reg:lookup_key(#gtp_port{name = 'remote-irx'},
					 {imsi, ?'PROXY-IMSI', 5}),
    true = is_pid(Context),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Context)} end),

    Request = recv_pdu(S, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    ?equal(Request, recv_pdu(S, 5000)),
    ?equal(Request, recv_pdu(S, 5000)),

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
ggsn_update_pdp_context_request() ->
    [{doc, "Check GGSN initiated Update PDP Context"},
     {timetrap,{seconds,60}}].
ggsn_update_pdp_context_request(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_pdp_context(S),

    Context = gtp_context_reg:lookup_key(#gtp_port{name = 'remote-irx'},
					 {imsi, ?'PROXY-IMSI', 5}),
    true = is_pid(Context),

    Self = self(),
    spawn(fun() -> Self ! {req, gen_server:call(Context, update_context)} end),

    Request = recv_pdu(S, 5000),
    ?match(#gtp{type = update_pdp_context_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(S, Response),

    receive
	{req, ok} ->
	    ok;
	{req, Other} ->
	    ct:fail(Other)
    after ?TIMEOUT ->
	    ct:fail(timeout)
    end,

    ?equal([], outstanding_requests()),
    delete_pdp_context(S, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_overload() ->
    [{doc, "Check that the overload protection works"}].
create_pdp_context_overload(Config) ->
    S = make_gtp_socket(Config),

    create_pdp_context(overload, S),
    ?equal([], outstanding_requests()),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
unsupported_request() ->
    [{doc, "Check that unsupported requests are silently ignore and don't get stuck"}].
unsupported_request(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_pdp_context(S),
    Request = make_request(unsupported, simple, GtpC),

    ?equal({error,timeout}, send_recv_pdu(S, Request, ?TIMEOUT, error)),
    ?equal([], outstanding_requests()),

    delete_pdp_context(S, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
cache_timeout() ->
    [{doc, "Check GTP socket queue timeout"}, {timetrap, {seconds, 150}}].
cache_timeout(Config) ->
    GtpPort =
	case gtp_socket_reg:lookup('proxy-irx') of
	    undefined ->
		gtp_socket_reg:lookup('irx');
	    Other ->
		Other
	end,
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_pdp_context(S),
    delete_pdp_context(S, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    {T0, Q0} = gtp_socket:get_request_q(GtpPort),
    ?match(X when X /= 0, length(T0)),
    ?match(X when X /= 0, length(Q0)),

    ct:sleep({seconds, 120}),

    {T1, Q1} = gtp_socket:get_request_q(GtpPort),
    ?equal(0, length(T1)),
    ?equal(0, length(Q1)),

    meck_validate(Config),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

proxy_context_selection_map(ProxyInfo, Context) ->
    case meck:passthrough([ProxyInfo]) of
	{ok, #proxy_info{ggsns = GGSNs} = P} ->
		{ok, P#proxy_info{ggsns = [GGSN#proxy_ggsn{context = Context} || GGSN <- GGSNs]}};
	Other ->
	    Other
    end.
