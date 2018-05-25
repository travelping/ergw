%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_c_lb_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").
-include("../include/gtp_proxy_ds.hrl").
-include("ergw_test_lib.hrl").

-define(TIMEOUT, 2000).
-define(HUT, gtp_c_lb).			%% Handler Under Test

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
		   {'irx1', [{type, 'gtp-c'},
			     {ip, ?MUST_BE_UPDATED},
			     {reuseaddr, true}
			    ]},
		   {'irx2', [{type, 'gtp-c'},
			     {ip, ?MUST_BE_UPDATED},
			     {reuseaddr, true}
			    ]},
		   {epc, [{type, 'gtp-c'},
			  {ip, ?MUST_BE_UPDATED},
			  {reuseaddr, true},
			  {mode, stateless}
			 ]},
		   {fwd, [{type, 'gtp-raw'},
			  {ip, ?MUST_BE_UPDATED},
			  {mode, stateless}
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
		  %% PGW handler
		  [{'pgw1', [{handler, pgw_s5s8},
			     {protocol, gn},
			     {sockets, ['irx1']},
			     {node_selection, [default]},
			     {aaa, [{'Username',
				     [{default, ['IMSI', <<"@">>, 'APN']}]}]}
			    ]},
		   {'pgw2', [{handler, pgw_s5s8},
			     {protocol, s5s8},
			     {sockets, ['irx1']},
			     {node_selection, [default]},
			     {aaa, [{'Username',
				     [{default, ['IMSI', <<"@">>, 'APN']}]}]}
			    ]},
		   %% GGSN handler
		   {'ggsn1', [{handler, ggsn_gn},
			      {protocol, gn},
			      {sockets, ['irx2']},
			      {node_selection, [default]},
			      {aaa, [{'Username',
				      [{default, ['IMSI', <<"@">>, 'APN']}]}]}
			     ]},
		   %% LB handler
		   {'h1', [{handler, gtp_c_lb},
			   {protocol, gn},
			   {sockets, [epc]},
			   {forward, [fwd]},
			   {node_selection, [default]},
			   {rules, [
				    {'r1', [
					    {conditions, [{src_ip, ?MUST_BE_UPDATED}]},
					    {strategy, random},
					    {nodes, [?MUST_BE_UPDATED]}
					   ]},
				    {'r2', [
					    {strategy, random},
					    {nodes, [?MUST_BE_UPDATED]}
					   ]}
				   ]}
			  ]},
		   {'h2', [{handler, gtp_c_lb},
			   {protocol, s5s8},
			   {sockets, [epc]},
			   {forward, [fwd]},
			   {node_selection, [default]},
			   {rules, [
				    {'r3', [
					    {conditions, [{src_ip, ?MUST_BE_UPDATED}]},
					    {strategy, random},
					    {nodes, [?MUST_BE_UPDATED]}
					   ]},
				    {'r4', [
					    {strategy, random},
					    {nodes, [?MUST_BE_UPDATED]}
					   ]}
				   ]}
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
		       [{"x-3gpp-upf","x-sxa"}],
		       "topon.sx.sgw-u01.$ORIGIN"},
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.pgw-u01.$ORIGIN"},

		      %% A/AAAA record alternatives
		      {"topon.s5s8.pgw.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.sgw-u01.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.pgw-u01.$ORIGIN", ?MUST_BE_UPDATED, []}
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
		       {'irx1', [{features, ['Access']}]},
		       {'irx2', [{features, ['Access']}]},
		       {upstream, [{features, ['SGi-LAN']}]}]
		     }]
		   }]
		 }
		]},
	 {ergw_aaa, [{ergw_aaa_provider, {ergw_aaa_mock, [{shared_secret, <<"MySecret">>}]}}]}
	]).

-define(CONFIG_UPDATE,
	[{[sockets, cp, ip], localhost},
	 {[sockets, 'irx1', ip], proxy_gsn},
	 {[sockets, 'irx2', ip], final_gsn},
	 {[sockets, epc, ip], test_gsn},
	 {[sockets, fwd, ip], test_gsn},
	 {[sx_socket, ip], localhost},
	 {[handlers, 'h1', rules, 'r1', conditions, src_ip], localhost},
	 {[handlers, 'h1', rules, 'r1', nodes], [final_gsn]},
	 {[handlers, 'h1', rules, 'r2', nodes], [final_gsn]},
	 {[handlers, 'h2', rules, 'r3', conditions, src_ip], localhost},
	 {[handlers, 'h2', rules, 'r3', nodes], [proxy_gsn]},
	 {[handlers, 'h2', rules, 'r4', nodes], [proxy_gsn]},
	 {[node_selection, {default, 2}, 2, "topon.s5s8.pgw.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.sx.sgw-u01.$ORIGIN"],
	  {fun node_sel_update/2, sgw_u_sx}},
	 {[node_selection, {default, 2}, 2, "topon.sx.pgw-u01.$ORIGIN"],
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
    [{handlers_under_test, [?HUT, pgw_s5s8, ggsn_gn]},
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
     simple_session_request,
     create_session_request_resend,
     simple_pdp_context_request,
     create_pdp_context_request_resend].

groups() ->
    [{ipv4, [], common()},
     {ipv6, [], common()}].

all() ->
    [{group, ipv4}
     %%, {group, ipv6} - see ergw_gtp_raw_socket:sendto/4
    ].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(Config) ->
    ct:pal("Sockets: ~p", [ergw_gtp_socket_reg:all()]),
    ergw_test_sx_up:reset('pgw-u'),
    meck_reset(Config),
    start_gtpc_server(Config).

init_per_testcase(_, Config) ->
    init_per_testcase(Config),
    Config.

end_per_testcase(_Config) ->
    stop_gtpc_server().

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
simple_session_request() ->
    [{doc, "Check simple Create Session, Delete Session sequence"}].
simple_session_request(Config) ->
    {GtpC, _, _} = ergw_pgw_test_lib:create_session(Config),
    ergw_pgw_test_lib:delete_session(GtpC),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_resend() ->
    [{doc, "Check that a retransmission of a Create Session Request works"}].
create_session_request_resend(Config) ->
    LB = gtp_context_reg:lookup_key(#gtp_port{name = 'epc'}, lb),
    true = is_pid(LB),
    {QIn, _} = gtp_c_lb:get_request_q(LB),

    {GtpC, Msg, Response} = ergw_pgw_test_lib:create_session(Config),
    ?equal(Response, send_recv_pdu(GtpC, Msg)),

    {QOut, _} = gtp_c_lb:get_request_q(LB),
    ?match([_], QOut -- QIn),

    ergw_pgw_test_lib:delete_session(GtpC),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
simple_pdp_context_request() ->
    [{doc, "Check simple Create PDP Context, Delete PDP Context sequence"}].
simple_pdp_context_request(Config) ->
    {GtpC, _, _} = ergw_ggsn_test_lib:create_pdp_context(Config),
    ergw_ggsn_test_lib:delete_pdp_context(GtpC),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_resend() ->
    [{doc, "Check that a retransmission of a Create PDP Context Request works"}].
create_pdp_context_request_resend(Config) ->
    LB = gtp_context_reg:lookup_key(#gtp_port{name = 'epc'}, lb),
    true = is_pid(LB),
    {QIn, _} = gtp_c_lb:get_request_q(LB),

    {GtpC, Msg, Response} = ergw_ggsn_test_lib:create_pdp_context(Config),
    ?equal(Response, send_recv_pdu(GtpC, Msg)),

    {QOut, _} = gtp_c_lb:get_request_q(LB),
    ?match([_], QOut -- QIn),

    ergw_ggsn_test_lib:delete_pdp_context(GtpC),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.
