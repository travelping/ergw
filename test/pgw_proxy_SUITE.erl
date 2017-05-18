%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_proxy_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("../include/ergw.hrl").
-include("../include/gtp_proxy_ds.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_pgw_test_lib.hrl").

-define(TIMEOUT, 2000).
-define(HUT, pgw_s5s8_proxy).			%% Handler Under Test

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
		  {handlers, [{lager_console_backend, info}]}
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
			 {pgw, ?FINAL_GSN}
			]},
		   {s5s8, [{handler, ?HUT},
			   {sockets, [irx]},
			   {data_paths, [grx]},
			   {proxy_sockets, ['proxy-irx']},
			   {proxy_data_paths, ['proxy-grx']},
			   {pgw, ?FINAL_GSN},
			   {contexts,
			    [{<<"ams">>,
			      [{proxy_sockets, ['proxy-irx']},
			       {proxy_data_paths, ['proxy-grx']}]}]}
			  ]},
		   %% remote PGW handler
		   {gn, [{handler, pgw_s5s8},
			 {sockets, ['remote-irx']},
			 {data_paths, ['remote-grx']},
			 {aaa, [{'Username',
				 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
			]},
		   {s5s8, [{handler, pgw_s5s8},
			   {sockets, ['remote-irx']},
			   {data_paths, ['remote-grx']}
			  ]}
		  ]},

		 {apns,
		  [{?'APN-PROXY', [{vrf, example}]}
		  ]},

		 {proxy_map,
		  [{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
		   {imsi, [{?'IMSI', {?'PROXY-IMSI', ?'PROXY-MSISDN'}}
			  ]}
		  ]}
		]},
	 {ergw_aaa, [{ergw_aaa_provider, {ergw_aaa_mock, [{secret, <<"MySecret">>}]}}]}
	]).

-define(TEST_CONFIG_SINGLE_PROXY_SOCKET,
	[
	 {lager, [{colored, true},
		  {error_logger_redirect, true},
		  %% force lager into async logging, otherwise
		  %% the test will timeout randomly
		  {async_threshold, undefined},
		  {handlers, [{lager_console_backend, info}]}
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
			 {pgw, ?FINAL_GSN}
			]},
		   {s5s8, [{handler, ?HUT},
			   {sockets, [irx]},
			   {data_paths, [grx]},
			   {proxy_sockets, ['irx']},
			   {proxy_data_paths, ['grx']},
			   {pgw, ?FINAL_GSN},
			   {contexts,
			    [{<<"ams">>,
			      [{proxy_sockets, ['irx']},
			       {proxy_data_paths, ['grx']}]}]}
			  ]},
		   %% remote PGW handler
		   {gn, [{handler, pgw_s5s8},
			 {sockets, ['remote-irx']},
			 {data_paths, ['remote-grx']},
			 {aaa, [{'Username',
				 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
			]},
		   {s5s8, [{handler, pgw_s5s8},
			   {sockets, ['remote-irx']},
			   {data_paths, ['remote-grx']}
			  ]}
		  ]},

		 {apns,
		  [{?'APN-PROXY', [{vrf, example}]}
		  ]},

		 {proxy_map,
		  [{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
		   {imsi, [{?'IMSI', {?'PROXY-IMSI', ?'PROXY-MSISDN'}}
			  ]}
		  ]}
		]},
	 {ergw_aaa, [{ergw_aaa_provider, {ergw_aaa_mock, [{secret, <<"MySecret">>}]}}]}
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

groups() ->
    [{single_proxy_interface, [], all_tests()},
     {multiple_proxy_interface, [], all_tests()}].

all() ->
    [{group, single_proxy_interface},
     {group, multiple_proxy_interface}].

all_tests() ->
    [invalid_gtp_pdu,
     create_session_request_missing_ie,
     create_session_request_accept_new,
     path_restart, path_restart_recovery,
     simple_session,
     create_session_overload_response,
     create_session_request_resend,
     delete_session_request_resend,
     modify_bearer_request_ra_update,
     modify_bearer_request_tei_update,
     modify_bearer_command,
     update_bearer_request,
     change_notification_request_with_tei,
     change_notification_request_without_tei,
     change_notification_request_invalid_imsi,
     suspend_notification_request,
     resume_notification_request,
     proxy_context_selection,
     proxy_context_invalid_selection,
     proxy_context_invalid_mapping,
     requests_invalid_teid,
     commands_invalid_teid,
     delete_bearer_request,
     delete_bearer_request_resend,
     interop_sgsn_to_sgw,
     interop_sgw_to_sgsn].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    meck_reset(Config).

init_per_testcase(delete_session_request_resend, Config) ->
    init_per_testcase(Config),
    ok = meck:new(gtp_path, [passthrough, no_link]),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == delete_bearer_request_resend ->
    init_per_testcase(Config),
    ok = meck:expect(gtp_socket, send_request,
		     fun(GtpPort, From, RemoteIP, _T3, _N3,
			 #gtp{type = delete_bearer_request} = Msg, ReqId) ->
			     %% reduce timeout to 1 second and 2 resends
			     %% to speed up the test
			     meck:passthrough([GtpPort, From, RemoteIP,
					       1000, 2, Msg, ReqId]);
			(GtpPort, From, RemoteIP, T3, N3, Msg, ReqId) ->
			     meck:passthrough([GtpPort, From, RemoteIP,
					       T3, N3, Msg, ReqId])
		     end),
    Config;
init_per_testcase(simple_session, Config) ->
    init_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    Config;
init_per_testcase(create_session_overload_response, Config) ->
    init_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    ok = meck:expect(pgw_s5s8, handle_request,
		     fun(_ReqKey, Request, _Resent, State) ->
			     Reply = make_response(Request, overload, undefined),
			     {stop, Reply, State}
		     end),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == interop_sgsn_to_sgw;
       TestCase == interop_sgw_to_sgsn ->
    init_per_testcase(Config),
    ok = meck:new(ggsn_gn_proxy, [passthrough, no_link]),
    Config;
init_per_testcase(update_bearer_request, Config) ->
    %% our PGW does not send update_bearer_request, so we have to fake them
    init_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    ok = meck:expect(pgw_s5s8, handle_call,
		     fun(update_context, From, #{context := Context} = State) ->
			     ergw_pgw_test_lib:pgw_update_context(From, Context),
			     {noreply, State};
			(Request, From, State) ->
			     meck:passthrough([Request, From, State])
		     end),
    ok = meck:expect(pgw_s5s8, handle_response,
		     fun(From, #gtp{type = update_bearer_response}, _Request, State) ->
			     gen_server:reply(From, ok),
			     {noreply, State};
			(From, Response, Request, State) ->
			     meck:passthrough([From, Response, Request, State])
		     end),
    Config;

init_per_testcase(_, Config) ->
    init_per_testcase(Config),
    Config.

end_per_testcase(delete_session_request_resend, Config) ->
    meck:unload(gtp_path),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == delete_bearer_request_resend ->
    ok = meck:delete(gtp_socket, send_request, 7),
    Config;
end_per_testcase(simple_session, Config) ->
    ok = meck:unload(pgw_s5s8),
    Config;
end_per_testcase(create_session_overload_response, Config) ->
    ok = meck:unload(pgw_s5s8),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == interop_sgsn_to_sgw;
       TestCase == interop_sgw_to_sgsn ->
    ok = meck:unload(ggsn_gn_proxy),
    Config;
end_per_testcase(update_bearer_request, Config) ->
    ok = meck:unload(pgw_s5s8),
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
create_session_overload_response() ->
    [{doc, "Check that Create Session Response with Cuase Overload works"}].
create_session_overload_response(Config) ->
    S = make_gtp_socket(Config),

    create_session(overload, S),

    meck_validate(Config),
    ok.


%%--------------------------------------------------------------------
path_restart() ->
    [{doc, "Check that Create Session Request works and "
           "that a Path Restart terminates the session"}].
path_restart(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_session(S),

    %% simulate patch restart to kill the PDP context
    Echo = make_request(echo_request, simple,
			gtp_context_inc_seq(
			  gtp_context_inc_restart_counter(GtpC))),
    send_recv_pdu(S, Echo),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_restart_recovery() ->
    [{doc, "Check that Create Session Request works, "
           "that a Path Restart terminates the session, "
           "and that a new Create Session Request also works"}].
path_restart_recovery(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_session(S),

    %% create 2nd session with new restart_counter (simulate SGW restart)
    {GtpC2, _, _} = create_session(S, gtp_context_inc_restart_counter(GtpC1)),

    delete_session(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
simple_session() ->
    [{doc, "Check simple Create Session, Delete Session sequence"}].
simple_session(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_session(S),
    delete_session(S, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    GtpRecMatch0 = list_to_tuple([gtp | lists:duplicate(record_info(size, gtp) - 1, '_')]),
    GtpRecMatch = GtpRecMatch0#gtp{type = create_session_request},
    V = meck:capture(first, pgw_s5s8, handle_request, ['_', GtpRecMatch, '_', '_'], 2),
    ct:pal("V: ~p", [ergw_test_lib:pretty_print(V)]),
    ?match(
       #gtp{ie = #{
	      {v2_access_point_name, 0} := #v2_access_point_name{apn = ?'APN-PROXY'},
	      {v2_international_mobile_subscriber_identity, 0} :=
		   #v2_international_mobile_subscriber_identity{imsi = ?'PROXY-IMSI'},
	      {v2_msisdn, 0} := #v2_msisdn{msisdn = ?'PROXY-MSISDN'}
	     }}, V),
    ok.

%%--------------------------------------------------------------------
create_session_request_resend() ->
    [{doc, "Check that a retransmission of a Create Session Request works"}].
create_session_request_resend(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, Msg, Response} = create_session(S),
    ?match(Response, send_recv_pdu(S, Msg)),

    delete_session(S, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_session_request_resend() ->
    [{doc, "Check that a retransmission of a Delete Session Request works"}].
delete_session_request_resend(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_session(S),
    {_, Msg, Response} = delete_session(S, GtpC),
    ?match(Response, send_recv_pdu(S, Msg)),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
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

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_command() ->
    [{doc, "Check Modify Bearer Command"}].
modify_bearer_command(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, Req} = modify_bearer_command(simple, S, GtpC1),
    ?equal({ok, timeout}, recv_pdu(S, Req#gtp.seq_no, ?TIMEOUT, ok)),
    delete_session(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
change_notification_request_with_tei() ->
    [{doc, "Check Change Notification request with TEID"}].
change_notification_request_with_tei(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, _, _} = change_notification(simple, S, GtpC1),
    delete_session(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
change_notification_request_without_tei() ->
    [{doc, "Check Change Notification request without TEID "
           "include IMEI and IMSI instead"}].
change_notification_request_without_tei(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, _, _} = change_notification(without_tei, S, GtpC1),
    delete_session(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
change_notification_request_invalid_imsi() ->
    [{doc, "Check Change Notification request without TEID "
           "include a invalid IMEI and IMSI instead"}].
change_notification_request_invalid_imsi(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, _, _} = change_notification(invalid_imsi, S, GtpC1),
    delete_session(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
suspend_notification_request() ->
    [{doc, "Check that Suspend Notification works"}].
suspend_notification_request(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, _, _} = suspend_notification(simple, S, GtpC1),
    delete_session(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
resume_notification_request() ->
    [{doc, "Check that Resume Notification works"}].
resume_notification_request(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, _, _} = resume_notification(simple, S, GtpC1),
    delete_session(S, GtpC2),

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

    {GtpC, _, _} = create_session(S),
    delete_session(S, GtpC),

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

    {GtpC, _, _} = create_session(S),
    delete_session(S, GtpC),

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

    {_, _, _} = create_session(invalid_mapping, S),

    meck:unload(gtp_proxy_ds),

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
    {GtpC3, _, _} = change_notification(invalid_teid, S, GtpC2),
    {GtpC4, _, _} = suspend_notification(invalid_teid, S, GtpC3),
    {GtpC5, _, _} = resume_notification(invalid_teid, S, GtpC4),
    delete_session(S, GtpC5),

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

    Context = gtp_context_reg:lookup(#gtp_port{name = 'remote-irx'},
				     {imsi, ?'PROXY-IMSI'}),
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

    Context = gtp_context_reg:lookup(#gtp_port{name = 'remote-irx'},
				     {imsi, ?'PROXY-IMSI'}),
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
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
interop_sgsn_to_sgw() ->
    [{doc, "Check 3GPP T 23.401, Annex D, SGSN to SGW handover"}].
interop_sgsn_to_sgw(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = ergw_ggsn_test_lib:create_pdp_context(S),
    {GtpC2, _, _} = modify_bearer(tei_update, S, GtpC1),
    delete_session(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    true = meck:validate(ggsn_gn_proxy),
    ok.

%%--------------------------------------------------------------------
interop_sgw_to_sgsn() ->
    [{doc, "Check 3GPP T 23.401, Annex D, SGW to SGSN handover"}].
interop_sgw_to_sgsn(Config) ->
    S = make_gtp_socket(Config),

    {GtpC1, _, _} = create_session(S),
    {GtpC2, _, _} = ergw_ggsn_test_lib:update_pdp_context(tei_update, S, GtpC1),
    ergw_ggsn_test_lib:delete_pdp_context(S, GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    true = meck:validate(ggsn_gn_proxy),
    ok.

%%--------------------------------------------------------------------
update_bearer_request() ->
    [{doc, "Check PGW initiated Update Bearer"},
     {timetrap,{seconds,60}}].
update_bearer_request(Config) ->
    S = make_gtp_socket(Config),

    {GtpC, _, _} = create_session(S),

    Context = gtp_context_reg:lookup(#gtp_port{name = 'remote-irx'},
				     {imsi, ?'PROXY-IMSI'}),
    true = is_pid(Context),

    Self = self(),
    spawn(fun() -> Self ! {req, gen_server:call(Context, update_context)} end),

    Request = recv_pdu(S, 5000),
    ?match(#gtp{type = update_bearer_request}, Request),
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

    delete_session(S, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

proxy_context_selection_map(ProxyInfo, Context) ->
    case meck:passthrough([ProxyInfo]) of
	{ok, #proxy_info{} = P} ->
	    {ok, P#proxy_info{context = Context}};
	Other ->
	    Other
    end.
