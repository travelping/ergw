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
-define(HUT, saegw_s11).                                %% Handler Under Test

%%%===================================================================
%%% Config
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

	 {ergw, [{'$setup_vars',
		  [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
		 {sockets,
		  [{cp, [{type, 'gtp-u'},
			 {ip, ?MUST_BE_UPDATED},
			 {reuseaddr, true}
			]},
		   {irx, [{type, 'gtp-c'},
			  {ip,  ?MUST_BE_UPDATED},
			  {reuseaddr, true}
			 ]}
		  ]},

		 {vrfs,
		  [{upstream, [{pools,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
					 {?IPv6PoolStart, ?IPv6PoolEnd, 64}
					]},
			       {'MS-Primary-DNS-Server', {8,8,8,8}},
			       {'MS-Secondary-DNS-Server', {8,8,4,4}},
			       {'MS-Primary-NBNS-Server', {127,0,0,1}},
			       {'MS-Secondary-NBNS-Server', {127,0,0,1}},
			       {'DNS-Server-IPv6-Address',
				[{16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8888},
				 {16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8844}]}
			      ]}
		  ]},

		 {handlers,
		  [{s11, [{handler, ?HUT},
			  {sockets, [irx]},
			  {node_selection, [default]},
			  {aaa, [{'Username',
				  [{default, ['IMSI', <<"/">>, 'IMEI', <<"/">>, 'MSISDN', <<"@">>, 'APN']}]}]}
			 ]}
		  ]},

		 {node_selection,
		  [{default,
		    {static,
		     [
		      %% APN NAPTR alternative
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
			{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
		       "topon.s5s8.pgw.$ORIGIN"},
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.prox01.$ORIGIN"},

		      %% A/AAAA record alternatives
		      {"topon.s5s8.pgw.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.prox01.$ORIGIN", ?MUST_BE_UPDATED, []}
		     ]
		    }
		   }
		  ]
		 },

		 {sx_socket,
		  [{node, 'ergw'},
		   {name, 'ergw'},
		   {socket, cp},
		   {ip, ?MUST_BE_UPDATED},
		   {reuseaddr, true}]},

		 {apns,
		  [{?'APN-EXAMPLE', [{vrf, upstream}]},
		   {[<<"APN1">>], [{vrf, upstream}]}
		  ]},

		 {nodes,
		  [{default,
		    [{vrfs,
		      [{cp, [{features, ['CP-Function']}]},
		       {irx, [{features, ['Access']}]},
		       {upstream, [{features, ['SGi-LAN']}]}]
		     }]
		   }]
		 }
		]},

	 {ergw_aaa,
	  [{handlers,
	    [{ergw_aaa_static,
	      [{'NAS-Identifier',          <<"NAS-Identifier">>},
	       {'Node-Id',                 <<"PGW-001">>},
	       {'Charging-Rule-Base-Name', <<"m2m0001">>},
	       {rules, #{'Default' =>
			     #{'Rating-Group' => [3000],
			       'Flow-Information' =>
				   [#{'Flow-Description' => [<<"permit out ip from any to assigned">>],
				      'Flow-Direction'   => [1]    %% DownLink
				     },
				    #{'Flow-Description' => [<<"permit out ip from any to assigned">>],
				      'Flow-Direction'   => [2]    %% UpLink
				     }],
			       'Metering-Method'  => [1],
			       'Precedence' => [100],
			       'Offline'  => [1]
			      }
			}
	       }
	      ]}
	    ]},
	   {services, [{'Default', [{handler, 'ergw_aaa_static'}]}]},
	   {apps, [{default, [{session, ['Default']}]}]}
	  ]}
	]).

-define(CONFIG_UPDATE,
	[{[sockets, cp, ip], localhost},
	 {[sockets, irx, ip], test_gsn},
	 {[sx_socket, ip], localhost},
	 {[node_selection, {default, 2}, 2, "topon.s5s8.pgw.$ORIGIN"],
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
    [{handler_under_test, ?HUT},
     {app_cfg, ?TEST_CONFIG} | Config0].

end_per_suite(_Config) ->
    ok.

init_per_group(ipv6, Config0) ->
    case ergw_test_lib:has_ipv6_test_config() of
	true ->
	    Config = update_app_config(ipv6, ?CONFIG_UPDATE, Config0),
	    lib_init_per_suite(Config);
	_ ->
	    {skip, "IPv6 test IPs not configured"}
    end;
init_per_group(ipv4, Config0) ->
    Config = update_app_config(ipv4, ?CONFIG_UPDATE, Config0),
    lib_init_per_suite(Config).

end_per_group(Group, Config)
  when Group == ipv4; Group == ipv6 ->
    ok = lib_end_per_suite(Config).

common() ->
    [invalid_gtp_pdu,
     create_session_request_missing_ie,
     create_session_request_aaa_reject,
     create_session_request_gx_fail,
     create_session_request_gy_fail,
     create_session_request_rf_fail,
     create_session_request_invalid_apn,
     create_session_request_accept_new,
     simple_session_request,
     create_session_request_x2_handover,
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
     create_session_overload,
     session_options,
     enb_connection_suspend
    ].

groups() ->
    [{ipv4, [], common()},
     {ipv6, [], common()}].

all() ->
    [{group, ipv4},
     {group, ipv6}].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(Config) ->
    ct:pal("Sockets: ~p", [ergw_gtp_socket_reg:all()]),
    ergw_test_sx_up:reset('pgw-u'),
    meck_reset(Config),
    start_gtpc_server(Config).

init_per_testcase(create_session_request_aaa_reject, Config) ->
    init_per_testcase(Config),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(_, _, authenticate, _) ->
			     {fail, #{}, []};
			(_, Opts, _, _) ->
			     {ok, Opts, []}
		     end),
    Config;
init_per_testcase(create_session_request_gx_fail, Config) ->
    init_per_testcase(Config),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(_, _, {gx, 'CCR-Initial'}, _) ->
			     {fail, #{}, []};
			(_, Opts, _, _) ->
			     {ok, Opts, []}
		     end),
    Config;
init_per_testcase(create_session_request_gy_fail, Config) ->
    init_per_testcase(Config),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(_, _, {gy, 'CCR-Initial'}, _) ->
			     {fail, #{}, []};
			(_, Opts, _, _) ->
			     {ok, Opts, []}
		     end),
    Config;
init_per_testcase(create_session_request_rf_fail, Config) ->
    init_per_testcase(Config),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(_, _, start, _) ->
			     {fail, #{}, []};
			(_, Opts, _, _) ->
			     {ok, Opts, []}
		     end),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == delete_bearer_request_resend;
       TestCase == modify_bearer_command_timeout ->
    init_per_testcase(Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
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

end_per_testcase(_Config) ->
    stop_gtpc_server().

end_per_testcase(TestCase, Config)
  when TestCase == create_session_request_aaa_reject;
       TestCase == create_session_request_gx_fail;
       TestCase == create_session_request_gy_fail;
       TestCase == create_session_request_rf_fail ->
    ok = meck:delete(ergw_aaa_session, invoke, 4),
    end_per_testcase(Config),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == delete_bearer_request_resend;
       TestCase == modify_bearer_command_timeout ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 7),
    end_per_testcase(Config),
    Config;
end_per_testcase(create_session_overload, Config) ->
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
    gen_udp:send(S, TestGSN, ?GTP2c_PORT, <<"TESTDATA">>),

    ?equal({error,timeout}, gen_udp:recv(S, 4096, ?TIMEOUT)),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_missing_ie() ->
    [{doc, "Check that Create Session Request IE validation works"}].
create_session_request_missing_ie(Config) ->
    create_session(missing_ie, Config),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_aaa_reject() ->
    [{doc, "Check AAA reject return on Create Session Request"}].
create_session_request_aaa_reject(Config) ->
    create_session(aaa_reject, Config),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_gx_fail() ->
    [{doc, "Check Gx failure on Create Session Request"}].
create_session_request_gx_fail(Config) ->
    create_session(gx_fail, Config),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_gy_fail() ->
    [{doc, "Check Gy failure on Create Session Request"}].
create_session_request_gy_fail(Config) ->
    create_session(gy_fail, Config),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_rf_fail() ->
    [{doc, "Check Gx failure on Create Session Request"}].
create_session_request_rf_fail(Config) ->
    {GtpC, _, _} = create_session(Config),
    delete_session(GtpC),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_invalid_apn() ->
    [{doc, "Check invalid APN return on Create Session Request"}].
create_session_request_invalid_apn(Config) ->
    create_session(invalid_apn, Config),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_accept_new() ->
    [{doc, "Check the accept_new = false can block new session"}].
create_session_request_accept_new(Config) ->
    ?equal(ergw:system_info(accept_new, false), true),
    create_session(overload, Config),
    ?equal(ergw:system_info(accept_new, true), false),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
simple_session_request() ->
    [{doc, "Check simple Create Session, Delete Session sequence"}].
simple_session_request(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer(enb_u_tei, GtpC1),
    delete_session(GtpC2),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_x2_handover() ->
    [{doc, "Check X11 handover, Delete Session sequence"}].
create_session_request_x2_handover(Config) ->
    {GtpC1, _, _} = create_session(x2_handover, Config),
    delete_session(GtpC1),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_resend() ->
    [{doc, "Check that a retransmission of a Create Session Request works"}].
create_session_request_resend(Config) ->
    {GtpC, Msg, Response} = create_session(Config),
    ?equal(Response, send_recv_pdu(GtpC, Msg)),

    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_session_request_resend() ->
    [{doc, "Check that a retransmission of a Delete Session Request works"}].
delete_session_request_resend(Config) ->
    {GtpC, _, _} = create_session(Config),
    {_, Msg, Response} = delete_session(GtpC),
    ?equal(Response, send_recv_pdu(GtpC, Msg)),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_request_ra_update() ->
    [{doc, "Check Modify Bearer Routing Area Update"}].
modify_bearer_request_ra_update(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer(enb_u_tei, GtpC1),
    {GtpC3, _, _} = modify_bearer(ra_update, GtpC2),
    delete_session(GtpC3),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_request_tei_update() ->
    [{doc, "Check Modify Bearer with TEID update (e.g. SGW change)"}].
modify_bearer_request_tei_update(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer(enb_u_tei, GtpC1),
    {GtpC3, _, _} = modify_bearer(tei_update, GtpC2),
    delete_session(GtpC3),

    [_, SMR0|_] = lists:filter(
		    fun(#pfcp{type = session_modification_request}) -> true;
		       (_) -> false
		    end, ergw_test_sx_up:history('pgw-u')),

    SMR = pfcp_packet:to_map(SMR0),
    #{update_far :=
	  #update_far{
	     group =
		 #{far_id := _,
		   update_forwarding_parameters :=
		       #update_forwarding_parameters{group = UFP}}}} = SMR#pfcp.ie,
    ?match(#sxsmreq_flags{sndem = 1}, maps:get(sxsmreq_flags, UFP)),

    #gtpc{local_data_tei = NewDataTEI} = GtpC3,
    ?match(#outer_header_creation{teid = NewDataTEI},
	   maps:get(outer_header_creation, UFP, undefined)),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_command() ->
    [{doc, "Check Modify Bearer Command"}].
modify_bearer_command(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer(enb_u_tei, GtpC1),
    {GtpC3, Req0} = modify_bearer_command(simple, GtpC2),

    Req1 = recv_pdu(GtpC3, Req0#gtp.seq_no, ?TIMEOUT, ok),
    validate_response(modify_bearer_command, simple, Req1, GtpC3),
    Response = make_response(Req1, simple, GtpC3),
    send_pdu(GtpC3, Response),

    ?equal({ok, timeout}, recv_pdu(GtpC3, Req1#gtp.seq_no, ?TIMEOUT, ok)),
    ?equal([], outstanding_requests()),

    delete_session(GtpC3),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_command_timeout() ->
    [{doc, "Check Modify Bearer Command"}].
modify_bearer_command_timeout(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer(enb_u_tei, GtpC1),
    {GtpC3, Req0} = modify_bearer_command(simple, GtpC2),

    Req1 = recv_pdu(GtpC3, Req0#gtp.seq_no, ?TIMEOUT, ok),
    validate_response(modify_bearer_command, simple, Req1, GtpC3),
    ?equal(Req1, recv_pdu(GtpC3, 5000)),
    ?equal(Req1, recv_pdu(GtpC3, 5000)),

    Req2 = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Req2),
    ?equal(Req2, recv_pdu(Cntl, 5000)),
    ?equal(Req2, recv_pdu(Cntl, 5000)),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_command_congestion() ->
    [{doc, "Check Modify Bearer Command"}].
modify_bearer_command_congestion(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer(enb_u_tei, GtpC1),
    {GtpC3, Req0} = modify_bearer_command(simple, GtpC2),

    Req1 = recv_pdu(GtpC3, Req0#gtp.seq_no, ?TIMEOUT, ok),
    validate_response(modify_bearer_command, simple, Req1, GtpC3),
    Resp1 = make_response(Req1, apn_congestion, GtpC3),
    send_pdu(GtpC3, Resp1),

    Req2 = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Req2),
    Resp2 = make_response(Req2, simple, GtpC3),
    send_pdu(Cntl, GtpC3, Resp2),

    ?equal({ok, timeout}, recv_pdu(GtpC3, Req2#gtp.seq_no, ?TIMEOUT, ok)),
    ?equal([], outstanding_requests()),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
requests_invalid_teid() ->
    [{doc, "Check invalid TEID's for a number of request types"}].
requests_invalid_teid(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer(enb_u_tei, GtpC1),
    {GtpC3, _, _} = modify_bearer(invalid_teid, GtpC2),
    {GtpC4, _, _} = delete_session(invalid_teid, GtpC3),
    delete_session(GtpC4),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
commands_invalid_teid() ->
    [{doc, "Check invalid TEID's for a number of command types"}].
commands_invalid_teid(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer(enb_u_tei, GtpC1),
    {GtpC3, _, _} = modify_bearer_command(invalid_teid, GtpC2),
    delete_session(GtpC3),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_bearer_request() ->
    [{doc, "Check PGW initiated bearer shutdown"},
     {timetrap,{seconds,60}}].
delete_bearer_request(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({irx, {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Server)} end),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request),
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
    Cntl = whereis(gtpc_client_server),

    {_, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({irx, {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Server)} end),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request),
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
unsupported_request() ->
    [{doc, "Check that unsupported requests are silently ignore and don't get stuck"}].
unsupported_request(Config) ->
    {GtpC, _, _} = create_session(Config),
    Request = make_request(unsupported, simple, GtpC),

    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, ?TIMEOUT, error)),
    ?equal([], outstanding_requests()),

    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_overload() ->
    [{doc, "Check that the overload protection works"}].
create_session_overload(Config) ->
    create_session(overload, Config),

    meck_validate(Config),
    ok.

%--------------------------------------------------------------------
session_options() ->
    [{doc, "Check that all required session options are present"}].
session_options(Config) ->
    {GtpC, _, _} = create_session(ipv4v6, Config),

    [#{'Process' := Pid}|_] = ergw_api:tunnel(all),
    #{'Session' := Session} = gtp_context:info(Pid),

    Opts = ergw_aaa_session:get(Session),
    ct:pal("Opts: ~p", [Opts]),

    Expected0 =
	case ?config(client_ip, Config) of
	    IP = {_,_,_,_,_,_,_,_} ->
		#{'3GPP-GGSN-IPv6-Address' => ?config(test_gsn, Config),
		  '3GPP-SGSN-IPv6-Address' => IP};
	    IP ->
		#{'3GPP-GGSN-Address' => ?config(test_gsn, Config),
		  '3GPP-SGSN-Address' => IP}
	end,
    Expected =
	Expected0#{'Node-Id' => <<"PGW-001">>,
		   'NAS-Identifier' => <<"NAS-Identifier">>,

		   '3GPP-Charging-Id' => '_',
		   %% TODO check '3GPP-Allocation-Retention-Priority' => 2,
		   '3GPP-Selection-Mode' => 0,
		   '3GPP-IMEISV' => <<"AAAAAAAA">>,
		   '3GPP-GGSN-MCC-MNC' => <<"00101">>,
		   '3GPP-NSAPI' => 5,
		   %% TODO: check '3GPP-GPRS-Negotiated-QoS-Profile' => '_',
		   '3GPP-IMSI-MCC-MNC' => <<"11111">>,
		   '3GPP-PDP-Type' => 'IPv4v6',
		   '3GPP-MSISDN' => ?MSISDN,
		   '3GPP-RAT-Type' => 6,
		   '3GPP-IMSI' => ?IMSI,
		   '3GPP-User-Location-Info' => '_',

		   'QoS-Information' =>
		       #{
			 'QoS-Class-Identifier' => 8,
			 'Max-Requested-Bandwidth-DL' => 0,
			 'Max-Requested-Bandwidth-UL' => 0,
			 'Guaranteed-Bitrate-DL' => 0,
			 'Guaranteed-Bitrate-UL' => 0,
			 'Allocation-Retention-Priority' =>
			     #{'Priority-Level' => 10,
			       'Pre-emption-Capability' => 1,
			       'Pre-emption-Vulnerability' => 0},
			 'APN-Aggregate-Max-Bitrate-UL' => '_',
			 'APN-Aggregate-Max-Bitrate-DL' => '_'
			},

		   credits => '_',

		   'Session-Id' => '_',
		   'Multi-Session-Id' => '_',
		   'Diameter-Session-Id' => '_',
		   'Called-Station-Id' =>
		       unicode:characters_to_binary(lists:join($., ?'APN-ExAmPlE')),
		   'Calling-Station-Id' => ?MSISDN,
		   'Service-Type' => 'Framed-User',
		   'Framed-Protocol' => 'GPRS-PDP-Context',
		   'Username' => '_',
		   'Password' => '_',

		   %% TODO check 'PDP-Context-Type' => primary,
		   'Framed-IP-Address' => {10, 180, '_', '_'},
		   'Framed-IPv6-Prefix' => {{16#8001, 0, 1, '_', '_', '_', '_', '_'},64},

		   'Charging-Rule-Base-Name' => <<"m2m0001">>,

		   'Accounting-Start' => '_',
		   'Session-Start' => '_',

		   rules => '_'
		  },
    ?match_map(Expected, Opts),

    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
enb_connection_suspend() ->
    [{doc, "Check S1 release / eNodeB initiated Connection Suspend procedure"}].
enb_connection_suspend(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer(enb_u_tei, GtpC1),
    {GtpC3, _, _} = release_access_bearers(simple, GtpC2),
    {GtpC4, _, _} = modify_bearer(enb_u_tei, GtpC3),
    delete_session(GtpC4),

    ?equal([], outstanding_requests()),

    [_, SMR0|_] = lists:filter(
		    fun(#pfcp{type = session_modification_request}) -> true;
		       (_) -> false
		    end, ergw_test_sx_up:history('pgw-u')),
    SMR = pfcp_packet:to_map(SMR0),
    ?match(#{remove_far := #remove_far{}}, SMR#pfcp.ie),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
