%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_proxy_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").
-include("../include/gtp_proxy_ds.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_pgw_test_lib.hrl").

-define(TIMEOUT, 2000).
-define(HUT, pgw_s5s8_proxy).			%% Handler Under Test

%%%===================================================================
%%% Config
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

	 {ergw, [{'$setup_vars',
		  [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
		 {sockets,
		  [{cp, [{type, 'gtp-u'},
			 {ip, ?MUST_BE_UPDATED},
			 {reuseaddr, true}
			]},
		   {irx, [{type, 'gtp-c'},
			  {ip, ?MUST_BE_UPDATED},
			  {reuseaddr, true}
			 ]},
		   {'proxy-irx', [{type, 'gtp-c'},
				  {ip, ?MUST_BE_UPDATED},
				  {reuseaddr, true}
				 ]},
		   {'remote-irx', [{type, 'gtp-c'},
				   {ip, ?MUST_BE_UPDATED},
				   {reuseaddr, true}
				  ]}
		  ]},

		 {vrfs,
		  [{example, [{pools,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
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
		  %% proxy handler
		  [{gn, [{handler, ?HUT},
			 {sockets, [irx]},
			 {proxy_sockets, ['proxy-irx']},
			 {node_selection, [default]}
			]},
		   {s5s8, [{handler, ?HUT},
			   {sockets, [irx]},
			   {proxy_sockets, ['proxy-irx']},
			   {node_selection, [default]},
			   {contexts,
			    [{<<"ams">>,
			      [{proxy_sockets, ['proxy-irx']}]}]}
			  ]},
		   %% remote PGW handler
		   {gn, [{handler, pgw_s5s8},
			 {sockets, ['remote-irx']},
			 {node_selection, [default]},
			 {aaa, [{'Username',
				 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
			]},
		   {s5s8, [{handler, pgw_s5s8},
			   {sockets, ['remote-irx']},
			   {node_selection, [default]}
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
		  [{?'APN-PROXY', [{vrf, example}]}
		  ]},

		 {charging,
		  [{default,
		    [{rulebase,
		      [{<<"r-0001">>,
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
			 }},
		       {<<"m2m0001">>, [<<"r-0001">>]}
		      ]}
		     ]}
		  ]},

		 {proxy_map,
		  [{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
		   {imsi, [{?'IMSI', {?'PROXY-IMSI', ?'PROXY-MSISDN'}}
			  ]}
		  ]},

		 {nodes,
		  [{default,
		    [{vrfs,
		      [{cp, [{features, ['CP-Function']}]},
		       {irx, [{features, ['Access']}]},
		       {'proxy-irx', [{features, ['Core']}]},
		       {'remote-irx', [{features, ['Access']}]},
		       {example, [{features, ['SGi-LAN']}]}]
		     }]
		   }]
		 }
		]},

	 {ergw_aaa,
	  [
	   {handlers,
	    [{ergw_aaa_static,
	      [{'NAS-Identifier',          <<"NAS-Identifier">>},
	       {'Node-Id',                 <<"PGW-001">>},
	       {'Charging-Rule-Base-Name', <<"m2m0001">>}
	      ]}
	    ]},
	   {services,
	    [{'Default',
	      [{handler, 'ergw_aaa_static'},
	       {answers,
		#{'Initial-Gx' =>
		      #{'Result-Code' => 2001,
			'Charging-Rule-Install' =>
			    [#{'Charging-Rule-Base-Name' => [<<"m2m0001">>]}]
		       },
		  'Update-Gx' => #{'Result-Code' => 2001},
		  'Final-Gx' => #{'Result-Code' => 2001}
		 }
	       }
	      ]}
	    ]},
	   {apps,
	    [{default,
	      [{session, ['Default']},
	       {procedures, [{authenticate, []},
			     {authorize, []},
			     {start, []},
			     {interim, []},
			     {stop, []},
			     {{gx, 'CCR-Initial'},   [{'Default', [{answer, 'Initial-Gx'}]}]},
			     {{gx, 'CCR-Update'},    [{'Default', [{answer, 'Update-Gx'}]}]},
			     {{gx, 'CCR-Terminate'}, [{'Default', [{answer, 'Final-Gx'}]}]},
			     {{gy, 'CCR-Initial'},   []},
			     {{gy, 'CCR-Update'},    []},
			     {{gy, 'CCR-Terminate'}, []}
			    ]}
	      ]}
	    ]}
	  ]}
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

	 {ergw, [{'$setup_vars',
		  [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
		 {sockets,
		  [{cp, [{type, 'gtp-u'},
			 {ip, ?MUST_BE_UPDATED},
			 {reuseaddr, true}
			]},
		   {irx, [{type, 'gtp-c'},
			  {ip, ?MUST_BE_UPDATED},
			  {reuseaddr, true}
			 ]},
		   {'remote-irx', [{type, 'gtp-c'},
				   {ip, ?MUST_BE_UPDATED},
				   {reuseaddr, true}
				  ]}
		  ]},

		 {vrfs,
		  [{example, [{pools,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
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
		  %% proxy handler
		  [{gn, [{handler, ?HUT},
			 {sockets, [irx]},
			 {proxy_sockets, ['irx']},
			 {node_selection, [default]}
			]},
		   {s5s8, [{handler, ?HUT},
			   {sockets, [irx]},
			   {proxy_sockets, ['irx']},
			   {node_selection, [default]},
			   {contexts,
			    [{<<"ams">>,
			      [{proxy_sockets, ['irx']}]}]}
			  ]},
		   %% remote PGW handler
		   {gn, [{handler, pgw_s5s8},
			 {sockets, ['remote-irx']},
			 {node_selection, [default]},
			 {aaa, [{'Username',
				 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
			]},
		   {s5s8, [{handler, pgw_s5s8},
			   {sockets, ['remote-irx']},
			   {node_selection, [default]}
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
		  [{?'APN-PROXY', [{vrf, example}]}
		  ]},

		 {charging,
		  [{default,
		    [{rulebase,
		      [{<<"r-0001">>,
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
			 }},
		       {<<"m2m0001">>, [<<"r-0001">>]}
		      ]}
		     ]}
		  ]},

		 {proxy_map,
		  [{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
		   {imsi, [{?'IMSI', {?'PROXY-IMSI', ?'PROXY-MSISDN'}}
			  ]}
		  ]},

		 {nodes,
		  [{default,
		    [{vrfs,
		      [{cp, [{features, ['CP-Function']}]},
		       {irx, [{features, ['Access', 'Core']}]},
		       {'remote-irx', [{features, ['Access']}]},
		       {example, [{features, ['SGi-LAN']}]}]
		     }]
		   }]
		 }
		]},

	 {ergw_aaa,
	  [
	   {handlers,
	    [{ergw_aaa_static,
	      [{'NAS-Identifier',          <<"NAS-Identifier">>},
	       {'Node-Id',                 <<"PGW-001">>},
	       {'Charging-Rule-Base-Name', <<"m2m0001">>}
	      ]}
	    ]},
	   {services,
	    [{'Default',
	      [{handler, 'ergw_aaa_static'},
	       {answers,
		#{'Initial-Gx' =>
		      #{'Result-Code' => 2001,
			'Charging-Rule-Install' =>
			    [#{'Charging-Rule-Base-Name' => [<<"m2m0001">>]}]
		       },
		  'Update-Gx' => #{'Result-Code' => 2001},
		  'Final-Gx' => #{'Result-Code' => 2001}
		 }
	       }
	      ]}
	    ]},
	   {apps,
	    [{default,
	      [{session, ['Default']},
	       {procedures, [{authenticate, []},
			     {authorize, []},
			     {start, []},
			     {interim, []},
			     {stop, []},
			     {{gx, 'CCR-Initial'},   [{'Default', [{answer, 'Initial-Gx'}]}]},
			     {{gx, 'CCR-Update'},    [{'Default', [{answer, 'Update-Gx'}]}]},
			     {{gx, 'CCR-Terminate'}, [{'Default', [{answer, 'Final-Gx'}]}]},
			     {{gy, 'CCR-Initial'},   []},
			     {{gy, 'CCR-Update'},    []},
			     {{gy, 'CCR-Terminate'}, []}
			    ]}
	      ]}
	    ]}
	  ]}
	]).

-define(CONFIG_UPDATE_MULTIPLE_PROXY_SOCKETS,
	[{[sockets, cp, ip], localhost},
	 {[sockets, irx, ip], test_gsn},
	 {[sockets, 'proxy-irx', ip], proxy_gsn},
	 {[sockets, 'remote-irx', ip], final_gsn},
	 {[sx_socket, ip], localhost},
	 {[node_selection, {default, 2}, 2, "topon.s5s8.pgw.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.sx.sgw-u01.$ORIGIN"],
	  {fun node_sel_update/2, sgw_u_sx}},
	 {[node_selection, {default, 2}, 2, "topon.sx.pgw-u01.$ORIGIN"],
	  {fun node_sel_update/2, pgw_u_sx}}
	]).

-define(CONFIG_UPDATE_SINGLE_PROXY_SOCKET,
	[{[sockets, cp, ip], localhost},
	 {[sockets, irx, ip], test_gsn},
	 {[sockets, 'remote-irx', ip], final_gsn},
	 {[sx_socket, ip], localhost},
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
    [{handler_under_test, ?HUT} | Config0].

end_per_suite(_Config) ->
    ok.

init_per_group(ipv6, Config) ->
    case ergw_test_lib:has_ipv6_test_config() of
	true ->
	    lists:keystore(ip_group, 1, Config, {ip_group, ipv6});
	_ ->
	    {skip, "IPv6 test IPs not configured"}
    end;
init_per_group(ipv4, Config) ->
    lists:keystore(ip_group, 1, Config, {ip_group, ipv4});

init_per_group(single_proxy_interface, Config0) ->
    Config1 = lists:keystore(app_cfg, 1, Config0,
			    {app_cfg, ?TEST_CONFIG_SINGLE_PROXY_SOCKET}),
    Config = update_app_config(proplists:get_value(ip_group, Config1),
			       ?CONFIG_UPDATE_SINGLE_PROXY_SOCKET, Config1),
    lib_init_per_suite(Config);
init_per_group(_Group, Config0) ->
    Config1 = lists:keystore(app_cfg, 1, Config0,
			    {app_cfg, ?TEST_CONFIG_MULTIPLE_PROXY_SOCKETS}),
    Config = update_app_config(proplists:get_value(ip_group, Config1),
			       ?CONFIG_UPDATE_MULTIPLE_PROXY_SOCKETS, Config1),
    lib_init_per_suite(Config).

end_per_group(Group, _Config)
  when Group == ipv4; Group == ipv6 ->
    ok;
end_per_group(_Group, Config) ->
    ok = lib_end_per_suite(Config),
    ok.

common() ->
    [invalid_gtp_pdu,
     create_session_request_missing_ie,
     create_session_request_accept_new,
     path_restart, path_restart_recovery,
     simple_session,
     simple_session_random_port,
     duplicate_session_request,
     create_session_overload_response,
     create_session_request_resend,
     create_session_proxy_request_resend,
     delete_session_request_resend,
     delete_session_request_timeout,
     error_indication_sgw2pgw,
     error_indication_pgw2sgw,
     %% request_fast_resend, TODO, FIXME
     modify_bearer_request_ra_update,
     modify_bearer_request_tei_update,
     modify_bearer_command,
     modify_bearer_command_timeout,
     modify_bearer_command_congestion,
     update_bearer_request,
     change_notification_request_with_tei,
     change_notification_request_without_tei,
     change_notification_request_invalid_imsi,
     suspend_notification_request,
     resume_notification_request,
     proxy_context_selection,
     proxy_context_invalid_selection,
     proxy_context_invalid_mapping,
     proxy_context_version_restricted,
     requests_invalid_teid,
     commands_invalid_teid,
     delete_bearer_request,
     delete_bearer_request_resend,
     delete_bearer_request_invalid_teid,
     delete_bearer_request_late_response,
     unsupported_request,
     interop_sgsn_to_sgw,
     interop_sgw_to_sgsn,
     create_session_overload,
     session_accounting].

common_groups() ->
    [{group, single_proxy_interface},
     {group, multiple_proxy_interface}].

groups() ->
    [{single_proxy_interface, [], common()},
     {multiple_proxy_interface, [], common()},
     {ipv4, [], common_groups()},
     {ipv6, [], common_groups()}].

all() ->
    [{group, ipv4},
     {group, ipv6}].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(Config) ->
    ergw_test_sx_up:reset('pgw-u'),
    ergw_test_sx_up:reset('sgw-u'),
    meck_reset(Config),
    start_gtpc_server(Config).

init_per_testcase(delete_session_request_resend, Config) ->
    init_per_testcase(Config),
    ok = meck:new(gtp_path, [passthrough, no_link]),
    Config;
init_per_testcase(create_session_proxy_request_resend, Config) ->
    init_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    ok = meck:expect(pgw_s5s8, handle_request,
		     fun(ReqKey, #gtp{type = create_session_request}, _Resent, State) ->
			     gtp_context:request_finished(ReqKey),
			     {noreply, State};
			(ReqKey, Msg, Resent, State) ->
			     meck:passthrough([ReqKey, Msg, Resent, State])
		     end),
    Config;
init_per_testcase(delete_session_request_timeout, Config) ->
    init_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    ok = meck:expect(pgw_s5s8, handle_request,
		     fun(ReqKey, #gtp{type = delete_session_request}, _Resent, State) ->
			     gtp_context:request_finished(ReqKey),
			     {noreply, State};
			(ReqKey, Msg, Resent, State) ->
			     meck:passthrough([ReqKey, Msg, Resent, State])
		     end),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == delete_bearer_request_resend;
       TestCase == delete_bearer_request_invalid_teid;
       TestCase == delete_bearer_request_late_response;
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
init_per_testcase(simple_session, Config) ->
    init_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    Config;
init_per_testcase(request_fast_resend, Config) ->
    init_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    ok = meck:expect(pgw_s5s8, handle_request,
		     fun(Request, Msg, Resent, State) ->
			     if Resent -> ok;
				true   -> ct:sleep(1000)
			     end,
			     meck:passthrough([Request, Msg, Resent, State])
		     end),
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
    [exometer:delete(Metric) || {Metric,_,_} <- exometer:find_entries([path, '_', '_', contexts])],
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

end_per_testcase(create_session_proxy_request_resend, Config) ->
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config),
    Config;
end_per_testcase(delete_session_request_resend, Config) ->
    meck:unload(gtp_path),
    end_per_testcase(Config),
    Config;
end_per_testcase(delete_session_request_timeout, Config) ->
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == delete_bearer_request_resend;
       TestCase == delete_bearer_request_invalid_teid;
       TestCase == delete_bearer_request_late_response;
       TestCase == modify_bearer_command_timeout ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 7),
    end_per_testcase(Config),
    Config;
end_per_testcase(simple_session, Config) ->
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config),
    Config;
end_per_testcase(request_fast_resend, Config) ->
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config),
    Config;
end_per_testcase(create_session_overload_response, Config) ->
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == interop_sgsn_to_sgw;
       TestCase == interop_sgw_to_sgsn ->
    ok = meck:unload(ggsn_gn_proxy),
    end_per_testcase(Config),
    Config;
end_per_testcase(update_bearer_request, Config) ->
    ok = meck:unload(pgw_s5s8),
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

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_accept_new() ->
    [{doc, "Check the accept_new = false can block new session"}].
create_session_request_accept_new(Config) ->
    ?equal(ergw:system_info(accept_new, false), true),
    create_session(overload, Config),
    ?equal(ergw:system_info(accept_new, true), false),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_overload_response() ->
    [{doc, "Check that Create Session Response with Cuase Overload works"}].
create_session_overload_response(Config) ->
    create_session(overload, Config),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.


%%--------------------------------------------------------------------
path_restart() ->
    [{doc, "Check that Create Session Request works and "
           "that a Path Restart terminates the session"}].
path_restart(Config) ->
    {GtpC, _, _} = create_session(Config),

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
    [{doc, "Check that Create Session Request works, "
           "that a Path Restart terminates the session, "
           "and that a new Create Session Request also works"}].
path_restart_recovery(Config) ->
    {GtpC1, _, _} = create_session(Config),

    %% create 2nd session with new restart_counter (simulate SGW restart)
    {GtpC2, _, _} = create_session('2nd', gtp_context_inc_restart_counter(GtpC1)),

    [?match(#{tunnels := 1}, X) || X <- ergw_api:peer(all)],

    delete_session(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
simple_session() ->
    [{doc, "Check simple Create Session, Delete Session sequence"}].
simple_session(Config) ->
    init_seq_no(?MODULE, 16#80000),
    GtpC0 = gtp_context(?MODULE, Config),

    {GtpC1, _, _} = create_session(GtpC0),
    delete_session(GtpC1),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    GtpRecMatch = #gtp{type = create_session_request, _ = '_'},
    P = meck:capture(first, ?HUT, handle_request, ['_', GtpRecMatch, '_', '_'], 2),
    ?match(#gtp{seq_no = SeqNo} when SeqNo >= 16#80000, P),

    FirstHR = meck:capture(first, pgw_s5s8, handle_request, ['_', GtpRecMatch, '_', '_'], 2),
    %% ct:pal("FirstHR: ~s", [ergw_test_lib:pretty_print(FirstHR)]),
    ?match(
       #gtp{ie = #{
	      {v2_access_point_name, 0} := #v2_access_point_name{apn = ?'APN-PROXY'},
	      {v2_international_mobile_subscriber_identity, 0} :=
		   #v2_international_mobile_subscriber_identity{imsi = ?'PROXY-IMSI'},
	      {v2_msisdn, 0} := #v2_msisdn{msisdn = ?'PROXY-MSISDN'}
	     }}, FirstHR),
    ?match(#gtp{seq_no = SeqNo} when SeqNo < 16#80000, FirstHR),

    ?equal([], outstanding_requests()),

    PSeids = pfcp_seids(),
    History = ergw_test_sx_up:history('sgw-u'),
    ct:pal("History:~n~s", [pfcp_packet:pretty_print(History)]),
    [SER, SMR|_] =
	lists:filter(
	  fun(#pfcp{type = session_establishment_request,
		    ie = #{f_seid := #f_seid{seid = FSeid}}}) ->
		  not lists:member(FSeid, PSeids);
	     (#pfcp{type = session_modification_request, seid = FSeid}) ->
		  not lists:member(FSeid, PSeids);
	     (_) -> false
	  end, History),

    SERMap =
	fun SERFilter(Value, Acc) when is_list(Value) ->
		lists:foldl(SERFilter, Acc, Value);
	    SERFilter(#create_pdr{
			 group =
			     #{pdi :=
				   #pdi{group =
					    #{source_interface :=
						  #source_interface{interface = Intf}}}}} = PDR,
		      Acc) ->
		Acc#{{pdr, Intf} => PDR};
	    SERFilter(#create_far{
			 group =
			     #{far_id := Id,
			       forwarding_parameters :=
				   #forwarding_parameters{
				      group =
					  #{destination_interface :=
						#destination_interface{interface = Intf}}}}
			} = FAR,
		      Acc) ->
		Acc#{{far, id, Intf} => Id, {far, Intf} => FAR};
	    SERFilter(#create_far{
			 group =
			     #{far_id := Id,
			       apply_action :=
				   #apply_action{drop = 1}}} = FAR,
		      Acc) ->
		Acc#{{far, id, drop} => Id, {far, drop} => FAR};
	    SERFilter(#create_urr{
			 group =
			     #{urr_id := Id,
			       reporting_triggers :=
				   #reporting_triggers{
				      periodic_reporting = 1}
			      }}, Acc) ->
		Acc#{{urr, id} => Id};
	    SERFilter(Value, Acc) ->
		Acc
	end(maps:values(SER#pfcp.ie), #{}),
    ct:pal("SER Map:~n~s", [pfcp_packet:pretty_print(SERMap)]),

    #{{far,'Access'} := FarAccess,
      {far,drop} := FarDrop,
      {pdr,'Access'} := PdrAccess,
      {pdr,'Core'} := PdrCore,
      {far,id,'Access'} := FarAccessId,
      {far,id,drop} := FarDropId,
      {urr, id} := UrrId} = SERMap,

    ?match(#create_far{
	      group =
		  #{far_id := #far_id{},
		    apply_action :=
			#apply_action{forw = 1},
		    forwarding_parameters :=
			#forwarding_parameters{
			   group =
			       #{destination_interface :=
				     #destination_interface{interface = 'Access'},
				 network_instance :=
				     #network_instance{},
				 outer_header_creation :=
				     #outer_header_creation{
					type = 'GTP-U'}
				}
			  }
		   }
	     }, FarAccess),
    ?match(#create_far{
	      group =
		  #{far_id := #far_id{},
		    apply_action :=
			#apply_action{drop = 1}
		   }
	     }, FarDrop),
    ?match(#create_pdr{
	      group =
		  #{far_id := FarDropId,
		    outer_header_removal :=
			#outer_header_removal{},
		    pdi :=
			#pdi{
			   group =
			       #{f_teid :=
				     #f_teid{},
				 network_instance :=
				     #network_instance{},
				 source_interface :=
				     #source_interface{interface = 'Access'}}},
		    pdr_id := #pdr_id{},
		    precedence := #precedence{precedence = 100},
		    urr_id := UrrId
		   }
	     }, PdrAccess),
    ?match(#create_pdr{
	      group =
		  #{far_id := FarAccessId,
		    outer_header_removal :=
			#outer_header_removal{},
		    pdi :=
			#pdi{
			   group =
			       #{f_teid :=
				     #f_teid{},
				 network_instance :=
				     #network_instance{},
				 source_interface :=
				     #source_interface{interface = 'Core'}}},
		    pdr_id := #pdr_id{},
		    precedence := #precedence{precedence = 100},
		    urr_id := UrrId
		   }
	     }, PdrCore),
    SMRMap =
	fun SMRFilter(Value, Acc) when is_list(Value) ->
		lists:foldl(SMRFilter, Acc, Value);
	    SMRFilter(#update_far{
			 group =
			     #{far_id := Id,
			       update_forwarding_parameters :=
				   #update_forwarding_parameters{
				      group =
					  #{destination_interface :=
						#destination_interface{interface = Intf}}}}
			} = FAR,
		      Acc) ->
		Acc#{{far, id, Intf} => Id, {far, Intf} => FAR};
	    SMRFilter(Value, Acc) ->
		Acc
	end(maps:values(SMR#pfcp.ie), #{}),
    ct:pal("SMR Map:~n~s", [pfcp_packet:pretty_print(SMRMap)]),

    #{{far,'Core'} := FarCore,
      {far,id,'Core'} := FarCoreId} = SMRMap,

    ?equal(FarCoreId, FarDropId),
    ?match(#update_far{
	      group =
		  #{apply_action :=
			#apply_action{forw = 1},
		    update_forwarding_parameters :=
			#update_forwarding_parameters{
			   group =
			       #{destination_interface :=
				     #destination_interface{interface = 'Core'},
				 network_instance :=
				     #network_instance{},
			      outer_header_creation :=
				     #outer_header_creation{
				      type = 'GTP-U'}
				}
			  }
		   }
	     }, FarCore),

    ok.

%%--------------------------------------------------------------------
simple_session_random_port() ->
    [{doc, "Check simple Create Session, Delete Session sequence"}].
simple_session_random_port(Config) ->
    init_seq_no(?MODULE, 16#80000),
    GtpC0 = gtp_context(?MODULE, Config),

    {GtpC1, _, _} = create_session(GtpC0),
    delete_session(GtpC1),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    GtpRecMatch = #gtp{type = create_session_request, _ = '_'},
    P = meck:capture(first, ?HUT, handle_request, ['_', GtpRecMatch, '_', '_'], 2),
    ?match(#gtp{seq_no = SeqNo} when SeqNo >= 16#80000, P),

    ?equal([], outstanding_requests()),
    ok.

%%--------------------------------------------------------------------
duplicate_session_request() ->
    [{doc, "Check the a new incomming request for the same IMSI terminates the first"}].
duplicate_session_request(Config) ->
    {GtpC1, _, _} = create_session(Config),

    %% create 2nd session with the same IMSI
    {GtpC2, _, _} = create_session(GtpC1),

    [?match(#{tunnels := 1}, X) || X <- ergw_api:peer(all)],

    delete_session(not_found, GtpC1),
    delete_session(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_resend() ->
    [{doc, "Check that a retransmission of a Create Session Request works"}].
create_session_request_resend(Config) ->
    {GtpC, Msg, Response} = create_session(Config),
    ?equal(Response, send_recv_pdu(GtpC, Msg)),
    ?equal([], outstanding_requests()),

    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_proxy_request_resend() ->
    [{doc, "Check that the proxy does not send the Create Session Request multiple times"}].
create_session_proxy_request_resend(Config) ->
    GtpC = gtp_context(Config),
    Request = make_request(create_session_request, simple, GtpC),

    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, 2 * 1000, error)),

    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),

    %% killing the proxy PGW context
    gtp_context:terminate_context(Server),

    ?match(1, meck:num_calls(pgw_s5s8, handle_request,
			     ['_', #gtp{type = create_session_request, _ = '_'}, '_', '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_session_request_resend() ->
    [{doc, "Check that a retransmission of a Delete Session Request works"}].
delete_session_request_resend(Config) ->
    {GtpC, _, _} = create_session(Config),
    {_, Msg, Response} = delete_session(GtpC),
    ?equal(Response, send_recv_pdu(GtpC, Msg)),
    ?equal([], outstanding_requests()),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_session_request_timeout() ->
    [{doc, "Check that a Delete Session Request terminates the "
           "proxy session even when the final GSN fails"}].
delete_session_request_timeout(Config) ->
    {GtpC, _, _} = create_session(Config),
    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),

    Request = make_request(delete_session_request, simple, GtpC),

    %% simulate retransmissions
    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, ?TIMEOUT, error)),
    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, ?TIMEOUT, error)),
    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, ?TIMEOUT, error)),

    %% killing the PGW context
    exit(Server, kill),

    wait4tunnels(20000),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
error_indication_sgw2pgw() ->
    [{doc, "Check the a GTP-U error indication terminates the session"}].
error_indication_sgw2pgw(Config) ->
    {GtpC, _, _} = create_session(Config),

    ergw_test_sx_up:send('sgw-u', make_error_indication_report(GtpC)),

    ct:sleep(100),
    delete_session(not_found, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
error_indication_pgw2sgw() ->
    [{doc, "Check the a GTP-U error indication terminates the session"}].
error_indication_pgw2sgw(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_session(Config),

    {_Handler, CtxPid} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    true = is_pid(CtxPid),
    #{proxy_context := Ctx} = gtp_context:info(CtxPid),

    ergw_test_sx_up:send('sgw-u', make_error_indication_report(Ctx)),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    ct:sleep(100),
    delete_session(not_found, GtpC),

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),
    %% killing the PGW context
    exit(Server, kill),

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
    Send = fun(Type, SubType, GtpCin) ->
		   GtpC = gtp_context_inc_seq(GtpCin),
		   Request = make_request(Type, SubType, GtpC),
		   send_pdu(GtpC, Request),
		   Response = send_recv_pdu(GtpC, Request),
		   validate_response(Type, SubType, Response, GtpC)
	   end,

    GtpC0 = gtp_context(Config),

    GtpC1 = Send(create_session_request, simple, GtpC0),
    ?equal(timeout, recv_pdu(GtpC1, -1, 100, fun(Why) -> Why end)),

    GtpC2 = Send(change_notification_request, simple, GtpC1),
    ?equal(timeout, recv_pdu(GtpC2, -1, 100, fun(Why) -> Why end)),

    GtpC3 = Send(change_notification_request, without_tei, GtpC2),
    ?equal(timeout, recv_pdu(GtpC3, -1, 100, fun(Why) -> Why end)),

    ?equal([], outstanding_requests()),

    delete_session(GtpC3),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(3, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_'])),
    ?match(3, meck:num_calls(pgw_s5s8, handle_request, ['_', '_', true, '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_request_ra_update() ->
    [{doc, "Check Modify Bearer Routing Area Update"}].
modify_bearer_request_ra_update(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {_Handler, CtxPid} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    #{context := Ctx1} = gtp_context:info(CtxPid),

    {GtpC2, _, _} = modify_bearer(ra_update, GtpC1),
    #{context := Ctx2} = gtp_context:info(CtxPid),

    ?equal([], outstanding_requests()),
    delete_session(GtpC2),

    %% make sure the SGW side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the PDN-GW side control TEID don't change
    ?equal(Ctx1#context.remote_control_teid, Ctx2#context.remote_control_teid),
    ?equal(Ctx1#context.remote_data_teid,    Ctx2#context.remote_data_teid),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_request_tei_update() ->
    [{doc, "Check Modify Bearer with TEID update (e.g. SGW change)"}].
modify_bearer_request_tei_update(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {_Handler, CtxPid} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    #{context := Ctx1} = gtp_context:info(CtxPid),

    {_Handler, ProxyCtxPid} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    #{proxy_context := PrxCtx1} = gtp_context:info(ProxyCtxPid),
    #context{control_port = #gtp_port{name = ProxySocket}} = PrxCtx1,
    ProxyRegKey1 = {ProxySocket, {teid, 'gtp-c', PrxCtx1#context.local_control_tei}},
    ?match({gtp_context, ProxyCtxPid}, gtp_context_reg:lookup(ProxyRegKey1)),

    {GtpC2, _, _} = modify_bearer(tei_update, GtpC1),
    #{context := Ctx2} = gtp_context:info(CtxPid),

    #{proxy_context := PrxCtx2} = gtp_context:info(ProxyCtxPid),
    ProxyRegKey2 = {ProxySocket, {teid, 'gtp-c', PrxCtx2#context.local_control_tei}},
    ?match(undefined, gtp_context_reg:lookup(ProxyRegKey1)),
    ?match({gtp_context, ProxyCtxPid}, gtp_context_reg:lookup(ProxyRegKey2)),

    ?equal([], outstanding_requests()),
    delete_session(GtpC2),

    %% make sure the SGW side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the PDN-GW side control TEID DOES change
    ?not_equal(Ctx1#context.remote_control_teid, Ctx2#context.remote_control_teid),
    ?equal(Ctx1#context.remote_data_teid, Ctx2#context.remote_data_teid),

    [_, SMR0|_] = lists:filter(
		    fun(#pfcp{type = session_modification_request}) -> true;
		       (_) -> false
		    end, ergw_test_sx_up:history('sgw-u')),
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
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, Req0} = modify_bearer_command(simple, GtpC1),

    Req1 = recv_pdu(GtpC2, Req0#gtp.seq_no, ?TIMEOUT, ok),
    validate_response(modify_bearer_command, simple, Req1, GtpC2),
    Response = make_response(Req1, simple, GtpC2),
    send_pdu(GtpC2, Response),

    ?equal({ok, timeout}, recv_pdu(GtpC2, Req1#gtp.seq_no, ?TIMEOUT, ok)),
    ?equal([], outstanding_requests()),

    delete_session(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_command_timeout() ->
    [{doc, "Check Modify Bearer Command"}].
modify_bearer_command_timeout(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC1, _, _} = create_session(Config),
    {GtpC2, Req0} = modify_bearer_command(simple, GtpC1),

    Req1 = recv_pdu(GtpC2, Req0#gtp.seq_no, ?TIMEOUT, ok),
    validate_response(modify_bearer_command, simple, Req1, GtpC2),
    ?equal(Req1, recv_pdu(GtpC2, 5000)),
    ?equal(Req1, recv_pdu(GtpC2, 5000)),

    Req2 = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Req2),
    ?equal(Req2, recv_pdu(Cntl, 5000)),
    ?equal(Req2, recv_pdu(Cntl, 5000)),

    wait4tunnels(20000),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_command_congestion() ->
    [{doc, "Check Modify Bearer Command"}].
modify_bearer_command_congestion(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC1, _, _} = create_session(Config),
    {GtpC2, Req0} = modify_bearer_command(simple, GtpC1),

    Req1 = recv_pdu(GtpC2, Req0#gtp.seq_no, ?TIMEOUT, ok),
    validate_response(modify_bearer_command, simple, Req1, GtpC2),
    Resp1 = make_response(Req1, apn_congestion, GtpC2),
    send_pdu(GtpC2, Resp1),

    Req2 = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Req2),
    Resp2 = make_response(Req2, simple, GtpC2),
    send_pdu(Cntl, GtpC2, Resp2),

    ?equal({ok, timeout}, recv_pdu(GtpC2, Req2#gtp.seq_no, ?TIMEOUT, ok)),
    ?equal([], outstanding_requests()),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
change_notification_request_with_tei() ->
    [{doc, "Check Change Notification request with TEID"}].
change_notification_request_with_tei(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = change_notification(simple, GtpC1),
    ?equal([], outstanding_requests()),
    delete_session(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
change_notification_request_without_tei() ->
    [{doc, "Check Change Notification request without TEID "
           "include IMEI and IMSI instead"}].
change_notification_request_without_tei(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = change_notification(without_tei, GtpC1),
    ?equal([], outstanding_requests()),
    delete_session(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
change_notification_request_invalid_imsi() ->
    [{doc, "Check Change Notification request without TEID "
           "include a invalid IMEI and IMSI instead"}].
change_notification_request_invalid_imsi(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = change_notification(invalid_imsi, GtpC1),
    ?equal([], outstanding_requests()),
    delete_session(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
suspend_notification_request() ->
    [{doc, "Check that Suspend Notification works"}].
suspend_notification_request(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = suspend_notification(simple, GtpC1),
    ?equal([], outstanding_requests()),
    delete_session(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
resume_notification_request() ->
    [{doc, "Check that Resume Notification works"}].
resume_notification_request(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = resume_notification(simple, GtpC1),
    ?equal([], outstanding_requests()),
    delete_session(GtpC2),

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

    {GtpC, _, _} = create_session(Config),
    ?equal([], outstanding_requests()),
    delete_session(GtpC),

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

    {GtpC, _, _} = create_session(Config),
    ?equal([], outstanding_requests()),
    delete_session(GtpC),

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

    {_, _, _} = create_session(invalid_mapping, Config),
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
			{ok, ProxyInfo#proxy_info{ggsns = [#proxy_ggsn{restrictions = [{v2, false}]}]}}
		end),

    {_, _, _} = create_session(version_restricted, Config),
    ?equal([], outstanding_requests()),

    meck:unload(gtp_proxy_ds),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
requests_invalid_teid() ->
    [{doc, "Check invalid TEID's for a number of request types"}].
requests_invalid_teid(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer(invalid_teid, GtpC1),
    {GtpC3, _, _} = change_notification(invalid_teid, GtpC2),
    {GtpC4, _, _} = suspend_notification(invalid_teid, GtpC3),
    {GtpC5, _, _} = resume_notification(invalid_teid, GtpC4),
    ?equal([], outstanding_requests()),
    delete_session(GtpC5),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
commands_invalid_teid() ->
    [{doc, "Check invalid TEID's for a number of command types"}].
commands_invalid_teid(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer_command(invalid_teid, GtpC1),
    ?equal([], outstanding_requests()),
    delete_session(GtpC2),

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

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
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

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
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

    ?match([_], outstanding_requests()),
    wait4tunnels(20000),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_bearer_request_invalid_teid() ->
    [{doc, "Check error response of PGW initiated bearer shutdown with invalid TEID"},
     {timetrap,{seconds,60}}].
delete_bearer_request_invalid_teid(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Server)} end),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request),

    Response = make_response(Request, invalid_teid, GtpC),
    send_pdu(Cntl, GtpC, Response),

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
delete_bearer_request_late_response() ->
    [{doc, "Check a answer folling a resend of PGW initiated bearer shutdown"},
     {timetrap,{seconds,60}}].
delete_bearer_request_late_response(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Server)} end),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request),
    ?equal(Request, recv_pdu(Cntl, 5000)),
    ?equal(Request, recv_pdu(Cntl, 5000)),

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
interop_sgsn_to_sgw() ->
    [{doc, "Check 3GPP T 23.401, Annex D, SGSN to SGW handover"}].
interop_sgsn_to_sgw(Config) ->
    {GtpC1, _, _} = ergw_ggsn_test_lib:create_pdp_context(Config),
    {_Handler, CtxPid} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    #{context := Ctx1} = gtp_context:info(CtxPid),

    check_exo_contexts(v1, 3, 1),
    check_exo_contexts(v2, 0, 0),

    {GtpC2, _, _} = modify_bearer(tei_update, GtpC1),
    #{context := Ctx2} = gtp_context:info(CtxPid),

    ?equal([], outstanding_requests()),
    check_exo_contexts(v1, 3, 0),
    check_exo_contexts(v2, 3, 1),
    delete_session(GtpC2),

    %% make sure the SGSN/SGW side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the GGSN/PDN-GW side control TEID DOES change
    ?not_equal(Ctx1#context.remote_control_teid, Ctx2#context.remote_control_teid),
    ?equal(Ctx1#context.remote_data_teid,    Ctx2#context.remote_data_teid),

    [_, SMR0|_] = lists:filter(
		    fun(#pfcp{type = session_modification_request}) -> true;
		       (_) -> false
		    end, ergw_test_sx_up:history('sgw-u')),
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
    true = meck:validate(ggsn_gn_proxy),

    ct:sleep(100),
    check_exo_contexts(v1, 3, 0),
    check_exo_contexts(v2, 3, 0),
    ok.

%%--------------------------------------------------------------------
interop_sgw_to_sgsn() ->
    [{doc, "Check 3GPP T 23.401, Annex D, SGW to SGSN handover"}].
interop_sgw_to_sgsn(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {_Handler, CtxPid} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    #{context := Ctx1} = gtp_context:info(CtxPid),

    check_exo_contexts(v1, 0, 0),
    check_exo_contexts(v2, 3, 1),
    {GtpC2, _, _} = ergw_ggsn_test_lib:update_pdp_context(tei_update, GtpC1),
    #{context := Ctx2} = gtp_context:info(CtxPid),

    check_exo_contexts(v1, 3, 1),
    check_exo_contexts(v2, 3, 0),
    ergw_ggsn_test_lib:delete_pdp_context(GtpC2),

    %% make sure the SGSN/SGW side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the GGSN/PDN-GW side control TEID DOES change
    ?not_equal(Ctx1#context.remote_control_teid, Ctx2#context.remote_control_teid),
    ?equal(Ctx1#context.remote_data_teid,    Ctx2#context.remote_data_teid),

    [_, SMR0|_] = lists:filter(
		    fun(#pfcp{type = session_modification_request}) -> true;
		       (_) -> false
		    end, ergw_test_sx_up:history('sgw-u')),
    SMR = pfcp_packet:to_map(SMR0),
    #{update_far :=
	  #update_far{
	     group =
		 #{update_forwarding_parameters :=
		       #update_forwarding_parameters{group = UFP}}}} = SMR#pfcp.ie,
    ?match(#sxsmreq_flags{sndem = 0},
	   maps:get(sxsmreq_flags, UFP, #sxsmreq_flags{sndem = 0})),


    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    true = meck:validate(ggsn_gn_proxy),

    ct:sleep(100),
    check_exo_contexts(v1, 3, 0),
    check_exo_contexts(v2, 3, 0),
    ok.

%%--------------------------------------------------------------------
update_bearer_request() ->
    [{doc, "Check PGW initiated Update Bearer"},
     {timetrap,{seconds,60}}].
update_bearer_request(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),

    Self = self(),
    spawn(fun() -> Self ! {req, gen_server:call(Server, update_context)} end),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = update_bearer_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    receive
	{req, ok} ->
	    ok;
	{req, Other} ->
	    ct:fail(Other)
    after ?TIMEOUT ->
	    ct:fail(timeout)
    end,

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
    ?equal([], outstanding_requests()),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------

%% Note: this test is outdated, with the AAA infrastructure, the
%%       URR rules are only installed when accounting/charging is
%%       active. However, this test lacks all for of AAA peer,
%%       so the URR rules are not actually installed. Querying them
%%       would therefore also not work. The test UPF is ignoring that
%%       and returns something every time.
session_accounting() ->
    [{doc, "Check that accounting in session works"}].
session_accounting(Config) ->
    ClientIP = proplists:get_value(client_ip, Config),

    {GtpC, _, _} = create_session(Config),

    [#{'Process' := Pid}|_] = ergw_api:tunnel(ClientIP),
    #{context := Context, pfcp:= PCtx} = gtp_context:info(Pid),

    %% make sure we handle that the Sx node is not returning any accounting
    ergw_test_sx_up:accounting('sgw-u', off),

    SessionOpts1 = ergw_test_lib:query_usage_report(Context, PCtx),
    ?equal(false, maps:is_key('InPackets', SessionOpts1)),
    ?equal(false, maps:is_key('InOctets', SessionOpts1)),

    %% enable accouting again....
    ergw_test_sx_up:accounting('sgw-u', on),

    SessionOpts2 = ergw_test_lib:query_usage_report(Context, PCtx),
    ?match(#{'InPackets' := 3, 'OutPackets' := 1,
	     'InOctets' := 4, 'OutOctets' := 2}, SessionOpts2),

    SessionOpts3 = ergw_test_lib:query_usage_report(Context, PCtx),
    ?match(#{'InPackets' := 3, 'OutPackets' := 1,
	     'InOctets' := 4, 'OutOctets' := 2}, SessionOpts3),

    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
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

check_exo_contexts(Version, Cnt, Expect) ->
    Metrics = exometer:get_values([path, '_', '_', contexts, Version]),
    ?equal(Cnt, length(Metrics)),
    [?equal({Path, Expect}, {Path, proplists:get_value(value, Value)}) ||
	{Path, Value} <- Metrics].

pfcp_seids() ->
    lists:flatten(ets:match(gtp_context_reg, {{seid, '$1'},{ergw_sx_node, '_'}})).
