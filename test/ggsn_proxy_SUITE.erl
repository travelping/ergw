%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_proxy_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_ggsn_test_lib.hrl").

-define(TIMEOUT, 2000).
-define(NUM_OF_CLIENTS, 6). %% Num of IP clients for multi contexts

-define(HUT, ggsn_gn_proxy).			%% Handler Under Test

%%%===================================================================
%%% Config
%%%===================================================================

-define(TEST_CONFIG_MULTIPLE_PROXY_SOCKETS,
	[
	 {kernel,
	  [{logger,
	    [%% force cth_log to async mode, never block the tests
	     {handler, cth_log_redirect, cth_log_redirect,
	      #{config =>
		    #{sync_mode_qlen => 10000,
		      drop_mode_qlen => 10000,
		      flush_qlen     => 10000}
	       }
	     }
	    ]}
	  ]},

	 {ergw, [{'$setup_vars',
		  [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
		 {dp_handler, '$meck'},
		 {sockets,
		  [{cp, [{type, 'gtp-u'},
			 {ip, ?MUST_BE_UPDATED},
			 {reuseaddr, true}
			]},
		   {irx, [{type, 'gtp-c'},
			  {ip,  ?MUST_BE_UPDATED},
			  {reuseaddr, true}
			 ]},
		   {'proxy-irx', [{type, 'gtp-c'},
				  {ip,  ?MUST_BE_UPDATED},
				  {reuseaddr, true}
				 ]},
		   {'remote-irx', [{type, 'gtp-c'},
				   {ip,  ?MUST_BE_UPDATED},
				   {reuseaddr, true}
				  ]},
		   {'remote-irx2', [{type, 'gtp-c'},
				    {ip, ?MUST_BE_UPDATED},
				    {reuseaddr, true}
				   ]} 
		  ]},

		 {ip_pools,
		  [{'pool-A', [{ranges,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
					  {?IPv6PoolStart, ?IPv6PoolEnd, 64},
					  {?IPv6HostPoolStart, ?IPv6HostPoolEnd, 128}]},
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
			 {node_selection, [default]},
			 {contexts,
			  [{<<"ams">>,
			      [{proxy_sockets, ['proxy-irx']}]}]}
			]},
		   %% remote GGSN handler
		   {gn, [{handler, ggsn_gn},
			 {sockets, ['remote-irx', 'remote-irx2']},
			 {node_selection, [default]},
			 {aaa, [{'Username',
				 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
			]}
		  ]},

		 {node_selection,
		  [{default,
		    {static,
		     [
		      %% APN NAPTR alternative
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-ggsn","x-gn"},{"x-3gpp-ggsn","x-gp"}],
		       "topon.gtp.ggsn.$ORIGIN"},
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxa"}],
		       "topon.sx.sgw-u01.$ORIGIN"},
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.pgw-u01.$ORIGIN"},

		      {"pgw-1.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-ggsn","x-gn"},{"x-3gpp-ggsn","x-gp"}],
		       "topon.pgw-1.nodes.$ORIGIN"},
		      {"upf-1.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.pgw-1.nodes.$ORIGIN"},

		      %% A/AAAA record alternatives
		      {"topon.gtp.ggsn.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.sgw-u01.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.pgw-u01.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.pgw-1.nodes.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.upf-1.nodes.$ORIGIN", ?MUST_BE_UPDATED, []}
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
		  [{?'APN-PROXY',
		    [{vrf, example},
		     {ip_pools, ['pool-A']}]}
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
		       {'remote-irx2', [{features, ['Access']}]},
		       {example, [{features, ['SGi-LAN']}]}]
		     },
		     {ip_pools, ['pool-A']}]
		   },
		   {"topon.sx.sgw-u01.$ORIGIN", [connect]},
		   {"topon.sx.pgw-u01.$ORIGIN", [connect]},
		   {"topon.upf-1.nodes.$ORIGIN", [connect]}
		  ]
		 },
		 {path_management,
		  [{t3, 10},  % echo retry interval timeout (Seconds > 0)
		   {n3, 5},   % echo etries per ping (Integer > 0)
		   {ping, 60}, % echo interval between successul pings (Seconds, >= 60)
		   {pd_mon_t, 300}, % echo interval monitoring of down peer (Seconds >= 60) 
		   {pd_mon_dur, 7200}] % echo sending duration to egress down peer (Seconds >= 60)
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
	 {kernel,
	  [{logger,
	    [%% force cth_log to async mode, never block the tests
	     {handler, cth_log_redirect, cth_log_redirect,
	      #{config =>
		    #{sync_mode_qlen => 10000,
		      drop_mode_qlen => 10000,
		      flush_qlen     => 10000}
	       }
	     }
	    ]}
	  ]},

	 {ergw, [{'$setup_vars',
		  [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
		 {dp_handler, '$meck'},
		 {sockets,
		  [{cp, [{type, 'gtp-u'},
			 {ip, ?MUST_BE_UPDATED},
			 {reuseaddr, true}
			]},
		   {irx, [{type, 'gtp-c'},
			  {ip,  ?TEST_GSN_IPv4},
			  {reuseaddr, true}
			 ]},
		   {'remote-irx', [{type, 'gtp-c'},
				   {ip,  ?FINAL_GSN_IPv4},
				   {reuseaddr, true}
				  ]},
		   {'remote-irx2', [{type, 'gtp-c'},
				    {ip, ?MUST_BE_UPDATED},
				    {reuseaddr, true}
				   ]}
		  ]},

		 {ip_pools,
		  [{'pool-A', [{ranges,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
					  {?IPv6PoolStart, ?IPv6PoolEnd, 64},
					  {?IPv6HostPoolStart, ?IPv6HostPoolEnd, 128}]},
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
			 {node_selection, [default]},
			 {contexts,
			  [{<<"ams">>,
			    [{proxy_sockets, ['irx']}]}]}
			]},
		   %% remote GGSN handler
		   {gn, [{handler, ggsn_gn},
			 {sockets, ['remote-irx', 'remote-irx2']},
			 {node_selection, [default]},
			 {aaa, [{'Username',
				 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
			]}
		  ]},

		 {node_selection,
		  [{default,
		    {static,
		     [
		      %% APN NAPTR alternative
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-ggsn","x-gn"},{"x-3gpp-ggsn","x-gp"}],
		       "topon.gtp.ggsn.$ORIGIN"},
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxa"}],
		       "topon.sx.sgw-u01.$ORIGIN"},
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.pgw-u01.$ORIGIN"},

		      {"pgw-1.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-ggsn","x-gn"},{"x-3gpp-ggsn","x-gp"}],
		       "topon.pgw-1.nodes.$ORIGIN"},
		      {"upf-1.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.pgw-1.nodes.$ORIGIN"},

		      %% A/AAAA record alternatives
		      {"topon.gtp.ggsn.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.sgw-u01.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.pgw-u01.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.pgw-1.nodes.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.upf-1.nodes.$ORIGIN", ?MUST_BE_UPDATED, []}
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
		  [{?'APN-PROXY',
		    [{vrf, example},
		     {ip_pools, ['pool-A']}]}
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
		       {'remote-irx2', [{features, ['Access']}]},
		       {example, [{features, ['SGi-LAN']}]}]
		     },
		     {ip_pools, ['pool-A']}]
		   },
		   {"topon.sx.sgw-u01.$ORIGIN", [connect]},
		   {"topon.sx.pgw-u01.$ORIGIN", [connect]},
		   {"topon.upf-1.nodes.$ORIGIN", [connect]}
		  ]
		 },
		 {path_management,
		  [{t3, 10},  % echo retry interval timeout (Seconds > 0)
		   {n3, 5},   % echo etries per ping (Integer > 0)
		   {ping, 60}, % echo interval between successul pings (Seconds, >= 60)
		   {pd_mon_t, 300}, % echo interval monitoring of down peer (Seconds >= 60) 
		   {pd_mon_dur, 7200}] % echo sending duration to egress down peer (Seconds >= 60)
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
	 {[sockets, 'remote-irx2', ip], final_gsn2},
	 {[sx_socket, ip], localhost},
	 {[node_selection, {default, 2}, 2, "topon.gtp.ggsn.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.sx.sgw-u01.$ORIGIN"],
	  {fun node_sel_update/2, sgw_u_sx}},
	 {[node_selection, {default, 2}, 2, "topon.sx.pgw-u01.$ORIGIN"],
	  {fun node_sel_update/2, pgw_u01_sx}},
	 {[node_selection, {default, 2}, 2, "topon.pgw-1.nodes.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.upf-1.nodes.$ORIGIN"],
	  {fun node_sel_update/2, sgw_u_sx}}
	]).

-define(CONFIG_UPDATE_SINGLE_PROXY_SOCKET,
	[{[sockets, cp, ip], localhost},
	 {[sockets, irx, ip], test_gsn},
	 {[sockets, 'remote-irx', ip], final_gsn},
	 {[sockets, 'remote-irx2', ip], final_gsn2},
	 {[sx_socket, ip], localhost},
	 {[node_selection, {default, 2}, 2, "topon.gtp.ggsn.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.sx.sgw-u01.$ORIGIN"],
	  {fun node_sel_update/2, sgw_u_sx}},
	 {[node_selection, {default, 2}, 2, "topon.sx.pgw-u01.$ORIGIN"],
	  {fun node_sel_update/2, pgw_u01_sx}},
	 {[node_selection, {default, 2}, 2, "topon.pgw-1.nodes.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.upf-1.nodes.$ORIGIN"],
	  {fun node_sel_update/2, sgw_u_sx}}
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
init_per_group(no_proxy_map, Config0) ->
    Cf0 = proplists:get_value(ergw, ?TEST_CONFIG_SINGLE_PROXY_SOCKET),
    Cf1 = proplists:delete(proxy_map, Cf0),
    Cf = lists:keystore(ergw, 1, ?TEST_CONFIG_SINGLE_PROXY_SOCKET, {ergw, Cf1}),
    Config1 = lists:keystore(app_cfg, 1, Config0, {app_cfg, Cf}),
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
     create_pdp_context_request_missing_ie,
     create_pdp_context_request_accept_new,
     path_restart, path_restart_recovery,
     path_failure_to_ggsn,
     path_failure_to_ggsn_and_restore,
     path_failure_to_sgsn,
     simple_pdp_context_request,
     simple_pdp_context_request_no_proxy_map,
     create_pdp_context_request_resend,
     create_pdp_context_proxy_request_resend,
     create_lb_multi_context,
     one_lb_node_down,
     delete_pdp_context_request_resend,
     delete_pdp_context_request_timeout,
     error_indication_sgsn2ggsn,
     error_indication_ggsn2sgsn,
     %% request_fast_resend, TODO, FIXME
     update_pdp_context_request_ra_update,
     update_pdp_context_request_tei_update,
     ggsn_update_pdp_context_request,
     ms_info_change_notification_request_with_tei,
     ms_info_change_notification_request_without_tei,
     ms_info_change_notification_request_invalid_imsi,
     proxy_context_selection,
     proxy_context_invalid_selection,
     proxy_context_invalid_mapping,
     proxy_api_v2,
     invalid_teid,
     delete_pdp_context_requested,
     delete_pdp_context_requested_resend,
     delete_pdp_context_requested_invalid_teid,
     delete_pdp_context_requested_late_response,
     create_pdp_context_overload,
     unsupported_request,
     cache_timeout,
     session_accounting,
     sx_upf_reconnect,
     sx_upf_removal,
     sx_timeout
    ].

common_groups() ->
    [{group, single_proxy_interface},
     {group, multiple_proxy_interface},
     {group, no_proxy_map}].

groups() ->
    [{single_proxy_interface, [], common()},
     {multiple_proxy_interface, [], common()},
     {no_proxy_map, [], [simple_pdp_context_request_no_proxy_map]},
     {ipv4, [], common_groups()},
     {ipv6, [], common_groups()}].

all() ->
    [{group, ipv4},
     {group, ipv6}].

%%%===================================================================
%%% Tests
%%%===================================================================

setup_per_testcase(Config) ->
    setup_per_testcase(Config, true).

setup_per_testcase(Config, ClearSxHist) ->
    ct:pal("Sockets: ~p", [ergw_gtp_socket_reg:all()]),
    ergw_test_sx_up:reset('pgw-u01'),
    ergw_test_sx_up:reset('sgw-u'),
    meck_reset(Config),
    start_gtpc_server(Config),
    reconnect_all_sx_nodes(),
    ClearSxHist andalso ergw_test_sx_up:history('pgw-u01', true),
    ok.

setup_per_testcase(Config, Name, ClearSxHist) ->
    ct:pal("Sockets: ~p", [ergw_gtp_socket_reg:all()]),
    ergw_test_sx_up:reset('pgw-u01'),
    ergw_test_sx_up:reset('sgw-u'),
    meck_reset(Config),
    start_gtpc_server(Config, Name),
    reconnect_all_sx_nodes(),
    ClearSxHist andalso ergw_test_sx_up:history('pgw-u01', true),
    ok.

init_per_testcase(path_restart, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(gtp_path, [passthrough, no_link]),
    Config;
init_per_testcase(create_pdp_context_proxy_request_resend, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    ok = meck:expect(ggsn_gn, handle_request,
		     fun(ReqKey, #gtp{type = create_pdp_context_request}, _, _, _) ->
			     gtp_context:request_finished(ReqKey),
			     keep_state_and_data;
			(ReqKey, Msg, Resent, State, Data) ->
			     meck:passthrough([ReqKey, Msg, Resent, State, Data])
		     end),
    Config;
init_per_testcase(delete_pdp_context_request_timeout, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    ok = meck:expect(ggsn_gn, handle_request,
		     fun(ReqKey, #gtp{type = delete_pdp_context_request}, _, _, _) ->
			     gtp_context:request_finished(ReqKey),
			     keep_state_and_data;
			(ReqKey, Msg, Resent, State, Data) ->
			     meck:passthrough([ReqKey, Msg, Resent, State, Data])
		     end),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == delete_pdp_context_requested_resend;
       TestCase == delete_pdp_context_requested_invalid_teid;
       TestCase == delete_pdp_context_requested_late_response ->
    setup_per_testcase(Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
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
    setup_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    ok = meck:expect(ggsn_gn, handle_request,
		     fun(Request, Msg, Resent, State, Data) ->
			     if Resent -> ok;
				true   -> ct:sleep(1000)
			     end,
			     meck:passthrough([Request, Msg, Resent, State, Data])
		     end),
    Config;
init_per_testcase(path_failure_to_ggsn_and_restore, Config) ->
    set_path_timers([{'pd_mon_t', 1},{pd_mon_dur, 70}]),
    setup_per_testcase(Config),
    Config;
init_per_testcase(simple_pdp_context_request, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == create_lb_multi_context;
       TestCase == one_lb_node_down ->
    IPGroup = proplists:get_value(ip_group, Config, ipv4),
    set_up_clients(?NUM_OF_CLIENTS, Config, IPGroup),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    Config;
init_per_testcase(ggsn_update_pdp_context_request, Config) ->
    %% our GGSN does not send update_bearer_request, so we have to fake them
    setup_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    ok = meck:expect(ggsn_gn, handle_event,
		     fun({call, From}, update_context, _State, #{context := Context}) ->
			     ergw_ggsn_test_lib:ggsn_update_context(From, Context),
			     keep_state_and_data;
			(Type, Content, State, Data) ->
			     meck:passthrough([Type, Content, State, Data])
		     end),
    ok = meck:expect(ggsn_gn, handle_response,
		     fun(From, #gtp{type = update_pdp_context_response}, _, _, _) ->
			     gen_statem:reply(From, ok),
			     keep_state_and_data;
			(From, Response, Request, State, Data) ->
			     meck:passthrough([From, Response, Request, State, Data])
		     end),
    Config;
init_per_testcase(create_pdp_context_overload, Config) ->
    setup_per_testcase(Config),
    jobs:modify_queue(create, [{max_size, 0}]),
    jobs:modify_regulator(rate, create, {rate,create,1}, [{limit,1}]),
    Config;
init_per_testcase(cache_timeout, Config) ->
    case os:getenv("CI_RUN_SLOW_TESTS") of
	"true" ->
	    setup_per_testcase(Config),
	    Config;
	_ ->
	    {skip, "slow tests run only on CI"}
    end;
init_per_testcase(_, Config) ->
    setup_per_testcase(Config),
    Config.

end_per_testcase(_Config) ->
    stop_gtpc_server().

end_per_testcase(path_restart, Config) ->
    meck:unload(gtp_path),
    end_per_testcase(Config),
    Config;
end_per_testcase(TestCase, Config) 
  when TestCase == create_lb_multi_context;
       TestCase == one_lb_node_down->
    ok = meck:unload(ggsn_gn),
    stop_gtpc_servers(?NUM_OF_CLIENTS),
    Config;
end_per_testcase(create_pdp_context_proxy_request_resend, Config) ->
    ok = meck:unload(ggsn_gn),
    end_per_testcase(Config),
    Config;
end_per_testcase(delete_pdp_context_request_timeout, Config) ->
    ok = meck:unload(ggsn_gn),
    end_per_testcase(Config),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == delete_pdp_context_requested_resend;
       TestCase == delete_pdp_context_requested_invalid_teid;
       TestCase == delete_pdp_context_requested_late_response ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 7),
    end_per_testcase(Config),
    Config;
end_per_testcase(request_fast_resend, Config) ->
    ok = meck:unload(ggsn_gn),
    end_per_testcase(Config),
    Config;
end_per_testcase(path_failure_to_ggsn_and_restore, Config) ->
    set_path_timers([{'pd_mon_t', 300},{pd_mon_dur, 7200}]),
    end_per_testcase(Config);
end_per_testcase(simple_pdp_context_request, Config) ->
    meck:unload(ggsn_gn),
    end_per_testcase(Config),
    Config;
end_per_testcase(ggsn_update_pdp_context_request, Config) ->
    meck:unload(ggsn_gn),
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
create_pdp_context_request_missing_ie() ->
    [{doc, "Check that Create Session Request IE validation works"}].
create_pdp_context_request_missing_ie(Config) ->
    create_pdp_context(missing_ie, Config),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_accept_new() ->
    [{doc, "Check the accept_new = false can block new connections"}].
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
    {GtpC2, _, _} = create_pdp_context('2nd', gtp_context_inc_restart_counter(GtpC1)),

    [?match(#{tunnels := 1}, X) || X <- ergw_api:peer(all)],

    delete_pdp_context(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_failure_to_ggsn() ->
    [{doc, "Check that Create PDP Context works and "
      "that a path failure (Echo timeout) terminates the session"}].
path_failure_to_ggsn(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, CtxPid} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    #{proxy_context := Ctx1} = gtp_context:info(CtxPid),
    #context{control_port = CPort} = Ctx1,

    FinalGSN = proplists:get_value(final_gsn, Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, IP, _, _, _, #gtp{type = echo_request}, CbInfo)
			   when IP =:= FinalGSN ->
			     %% simulate a Echo timeout
			     ergw_gtp_c_socket:send_reply(CbInfo, timeout);
			 (GtpPort, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([GtpPort, IP, Port, T3, N3, Msg, CbInfo])
		     end),

    gtp_path:ping(CPort, v1, FinalGSN),

    %% echo timeout should trigger a Delete PDP Context Request to SGSN.
    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    %% wait for session cleanup
    ct:sleep(100),
    delete_pdp_context(not_found, GtpC),

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),
    %% killing the GGSN context
    exit(Server, kill),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    {ok, [RestartPeerIP]} = gtp_path_reg:get_down_peers(),
    gtp_path_reg:remove_down_peer(RestartPeerIP),

    meck_validate(Config),

    ok = meck:delete(ergw_gtp_c_socket, send_request, 7),
    ok.

%%--------------------------------------------------------------------
path_failure_to_ggsn_and_restore() ->
    [{doc, "Check that Create Session Request works and "
      "that a path failure (Echo timeout) terminates the session "
      "and is later restored with a valid echo"}].
path_failure_to_ggsn_and_restore(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_pdp_context(Config),

    % Check that IP is not marked down
    {ok, RestartPeer} = gtp_path_reg:get_down_peers(),
    ?match([], RestartPeer),

    {_Handler, CtxPid} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    #{proxy_context := Ctx1} = gtp_context:info(CtxPid),
    #context{control_port = CPort} = Ctx1,

    FinalGSN = proplists:get_value(final_gsn, Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, IP, _, _, _, #gtp{type = echo_request}, CbInfo)
			   when IP =:= FinalGSN ->
			     %% simulate a Echo timeout
			     ergw_gtp_c_socket:send_reply(CbInfo, timeout);
			 (GtpPort, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([GtpPort, IP, Port, T3, N3, Msg, CbInfo])
		     end),

    gtp_path:ping(CPort, v1, FinalGSN),
    %% echo timeout should trigger a Delete PDP Context Request to SGSN.
    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),
    
    %% wait for session cleanup
    ct:sleep(100),
    delete_pdp_context(not_found, GtpC),

    % Check that IP is marked down
    {ok, [RestartPeerIP]} = gtp_path_reg:get_down_peers(),
    ?match(FinalGSN, RestartPeerIP),

    % confirm that a new session will now fail as the PGW is marked as down
    GtpC0 = gtp_context(Config),
    Req = make_request(create_pdp_context_request, simple, GtpC0),
    NRResp = send_recv_pdu(GtpC0, Req),
    ?match(
       #gtp{ie = #{
		   {cause, 0} :=
		       #cause{value = no_resources_available}
		  }}, NRResp),
    
    ct:sleep(100),
    gtp_path:ping(CPort, v1, FinalGSN),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, IP, _, _, _, #gtp{type = echo_request}, CbInfo)
			   when IP =:= FinalGSN ->
			     %% simulate a Echo success
			     EchoResp = #gtp{version = v1, type = echo_response,
					     seq_no = 0,
					     ie = [#recovery{instance = 0,
                                restart_counter = 3}]},
			     ergw_gtp_c_socket:send_reply(CbInfo, EchoResp);
			 (GtpPort, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([GtpPort, IP, Port, T3, N3, Msg, CbInfo])
             end),
    %% Successful echo, clears down marked IP.
    gtp_path:ping(CPort, v1, FinalGSN),
    ct:sleep(100),
    {ok, Res} = gtp_path_reg:get_down_peers(),
    ?match([], Res),

    %% Check that new session now successfully created
    {GtpC1, _, _} = create_pdp_context(Config),
    ?match(#gtpc{}, GtpC1),

    delete_pdp_context(GtpC1),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    
    ok = meck:delete(ergw_gtp_c_socket, send_request, 7),
    ok.

%%--------------------------------------------------------------------
path_failure_to_sgsn() ->
    [{doc, "Check that Create PDP Context works and "
      "that a path failure (Echo timeout) terminates the session"}].
path_failure_to_sgsn(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, CtxPid} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    #{context := Ctx1} = gtp_context:info(CtxPid),
    #context{control_port = CPort} = Ctx1,

    ClientIP = proplists:get_value(client_ip, Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, IP, _, _, _, #gtp{type = echo_request}, CbInfo)
			   when IP =:= ClientIP ->
			     %% simulate a Echo timeout
			     ergw_gtp_c_socket:send_reply(CbInfo, timeout);
			 (GtpPort, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([GtpPort, IP, Port, T3, N3, Msg, CbInfo])
		     end),

    gtp_path:ping(CPort, v1, ClientIP),

    %% wait for session cleanup
    ct:sleep(100),
    delete_pdp_context(not_found, GtpC),

    [?match(#{tunnels := 0}, X) || X <- ergw_api:peer(all)],

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),

    ok = meck:delete(ergw_gtp_c_socket, send_request, 7),
    ok.

%%--------------------------------------------------------------------
simple_pdp_context_request() ->
    [{doc, "Check simple Create PDP Context, Delete PDP Context sequence"}].
simple_pdp_context_request(Config) ->
    init_seq_no(?MODULE, 16#8000),
    GtpC0 = gtp_context(?MODULE, Config),

    {GtpC1, _, _} = create_pdp_context(GtpC0),
    delete_pdp_context(GtpC1),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    GtpRecMatch = #gtp{type = create_pdp_context_request, _ = '_'},
    P = meck:capture(first, ?HUT, handle_request, ['_', GtpRecMatch, '_', '_', '_'], 2),
    ?match(#gtp{seq_no = SeqNo} when SeqNo >= 16#8000, P),

    V = meck:capture(first, ggsn_gn, handle_request, ['_', GtpRecMatch, '_', '_', '_'], 2),
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

    GtpDelMatch = #gtp{type = delete_pdp_context_request, _ = '_'},
    #gtp{ie = DelIEs} =
	meck:capture(first, ggsn_gn, handle_request, ['_', GtpDelMatch, '_', '_', '_'], 2),
    ?equal(false, maps:is_key({recovery, 0}, DelIEs)),

    ?equal([], outstanding_requests()),
    ok.

%%--------------------------------------------------------------------
simple_pdp_context_request_no_proxy_map() ->
    [{doc, "Check simple Create PDP Context, Delete PDP Context sequence without proxy_map config"}].
simple_pdp_context_request_no_proxy_map(Config) ->
    init_seq_no(?MODULE, 16#8000),
    GtpC0 = gtp_context(?MODULE, Config),

    {GtpC1, _, _} = create_pdp_context(proxy_apn, GtpC0),
    delete_pdp_context(GtpC1),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    GtpRecMatch = #gtp{type = create_pdp_context_request, _ = '_'},
    P = meck:capture(first, ?HUT, handle_request, ['_', GtpRecMatch, '_', '_', '_'], 2),
    ?match(#gtp{seq_no = SeqNo} when SeqNo >= 16#8000, P),

    ?equal([], outstanding_requests()),
    ok.

%%--------------------------------------------------------------------
create_lb_multi_context() ->
    [{doc, "Create multi contexts across the 2 Load Balancers"}].
create_lb_multi_context(Config) ->
    IPGroup = proplists:get_value(ip_group, Config, ipv4),
    NSMap = set_lb_envs(IPGroup),
    init_seq_no(?MODULE, 16#8000),
    %% for 6 clients cumulative nCr for at least 1 hit on both lb = 0.984
    %% for 10 clients it is = 0.999. 1 < No of clients =< 10
    GtpCtxs = make_gtp_contexts(?NUM_OF_CLIENTS, Config, IPGroup),
    Contexts = lists:map(fun(Ctx) -> create_pdp_context(random, Ctx) end, GtpCtxs),
    lists:foreach(fun({Context,_,_}) -> delete_pdp_context(Context) end, Contexts),

    ok = meck:wait(?NUM_OF_CLIENTS, ?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    application:set_env(ergw, node_selection, NSMap),
    meck_validate(Config),
    ok.

% set one peer node as down gtp_path_req and ensure that it is not chosen
%%----------------------------------------------------------------------
one_lb_node_down() ->
    [{doc, "One lb PGW peer node is down"}].
one_lb_node_down(Config) ->
    IPGroup = proplists:get_value(ip_group, Config, ipv4),
    NSMap = set_lb_envs(IPGroup),
    init_seq_no(?MODULE, 16#8000),
    GtpCtxs = make_gtp_contexts(?NUM_OF_CLIENTS, Config, IPGroup),
    % mark one lb node as down
    DownPeerIP = case IPGroup of
		     ipv4 ->
			 ?FINAL_GSN2_IPv4;
		     ipv6 ->
			 ?FINAL_GSN2_IPv6
		 end,
    gtp_path_reg:add_down_peer(DownPeerIP),
    % check down peer set in gtp_path_reg state
    ?match({ok, [DownPeerIP]}, gtp_path_reg:get_down_peers()),

    Contexts = lists:map(fun(Ctx) -> create_pdp_context(random, Ctx) end, GtpCtxs),
    % Scan outgoing pgw peer entries to confirm that dowm peer was not selected
    % for interface irx (single) and proxy-irx (multi)
    PgwFqTeids = [X || {{_,{teid,'gtp-c',{fq_teid, DownPeerIP1,_}}},_} =
			   X <- gtp_context_reg:all(), DownPeerIP == DownPeerIP1],
    ?match(0, length(PgwFqTeids)), %No connection to down peer

    lists:foreach(fun({Context,_,_}) -> delete_pdp_context(Context) end, Contexts),
    ok = meck:wait(?NUM_OF_CLIENTS, ?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    application:set_env(ergw, node_selection, NSMap),
    gtp_path_reg:remove_down_peer(DownPeerIP),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
duplicate_pdp_context_request() ->
    [{doc, "Check the a new incomming request for the same IMSI terminates the first"}].
duplicate_pdp_context_request(Config) ->
    {GtpC1, _, _} = create_pdp_context(Config),

    %% create 2nd PDP context with the same IMSI
    {GtpC2, _, _} = create_pdp_context(Config),

    [?match(#{tunnels := 1}, X) || X <- ergw_api:peer(all)],

    delete_pdp_context(not_found, GtpC1),
    delete_pdp_context(GtpC2),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_resend() ->
    [{doc, "Check that a retransmission of a Create PDP Context Request works"}].
create_pdp_context_request_resend(Config) ->
    {GtpC, Msg, Response} = create_pdp_context(Config),
    ?equal(Response, send_recv_pdu(GtpC, Msg)),
    ?equal([], outstanding_requests()),

    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_proxy_request_resend() ->
    [{doc, "Check that the proxy does not send the Create PDP Context Request multiple times"}].
create_pdp_context_proxy_request_resend(Config) ->
    GtpC = gtp_context(Config),
    Request = make_request(create_pdp_context_request, simple, GtpC),

    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, 2 * 1000, error)),

    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),

    %% killing the proxy PGW context
    gtp_context:terminate_context(Server),

    ?match(1, meck:num_calls(ggsn_gn, handle_request,
			     ['_', #gtp{type = create_pdp_context_request, _ = '_'}, '_', '_', '_'])),
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
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_pdp_context_request_timeout() ->
    [{doc, "Check that a Delete PDP Context Request terminates the "
           "proxy session even when the final GSN fails"}].
delete_pdp_context_request_timeout(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),
    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),

    Request = make_request(delete_pdp_context_request, simple, GtpC),

    %% simulate retransmissions
    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, ?TIMEOUT, error)),
    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, ?TIMEOUT, error)),
    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, ?TIMEOUT, error)),

    %% killing the GGSN context
    exit(Server, kill),

    wait4tunnels(20000),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
error_indication_sgsn2ggsn() ->
    [{doc, "Check the a GTP-U error indication terminates the session"}].
error_indication_sgsn2ggsn(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),

    ergw_test_sx_up:send('sgw-u', make_error_indication_report(GtpC)),

    ct:sleep(100),
    delete_pdp_context(not_found, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
error_indication_ggsn2sgsn() ->
    [{doc, "Check the a GTP-U error indication terminates the session"}].
error_indication_ggsn2sgsn(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, CtxPid} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    true = is_pid(CtxPid),
    #{proxy_context := Ctx} = gtp_context:info(CtxPid),

    ergw_test_sx_up:send('sgw-u', make_error_indication_report(Ctx)),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    ct:sleep(100),
    delete_pdp_context(not_found, GtpC),

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),
    %% killing the GGSN context
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

    GtpC1 = Send(create_pdp_context_request, simple, GtpC0),
    ?equal(timeout, recv_pdu(GtpC1, undefined, 100, fun(Why) -> Why end)),

    GtpC2 = Send(ms_info_change_notification_request, simple, GtpC1),
    ?equal(timeout, recv_pdu(GtpC2, undefined, 100, fun(Why) -> Why end)),

    GtpC3 = Send(ms_info_change_notification_request, without_tei, GtpC2),
    ?equal(timeout, recv_pdu(GtpC3, undefined, 100, fun(Why) -> Why end)),

    ?equal([], outstanding_requests()),

    delete_pdp_context(GtpC3),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(3, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),
    ?match(3, meck:num_calls(ggsn_gn, handle_request, ['_', '_', true, '_', '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
update_pdp_context_request_ra_update() ->
    [{doc, "Check Update PDP Context with Routing Area Update"}].
update_pdp_context_request_ra_update(Config) ->
    {GtpC1, _, _} = create_pdp_context(Config),
    {_Handler, CtxPid} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    #{context := Ctx1} = gtp_context:info(CtxPid),

    {GtpC2, _, _} = update_pdp_context(ra_update, GtpC1),
    #{context := Ctx2} = gtp_context:info(CtxPid),

    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC2),

    %% make sure the SGSN side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the GGSN side control TEID don't change
    ?equal(Ctx1#context.remote_control_teid, Ctx2#context.remote_control_teid),
    ?equal(Ctx1#context.remote_data_teid,    Ctx2#context.remote_data_teid),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
update_pdp_context_request_tei_update() ->
    [{doc, "Check Update PDP Context with TEID update (e.g. SGSN change)"}].
update_pdp_context_request_tei_update(Config) ->
    {GtpC1, _, _} = create_pdp_context(Config),
    {_Handler, CtxPid} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    #{context := Ctx1} = gtp_context:info(CtxPid),

    {_Handler, ProxyCtxPid} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    #{proxy_context := PrxCtx1} = gtp_context:info(ProxyCtxPid),
    #context{control_port = #gtp_port{name = ProxySocket}} = PrxCtx1,
    ProxyRegKey1 = {ProxySocket, {teid, 'gtp-c', PrxCtx1#context.local_control_tei}},
    ?match({gtp_context, ProxyCtxPid}, gtp_context_reg:lookup(ProxyRegKey1)),

    {GtpC2, _, _} = update_pdp_context(tei_update, GtpC1),
    #{context := Ctx2} = gtp_context:info(CtxPid),

    #{proxy_context := PrxCtx2} = gtp_context:info(ProxyCtxPid),
    ProxyRegKey2 = {ProxySocket, {teid, 'gtp-c', PrxCtx2#context.local_control_tei}},
    ?match(undefined, gtp_context_reg:lookup(ProxyRegKey1)),
    ?match({gtp_context, ProxyCtxPid}, gtp_context_reg:lookup(ProxyRegKey2)),

    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC2),

    %% make sure the SGSN side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the GGSN side control TEID DOES change
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
proxy_context_selection() ->
    [{doc, "Check that the proxy context selection works"}].
proxy_context_selection(Config) ->
    ok = meck:new(gtp_proxy_ds, [passthrough]),
    meck:expect(gtp_proxy_ds, map,
		fun(ProxyInfo) ->
			proxy_context_selection_map(ProxyInfo, <<"ams">>)
		end),

    {GtpC, _, _} = create_pdp_context(Config),
    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC),

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

    {GtpC, _, _} = create_pdp_context(Config),
    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC),

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
		fun(_ProxyInfo) -> {error, user_authentication_failed} end),

    {_, _, _} = create_pdp_context(invalid_mapping, Config),
    ?equal([], outstanding_requests()),

    meck:unload(gtp_proxy_ds),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
%% TDB: the test only checks that the API works, it does not verify that
%%      the correct GGSN/PGW or UPF node is actually used
proxy_api_v2() ->
    [{doc, "Check that the proxy API v2 works"}].
proxy_api_v2(Config) ->
    APN = fun(Bin) -> binary:split(Bin, <<".">>, [global, trim_all]) end,
    ok = meck:new(gtp_proxy_ds, [passthrough]),
    meck:expect(gtp_proxy_ds, map,
		fun(PI) ->
			ct:pal("PI: ~p", [PI]),
			Context = <<"ams">>,
			PGW = APN(<<"pgw-1.mnc001.mcc001.gprs">>),
			UPF = APN(<<"upf-1.mnc001.mcc001.gprs">>),
			PI#{imsi   => ?'PROXY-IMSI',
			    msisdn => ?'PROXY-MSISDN',
			    apn    => ?'APN-PROXY',
			    context => Context,
			    gwSelectionAPN  => PGW,
			    upfSelectionAPN => UPF}
		end),

    {GtpC, _, _} = create_pdp_context(Config),
    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC),

    meck:unload(gtp_proxy_ds),

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

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Server)} end),

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

    wait4tunnels(?TIMEOUT),
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

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Server)} end),

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

    ?match([_], outstanding_requests()),
    wait4tunnels(20000),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_pdp_context_requested_invalid_teid() ->
    [{doc, "Check error response of GGSN initiated Delete PDP Context with invalid TEID"}].
delete_pdp_context_requested_invalid_teid(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Server)} end),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),

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
delete_pdp_context_requested_late_response() ->
    [{doc, "Check a answer folling a resend of GGSN initiated Delete PDP Context"}].
delete_pdp_context_requested_late_response(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),

    Self = self(),
    spawn(fun() -> Self ! {req, gtp_context:delete_context(Server)} end),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
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
ggsn_update_pdp_context_request() ->
    [{doc, "Check GGSN initiated Update PDP Context"},
     {timetrap,{seconds,60}}].
ggsn_update_pdp_context_request(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'remote-irx', {imsi, ?'PROXY-IMSI', 5}}),
    true = is_pid(Server),

    Self = self(),
    spawn(fun() -> Self ! {req, gen_server:call(Server, update_context)} end),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = update_pdp_context_request}, Request),
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
    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
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
    GtpPort =
	case ergw_gtp_socket_reg:lookup('proxy-irx') of
	    undefined ->
		ergw_gtp_socket_reg:lookup('irx');
	    Other ->
		Other
	end,
    {GtpC, _, _} = create_pdp_context(Config),
    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    {T0, Q0} = ergw_gtp_c_socket:get_request_q(GtpPort),
    ?match(X when X /= 0, length(T0)),
    ?match(X when X /= 0, length(Q0)),

    ct:sleep({seconds, 120}),

    {T1, Q1} = ergw_gtp_c_socket:get_request_q(GtpPort),
    ?equal(0, length(T1)),
    ?equal(0, length(Q1)),

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

    {GtpC, _, _} = create_pdp_context(Config),

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

    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
sx_upf_reconnect() ->
    [{doc, "Test UPF reconnect behavior"}].
sx_upf_reconnect(Config) ->
    ok = meck:expect(ergw_proxy_lib, create_forward_session,
		     fun(Candidates, Left, Right) ->
			     try
				 meck:passthrough([Candidates, Left, Right])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),

    {GtpCinit, _, _} = create_pdp_context(Config),
    delete_pdp_context(GtpCinit),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    ergw_test_sx_up:restart('sgw-u'),
    ct:pal("R1: ~p", [ergw_sx_node_reg:available()]),

    %% expect the first request to fail
    create_pdp_context(system_failure, Config),
    ct:pal("R2: ~p", [ergw_sx_node_reg:available()]),

    wait_for_all_sx_nodes(),
    ct:pal("R3: ~p", [ergw_sx_node_reg:available()]),

    %% the next should work
    {GtpC2nd, _, _} = create_pdp_context(Config),
    delete_pdp_context(GtpC2nd),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    meck_validate(Config),
    ok = meck:delete(ergw_proxy_lib, create_forward_session, 3),
    ok.

%%--------------------------------------------------------------------
sx_upf_removal() ->
    [{doc, "Test UPF removal mid session"}].
sx_upf_removal(Config) ->
    Cntl = whereis(gtpc_client_server),

    ok = meck:new(ergw_sx_node, [passthrough]),
    %% reduce Sx timeout to speed up test
    ok = meck:expect(ergw_sx_socket, call,
		     fun(Peer, _T1, _N1, Msg, CbInfo) ->
			     meck:passthrough([Peer, 100, 2, Msg, CbInfo])
		     end),

    {GtpC, _, _} = create_pdp_context(Config),

    ergw_test_sx_up:disable('sgw-u'),

    Req = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Req),
    Resp = make_response(Req, simple, GtpC),
    send_pdu(Cntl, GtpC, Resp),

    %% make sure the PGW -> SGW response doesn't bleed through
    ?equal({error,timeout}, recv_pdu(Cntl, undefined, ?TIMEOUT, error)),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
sx_timeout() ->
    [{doc, "Check that a timeout on Sx leads to a proper error response"}].
sx_timeout(Config) ->
    %% reduce Sx timeout to speed up test
    ok = meck:expect(ergw_sx_socket, call,
		     fun(Peer, _T1, _N1, Msg, CbInfo) ->
			     meck:passthrough([Peer, 100, 2, Msg, CbInfo])
		     end),
    ok = meck:expect(ergw_proxy_lib, create_forward_session,
		     fun(Candidates, Left, Right) ->
			     try
				 meck:passthrough([Candidates, Left, Right])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),
    ergw_test_sx_up:disable('sgw-u'),

    create_pdp_context(system_failure, Config),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    ok = meck:delete(ergw_sx_socket, call, 5),
    ok = meck:delete(ergw_proxy_lib, create_forward_session, 3),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

proxy_context_selection_map(ProxyInfo, Context) ->
    case meck:passthrough([ProxyInfo]) of
	{ok, PI} ->
	    {ok, PI#{context => Context}};
	Other ->
	    Other
    end.

% Set Timers for Path management
set_path_timers(SetTimers) ->
    {ok, Timers} = application:get_env(ergw, path_management),
    NewTimers = lists:ukeymerge(1, lists:sort(SetTimers), lists:sort(Timers)),
    application:set_env(ergw, path_management, NewTimers).

% PID registered naming convention is gtp_client_server_x
% client IP range from 2 to 10
% Clients IPv4_address from {127,127,127,128} 10 max
% Clients IPv6_address from {16#fd96, 16#dcd2, 16#efdb, 16#41c3, 0, 0, 0, 16#11} 10 Max
set_up_clients(Max, Config, IPGroup)
  when is_integer(Max), Max > 1, Max =< 10 ->
    set_up_clients(1, Max, Config, IPGroup);
set_up_clients(_Max, Config, IPGroup) ->
    set_up_clients(1, 10, Config, IPGroup).

set_up_clients(Cnt, Max, _Config, _Group) when Cnt > Max ->
    ok;
set_up_clients(Cnt, Max, Config, IPGroup) ->
    Name = list_to_atom("gtpc_client_server" ++ "_" ++ integer_to_list(Cnt)),
    Config1 = inc_client_ip_addr(Cnt, Config, IPGroup),
    setup_per_testcase(Config1, Name, true),
    set_up_clients(Cnt+1, Max, Config, IPGroup).

%Stop Gtpc servers
stop_gtpc_servers(Max)
  when is_integer(Max), Max > 1, Max =< 10 ->
    stop_gtpc_servers(1, Max);
stop_gtpc_servers(_Max) ->
    stop_gtpc_servers(1, 10).

stop_gtpc_servers(Cnt, Max) when Cnt > Max ->
    ok;
stop_gtpc_servers(Cnt, Max) ->
    Name = list_to_atom("gtpc_client_server" ++ "_" ++ integer_to_list(Cnt)),
    stop_gtpc_server(Name),
    stop_gtpc_servers(Cnt+1, Max).

% Make multi gtp contexts range 2 to 10
make_gtp_contexts(Max, Config, IPGroup)
  when is_integer(Max), Max > 1, Max =< 10 ->
    make_gtp_contexts(1, Max, Config, IPGroup, []);
make_gtp_contexts(_Max, Config, IPGroup) ->
    make_gtp_contexts(1, 10, Config, IPGroup, []).

make_gtp_contexts(Cnt, Max, _Config, _IPGRoup, GtpCtxs) when Cnt > Max ->
    lists:reverse(GtpCtxs);
make_gtp_contexts(Cnt, Max, Config, IPGroup, GtpCtxs) ->
    Config1 = inc_client_ip_addr(Cnt, Config, IPGroup),
    GtpCtx = gtp_context(?MODULE, Config1),
    make_gtp_contexts(Cnt+1, Max, Config, IPGroup, [GtpCtx | GtpCtxs]).

% Add 2nd dest PGW
set_lb_envs(IPGroup) ->
    NodeDest = case IPGroup of
		   ipv4 ->
		       {"topon.s5s8.pgw-1.epc.mnc001.mcc001.3gppnetwork.org",
			[?FINAL_GSN2_IPv4], []};
		   ipv6 ->
		       {"topon.s5s8.pgw-1.epc.mnc001.mcc001.3gppnetwork.org",
			[], [?FINAL_GSN2_IPv6]}
	       end,
    NewLBNode = [{"_default.apn.epc.mnc001.mcc001.3gppnetwork.org",
		  {300,64536},
		  [{"x-3gpp-pgw","x-gn"},
		   {"x-3gpp-pgw","x-gp"},
		   {"x-3gpp-pgw","x-s5-gtp"},
		   {"x-3gpp-pgw","x-s8-gtp"}],
		  "topon.s5s8.pgw-1.epc.mnc001.mcc001.3gppnetwork.org"},
		 NodeDest],
    {_, NSMap} = application:get_env(ergw, node_selection),
    NNSMap = add_static_data(NSMap, NewLBNode),
    application:set_env(ergw, node_selection, NNSMap),
    NSMap.

add_static_data(#{default := {static, Nodes}} = NSMap, NewLBNode) ->
    maps:put(default, {static,lists:sort(lists:append(NewLBNode, Nodes))}, NSMap).

inc_client_ip_addr(Cnt, Config, IPGroup) ->
    case IPGroup of
        ipv4 ->
            lists:keyreplace(client_ip, 1, Config,
                             {client_ip, {127,127,127,127+Cnt}});
        ipv6 ->
            lists:keyreplace(client_ip, 1, Config,
                             {client_ip,
			      {16#fd96, 16#dcd2, 16#efdb, 16#41c3, 0, 0, 0, 16#10+Cnt}})
    end.
