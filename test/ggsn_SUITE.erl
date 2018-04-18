%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_ggsn_test_lib.hrl").

-define(TIMEOUT, 2000).
-define(HUT, ggsn_gn).				%% Handler Under Test

%%%===================================================================
%%% Config
%%%===================================================================

-define(TEST_CONFIG,
	[
	 {lager, [{colored, true},
		  {error_logger_redirect, false},
		  %% force lager into async logging, otherwise
		  %% the test will timeout randomly
		  {async_threshold, undefined},
		  {handlers, [{lager_console_backend, [{level, info}]}]}
		 ]},

	 {ergw, [{'$setup_vars',
		  [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
		 {sockets,
		  [{irx, [{type, 'gtp-c'},
			  {ip,  ?MUST_BE_UPDATED},
			  {reuseaddr, true}
			 ]}
		  ]},

		 {vrfs,
		  [{upstream, [{pools,  [{{10, 180, 0, 1}, {10, 180, 255, 254}, 32},
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
		  [{gn, [{handler, ggsn_gn},
			 {sockets, [irx]},
			 {node_selection, [default]},
			 {aaa, [{'Username',
				 [{default, ['IMSI',   <<"/">>,
					     'IMEI',   <<"/">>,
					     'MSISDN', <<"/">>,
					     'ATOM',   <<"/">>,
					     "TEXT",   <<"/">>,
					     12345,
					     <<"@">>, 'APN']}]}]}
			]}
		  ]},

		 {node_selection,
		  [{default,
		    {static,
		     [
		      %% APN NAPTR alternative
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-ggsn","x-gn"},{"x-3gpp-ggsn","x-gp"}],
		       "topon.gn.ggsn.$ORIGIN"},
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.prox01.$ORIGIN"},

		      %% A/AAAA record alternatives
		      {"topon.gn.ggsn.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.prox01.$ORIGIN", ?MUST_BE_UPDATED, []}
		     ]
		    }
		   }
		  ]
		 },

		 {sx_socket,
		  [{node, 'ergw'},
		   {name, 'ergw'},
		   {ip, ?MUST_BE_UPDATED},
		   {reuseaddr, true}]},

		 {apns,
		  [{?'APN-EXAMPLE', [{vrf, upstream}]},
		   {[<<"APN1">>], [{vrf, upstream}]}
		  ]}
		]},
	 {ergw_aaa, [{ergw_aaa_provider, {ergw_aaa_mock, [{shared_secret, <<"MySecret">>}]}}]}
	]).


-define(CONFIG_UPDATE,
	[{[sockets, irx, ip], test_gsn},
	 {[sx_socket, ip], localhost},
	 {[node_selection, {default, 2}, 2, "topon.gn.ggsn.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox01.$ORIGIN"],
	  {fun node_sel_update/2, pgw_u_sx}}
	]).

node_sel_update(Node, {_,_,_,_} = IP) ->
    {Node, [IP], []};
node_sel_update(Node, {_,_,_,_,_,_,_,_} = IP) ->
    {Node, [], [IP]}.

%%%===================================================================
%%% Setup
%%%===================================================================

suite() ->
    [{timetrap,{seconds,30}}].

init_per_suite(Config0) ->
    Config1 = [{handler_under_test, ?HUT},
	       {app_cfg, ?TEST_CONFIG}
	       | Config0],

    Config = update_app_config(ipv4, ?CONFIG_UPDATE, Config1),
    lib_init_per_suite(Config).

end_per_suite(Config) ->
    ok = lib_end_per_suite(Config),
    ok.

all() ->
    [invalid_gtp_pdu,
     invalid_gtp_msg,
     create_pdp_context_request_missing_ie,
     create_pdp_context_request_aaa_reject,
     create_pdp_context_request_invalid_apn,
     create_pdp_context_request_accept_new,
     path_restart, path_restart_recovery, path_restart_multi,
     simple_pdp_context_request,
     duplicate_pdp_context_request,
     error_indication,
     ipv6_pdp_context_request,
     ipv4v6_pdp_context_request,
     request_fast_resend,
     create_pdp_context_request_resend,
     delete_pdp_context_request_resend,
     update_pdp_context_request_ra_update,
     update_pdp_context_request_tei_update,
     ms_info_change_notification_request_with_tei,
     ms_info_change_notification_request_without_tei,
     ms_info_change_notification_request_invalid_imsi,
     invalid_teid,
     delete_pdp_context_requested,
     delete_pdp_context_requested_resend,
     create_pdp_context_overload,
     unsupported_request,
     cache_timeout,
     session_accounting].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    ergw_test_sx_up:reset('pgw-u'),
    meck_reset(Config),
    start_gtpc_server(Config).

init_per_testcase(create_pdp_context_request_aaa_reject, Config) ->
    init_per_testcase(Config),
    ok = meck:new(ergw_aaa_session, [passthrough, no_link]),
    ok = meck:expect(ergw_aaa_session,authenticate,
		     fun(_Session, _SessionOpts) ->
			     {fail, []}
		     end),
    Config;
init_per_testcase(path_restart, Config) ->
    init_per_testcase(Config),
    ok = meck:new(gtp_path, [passthrough, no_link]),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == delete_pdp_context_requested_resend ->
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
    ok = meck:expect(?HUT, handle_request,
		     fun(Request, Msg, Resent, State) ->
			     if Resent -> ok;
				true   -> ct:sleep(1000)
			     end,
			     meck:passthrough([Request, Msg, Resent, State])
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

end_per_testcase(_Config) ->
    stop_gtpc_server().

end_per_testcase(create_pdp_context_request_aaa_reject, Config) ->
    meck:unload(ergw_aaa_session),
    end_per_testcase(Config),
    Config;
end_per_testcase(path_restart, Config) ->
    meck:unload(gtp_path),
    end_per_testcase(Config),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == delete_pdp_context_requested_resend ->
    ok = meck:delete(gtp_socket, send_request, 7),
    end_per_testcase(Config),
    Config;
end_per_testcase(request_fast_resend, Config) ->
    ok = meck:delete(?HUT, handle_request, 4),
    end_per_testcase(Config),
    Config;
end_per_testcase(create_pdp_context_overload, Config) ->
    jobs:modify_queue(create, [{max_size, 10}]),
    jobs:modify_regulator(rate, create, {rate,create,1}, [{limit,100}]),
    end_per_testcase(Config),
    Config;
end_per_testcase(_, Config) ->
    end_per_testcase(Config),
    Config.

%%--------------------------------------------------------------------
invalid_gtp_pdu() ->
    [{doc, "Test that an invalid PDU is silently ignored"
      " and that the GTP socket is not crashing"}].
invalid_gtp_pdu(Config) ->
    TestGSN = proplists:get_value(test_gsn, Config),

    S = make_gtp_socket(Config),
    gen_udp:send(S, TestGSN, ?GTP1c_PORT, <<"TESTDATA">>),

    ?equal({error,timeout}, gen_udp:recv(S, 4096, ?TIMEOUT)),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
invalid_gtp_msg() ->
    [{doc, "Test that an invalid message is silently ignored"
      " and that the GTP socket is not crashing"}].
invalid_gtp_msg(Config) ->
    TestGSN = proplists:get_value(test_gsn, Config),
    Msg = hexstr2bin("320000040000000044000000"),

    S = make_gtp_socket(Config),
    gen_udp:send(S, TestGSN, ?GTP1c_PORT, Msg),

    ?equal({error,timeout}, gen_udp:recv(S, 4096, ?TIMEOUT)),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_missing_ie() ->
    [{doc, "Check that Create Session Request IE validation works"}].
create_pdp_context_request_missing_ie(Config) ->
    create_pdp_context(missing_ie, Config),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_aaa_reject() ->
    [{doc, "Check AAA reject return on Create PDP Context Request"}].
create_pdp_context_request_aaa_reject(Config) ->
    create_pdp_context(aaa_reject, Config),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_invalid_apn() ->
    [{doc, "Check invalid APN return on Create PDP Context Request"}].
create_pdp_context_request_invalid_apn(Config) ->
    create_pdp_context(invalid_apn, Config),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_accept_new() ->
    [{doc, "Check the accept_new = false can block new contexts"}].
create_pdp_context_request_accept_new(Config) ->
    ?equal(ergw:system_info(accept_new, false), true),
    create_pdp_context(overload, Config),
    ?equal(ergw:system_info(accept_new, true), false),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_restart() ->
    [{doc, "Check that Create PDP Context Request works and "
           "that a Path Restart terminates the session"}].
path_restart(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),

    %% simulate patch restart to kill the PDP context
    Echo = make_request(echo_request, simple,
			gtp_context_inc_seq(
			  gtp_context_inc_restart_counter(GtpC))),
    send_recv_pdu(GtpC, Echo),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_restart_recovery() ->
    [{doc, "Check that Create PDP Context Request works and "
           "that a Path Restart terminates the session"}].
path_restart_recovery(Config) ->
    {GtpC1, _, _} = create_pdp_context(Config),

    %% create 2nd session with new restart_counter (simulate SGSN restart)
    {GtpC2, _, _} = create_pdp_context(gtp_context_inc_restart_counter(GtpC1)),

    [?match(#{tunnels := 1}, X) || X <- ergw_api:peer(all)],

    delete_pdp_context(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_restart_multi() ->
    [{doc, "Check that a Path Restart terminates multiple sessions"}].
path_restart_multi(Config) ->
    {GtpC0, _, _} = create_pdp_context(Config),
    {GtpC1, _, _} = create_pdp_context(random, GtpC0),
    {GtpC2, _, _} = create_pdp_context(random, GtpC1),
    {GtpC3, _, _} = create_pdp_context(random, GtpC2),
    {GtpC4, _, _} = create_pdp_context(random, GtpC3),

    [?match(#{tunnels := 5}, X) || X <- ergw_api:peer(all)],

    %% simulate patch restart to kill the PDP context
    Echo = make_request(echo_request, simple,
			gtp_context_inc_seq(
			  gtp_context_inc_restart_counter(GtpC4))),
    send_recv_pdu(GtpC4, Echo),

    ok = meck:wait(5, ?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
simple_pdp_context_request() ->
    [{doc, "Check simple Create PDP Context, Delete PDP Context sequence"}].
simple_pdp_context_request(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),
    delete_pdp_context(GtpC),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
duplicate_pdp_context_request() ->
    [{doc, "Check the a new incomming request for the same IMSI terminates the first"}].
duplicate_pdp_context_request(Config) ->
    {GtpC1, _, _} = create_pdp_context(Config),

    %% create 2nd PDP context with the same IMSI
    {GtpC2, _, _} = create_pdp_context(GtpC1),

    [?match(#{tunnels := 1}, X) || X <- ergw_api:peer(all)],

    delete_pdp_context(not_found, GtpC1),
    delete_pdp_context(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
error_indication() ->
    [{doc, "Check the a GTP-U error indication terminates the context"}].
error_indication(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),

    ergw_test_sx_up:send('pgw-u', make_error_indication_report(GtpC)),

    ct:sleep(100),
    delete_pdp_context(not_found, GtpC),

    [?match(#{tunnels := 0}, X) || X <- ergw_api:peer(all)],

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
ipv6_pdp_context_request() ->
    [{doc, "Check Create PDP Context, Delete PDP Context sequence "
           "for IPv6 contexts"}].
ipv6_pdp_context_request(Config) ->
    {GtpC, _, _} = create_pdp_context(ipv6, Config),
    delete_pdp_context(GtpC),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
ipv4v6_pdp_context_request() ->
    [{doc, "Check Create PDP Context, Delete PDP Context sequence "
           "for dual stack IPv4/IPv6 contexts"}].
ipv4v6_pdp_context_request(Config) ->
    {GtpC, _, _} = create_pdp_context(ipv4v6, Config),
    delete_pdp_context(GtpC),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
request_fast_resend() ->
    [{doc, "Check that a retransmission that arrives before the original "
      "request was processed works"}].
request_fast_resend(Config) ->
    Send = fun(Type, SubType, GtpCin) ->
		   GtpC = gtp_context_inc_seq(GtpCin),
		   Request = make_request(Type, SubType, GtpC),
		   send_pdu(GtpC, Request),
		   Response = send_recv_pdu(GtpC, Request),
		   ?equal([], outstanding_requests()),
		   validate_response(Type, SubType, Response, GtpC)
	   end,

    GtpC0 = gtp_context(Config),

    GtpC1 = Send(create_pdp_context_request, simple, GtpC0),
    ?equal(timeout, recv_pdu(GtpC1, -1, 100, fun(Why) -> Why end)),

    GtpC2 = Send(ms_info_change_notification_request, simple, GtpC1),
    ?equal(timeout, recv_pdu(GtpC2, -1, 100, fun(Why) -> Why end)),

    GtpC3 = Send(ms_info_change_notification_request, without_tei, GtpC2),
    ?equal(timeout, recv_pdu(GtpC3, -1, 100, fun(Why) -> Why end)),

    delete_pdp_context(GtpC3),

    ?match(3, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_resend() ->
    [{doc, "Check that a retransmission of a Create PDP Context Request works"}].
create_pdp_context_request_resend(Config) ->
    CntId = [socket,'gtp-c',irx,rx,v1,create_pdp_context_request,count],
    DupId = [socket,'gtp-c',irx,rx,v1,create_pdp_context_request,duplicate],
    Cnt0 = get_exo_value(CntId),
    Dup0 = get_exo_value(DupId),

    {GtpC, Msg, Response} = create_pdp_context(Config),
    match_exo_value(CntId, Cnt0 + 1),
    ?equal(Response, send_recv_pdu(GtpC, Msg)),
    ?equal([], outstanding_requests()),

    delete_pdp_context(GtpC),
    match_exo_value(DupId, Dup0 + 1),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_pdp_context_request_resend() ->
    [{doc, "Check that a retransmission of a Delete PDP Context Request works"}].
delete_pdp_context_request_resend(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),
    {_, Msg, Response} = delete_pdp_context(GtpC),
    ?equal(Response, send_recv_pdu(GtpC, Msg)),
    ?equal([], outstanding_requests()),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
update_pdp_context_request_ra_update() ->
    [{doc, "Check Update PDP Context with Routing Area Update"}].
update_pdp_context_request_ra_update(Config) ->
    {GtpC1, _, _} = create_pdp_context(Config),
    {GtpC2, _, _} = update_pdp_context(ra_update, GtpC1),
    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
update_pdp_context_request_tei_update() ->
    [{doc, "Check Update PDP Context with TEID update (e.g. SGSN change)"}].
update_pdp_context_request_tei_update(Config) ->
    {GtpC1, _, _} = create_pdp_context(Config),
    {GtpC2, _, _} = update_pdp_context(tei_update, GtpC1),
    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC2),

    [SMR0|_] = lists:filter(
		 fun(#pfcp{type = session_modification_request}) -> true;
		    (_) -> false
		 end, ergw_test_sx_up:history('pgw-u')),
    SMR = pfcp_packet:to_map(SMR0),
    #{update_far :=
	  #update_far{
	     group =
		 #{update_forwarding_parameters :=
		       #update_forwarding_parameters{group = UFP}}}} = SMR#pfcp.ie,
    ?match(#sxsmreq_flags{sndem = 0},
	   maps:get(sxsmreq_flags, UFP, #sxsmreq_flags{sndem = 0})),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
ms_info_change_notification_request_with_tei() ->
    [{doc, "Check Ms_Info_Change Notification request with TEID"}].
ms_info_change_notification_request_with_tei(Config) ->
    {GtpC1, _, _} = create_pdp_context(Config),
    {GtpC2, _, _} = ms_info_change_notification(simple, GtpC1),
    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
ms_info_change_notification_request_without_tei() ->
    [{doc, "Check Ms_Info_Change Notification request without TEID "
           "include IMEI and IMSI instead"}].
ms_info_change_notification_request_without_tei(Config) ->
    {GtpC1, _, _} = create_pdp_context(Config),
    {GtpC2, _, _} = ms_info_change_notification(without_tei, GtpC1),
    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
ms_info_change_notification_request_invalid_imsi() ->
    [{doc, "Check Ms_Info_Change Notification request without TEID "
           "include a invalid IMEI and IMSI instead"}].
ms_info_change_notification_request_invalid_imsi(Config) ->
    {GtpC1, _, _} = create_pdp_context(Config),
    {GtpC2, _, _} = ms_info_change_notification(invalid_imsi, GtpC1),
    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
invalid_teid() ->
    [{doc, "Check invalid TEID's for a number of request types"}].
invalid_teid(Config) ->
    {GtpC1, _, _} = create_pdp_context(Config),
    {GtpC2, _, _} = delete_pdp_context(invalid_teid, GtpC1),
    {GtpC3, _, _} = update_pdp_context(invalid_teid, GtpC2),
    {GtpC4, _, _} = ms_info_change_notification(invalid_teid, GtpC3),
    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC4),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_pdp_context_requested() ->
    [{doc, "Check GGSN initiated Delete PDP Context"}].
delete_pdp_context_requested(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_pdp_context(Config),

    Context = gtp_context_reg:lookup_key(#gtp_port{name = 'irx'},
					 {imsi, ?'IMSI', 5}),
    true = is_pid(Context),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Context)} end),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    receive
	{req, {ok, request_accepted}} ->
	    ok;
	{req, Other} ->
	    ct:fail(Other)
    after ?TIMEOUT ->
	    ct:fail(timeout)
    end,
    ?equal([], outstanding_requests()),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_pdp_context_requested_resend() ->
    [{doc, "Check resend of GGSN initiated Delete PDP Context"}].
delete_pdp_context_requested_resend(Config) ->
    Cntl = whereis(gtpc_client_server),

    {_, _, _} = create_pdp_context(Config),

    Context = gtp_context_reg:lookup_key(#gtp_port{name = 'irx'},
					 {imsi, ?'IMSI', 5}),
    true = is_pid(Context),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Context)} end),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    ?equal(Request, recv_pdu(Cntl, 5000)),
    ?equal(Request, recv_pdu(Cntl, 5000)),

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
create_pdp_context_overload() ->
    [{doc, "Check that the overload protection works"}].
create_pdp_context_overload(Config) ->
    create_pdp_context(overload, Config),
    ?equal([], outstanding_requests()),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
unsupported_request() ->
    [{doc, "Check that unsupported requests are silently ignore and don't get stuck"}].
unsupported_request(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),
    Request = make_request(unsupported, simple, GtpC),

    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, ?TIMEOUT, error)),
    ?equal([], outstanding_requests()),

    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
cache_timeout() ->
    [{doc, "Check GTP socket queue timeout"}, {timetrap, {seconds, 150}}].
cache_timeout(Config) ->
    GtpPort = gtp_socket_reg:lookup('irx'),
    {GtpC, _, _} = create_pdp_context(Config),
    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    {T0, Q0} = gtp_socket:get_response_q(GtpPort),
    ?match(X when X /= 0, length(T0)),
    ?match(X when X /= 0, length(Q0)),

    ct:sleep({seconds, 120}),

    {T1, Q1} = gtp_socket:get_response_q(GtpPort),
    ?equal(0, length(T1)),
    ?equal(0, length(Q1)),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
session_accounting() ->
    [{doc, "Check that accounting in session works"}].
session_accounting(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),

    [#{'Session' := Session, 'Process' := Context}|_] = ergw_api:tunnel(all),
    SessionOpts0 = ergw_aaa_session:get(Session),
    #{'Accouting-Update-Fun' := UpdateFun} = SessionOpts0,

    %% make sure we handle that the Sx node is not returning any accounting
    ergw_test_sx_up:accounting('pgw-u', off),

    SessionOpts1 = UpdateFun(Context, SessionOpts0),
    ?equal(false, maps:is_key('InPackets', SessionOpts1)),
    ?equal(false, maps:is_key('InOctets', SessionOpts1)),

    %% enable accouting again....
    ergw_test_sx_up:accounting('pgw-u', on),

    SessionOpts2 = UpdateFun(Context, SessionOpts1),
    ?match(#{'InPackets' := 3, 'OutPackets' := 1,
	     'InOctets' := 4, 'OutOctets' := 2}, SessionOpts2),

    SessionOpts3 = UpdateFun(Context, SessionOpts2),
    ?match(#{'InPackets' := 3, 'OutPackets' := 1,
	     'InOctets' := 4, 'OutOctets' := 2}, SessionOpts3),

    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
