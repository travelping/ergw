%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("kernel/include/logger.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_3gpp.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_pgw_test_lib.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-define(TIMEOUT, 2000).
-define(HUT, pgw_s5s8).				%% Handler Under Test

%%%===================================================================
%%% Config
%%%===================================================================

-define(TEST_CONFIG,
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
		 {sockets,
		  [{'cp-socket',
		        [{type, 'gtp-u'},
			 {vrf, cp},
			 {ip, ?MUST_BE_UPDATED},
			 {reuseaddr, true}
			]},
		   {'irx-socket',
		         [{type, 'gtp-c'},
			  {vrf, irx},
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
			      ]},
		   {'pool-B', [{ranges,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
					  {?IPv6PoolStart, ?IPv6PoolEnd, 64},
					  {?IPv6HostPoolStart, ?IPv6HostPoolEnd, 128}]},
			       {'MS-Primary-DNS-Server', {8,8,8,8}},
			       {'MS-Secondary-DNS-Server', {8,8,4,4}},
			       {'MS-Primary-NBNS-Server', {127,0,0,1}},
			       {'MS-Secondary-NBNS-Server', {127,0,0,1}},
			       {'DNS-Server-IPv6-Address',
				[{16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8888},
				 {16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8844}]}
			      ]},
		   {'pool-C', [{ranges,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
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
		  [{gn, [{handler, ?HUT},
			 {sockets, ['irx-socket']},
			 {node_selection, [default]},
			 {aaa, [{'Username',
				 [{default, ['IMSI',   <<"/">>,
					     'IMEI',   <<"/">>,
					     'MSISDN', <<"/">>,
					     'ATOM',   <<"/">>,
					     "TEXT",   <<"/">>,
					     12345,
					     <<"@">>, 'APN']}]}]}
			]},
		   {s5s8, [{handler, ?HUT},
			   {sockets, ['irx-socket']},
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
		       [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
			{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
		       "topon.s5s8.pgw.$ORIGIN"},
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.prox01.$ORIGIN"},
		      {"_default.apn.$ORIGIN", {400,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.prox03.$ORIGIN"},
		      {"async-sx.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.prox01.$ORIGIN"},
		      {"async-sx.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.prox02.$ORIGIN"},

		      %% A/AAAA record alternatives
		      {"topon.s5s8.pgw.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.prox01.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.prox02.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.prox03.$ORIGIN", ?MUST_BE_UPDATED, []}
		     ]
		    }
		   }
		  ]
		 },

		 {sx_socket,
		  [{node, 'ergw'},
		   {name, 'ergw'},
		   {socket, 'cp-socket'},
		   {ip, ?MUST_BE_UPDATED},
		   {reuseaddr, true}]},

		 {apns,
		  [{?'APN-EXAMPLE',
		    [{vrf, sgi},
		     {ip_pools, ['pool-A', 'pool-B']},
		     {'Idle-Timeout', 21600000}]}, % Idle timeout 6 hours
		   {[<<"exa">>, <<"mple">>, <<"net">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]},
		   {[<<"APN1">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']},
		     {'Idle-Timeout', 28800000}]}, % Idle timeout 8 hours
		   {[<<"APN2">>, <<"mnc001">>, <<"mcc001">>, <<"gprs">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]},
		   {[<<"v6only">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']},
		     {bearer_type, 'IPv6'},
		     {'Idle-Timeout', infinity}]},
		   {[<<"v4only">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']},
		     {bearer_type, 'IPv4'},
		     {'Idle-Timeout', 21600000}]},
		   {[<<"prefV6">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']},
		     {prefered_bearer_type, 'IPv6'}]},
		   {[<<"prefV4">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']},
		     {prefered_bearer_type, 'IPv4'}]},
		   {[<<"async-sx">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]}
		   %% {'_', [{vrf, wildcard}]}
		  ]},

		 {charging,
		  [{default,
		    [{offline,
		      [{triggers,
			[{'cgi-sai-change',            'container'},
			 {'ecgi-change',               'container'},
			 {'max-cond-change',           'cdr'},
			 {'ms-time-zone-change',       'cdr'},
			 {'qos-change',                'container'},
			 {'rai-change',                'container'},
			 {'rat-change',                'cdr'},
			 {'sgsn-sgw-change',           'cdr'},
			 {'sgsn-sgw-plmn-id-change',   'cdr'},
			 {'tai-change',                'container'},
			 {'tariff-switch-change',      'container'},
			 {'user-location-info-change', 'container'}
			]}
		      ]},
		     {rulebase,
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
		       {<<"r-0002">>,
			#{'Rating-Group' => [4000],
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
		       {<<"m2m0001">>, [<<"r-0001">>]},
		       {<<"m2m0002">>, [<<"r-0002">>]}
		      ]}
		     ]}
		  ]},

		 {nodes,
		  [{default,
		    [{vrfs,
		      [{cp, [{features, ['CP-Function']}]},
		       {irx, [{features, ['Access']}]},
		       {sgi, [{features, ['SGi-LAN']}]}
		      ]},
		     {ip_pools, ['pool-A']}]
		   },
		   {"topon.sx.prox01.$ORIGIN", [connect]},
		   {"topon.sx.prox03.$ORIGIN", [connect, {ip_pools, ['pool-B', 'pool-C']}]}
		  ]
		 }
		]},

	 {ergw_aaa,
	  [
	   {handlers,
	    [{ergw_aaa_static,
	      [{'NAS-Identifier',          <<"NAS-Identifier">>},
	       {'Node-Id',                 <<"PGW-001">>},
	       {'Charging-Rule-Base-Name', <<"m2m0001">>},
	       {'Acct-Interim-Interval',  600}
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
		  'Initial-Gx-Redirect' =>
		      #{'Result-Code' => 2001,
			'Charging-Rule-Install' =>
			    [#{'Charging-Rule-Definition' =>
				   [#{
				      'Charging-Rule-Name' => <<"m2m">>,
				      'Rating-Group' => [3000],
				      'Flow-Information' =>
					  [#{'Flow-Description' => [<<"permit out ip from any to assigned">>],
					     'Flow-Direction'   => [1]    %% DownLink
					    },
					   #{'Flow-Description' => [<<"permit out ip from any to assigned">>],
					     'Flow-Direction'   => [2]    %% UpLink
					    }],
				      'Metering-Method'  => [1],
				      'Precedence' => [100],
				      'Offline'  => [1],
				      'Redirect-Information' =>
					  [#{'Redirect-Support' =>
						 [1],   %% ENABLED
					     'Redirect-Address-Type' =>
						 [2],   %% URL
					     'Redirect-Server-Address' =>
						 ["http://www.heise.de/"]
					    }]
				     }]
			      }]
		       },
		  'Initial-Gx-TDF-App' =>
		      #{'Result-Code' => 2001,
			'Charging-Rule-Install' =>
			    [#{'Charging-Rule-Definition' =>
				   [#{
				      'Charging-Rule-Name' => <<"m2m">>,
				      'Rating-Group' => [3000],
				      'TDF-Application-Identifier' => [<<"Gold">>],
				      'Metering-Method'  => [1],
				      'Precedence' => [100],
				      'Offline'  => [1]
				     }]
			      }]
		       },
		  'Update-Gx' => #{'Result-Code' => 2001},
		  'Final-Gx' => #{'Result-Code' => 2001},

		  'Initial-Gx-Fail-1' =>
		      #{'Result-Code' => 2001,
			'Charging-Rule-Install' =>
			    [#{'Charging-Rule-Base-Name' =>
				   [<<"m2m0001">>, <<"unknown-rulebase">>]}]
		       },
		  'Initial-Gx-Fail-2' =>
		      #{'Result-Code' => 2001,
			'Charging-Rule-Install' =>
			    [#{'Charging-Rule-Name' => [<<"r-0001">>, <<"unknown-rule">>]}]
		       },

		  'Initial-OCS' =>
		      #{'Result-Code' => 2001,
			'Multiple-Services-Credit-Control' =>
			    [#{'Envelope-Reporting' => [0],
			       'Granted-Service-Unit' =>
				   [#{'CC-Time' => [3600],
				      'CC-Total-Octets' => [102400]}],
			       'Rating-Group' => [3000],
			       'Validity-Time' => [3600],
			       'Result-Code' => [2001],
			       'Time-Quota-Threshold' => [60],
			       'Volume-Quota-Threshold' => [10240]
			      }]
		       },
		  'Update-OCS-Fail' =>
		      #{'Result-Code' => 3001},
		  'Update-OCS' =>
		      #{'Result-Code' => 2001,
			'Multiple-Services-Credit-Control' =>
			    [#{'Envelope-Reporting' => [0],
			       'Granted-Service-Unit' =>
				   [#{'CC-Time' => [3600],
				      'CC-Total-Octets' => [102400]}],
			       'Rating-Group' => [3000],
			       'Validity-Time' => [3600],
			       'Result-Code' => [2001],
			       'Time-Quota-Threshold' => [60],
			       'Volume-Quota-Threshold' => [10240]
			      }]
		       },
		  'Update-OCS-GxGy' =>
		      #{'Result-Code' => 2001,
			'Multiple-Services-Credit-Control' =>
			    [#{'Envelope-Reporting' => [0],
			       'Granted-Service-Unit' =>
				   [#{'CC-Time' => [3600],
				      'CC-Total-Octets' => [102400]}],
			       'Rating-Group' => [3000],
			       'Validity-Time' => [3600],
			       'Result-Code' => [2001],
			       'Time-Quota-Threshold' => [60],
			       'Volume-Quota-Threshold' => [10240]
			      },
			     #{'Envelope-Reporting' => [0],
			       'Granted-Service-Unit' =>
				   [#{'CC-Time' => [3600],
				      'CC-Total-Octets' => [102400]}],
			       'Rating-Group' => [4000],
			       'Validity-Time' => [3600],
			       'Result-Code' => [2001],
			       'Time-Quota-Threshold' => [60],
			       'Volume-Quota-Threshold' => [10240]
			      }]
		       },
		  'Initial-OCS-VT' =>
		      #{'Result-Code' => 2001,
			'Multiple-Services-Credit-Control' =>
			    [#{'Envelope-Reporting' => [0],
			       'Granted-Service-Unit' =>
				   [#{'CC-Time' => [3600],
				      'CC-Total-Octets' => [102400]}],
			       'Rating-Group' => [3000],
			       'Validity-Time' => [2],
			       'Result-Code' => [2001],
			       'Time-Quota-Threshold' => [60],
			       'Volume-Quota-Threshold' => [10240]
			      }]
		       },
		  'Update-OCS-VT' =>
		      #{'Result-Code' => 2001,
			'Multiple-Services-Credit-Control' =>
			    [#{'Envelope-Reporting' => [0],
			       'Granted-Service-Unit' =>
				   [#{'CC-Time' => [3600],
				      'CC-Total-Octets' => [102400]}],
			       'Rating-Group' => [3000],
			       'Validity-Time' => [2],
			       'Result-Code' => [2001],
			       'Time-Quota-Threshold' => [60],
			       'Volume-Quota-Threshold' => [10240]
			      }]
		       },
		  'Initial-OCS-TTC' =>
		      #{'Result-Code' => 2001,
			'Multiple-Services-Credit-Control' =>
			    [#{'Envelope-Reporting' => [0],
			       'Granted-Service-Unit' =>
				   [#{'Tariff-Time-Change' => [{{2019, 8, 26}, {14, 14, 0}}],
				      'CC-Time' => [3600],
				      'CC-Total-Octets' => [102400]}],
			       'Rating-Group' => [3000],
			       'Tariff-Time-Change' => [{{2019, 8, 26}, {14, 14, 0}}],
			       'Result-Code' => [2001],
			       'Time-Quota-Threshold' => [60],
			       'Volume-Quota-Threshold' => [10240]
			      }]
		       },
		  'Update-OCS-TTC' =>
		      #{'Result-Code' => 2001,
			'Multiple-Services-Credit-Control' =>
			    [#{'Envelope-Reporting' => [0],
			       'Granted-Service-Unit' =>
				   [#{'Tariff-Time-Change' => [{{2019, 8, 26}, {14, 14, 0}}],
				      'CC-Time' => [3600],
				      'CC-Total-Octets' => [102400]}],
			       'Rating-Group' => [3000],
			       'Result-Code' => [2001],
			       'Time-Quota-Threshold' => [60],
			       'Volume-Quota-Threshold' => [10240]
			      }]
		       },
		  'Final-OCS' => #{'Result-Code' => 2001}
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
			     %%{{gy, 'CCR-Update'},    [{'Default', [{answer, 'Update-If-Down'}]}]},
			     {{gy, 'CCR-Terminate'}, []}
			    ]}
	      ]}
	    ]}
	  ]}
	]).

-define(CONFIG_UPDATE,
	[{[sockets, 'cp-socket', ip], localhost},
	 {[sockets, 'irx-socket', ip], test_gsn},
	 {[sx_socket, ip], localhost},
	 {[node_selection, {default, 2}, 2, "topon.s5s8.pgw.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox01.$ORIGIN"],
	  {fun node_sel_update/2, pgw_u01_sx}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox02.$ORIGIN"],
	  {fun node_sel_update/2, sgw_u_sx}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox03.$ORIGIN"],
	  {fun node_sel_update/2, pgw_u02_sx}}
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

init_per_group(sx_fail, Config) ->
    [{upf, false} | Config];
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
    ok = lib_end_per_suite(Config);
end_per_group(sx_fail, _Config) ->
    ok.

common() ->
    [invalid_gtp_pdu,
     invalid_gtp_version,
     apn_lookup,
     create_session_request_missing_ie,
     create_session_request_aaa_reject,
     create_session_request_gx_fail,
     create_session_request_gy_fail,
     create_session_request_rf_fail,
     create_session_request_invalid_apn,
     create_session_request_pool_exhausted,
     create_session_request_dotted_apn,
     create_session_request_accept_new,
     path_restart, path_restart_recovery, path_restart_multi,
     simple_session_request,
     duplicate_session_request,
     duplicate_session_slow,
     error_indication,
     pdn_session_request_bearer_types,
     ipv6_bearer_request,
     static_ipv6_bearer_request,
     static_ipv6_host_bearer_request,
     %% request_fast_resend, TODO, FIXME
     create_session_request_resend,
     delete_session_request_resend,
     delete_session_fq_teid,
     delete_session_invalid_fq_teid,
     modify_bearer_request_ra_update,
     modify_bearer_request_rat_update,
     modify_bearer_request_tei_update,
     modify_bearer_command,
     modify_bearer_command_resend,
     modify_bearer_command_timeout,
     modify_bearer_command_congestion,
     change_notification_request_with_tei,
     change_notification_request_without_tei,
     change_notification_request_invalid_imsi,
     suspend_notification_request,
     resume_notification_request,
     requests_invalid_teid,
     commands_invalid_teid,
     delete_bearer_request,
     delete_bearer_requests_multi,
     delete_bearer_request_resend,
     unsupported_request,
     interop_sgsn_to_sgw,
     interop_sgsn_to_sgw_const_tei,
     interop_sgw_to_sgsn,
     create_session_overload,
     session_options,
     session_accounting,
     sx_cp_to_up_forward,
     sx_up_to_cp_forward,
     sx_upf_restart,
     sx_timeout,
     sx_ondemand,
     gy_validity_timer,
     simple_aaa,
     simple_ofcs,
     secondary_rat_usage_data_report,
     simple_ocs,
     aa_pool_select,
     aa_pool_select_fail,
     tariff_time_change,
     gy_ccr_asr_overlap,
     volume_threshold,
     redirect_info,
     gx_asr,
     gx_rar,
     gy_asr,
     gy_async_stop,
     gx_invalid_charging_rulebase,
     gx_invalid_charging_rule,
     gx_rar_gy_interaction,
	 tdf_app_id,
	 gtp_idle_timeout].

sx_fail() ->
    [sx_connect_fail].

groups() ->
    [{ipv4, [], common()},
     {ipv6, [], common()},
     {sx_fail, [{ipv4, [], sx_fail()},
		{ipv6, [], sx_fail()}]
     }
    ].

all() ->
    [{group, ipv4},
     {group, ipv6},
     {group, sx_fail}].

%%%===================================================================
%%% Tests
%%%===================================================================

setup_per_testcase(Config) ->
    setup_per_testcase(Config, true).

setup_per_testcase(Config, ClearSxHist) ->
    ct:pal("Sockets: ~p", [ergw_gtp_socket_reg:all()]),
    ct:pal("Logger: ~p", [logger:get_handler_config()]),
    ergw_test_sx_up:reset('pgw-u01'),
    meck_reset(Config),
    start_gtpc_server(Config),
    reconnect_all_sx_nodes(),
    ClearSxHist andalso ergw_test_sx_up:history('pgw-u01', true),
    ok.

init_per_testcase(create_session_request_aaa_reject, Config) ->
    setup_per_testcase(Config),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(_, _, authenticate, _) ->
			     {fail, #{}, []};
			(Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),
    Config;
init_per_testcase(create_session_request_gx_fail, Config) ->
    setup_per_testcase(Config),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(_, _, {gx, 'CCR-Initial'}, _) ->
			     {fail, #{}, []};
			(Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),
    Config;
init_per_testcase(create_session_request_gy_fail, Config) ->
    setup_per_testcase(Config),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(_, _, {gy, 'CCR-Initial'}, _) ->
			     {fail, #{}, []};
			(Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),
    Config;
init_per_testcase(create_session_request_rf_fail, Config) ->
    setup_per_testcase(Config),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(_, _, start, _) ->
			     {fail, #{}, []};
			(Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),
    Config;
init_per_testcase(create_session_request_pool_exhausted, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(ergw_ip_pool, [passthrough, no_link]),
    Config;
init_per_testcase(path_restart, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(gtp_path, [passthrough, no_link]),
    Config;
init_per_testcase(duplicate_session_slow, Config) ->
    setup_per_testcase(Config),
    ok = meck:expect(?HUT, handle_event,
		     fun({call, _} = Type, terminate_context = Content, run = State, Data) ->
			     %% simulate a 500ms delay in terminating the context
			     ct:sleep(500),
			     meck:passthrough([Type, Content, State, Data]);
			(Type, Content, State, Data) ->
			     meck:passthrough([Type, Content, State, Data])
		     end),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == delete_bearer_request_resend;
       TestCase == modify_bearer_command_timeout ->
    setup_per_testcase(Config),
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
init_per_testcase(delete_bearer_requests_multi, Config) ->
    setup_per_testcase(Config),
    Config;
init_per_testcase(request_fast_resend, Config) ->
    setup_per_testcase(Config),
    ok = meck:expect(?HUT, handle_request,
		     fun(Request, Msg, Resent, State, Data) ->
			     if Resent -> ok;
				true   -> ct:sleep(1000)
			     end,
			     meck:passthrough([Request, Msg, Resent, State, Data])
		     end),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == interop_sgsn_to_sgw;
       TestCase == interop_sgsn_to_sgw_const_tei;
       TestCase == interop_sgw_to_sgsn ->
    setup_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    Config;
init_per_testcase(create_session_overload, Config) ->
    setup_per_testcase(Config),
    jobs:modify_queue(create, [{max_size, 0}]),
    jobs:modify_regulator(rate, create, {rate,create,1}, [{limit,1}]),
    Config;
init_per_testcase(sx_cp_to_up_forward, Config) ->
    setup_per_testcase(Config, false),
    Config;
init_per_testcase(sx_connect_fail, Config) ->
    meck_reset(Config),
    start_gtpc_server(Config),
    Config;
init_per_testcase(gy_validity_timer, Config) ->
    setup_per_testcase(Config),
    set_online_charging(true),
    load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS-VT'},
			    {{gy, 'CCR-Update'},  'Update-OCS-VT'}]),
    Config;
init_per_testcase(gy_async_stop, Config) ->
    setup_per_testcase(Config),
    set_online_charging(true),
    load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS-VT'},
			    {{gy, 'CCR-Update'},  'Update-OCS-Fail'}]),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == simple_ocs;
       TestCase == gy_ccr_asr_overlap;
       TestCase == volume_threshold ->
    setup_per_testcase(Config),
    set_online_charging(true),
    load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS'},
			    {{gy, 'CCR-Update'},  'Update-OCS'}]),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == tariff_time_change ->
    setup_per_testcase(Config),
    set_online_charging(true),
    load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS-TTC'},
			    {{gy, 'CCR-Update'},  'Update-OCS-TTC'}]),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == gx_rar_gy_interaction ->
    setup_per_testcase(Config),
    set_online_charging(true),
    load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS'},
			    {{gy, 'CCR-Update'},  'Update-OCS-GxGy'}]),
    Config;
init_per_testcase(redirect_info, Config) ->
    setup_per_testcase(Config),
    load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-Redirect'}]),
    Config;
%% init_per_testcase(TestCase, Config)
%%   when TestCase == gx_rar ->
%%     setup_per_testcase(Config),
%%     load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS'},
%%			    {{gy, 'CCR-Update'},  'Update-OCS'}]),
%%     Config;
init_per_testcase(gx_invalid_charging_rulebase, Config) ->
    setup_per_testcase(Config),
    load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-Fail-1'}]),
    Config;
init_per_testcase(gx_invalid_charging_rule, Config) ->
    setup_per_testcase(Config),
    load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-Fail-2'}]),
    Config;
init_per_testcase(tdf_app_id, Config) ->
    setup_per_testcase(Config),
    load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-TDF-App'}]),
    Config;
%% gtp 'Idle-Timeout' reduced to 300ms for test purposes
init_per_testcase(gtp_idle_timeout, Config) ->
    set_apn_key('Idle-Timeout', 300),
    setup_per_testcase(Config),
    Config;
init_per_testcase(_, Config) ->
    setup_per_testcase(Config),
    Config.

end_per_testcase(Config) ->
    stop_gtpc_server(),

    PoolId = [<<"pool-A">>, ipv4, "10.180.0.1"],
    ?match_metric(prometheus_gauge, ergw_ip_pool_free, PoolId, 65534),

    AppsCfg = proplists:get_value(aaa_cfg, Config),
    ok = application:set_env(ergw_aaa, apps, AppsCfg),
    set_online_charging(false),
    ok.

end_per_testcase(delete_bearer_requests_multi, Config) ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 7),
    end_per_testcase(Config),
    Config;

end_per_testcase(TestCase, Config)
  when TestCase == create_session_request_aaa_reject;
       TestCase == create_session_request_gx_fail;
       TestCase == create_session_request_gy_fail;
       TestCase == create_session_request_rf_fail;
       TestCase == gy_ccr_asr_overlap;
       TestCase == simple_aaa;
       TestCase == simple_ofcs;
       TestCase == tariff_time_change ->
    ok = meck:delete(ergw_aaa_session, start_link, 2),
    ok = meck:delete(ergw_aaa_session, invoke, 4),
    end_per_testcase(Config),
    Config;
end_per_testcase(create_session_request_pool_exhausted, Config) ->
    meck:unload(ergw_ip_pool),
    end_per_testcase(Config),
    Config;
end_per_testcase(path_restart, Config) ->
    meck:unload(gtp_path),
    end_per_testcase(Config),
    Config;
end_per_testcase(duplicate_session_slow, Config) ->
    ok = meck:delete(?HUT, handle_event, 4),
    end_per_testcase(Config),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == delete_bearer_request_resend;
       TestCase == modify_bearer_command_timeout ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 7),
    end_per_testcase(Config),
    Config;
end_per_testcase(request_fast_resend, Config) ->
    ok = meck:delete(?HUT, handle_request, 5),
    end_per_testcase(Config),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == interop_sgsn_to_sgw;
       TestCase == interop_sgsn_to_sgw_const_tei;
       TestCase == interop_sgw_to_sgsn ->
    ok = meck:unload(ggsn_gn),
    end_per_testcase(Config),
    Config;
end_per_testcase(create_session_overload, Config) ->
    jobs:modify_queue(create, [{max_size, 10}]),
    jobs:modify_regulator(rate, create, {rate,create,1}, [{limit,100}]),
    end_per_testcase(Config),
    Config;
%% gtp 'Idle-Timeout' reset to default 28800000ms ~8 hrs
end_per_testcase(gtp_idle_timeout, Config) ->
    set_apn_key('Idle-Timeout', 28800000),
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
    MfrId = ['irx-socket', rx, 'malformed-requests'],
    MfrCnt = get_metric(prometheus_counter, gtp_c_socket_errors_total, MfrId, 0),

    S = make_gtp_socket(Config),
    gen_udp:send(S, TestGSN, ?GTP2c_PORT, <<"TESTDATA">>),

    ?equal({error,timeout}, gen_udp:recv(S, 4096, ?TIMEOUT)),
    ?match_metric(prometheus_counter, gtp_c_socket_errors_total, MfrId, MfrCnt + 1),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
invalid_gtp_version() ->
    [{doc, "Test that an invalid version is silently ignored"
      " and that the GTP socket is not crashing"}].
invalid_gtp_version(Config) ->
    TestGSN = proplists:get_value(test_gsn, Config),

    S = make_gtp_socket(Config),

    %% broken GTP' echo request, observed in the "wild"
    BrokenPrime = <<16#2a, 16#01, 16#00, 16#02, 16#00, 16#00, 16#0e, 16#00>>,
    gen_udp:send(S, TestGSN, ?GTP2c_PORT, BrokenPrime),
    ?equal({error,timeout}, gen_udp:recv(S, 4096, ?TIMEOUT)),

    Prime =
	#gtp{version = prime_v1, type = echo_request,
	     seq_no = 0, ie = [#recovery{instance = 0,restart_counter = 0}]},
    gen_udp:send(S, TestGSN, ?GTP2c_PORT, gtp_packet:encode(Prime)),
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
    PoolId = [<<"pool-A">>, ipv4, "10.180.0.1"],

    ?match_metric(prometheus_gauge, ergw_ip_pool_free, PoolId, 65534),
    ?match_metric(prometheus_gauge, ergw_ip_pool_used, PoolId, 0),

    create_session(gy_fail, Config),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    ?match_metric(prometheus_gauge, ergw_ip_pool_free, PoolId, 65534),
    ?match_metric(prometheus_gauge, ergw_ip_pool_used, PoolId, 0),

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
create_session_request_pool_exhausted() ->
    [{doc, "Dynamic IP pool exhausted"}].
create_session_request_pool_exhausted(Config) ->
    ok = meck:expect(ergw_gsn_lib, allocate_ips,
		     fun(AllocInfo, APNOpts, SOpts, DualAddressBearerFlag, Context) ->
			     try
				 meck:passthrough([AllocInfo, APNOpts, SOpts, DualAddressBearerFlag, Context])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),
    ok = meck:expect(ergw_ip_pool, get,
		     fun(_Pool, _TEI, ipv6, _PrefixLen) ->
			     {error, empty};
			(Pool, TEI, Request, PrefixLen) ->
			     meck:passthrough([Pool, TEI, Request, PrefixLen])
		     end),
    create_session(pool_exhausted, Config),
    %% {GtpC1, _, _} = create_session({partial, ipv6}, Config),
    %% delete_session(GtpC1),

    ok = meck:expect(ergw_ip_pool, get,
		     fun(_Pool, _TEI, ipv4, _PrefixLen) ->
			     {error, empty};
			(Pool, TEI, Request, PrefixLen) ->
			     meck:passthrough([Pool, TEI, Request, PrefixLen])
		     end),
    create_session(pool_exhausted, Config),
    %% {GtpC2, _, _} = create_session({partial, ipv4}, Config),
    %% delete_session(GtpC2),

    ok = meck:expect(ergw_ip_pool, get,
		     fun(_Pool, _TEI, _Type, _PrefixLen) ->
			     {error, empty}
		     end),
    create_session(pool_exhausted, Config),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_dotted_apn() ->
    [{doc, "Check dotted APN return on Create Session Request"}].
create_session_request_dotted_apn(Config) ->
    {GtpC, _, _} = create_session(dotted_apn, Config),
    {_, _Msg, _Response} = delete_session(GtpC),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
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
    [{doc, "Check that Create Session Request works and "
           "that a Path Restart terminates the session"}].
path_restart_recovery(Config) ->
    {GtpC1, _, _} = create_session(Config),

    %% create 2nd session with new restart_counter (simulate SGW restart)
    {GtpC2, _, _} = create_session(gtp_context_inc_restart_counter(GtpC1)),

    ct:pal("ALL: ~p", [ergw_api:peer(all)]),
    [?match(#{tunnels := 1}, X) || X <- ergw_api:peer(all)],

    delete_session(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_restart_multi() ->
    [{doc, "Check that a Path Restart terminates multiple session"}].
path_restart_multi(Config) ->
    {GtpC0, _, _} = create_session(Config),
    {GtpC1, _, _} = create_session(random, GtpC0),
    {GtpC2, _, _} = create_session(random, GtpC1),
    {GtpC3, _, _} = create_session(random, GtpC2),
    {GtpC4, _, _} = create_session(random, GtpC3),

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
simple_session_request() ->
    [{doc, "Check simple Create Session, Delete Session sequence"}].
simple_session_request(Config) ->
    PoolId = [<<"pool-A">>, ipv4, "10.180.0.1"],

    ?match_metric(prometheus_gauge, ergw_ip_pool_free, PoolId, 65534),
    ?match_metric(prometheus_gauge, ergw_ip_pool_used, PoolId, 0),

    {GtpC, _, _} = create_session(ipv4, Config),

    ?match_metric(prometheus_gauge, ergw_ip_pool_free, PoolId, 65533),
    ?match_metric(prometheus_gauge, ergw_ip_pool_used, PoolId, 1),

    delete_session(GtpC),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    ?match_metric(prometheus_gauge, ergw_ip_pool_free, PoolId, 65534),
    ?match_metric(prometheus_gauge, ergw_ip_pool_used, PoolId, 0),

    [SER|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) ->false
		end, ergw_test_sx_up:history('pgw-u01')),

    ?match_map(#{create_pdr => '_', create_far => '_',  create_urr => '_'}, SER#pfcp.ie),
    #{create_pdr := PDRs0,
      create_far := FARs0,
      create_urr := URR
     } = SER#pfcp.ie,

    PDRs = lists:sort(PDRs0),
    FARs = lists:sort(FARs0),

    ?LOG(debug, "PDRs: ~s", [pfcp_packet:pretty_print(PDRs)]),
    ?LOG(debug, "FARs: ~s", [pfcp_packet:pretty_print(FARs)]),
    ?LOG(debug, "URR: ~s", [pfcp_packet:pretty_print([URR])]),

    ?match(
       [#create_pdr{
	   group =
	       #{pdr_id := #pdr_id{id = _},
		 precedence := #precedence{precedence = 100},
		 pdi :=
		     #pdi{
			group =
			    #{network_instance :=
				  #network_instance{instance = <<3, "sgi">>},
			      sdf_filter :=
				  #sdf_filter{
				     flow_description =
					 <<"permit out ip from any to assigned">>},
			      source_interface :=
				  #source_interface{interface='SGi-LAN'},
			      ue_ip_address := #ue_ip_address{type = dst}
			     }
		       },
		 far_id := #far_id{id = _},
		 urr_id := #urr_id{id = _}
		}
	  },
	#create_pdr{
	   group =
	       #{
		 pdr_id := #pdr_id{id = _},
		 precedence := #precedence{precedence = 100},
		 pdi :=
		     #pdi{
			group =
			    #{network_instance :=
				  #network_instance{instance = <<3, "irx">>},
			      sdf_filter :=
				  #sdf_filter{
				     flow_description =
					 <<"permit out ip from any to assigned">>},
			      source_interface :=
				  #source_interface{interface='Access'},
			      ue_ip_address := #ue_ip_address{type = src}
			     }
		       },
		 far_id := #far_id{id = _},
		 urr_id := #urr_id{id = _}
		}
	  }], PDRs),

    ?match(
       [#create_far{
	   group =
	       #{far_id := #far_id{id = _},
		 apply_action :=
		     #apply_action{forw = 1},
		 forwarding_parameters :=
		     #forwarding_parameters{
			group =
			    #{destination_interface :=
				  #destination_interface{interface='Access'},
			      network_instance :=
				  #network_instance{instance = <<3, "irx">>}
			     }
		       }
		}
	  },
	#create_far{
	   group =
	       #{far_id := #far_id{id = _},
		 apply_action :=
		     #apply_action{forw = 1},
		 forwarding_parameters :=
		     #forwarding_parameters{
			group =
			    #{destination_interface :=
				  #destination_interface{interface='SGi-LAN'},
			      network_instance :=
				  #network_instance{instance = <<3, "sgi">>}
			     }
		       }
		}
	  }], FARs),

    ?match(
       #create_urr{
	  group =
	      #{urr_id := #urr_id{id = _},
		measurement_method :=
		    #measurement_method{volum = 1}
		%% measurement_period :=
		%%     #measurement_period{period = 600},
		%% reporting_triggers :=
		%%     #reporting_triggers{periodic_reporting=1}
	       }
	 }, URR),

    meck_validate(Config),
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

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
duplicate_session_slow() ->
    [{doc, "Check the a new incomming request for the same IMSI terminates the first "
           "and deals with a slow shutdown of the first one correctly"}].
duplicate_session_slow(Config) ->
    {GtpC1, _, _} = create_session(Config),

    %% create 2nd session with the same IMSI
    {GtpC2, _, _} = create_session(GtpC1),

    delete_session(not_found, GtpC1),
    delete_session(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
error_indication() ->
    [{doc, "Check the a GTP-U error indication terminates the session"}].
error_indication(Config) ->
    {GtpC, _, _} = create_session(Config),

    ergw_test_sx_up:send('pgw-u01', make_error_indication_report(GtpC)),

    ct:sleep(100),
    delete_session(not_found, GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
pdn_session_request_bearer_types() ->
    [{doc, "Create different IP bearers against APNs with restrictions/preferences"}].
pdn_session_request_bearer_types(Config) ->
    ok = meck:expect(ergw_gsn_lib, allocate_ips,
		     fun(AllocInfo, APNOpts, SOpts, DualAddressBearerFlag, Context) ->
			     try
				 meck:passthrough([AllocInfo, APNOpts, SOpts, DualAddressBearerFlag, Context])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),

    {GtpC1, _, _} = create_session({ipv4, false, default}, Config),
    delete_session(GtpC1),

    {GtpC2, _, _} = create_session({ipv6, false, default}, Config),
    delete_session(GtpC2),

    {GtpC3, _, _} = create_session({ipv4v6, true, default}, Config),
    delete_session(GtpC3),

    {GtpC4, _, _} = create_session({ipv4v6, true, v4only}, Config),
    delete_session(GtpC4),

    {GtpC5, _, _} = create_session({ipv4v6, true, v6only}, Config),
    delete_session(GtpC5),

    {GtpC6, _, _} = create_session({ipv4,   false, prefV4}, Config),
    delete_session(GtpC6),

    {GtpC7, _, _} = create_session({ipv4,   false, prefV6}, Config),
    delete_session(GtpC7),

    {GtpC8, _, _} = create_session({ipv6,   false, prefV4}, Config),
    delete_session(GtpC8),

    {GtpC9, _, _} = create_session({ipv6,   false, prefV6}, Config),
    delete_session(GtpC9),

    {GtpC10, _, _} = create_session({ipv4v6, false, v4only}, Config),
    delete_session(GtpC10),

    {GtpC11, _, _} = create_session({ipv4v6, false, v6only}, Config),
    delete_session(GtpC11),

    {GtpC12, _, _} = create_session({ipv4v6, false, prefV4}, Config),
    delete_session(GtpC12),

    {GtpC13, _, _} = create_session({ipv4v6, false, prefV6}, Config),
    delete_session(GtpC13),

    create_session({ipv4, false, v6only}, Config),
    create_session({ipv6, false, v4only}, Config),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
ipv6_bearer_request() ->
    [{doc, "Check Create Session, Delete Session sequence for IPv6 bearer"}].
ipv6_bearer_request(Config) ->
    {GtpC, _, _} = create_session(ipv6, Config),
    delete_session(GtpC),

    %% check that the wildcard PDR and FAR are present
    [SER0|_] = lists:filter(
		 fun(#pfcp{type = session_establishment_request}) -> true;
		    (_) -> false
		 end, ergw_test_sx_up:history('pgw-u01')),
    SER = pfcp_packet:to_map(SER0),
    #{create_far := FAR0,
      create_pdr := PDR0} = SER#pfcp.ie,
    FAR = lists:filter(
	    fun(#create_far{
		   group =
		       #{forwarding_parameters :=
			     #forwarding_parameters{
				group =
				    #{destination_interface :=
					  #destination_interface{interface = 'CP-function'}
				     }
			       }
			 }}) -> true;
	       (_) -> false
	    end, FAR0),
    PDR = lists:filter(
	    fun(#create_pdr{
		   group =
		       #{pdi :=
			     #pdi{
				group =
				    #{source_interface :=
					  #source_interface{interface = 'Access'},
				      sdf_filter :=
					  #sdf_filter{
					     flow_description =
						 <<"permit out 58 from ff00::/8 to assigned">>}
				     }
			       }
			}}) -> true;
	       (_) -> false
	    end, PDR0),
    ?match([_], PDR),
    ?match([_], FAR),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
static_ipv6_bearer_request() ->
    [{doc, "Check Create Session, Delete Session sequence for "
      "IPv6 bearer with static IP"}].
static_ipv6_bearer_request(Config) ->
    {GtpC, _, _} = create_session(static_ipv6, Config),
    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
static_ipv6_host_bearer_request() ->
    [{doc, "Check Create Session, Delete Session sequence for "
      "IPv6 bearer with non-standard /128 static IP"}].
static_ipv6_host_bearer_request(Config) ->
    {GtpC, _, _} = create_session(static_host_ipv6, Config),
    delete_session(GtpC),

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
		   validate_response(Type, SubType, Response, GtpC)
	   end,

    GtpC0 = gtp_context(Config),

    GtpC1 = Send(create_session_request, simple, GtpC0),
    ?equal(timeout, recv_pdu(GtpC1, undefined, 100, fun(Why) -> Why end)),

    GtpC2 = Send(change_notification_request, simple, GtpC1),
    ?equal(timeout, recv_pdu(GtpC2, undefined, 100, fun(Why) -> Why end)),

    GtpC3 = Send(change_notification_request, without_tei, GtpC2),
    ?equal(timeout, recv_pdu(GtpC3, undefined, 100, fun(Why) -> Why end)),

    delete_session(GtpC3),

    ?match(3, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),

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
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),
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
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_session_fq_teid() ->
    [{doc, "Check that a Delete Session Request with Sender F-TEID works"}].
delete_session_fq_teid(Config) ->
    {GtpC, _, _} = create_session(Config),
    delete_session(fq_teid, GtpC),

    ?equal([], outstanding_requests()),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_session_invalid_fq_teid() ->
    [{doc, "Check that a Delete Session Request with the wrong Sender F-TEID is rejected"}].
delete_session_invalid_fq_teid(Config) ->
    {GtpC, _, _} = create_session(Config),
    delete_session(invalid_peer_teid, GtpC),
    delete_session(invalid_peer_ip, GtpC),

    ?equal([], outstanding_requests()),

    delete_session(GtpC),

    ?equal([], outstanding_requests()),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_request_ra_update() ->
    [{doc, "Check Modify Bearer Routing Area Update"}].
modify_bearer_request_ra_update(Config) ->
    UpdateCount = 4,

    {GtpC1, _, _} = create_session(Config),

    GtpC2 =
	lists:foldl(
	  fun(_, GtpCtxIn) ->
		  {GtpCtxOut, _, _} = modify_bearer(ra_update, GtpCtxIn),
		  ?equal([], outstanding_requests()),
		  ct:sleep(1000),
		  GtpCtxOut
	  end, GtpC1, lists:seq(1, UpdateCount)),

    delete_session(GtpC2),

    ContainerClosePredicate =
	meck:is(fun(#{gy_event := container_closure}) -> true;
		   (_) -> false
		end),
    ?match(UpdateCount, meck:num_calls(ergw_aaa_session, invoke,
				       ['_', '_', {rf, 'Update'}, ContainerClosePredicate])),
    ?match(1, meck:num_calls(ergw_aaa_session, invoke,
			     ['_', '_', {rf, 'Terminate'}, '_'])),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_request_rat_update() ->
    [{doc, "Check Modify Bearer Routing Area Update and RAT change"}].
modify_bearer_request_rat_update(Config) ->
    UpdateCount = 4,

    {GtpC1, _, _} = create_session(Config),

    GtpC2 =
	lists:foldl(
	  fun(_, GtpCtxIn) ->
		  {GtpCtxOut, _, _} = modify_bearer(ra_update, GtpCtxIn),
		  ?equal([], outstanding_requests()),
		  ct:sleep(1000),
		  GtpCtxOut
	  end, GtpC1, lists:seq(1, UpdateCount)),

    {GtpC3, _, _} = modify_bearer(ra_update, GtpC2#gtpc{rat_type = 5}),
    ?equal([], outstanding_requests()),
    ct:sleep(1000),

    delete_session(GtpC3),

    ContainerClosePredicate =
	meck:is(fun(#{gy_event := container_closure}) -> true;
		   (_) -> false
		end),
    ?match(UpdateCount, meck:num_calls(ergw_aaa_session, invoke,
				       ['_', '_', {rf, 'Update'}, ContainerClosePredicate])),
    CDRClosePredicate =
	meck:is(fun(#{gy_event := cdr_closure}) -> true;
		   (_) -> false
		end),
    ?match(1, meck:num_calls(ergw_aaa_session, invoke,
			     ['_', '_', {rf, 'Update'}, CDRClosePredicate])),
    ?match(1, meck:num_calls(ergw_aaa_session, invoke,
			     ['_', '_', {rf, 'Terminate'}, '_'])),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_request_tei_update() ->
    [{doc, "Check Modify Bearer with TEID update (e.g. SGW change)"}].
modify_bearer_request_tei_update(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer(tei_update, GtpC1#gtpc{local_ip = {1,1,1,1}}),
    ct:sleep(1000),
    delete_session(GtpC2),

    [SMR0|_] = lists:filter(
		 fun(#pfcp{type = session_modification_request}) -> true;
		    (_) -> false
		 end, ergw_test_sx_up:history('pgw-u01')),
    SMR = pfcp_packet:to_map(SMR0),
    #{update_far :=
	  #update_far{
	     group =
		 #{far_id := _,
		   update_forwarding_parameters :=
		       #update_forwarding_parameters{group = UFP}}}} = SMR#pfcp.ie,
    ?match(#sxsmreq_flags{sndem = 1}, maps:get(sxsmreq_flags, UFP, undefined)),

    #gtpc{local_data_tei = NewDataTEI} = GtpC2,
    ?match(#outer_header_creation{teid = NewDataTEI},
	   maps:get(outer_header_creation, UFP, undefined)),

    CDRClosePred =
	meck:is(fun(#{gy_event := cdr_closure}) -> true;
		   (_) -> false
		end),
    ?match(1, meck:num_calls(ergw_aaa_session, invoke,
			     ['_', '_', {rf, 'Update'}, CDRClosePred])),

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
modify_bearer_command_resend() ->
    [{doc, "Check Modify Bearer Command"}].
modify_bearer_command_resend(Config) ->
    %% a resend of a Modify Bearer Command should not
    %% trigger a second Update Bearer Request

    {GtpC1, _, _} = create_session(Config),
    {GtpC2, Req0} = modify_bearer_command(simple, GtpC1),

    Req1 = recv_pdu(GtpC2, Req0#gtp.seq_no, ?TIMEOUT, ok),
    validate_response(modify_bearer_command, simple, Req1, GtpC2),

    %% resend Modify Bearer Command...
    send_pdu(GtpC2, Req0),
    %% ... should not trigger a second request
    ?equal(timeout, recv_pdu(GtpC2, undefined, 100, fun(Why) -> Why end)),

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
    delete_session(GtpC2),

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
    {GtpC6, _, _} = delete_session(invalid_teid, GtpC5),
    delete_session(GtpC6),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
commands_invalid_teid() ->
    [{doc, "Check invalid TEID's for a number of command types"}].
commands_invalid_teid(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = modify_bearer_command(invalid_teid, GtpC1),
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

    {_Handler, Server} = gtp_context_reg:lookup({'irx-socket', {imsi, ?'IMSI', 5}}),
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
delete_bearer_requests_multi() ->
    [{doc, "Check ergw_api deletes multiple contexts"}].
delete_bearer_requests_multi(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC0, _, _} = create_session(Config),
    {GtpC1, _, _} = create_session(random, GtpC0),

    Ref = make_ref(),
    Self = self(),
    spawn(fun() -> Self ! {req, Ref, ergw_api:delete_contexts(2)} end),

    Request0 = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request0),
    Response0 = make_response(Request0, simple, GtpC0),
    send_pdu(Cntl, GtpC0, Response0),

    Request1 = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request1),
    Response1 = make_response(Request1, simple, GtpC1),
    send_pdu(Cntl, GtpC1, Response1),

    receive
	{req, Ref, ok} ->
	    ok;
	{req, Ref, Other} ->
	    ct:fail({receive_other, Other})
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

    {_Handler, Server} = gtp_context_reg:lookup({'irx-socket', {imsi, ?'IMSI', 5}}),
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
interop_sgsn_to_sgw() ->
    [{doc, "Check 3GPP T 23.401, Annex D, SGSN to SGW handover"}].
interop_sgsn_to_sgw(Config) ->
    ClientIP = proplists:get_value(client_ip, Config),
    CtxMetricV1 = ['irx-socket', inet:ntoa(ClientIP), v1],
    CtxMetricV2 = ['irx-socket', inet:ntoa(ClientIP), v2],

    {GtpC1, _, _} = ergw_ggsn_test_lib:create_pdp_context(Config),
    ?match_metric(prometheus_gauge, gtp_path_contexts_total, CtxMetricV1, 1),
    {GtpC2, _, _} = modify_bearer(tei_update, GtpC1),
    ?match_metric(prometheus_gauge, gtp_path_contexts_total, CtxMetricV1, 0),
    ?match_metric(prometheus_gauge, gtp_path_contexts_total, CtxMetricV2, 1),
    delete_session(GtpC2),

    [SMR0|_] = lists:filter(
		 fun(#pfcp{type = session_modification_request}) -> true;
		    (_) -> false
		 end, ergw_test_sx_up:history('pgw-u01')),
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
    true = meck:validate(ggsn_gn),

    ?match_metric(prometheus_gauge, gtp_path_contexts_total, CtxMetricV1, 0),
    ?match_metric(prometheus_gauge, gtp_path_contexts_total, CtxMetricV2, 0),
    ok.

%%--------------------------------------------------------------------
interop_sgsn_to_sgw_const_tei() ->
    [{doc, "Check 3GPP T 23.401, Annex D, SGSN to SGW handover without changing SGW IP or TEI"}].
interop_sgsn_to_sgw_const_tei(Config) ->
    {GtpC1, _, _} = ergw_ggsn_test_lib:create_pdp_context(Config),
    {GtpC2, _, _} = modify_bearer(sgw_change, GtpC1),
    delete_session(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    true = meck:validate(ggsn_gn),
    ok.

%%--------------------------------------------------------------------
interop_sgw_to_sgsn() ->
    [{doc, "Check 3GPP T 23.401, Annex D, SGW to SGSN handover"}].
interop_sgw_to_sgsn(Config) ->
    ClientIP = proplists:get_value(client_ip, Config),
    CtxMetricV1 = ['irx-socket', inet:ntoa(ClientIP), v1],
    CtxMetricV2 = ['irx-socket', inet:ntoa(ClientIP), v2],

    {GtpC1, _, _} = create_session(Config),
    ?match_metric(prometheus_gauge, gtp_path_contexts_total, CtxMetricV2, 1),
    {GtpC2, _, _} = ergw_ggsn_test_lib:update_pdp_context(tei_update, GtpC1),
    ?match_metric(prometheus_gauge, gtp_path_contexts_total, CtxMetricV1, 1),
    ?match_metric(prometheus_gauge, gtp_path_contexts_total, CtxMetricV2, 0),
    ergw_ggsn_test_lib:delete_pdp_context(GtpC2),

    [SMR0|_] = lists:filter(
		 fun(#pfcp{type = session_modification_request}) -> true;
		    (_) -> false
		 end, ergw_test_sx_up:history('pgw-u01')),
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
    true = meck:validate(ggsn_gn),

    ?match_metric(prometheus_gauge, gtp_path_contexts_total, CtxMetricV1, 0),
    ?match_metric(prometheus_gauge, gtp_path_contexts_total, CtxMetricV2, 0),
    ok.

%%--------------------------------------------------------------------
create_session_overload() ->
    [{doc, "Check that the overload protection works"}].
create_session_overload(Config) ->
    create_session(overload, Config),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
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
		   '3GPP-IMEISV' => ?IMEISV,
		   '3GPP-GGSN-MCC-MNC' => <<"00101">>,
		   '3GPP-NSAPI' => 5,
		   %% TODO: check '3GPP-GPRS-Negotiated-QoS-Profile' => '_',
		   '3GPP-IMSI-MCC-MNC' => <<"11111">>,
		   '3GPP-PDP-Type' => 'IPv4v6',
		   '3GPP-MSISDN' => ?MSISDN,
		   '3GPP-RAT-Type' => 1,
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
		   'Framed-Pool' => <<"pool-A">>,
		   'Framed-IPv6-Pool' => <<"pool-A">>,

		   'Charging-Rule-Base-Name' => <<"m2m0001">>,

		   'Accounting-Start' => '_',
		   'Session-Start' => '_'
		  },
    ?match_map(Expected, Opts),

    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
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
    {GtpC, _, _} = create_session(Config),

    [#{'Process' := Pid}|_] = ergw_api:tunnel(all),
    #{context := Context, pfcp:= PCtx} = gtp_context:info(Pid),

    %% make sure we handle that the Sx node is not returning any accounting
    ergw_test_sx_up:accounting('pgw-u01', off),

    SessionOpts1 = ergw_test_lib:query_usage_report(Context, PCtx),
    ?equal(false, maps:is_key('InPackets', SessionOpts1)),
    ?equal(false, maps:is_key('InOctets', SessionOpts1)),

    %% enable accouting again....
    ergw_test_sx_up:accounting('pgw-u01', on),

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

%%--------------------------------------------------------------------
sx_cp_to_up_forward() ->
    [{doc, "Test Sx{a,b,c} CP to UP forwarding"}].
sx_cp_to_up_forward(Config) ->
    {GtpC, _, _} = create_session(Config),

    #gtpc{remote_data_tei = DataTEI} = GtpC,

    SxIP = ergw_inet:ip2bin(proplists:get_value(pgw_u01_sx, Config)),
    LocalIP = ergw_inet:ip2bin(proplists:get_value(localhost, Config)),

    InnerGTP = gtp_packet:encode(
		 #gtp{version = v1, type = g_pdu, tei = DataTEI, ie = <<0,0,0,0,0,0,0>>}),
    InnerIP = ergw_inet:make_udp(SxIP, LocalIP, ?GTP1u_PORT, ?GTP1u_PORT, InnerGTP),
    ergw_test_sx_up:send('pgw-u01', InnerIP),

    ct:sleep(500),
    delete_session(GtpC),

    %% check that the CP to UP PDR and FAR are present
    [SER0|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) -> false
		end, ergw_test_sx_up:history('pgw-u01')),
    SER = pfcp_packet:to_map(SER0),
    #{create_far := FAR,
      create_pdr := PDR} = SER#pfcp.ie,
    ?match(#create_far{
	      group =
		  #{forwarding_parameters :=
			#forwarding_parameters{
			   group =
			       #{network_instance :=
				     #network_instance{instance = <<3, "irx">>},
				 destination_interface :=
				     #destination_interface{interface = 'Access'}}},
		    apply_action := #apply_action{forw = 1}}}, FAR),
    ?match(#create_pdr{
	      group =
		  #{pdi :=
			#pdi{
			   group =
			       #{source_interface :=
				     #source_interface{interface = 'CP-function'},
				 network_instance :=
				     #network_instance{instance = <<2, "cp">>}}},
		    outer_header_removal :=
			#outer_header_removal{}
		    }}, PDR),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(1, meck:num_calls(?HUT, handle_pdu, ['_', #gtp{type = g_pdu, _ = '_'}, '_', '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
-define('ICMPv6', 58).

%-define('IPv6 All Nodes LL',   <<255,2,0,0,0,0,0,0,0,0,0,0,0,0,0,1>>).
-define('IPv6 All Routers LL', <<255,2,0,0,0,0,0,0,0,0,0,0,0,0,0,2>>).
-define('ICMPv6 Router Solicitation',  133).
%-define('ICMPv6 Router Advertisement', 134).

%-define(NULL_INTERFACE_ID, {0,0,0,0,0,0,0,0}).
%-define('Our LL IP', <<254,128,0,0,0,0,0,0,0,0,0,0,0,0,0,2>>).

%-define('RA Prefix Information', 3).
%-define('RDNSS', 25).

sx_up_to_cp_forward() ->
    [{doc, "Test Sx{a,b,c} UP to CP forwarding"}].
sx_up_to_cp_forward(Config) ->
    %% use a IPv6 session Router Solitation for the test...

    {GtpC, _, _} = create_session(ipv6, Config),

    #gtpc{remote_data_tei = DataTEI} = GtpC,

    SxIP = ergw_inet:ip2bin(proplists:get_value(pgw_u01_sx, Config)),
    LocalIP = ergw_inet:ip2bin(proplists:get_value(localhost, Config)),

    Code = 0,
    CSum = 0,
    Pad = <<1,2,3,4,5,6,7,8>>,
    PayLoad = <<?'ICMPv6 Router Solicitation':8, Code:8, CSum:16, Pad/binary>>,

    TC = 0,
    FlowLabel = 0,
    Length = byte_size(PayLoad),
    HopLimit = 255,
    SrcAddr = <<1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16>>,
    DstAddr = ?'IPv6 All Routers LL',

    PDU = <<6:4, TC:8, FlowLabel:20, Length:16, ?ICMPv6:8,
	    HopLimit:8, SrcAddr:16/bytes, DstAddr:16/bytes,
	    PayLoad/binary>>,

    InnerGTP = gtp_packet:encode(
		 #gtp{version = v1, type = g_pdu, tei = DataTEI, ie = PDU}),
    InnerIP = ergw_inet:make_udp(SxIP, LocalIP, ?GTP1u_PORT, ?GTP1u_PORT, InnerGTP),
    ergw_test_sx_up:send('pgw-u01', InnerIP),

    ct:sleep(500),
    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(1, meck:num_calls(?HUT, handle_pdu, ['_', #gtp{type = g_pdu, _ = '_'}, '_', '_'])),

    UDP = lists:filter(
	    fun({udp, _, _, ?GTP1u_PORT, _}) -> true;
	       (_) -> false
	    end, ergw_test_sx_up:history('pgw-u01')),

    ?match([{_, _, _, _, <<_/binary>>}|_], UDP),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------

sx_upf_restart() ->
    [{doc, "Test UPF restart behavior"}].
sx_upf_restart(Config) ->
    ok = meck:expect(ergw_gsn_lib, create_sgi_session,
		     fun(PCtx, NodeCaps, SessionOpts, Ctx) ->
			     try
				 meck:passthrough([PCtx, NodeCaps, SessionOpts, Ctx])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),

    {GtpCinit, _, _} = create_session(Config),
    delete_session(GtpCinit),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    ergw_test_sx_up:restart('pgw-u01'),
    ct:pal("R1: ~p", [ergw_sx_node_reg:available()]),

    %% expect the first request to fail
    create_session(system_failure, Config),
    ct:pal("R2: ~p", [ergw_sx_node_reg:available()]),

    wait_for_all_sx_nodes(),
    ct:pal("R3: ~p", [ergw_sx_node_reg:available()]),

    %% the next should work
    {GtpC2nd, _, _} = create_session(Config),
    delete_session(GtpC2nd),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    %% check that a IPv6 session Router Solitation after UPF restart works...

    {GtpC, _, _} = create_session(ipv6, Config),

    #gtpc{remote_data_tei = DataTEI} = GtpC,

    SxIP = ergw_inet:ip2bin(proplists:get_value(pgw_u01_sx, Config)),
    LocalIP = ergw_inet:ip2bin(proplists:get_value(localhost, Config)),

    Code = 0,
    CSum = 0,
    Pad = <<1,2,3,4,5,6,7,8>>,
    PayLoad = <<?'ICMPv6 Router Solicitation':8, Code:8, CSum:16, Pad/binary>>,

    TC = 0,
    FlowLabel = 0,
    Length = byte_size(PayLoad),
    HopLimit = 255,
    SrcAddr = <<1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16>>,
    DstAddr = ?'IPv6 All Routers LL',

    PDU = <<6:4, TC:8, FlowLabel:20, Length:16, ?ICMPv6:8,
	    HopLimit:8, SrcAddr:16/bytes, DstAddr:16/bytes,
	    PayLoad/binary>>,

    InnerGTP = gtp_packet:encode(
		 #gtp{version = v1, type = g_pdu, tei = DataTEI, ie = PDU}),
    InnerIP = ergw_inet:make_udp(SxIP, LocalIP, ?GTP1u_PORT, ?GTP1u_PORT, InnerGTP),
    ergw_test_sx_up:send('pgw-u01', InnerIP),

    ct:sleep(500),
    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(1, meck:num_calls(?HUT, handle_pdu, ['_', #gtp{type = g_pdu, _ = '_'}, '_', '_'])),

    UDP = lists:filter(
	    fun({udp, _, _, ?GTP1u_PORT, _}) -> true;
	       (_) -> false
	    end, ergw_test_sx_up:history('pgw-u01')),

    ?match([{_, _, _, _, <<_/binary>>}|_], UDP),

    meck_validate(Config),
    ok = meck:delete(ergw_gsn_lib, create_sgi_session, 4),
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
    ok = meck:expect(ergw_gsn_lib, create_sgi_session,
		     fun(PCtx, NodeCaps, SessionOpts, Ctx) ->
			     try
				 meck:passthrough([PCtx, NodeCaps, SessionOpts, Ctx])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),
    ergw_test_sx_up:disable('pgw-u01'),

    create_session(system_failure, Config),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    ok = meck:delete(ergw_sx_socket, call, 5),
    ok = meck:delete(ergw_gsn_lib, create_sgi_session, 4),
    ok.

%%--------------------------------------------------------------------
sx_connect_fail() ->
    [{doc, "Check that a unreachable UPF leads to a proper error response"}].
sx_connect_fail(Config) ->
    ok = meck:new(ergw_sx_node, [passthrough]),
    ok = meck:expect(ergw_sx_node,select_sx_node,
		     fun(Candidates, Context) ->
			     try
				 meck:passthrough([Candidates, Context])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),

    %% reduce Sx timeout to speed up test
    ok = meck:expect(ergw_sx_socket, call,
		     fun(Peer, _T1, _N1, Msg, CbInfo) ->
			     meck:passthrough([Peer, 100, 2, Msg, CbInfo])
		     end),
    ok = meck:expect(ergw_gsn_lib, create_sgi_session,
		     fun(PCtx, NodeCaps, SessionOpts, Ctx) ->
			     try
				 meck:passthrough([PCtx, NodeCaps, SessionOpts, Ctx])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),

    Self = self(),
    SxNodes = supervisor:which_children(ergw_sx_node_sup),
    %%?match([_], SxNodes),
    ct:pal("SxNodes: ~p", [SxNodes]),
    Expect =
	[begin
	     Ref = make_ref(),
	     ergw_sx_node:test_cmd(Pid, reconnect),
	     ergw_sx_node:notify_up(Pid, {Self, Ref}),
	     Ref
	 end || {_, Pid, _, _} <- SxNodes, is_pid(Pid)],
    Result =
	[receive {Ref, Notify} -> Notify after 2000 -> timeout end || Ref <- Expect],
    [?equal(dead, R) || R <- Result],

    create_session(overload , Config),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    true = meck:validate(ergw_sx_node),

    ok = meck:delete(ergw_sx_socket, call, 5),
    ok = meck:delete(ergw_gsn_lib, create_sgi_session, 4),
    ok.

%%--------------------------------------------------------------------
sx_ondemand() ->
    [{doc, "Connect to Sx Node on demand"}].
sx_ondemand(Config) ->
    SxNodeAvail = maps:size(ergw_sx_node_reg:available()),

    {GtpC, _, _} = create_session(async_sx, Config),
    delete_session(GtpC),

    ?equal(SxNodeAvail + 1, maps:size(ergw_sx_node_reg:available())),
    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT).

%%--------------------------------------------------------------------

gy_validity_timer() ->
    [{doc, "Check Validity-Timer attached to MSCC"}].
gy_validity_timer(Config) ->
    {GtpC, _, _} = create_session(Config),
    ct:sleep({seconds, 10}),
    delete_session(GtpC),

    ?match(X when X >= 3 andalso X < 10,
		  meck:num_calls(?HUT, handle_event, [info, {pfcp_timer, '_'}, '_', '_'])),

    CCRU = lists:filter(
	     fun({_, {ergw_aaa_session, invoke, [_, S, {gy,'CCR-Update'}, _]}, _}) ->
		     ?match(
			#{used_credits :=
			      [{3000,
				#{'Reporting-Reason' :=
				      [?'DIAMETER_3GPP_CHARGING_REPORTING-REASON_VALIDITY_TIME']}}]}, S),
		     true;
		(_) -> false
	     end, meck:history(ergw_aaa_session)),
    ?match(Y when Y >= 3 andalso Y < 10, length(CCRU)),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
simple_aaa() ->
    [{doc, "Check simple session with RADIOS/DIAMETER over (S)Gi"}].
simple_aaa(Config) ->
    Interim = rand:uniform(1800) + 1800,
    AAAReply = #{'Acct-Interim-Interval' => Interim},

    ok = meck:expect(ergw_aaa_session, invoke,
		     fun (Session, SessionOpts, Procedure = authenticate, Opts) ->
			     {_, SIn, EvIn} =
				 meck:passthrough([Session, SessionOpts, Procedure, Opts]),
			     {SOut, EvOut} =
				 ergw_aaa_radius:to_session(authenticate, {SIn, EvIn}, AAAReply),
			     {ok, SOut, EvOut};
			 (Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),

    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx-socket', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),
    {ok, PCtx} = gtp_context:test_cmd(Server, pfcp_ctx),

    [SER|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) ->false
		end, ergw_test_sx_up:history('pgw-u01')),

    URR = lists:sort(maps:get(create_urr, SER#pfcp.ie)),

    ?match(
       [%% offline charging URR
	#create_urr{
	   group =
	       #{urr_id := #urr_id{id = _},
		 measurement_method :=
		     #measurement_method{volum = 1},
		 reporting_triggers := #reporting_triggers{}
		}
	  },
	%% AAA (RADIUS/DIAMETER) URR
	#create_urr{
	   group =
	       #{urr_id := #urr_id{id = _},
		 measurement_method :=
		     #measurement_method{volum = 1, durat = 1},
		 measurement_period :=
		     #measurement_period{period = Interim},
		 reporting_triggers :=
		     #reporting_triggers{periodic_reporting = 1}
		}
	  }], URR),

    MatchSpec = ets:fun2ms(fun({Id, {monitor, 'IP-CAN', _}}) -> Id end),
    Report =
	[#usage_report_trigger{perio = 1},
	 #volume_measurement{total = 5, uplink = 2, downlink = 3},
	 #tp_packet_measurement{total = 12, uplink = 5, downlink = 7}],
    ergw_test_sx_up:usage_report('pgw-u01', PCtx, MatchSpec, Report),

    ct:sleep(100),
    delete_session(GtpC),

    H = meck:history(ergw_aaa_session),
    SInv =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke, [_, _, Procedure, _]}, _})
		when Procedure =:= start; Procedure =:= interim; Procedure =:= stop ->
		  true;
	     (_) ->
		  false
	  end, H),
    ?match(X when X == 3, length(SInv)),

    [Start, SInterim, Stop] =
	lists:map(fun({_, {_, _, [_, SOpts, _, _]}, _}) -> SOpts end, SInv),

    ?equal(false, maps:is_key('Acct-Session-Time', Start)),
    ?equal(false, maps:is_key('InOctets', Start)),
    ?equal(false, maps:is_key('OutOctets', Start)),
    ?equal(false, maps:is_key('InPackets', Start)),
    ?equal(false, maps:is_key('OutPackets', Start)),

    ?match_map(
       #{'Acct-Session-Time' => '_',
	 'InOctets' => '_',  'OutOctets' => '_',
	 'InPackets' => '_', 'OutPackets' => '_'}, SInterim),
    ?match_map(
       #{'Acct-Session-Time' => '_',
	 'InOctets' => '_',  'OutOctets' => '_',
	 'InPackets' => '_', 'OutPackets' => '_'}, Stop),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
simple_ofcs() ->
    [{doc, "Check simple session with DIAMETER Rf"}].
simple_ofcs(Config) ->
    Interim = rand:uniform(1800) + 1800,
    AAAReply = #{'Acct-Interim-Interval' => [Interim]},

    ok = meck:expect(ergw_aaa_session, invoke,
		     fun (Session, SessionOpts, {rf, 'Initial'} = Procedure, Opts) ->
			     {_, SIn, EvIn} =
				 meck:passthrough([Session, SessionOpts, Procedure, Opts]),
			     {SOut, EvOut} =
				 ergw_aaa_rf:to_session({rf, 'ACA'}, {SIn, EvIn}, AAAReply),
			     {ok, SOut, EvOut};
			 (Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),

    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx-socket', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),
    {ok, PCtx} = gtp_context:test_cmd(Server, pfcp_ctx),

    [SER|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) ->false
		end, ergw_test_sx_up:history('pgw-u01')),

    URR = maps:get(create_urr, SER#pfcp.ie),
    ?match(
       %% offline charging URR
       #create_urr{
	  group =
	      #{urr_id := #urr_id{id = _},
		measurement_method :=
		    #measurement_method{volum = 1},
		measurement_period :=
		    #measurement_period{period = Interim},
		reporting_triggers :=
		    #reporting_triggers{periodic_reporting = 1}
	       }
	 }, URR),

    MatchSpec = ets:fun2ms(fun({Id, {'offline', _}}) -> Id end),
    Report =
	[#usage_report_trigger{perio = 1},
	 #volume_measurement{total = 5, uplink = 2, downlink = 3},
	 #tp_packet_measurement{total = 12, uplink = 5, downlink = 7}],
    ergw_test_sx_up:usage_report('pgw-u01', PCtx, MatchSpec, Report),

    ct:sleep(100),
    delete_session(GtpC),
    ct:sleep(10),

    H = meck:history(ergw_aaa_session),
    SInv =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke, [_, _, {rf, _}, _]}, _}) ->
		  true;
	     (_) ->
		  false
	  end, H),
    ?match(X when X == 3, length(SInv)),

    [Start, SInterim, Stop] =
	lists:map(fun({_, {_, _, [_, SOpts, _, _]}, _}) -> SOpts end, SInv),

    ?equal(false, maps:is_key('service_data', Start)),

    ?match_map(
       #{service_data =>
	     [#{'Accounting-Input-Octets' => ['_'],
		'Accounting-Output-Octets' => ['_'],
		'Change-Condition' => [4]
	       }]}, SInterim),

    ?match_map(
       #{service_data =>
	     [#{'Accounting-Input-Octets' => ['_'],
		'Accounting-Output-Octets' => ['_'],
		'Change-Condition' => [0]}
	     ]}, Stop),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
secondary_rat_usage_data_report() ->
    [{doc, "Secondary RAT Usage Data Report in DIAMETER Rf"}].
secondary_rat_usage_data_report(Config) ->
    {GtpC1, _, _} = create_session(Config),
    ct:sleep(100),

    {GtpC2, _, _} = modify_bearer(secondary_rat_usage_data_report, GtpC1),
    ct:sleep(100),

    delete_session(secondary_rat_usage_data_report, GtpC2),
    ct:sleep(10),

    H = meck:history(ergw_aaa_session),
    SInv =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke, [_, _, {rf, _}, _]}, _}) ->
		  true;
	     (_) ->
		  false
	  end, H),
    ?match(X when X == 5, length(SInv)),

    [Start, SecRat1, _Interim, SecRat2, _Stop] =
	lists:map(fun({_, {_, _, [_, SOpts, _, _]}, _}) -> SOpts end, SInv),

    ?equal(false, maps:is_key('RAN-Secondary-RAT-Usage-Report', Start)),

    SecRatExpected =
	#{'RAN-Secondary-RAT-Usage-Report' =>
	      [#{'3GPP-Charging-Id' => ['_'],
		 'Accounting-Input-Octets' => ['_'],
		 'Accounting-Output-Octets' => ['_'],
		 'RAN-End-Timestamp' => ['_'],
		 'RAN-Start-Timestamp' => ['_'],
		 'Secondary-RAT-Type' => ['_']
		},
	       #{'3GPP-Charging-Id' => ['_'],
		 'Accounting-Input-Octets' => ['_'],
		 'Accounting-Output-Octets' => ['_'],
		 'RAN-End-Timestamp' => ['_'],
		 'RAN-Start-Timestamp' => ['_'],
		 'Secondary-RAT-Type' => ['_']
		},
	       #{'3GPP-Charging-Id' => ['_'],
		 'Accounting-Input-Octets' => ['_'],
		 'Accounting-Output-Octets' => ['_'],
		 'RAN-End-Timestamp' => ['_'],
		 'RAN-Start-Timestamp' => ['_'],
		 'Secondary-RAT-Type' => ['_']
		}]},
    ?match_map(SecRatExpected, SecRat1),
    ?match_map(SecRatExpected, SecRat2),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------

simple_ocs() ->
    [{doc, "Test Gy a simple interaction"}].
simple_ocs(Config) ->
    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx-socket', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),
    {ok, PCtx} = gtp_context:test_cmd(Server, pfcp_ctx),

    [SER|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) ->false
		end, ergw_test_sx_up:history('pgw-u01')),

    URR = lists:sort(maps:get(create_urr, SER#pfcp.ie)),
    ?match(
       [%% offline charging URR
	#create_urr{
	   group =
	       #{urr_id := #urr_id{id = _},
		 measurement_method :=
		     #measurement_method{volum = 1},
		 reporting_triggers := #reporting_triggers{}
		}
	  },
	%% online charging URR
	#create_urr{
	   group =
	       #{urr_id := #urr_id{id = _},
		 measurement_method :=
		     #measurement_method{volum = 1, durat = 1},
		 reporting_triggers :=
		     #reporting_triggers{
			time_quota = 1,   time_threshold = 1,
			volume_quota = 1, volume_threshold = 1},
		 time_quota :=
		     #time_quota{quota = 3600},
		 time_threshold :=
		     #time_threshold{threshold = 3540},
		 volume_quota :=
		     #volume_quota{total = 102400},
		 volume_threshold :=
		     #volume_threshold{total = 92160}
		}
	  }], URR),

    MatchSpec = ets:fun2ms(fun({Id, {'online', _}}) -> Id end),
    Report =
	[#usage_report_trigger{volqu = 1},
	 #volume_measurement{total = 5, uplink = 2, downlink = 3},
	 #tp_packet_measurement{total = 12, uplink = 5, downlink = 7}],
    ergw_test_sx_up:usage_report('pgw-u01', PCtx, MatchSpec, Report),

    ct:sleep(100),
    delete_session(GtpC),

    H = meck:history(ergw_aaa_session),
    CCR =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke, [_, _, {gy,_}, _]}, _}) ->
		  true;
	     (_) ->
		  false
	  end, H),
    ?match(X when X == 3, length(CCR)),

    {_, {_, _, [_, _, {gy,'CCR-Initial'}, _]},
     {ok, Session, _Events}} = hd(CCR),

    Expected0 =
	case ?config(client_ip, Config) of
	    IP = {_,_,_,_,_,_,_,_} ->
		#{'3GPP-GGSN-IPv6-Address' => ?config(test_gsn, Config),
		  '3GPP-SGSN-IPv6-Address' => IP};
	    IP ->
		#{'3GPP-GGSN-Address' => ?config(test_gsn, Config),
		  '3GPP-SGSN-Address' => IP}
	end,

    %% TBD: the comment elements are present in the PGW handler,
    %%      but not in the GGSN. Check if that is correct.
    Expected =
	Expected0
	#{
	  %% '3GPP-Allocation-Retention-Priority' => '?????',
	  '3GPP-Charging-Id' => '_',
	  '3GPP-GGSN-MCC-MNC' => <<"00101">>,
	  %% '3GPP-GPRS-Negotiated-QoS-Profile' => '?????',
	  '3GPP-IMEISV' => ?IMEISV,
	  '3GPP-IMSI' => ?IMSI,
	  '3GPP-IMSI-MCC-MNC' => <<"11111">>,
	  '3GPP-MS-TimeZone' => '_',
	  '3GPP-MSISDN' => ?MSISDN,
	  %% '3GPP-NSAPI' => 5,
	  %% '3GPP-PDP-Type' => 'IPv4v6',
	  '3GPP-RAT-Type' => 1,
	  '3GPP-SGSN-MCC-MNC' => '_',
	  '3GPP-User-Location-Info' => '_',
	  %% 'Acct-Interim-Interval' => '?????',
	  %% 'Bearer-Operation' => '?????',
	  'Called-Station-Id' =>
	      unicode:characters_to_binary(lists:join($., ?'APN-ExAmPlE')),
	  'Calling-Station-Id' => ?MSISDN,
	  'Charging-Rule-Base-Name' => <<"m2m0001">>,
	  'Diameter-Session-Id' => '_',
	  'ECGI' => '_',
	  'Event-Trigger' => '_',
	  'Framed-IP-Address' => {10, 180, '_', '_'},
	  %% 'Framed-IPv6-Prefix' => {{16#8001, 0, 1, '_', '_', '_', '_', '_'},64},
	  'Framed-Protocol' => 'GPRS-PDP-Context',
	  'Multi-Session-Id' => '_',
	  'NAS-Identifier' => '_',
	  'Node-Id' => <<"PGW-001">>,
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

	  %% 'Requested-IP-Address' => '_',
	  %% 'SAI' => '?????',
	  'Service-Type' => 'Framed-User',
	  'Session-Id' => '_',
	  'Session-Start' => '_',
	  'TAI' => '_',
	  'Username' => '_'
	 },
    ?match_map(Expected, Session),

    [Start, SInterim, Stop] =
	lists:map(fun({_, {_, _, [_, SOpts, _, _]}, _}) -> SOpts end, CCR),

    ?match_map(
       #{credits => #{3000 => empty}}, Start),
    ?equal(false, maps:is_key('used_credits', Start)),

    ?match_map(
       #{credits => #{3000 => empty},
	 used_credits =>
	     [{3000,
	       #{'CC-Input-Octets'  => ['_'],
		 'CC-Output-Octets' => ['_'],
		 'CC-Total-Octets'  => ['_'],
		 'Reporting-Reason' => [3]}}]
	}, SInterim),

    ?match_map(
       #{'Termination-Cause' => 1,
	 used_credits =>
	     [{3000,
	       #{'CC-Input-Octets'  => ['_'],
		 'CC-Output-Octets' => ['_'],
		 'CC-Total-Octets'  => ['_'],
		 'Reporting-Reason' => [2]}}]
	}, Stop),
    ?equal(false, maps:is_key('credits', Stop)),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    ok.

%%--------------------------------------------------------------------
aa_pool_select() ->
    [{doc, "Select IP-{IPv6}-Pool through AAA"}].
aa_pool_select(Config) ->
    AAAReply = #{'Framed-Pool'      => <<"pool-B">>,
		 'Framed-IPv6-Pool' => <<"pool-B">>},

    ok = meck:expect(ergw_aaa_session, invoke,
		     fun (Session, SessionOpts, Procedure = authenticate, Opts) ->
			     {_, SIn, Ev} =
				 meck:passthrough([Session, SessionOpts, Procedure, Opts]),
			     SOut = maps:merge(SIn, AAAReply),
			     {ok, SOut, Ev};
			 (Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),

    {GtpC, _, _} = create_session(Config),
    delete_session(GtpC),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
aa_pool_select_fail() ->
    [{doc, "Select IP-{IPv6}-Pool through AAA and fail!"}].
aa_pool_select_fail(Config) ->
    AAAReply = #{'Framed-Pool'      => <<"pool-C">>,
		 'Framed-IPv6-Pool' => <<"pool-C">>},

    ok = meck:expect(ergw_gsn_lib, reselect_upf,
		     fun(Candidates, SOpts, Ctx, UPinfo) ->
			     try
				 meck:passthrough([Candidates, SOpts, Ctx, UPinfo])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun (Session, SessionOpts, Procedure = authenticate, Opts) ->
			     {_, SIn, Ev} =
				 meck:passthrough([Session, SessionOpts, Procedure, Opts]),
			     SOut = maps:merge(SIn, AAAReply),
			     {ok, SOut, Ev};
			 (Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),

    create_session(overload, Config),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
tariff_time_change() ->
    [{doc, "Check Rf and Gy action on Tariff-Time-Change"}].
tariff_time_change(Config) ->
    Interim = rand:uniform(1800) + 1800,
    AAAReply = #{'Acct-Interim-Interval' => [Interim]},

    ok = meck:expect(ergw_aaa_session, start_link,
		     fun (Owner, SOpts0) ->
			     OPC = #{'Default' => #{'Tariff-Time' => [{15, 4}]}},
			     SOpts = SOpts0#{'Offline-Charging-Profile' => OPC},
			     meck:passthrough([Owner, SOpts])
		     end),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun (Session, SessionOpts, {rf, 'Initial'} = Procedure, Opts) ->
			     {_, SIn, EvIn} =
				 meck:passthrough([Session, SessionOpts, Procedure, Opts]),
			     {SOut, EvOut} =
				 ergw_aaa_rf:to_session({rf, 'ACA'}, {SIn, EvIn}, AAAReply),
			     {ok, SOut, EvOut};
			 (Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),

    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx-socket', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),
    {ok, PCtx} = gtp_context:test_cmd(Server, pfcp_ctx),

    [SER|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) ->false
		end, ergw_test_sx_up:history('pgw-u01')),

    URR = lists:sort(maps:get(create_urr, SER#pfcp.ie)),
    ?match(
       [%% offline charging URR
       #create_urr{
	  group =
	      #{urr_id := #urr_id{id = _},
		measurement_method :=
		    #measurement_method{volum = 1},
		measurement_period :=
		    #measurement_period{period = Interim},
		monitoring_time :=
		    #monitoring_time{time = _},
		reporting_triggers :=
		    #reporting_triggers{periodic_reporting = 1}
	       }
	 },
	%% online charging URR
	#create_urr{
	   group =
	       #{urr_id := #urr_id{id = _},
		 measurement_method :=
		     #measurement_method{volum = 1, durat = 1},
		 monitoring_time :=
		     #monitoring_time{time = _},
		 reporting_triggers :=
		     #reporting_triggers{
			time_quota = 1,   time_threshold = 1,
			volume_quota = 1, volume_threshold = 1},
		 time_quota :=
		     #time_quota{quota = 3600},
		 time_threshold :=
		     #time_threshold{threshold = 3540},
		 volume_quota :=
		     #volume_quota{total = 102400},
		 volume_threshold :=
		     #volume_threshold{total = 92160}
		}
	  }], URR),

    MatchSpec = ets:fun2ms(fun({Id, {Type, _}})
				 when Type =:= offline; Type =:= online -> {Type, Id} end),
    ReportFun =
	fun({online, Id}, IEs) ->
		IEbef =
		    #usage_report_srr{
		       group =
			   [#urr_id{id = Id},
			    #usage_report_trigger{monit = 1},
			    #usage_information{bef = 1},
			    #start_time{time = 3775809600},
			    #end_time{time = 3775810200},
			    #duration_measurement{duration = 600},
			    #volume_measurement{total = 5, uplink = 2, downlink = 3},
			    #tp_packet_measurement{total = 12, uplink = 5, downlink = 7}]},
		IEaft =
		    #usage_report_srr{
		       group =
			   [#urr_id{id = Id},
			    #usage_report_trigger{perio = 1},
			    #usage_information{aft = 1},
			    #start_time{time = 3775810200},
			    #end_time{time = 3775810800},
			    #duration_measurement{duration = 600},
			    #volume_measurement{total = 20, uplink = 9, downlink = 11},
			    #tp_packet_measurement{total = 28, uplink = 13, downlink = 15}]},
		[IEbef, IEaft | IEs];
	   ({offline, Id}, IEs) ->
		IEbef =
		    #usage_report_srr{
		       group =
			   [#urr_id{id = Id},
			    #usage_report_trigger{monit = 1},
			    #usage_information{bef = 1},
			    #start_time{time = 3775809600},
			    #end_time{time = 3775810200},
			    #duration_measurement{duration = 600},
			    #volume_measurement{total = 5, uplink = 2, downlink = 3},
			    #tp_packet_measurement{total = 12, uplink = 5, downlink = 7}]},
		IEaft =
		    #usage_report_srr{
		       group =
			   [#urr_id{id = Id},
			    #usage_report_trigger{volqu = 1},
			    #usage_information{aft = 1},
			    #start_time{time = 3775810200},
			    #end_time{time = 3775810800},
			    #duration_measurement{duration = 600},
			    #volume_measurement{total = 20, uplink = 9, downlink = 11},
			    #tp_packet_measurement{total = 28, uplink = 13, downlink = 15}]},
		[IEbef, IEaft | IEs]
	end,
    ergw_test_sx_up:usage_report('pgw-u01', PCtx, MatchSpec, ReportFun),

    ct:sleep(100),
    delete_session(GtpC),

    H = meck:history(ergw_aaa_session),
    RfInv =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke, [_, _, {rf, _}, _]}, _}) ->
		  true;
	     (_) ->
		  false
	  end, H),
    ?match(X when X == 3, length(RfInv)),

    [RfStart, RfInterim, RfStop] =
	lists:map(fun({_, {_, _, [_, SOpts, _, _]}, _}) -> SOpts end, RfInv),

    ?equal(false, maps:is_key('service_data', RfStart)),

    ?equal(true, maps:is_key('service_data', RfInterim)),
    [SDI1, SDI2] = lists:sort(maps:get('service_data', RfInterim)),
    ?match_map(
       #{'Rating-Group' => [3000],
	 'Accounting-Input-Octets' => [2],
	 'Accounting-Output-Octets' => [3],
	 'Change-Condition' => [?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TARIFF_TIME_CHANGE'],

	 'Time-First-Usage' => [{{2019,8,26},{12,0,0}}],
	 'Time-Last-Usage' => [{{2019,8,26},{12,10,0}}],
	 'Time-Usage' => [600]
	}, SDI1),
    ?match_map(
       #{'Rating-Group' => [3000],
	 'Accounting-Input-Octets' => [9],
	 'Accounting-Output-Octets' => [11],
	 'Change-Condition' => [?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_VOLUME_LIMIT'],

	 'Time-First-Usage' => [{{2019,8,26},{12,10,0}}],
	 'Time-Last-Usage' => [{{2019,8,26},{12,20,0}}],
	 'Time-Usage' => [600]
	}, SDI2),

    ?match_map(
       #{service_data =>
	     [#{'Accounting-Input-Octets' => ['_'],
		'Accounting-Output-Octets' => ['_'],
		'Change-Condition' => [0]}
	     ]}, RfStop),

    GyInv =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke, [_, _, {gy,_}, _]}, _}) ->
		  true;
	     (_) ->
		  false
	  end, H),
    ?match(X when X == 3, length(GyInv)),

    [GyStart, GyInterim, GyStop] =
	lists:map(fun({_, {_, _, [_, SOpts, _, _]}, _}) -> SOpts end, GyInv),

    ?match_map(
       #{credits => #{3000 => empty}}, GyStart),
    ?equal(false, maps:is_key('used_credits', GyStart)),

    ?equal(true, maps:is_key('used_credits', GyInterim)),
    [UCI1, UCI2] = lists:sort([X || {3000, X} <- maps:get('used_credits', GyInterim)]),
    ?match_map(
       #{'CC-Input-Octets'  => [2],
	 'CC-Output-Octets' => [3],
	 'CC-Total-Octets'  => [5],
	 'Tariff-Change-Usage' =>
	     [?'DIAMETER_3GPP_CHARGING_TARIFF-CHANGE-USAGE_UNIT_BEFORE_TARIFF_CHANGE']
	}, UCI1),
    ?match_map(
       #{'CC-Input-Octets'  => [9],
	 'CC-Output-Octets' => [11],
	 'CC-Total-Octets'  => [20],
	 'Tariff-Change-Usage' =>
	     [?'DIAMETER_3GPP_CHARGING_TARIFF-CHANGE-USAGE_UNIT_AFTER_TARIFF_CHANGE']
	}, UCI2),

    ?match_map(
       #{'Termination-Cause' => 1,
	 used_credits =>
	     [{3000,
	       #{'CC-Input-Octets'  => ['_'],
		 'CC-Output-Octets' => ['_'],
		 'CC-Total-Octets'  => ['_'],
		 'Reporting-Reason' => [2]}}]
	}, GyStop),
    ?equal(false, maps:is_key('credits', GyStop)),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------

gy_ccr_asr_overlap() ->
    [{doc, "Test that ASR is answered when it arrives during CCR-T"}].
gy_ccr_asr_overlap(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx-socket', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),

    #{'Session' := Session} = gtp_context:info(Server),
    SessionOpts = ergw_aaa_session:get(Session),

    Self = self(),
    ResponseFun =
	fun(Request, Result, Avps, SOpts) ->
		Self ! {'$response', Request, Result, Avps, SOpts} end,
    AAAReq = #aaa_request{from = ResponseFun, procedure = {gy, 'ASR'},
			  session = SessionOpts, events = []},

    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(MSession, MSessionOpts, {gy, 'CCR-Terminate'} = Procedure, Opts) ->
			     ct:pal("AAAReq: ~p", [AAAReq]),
			     Server ! AAAReq,
			     meck:passthrough([MSession, MSessionOpts, Procedure, Opts]);
			(MSession, MSessionOpts, Procedure, Opts) ->
			     meck:passthrough([MSession, MSessionOpts, Procedure, Opts])
		     end),

    ct:sleep({seconds, 1}),
    delete_session(GtpC),

    ?equal(timeout, recv_pdu(Cntl, undefined, 100, fun(Why) -> Why end)),

    {_, Resp0, _, _} =
	receive {'$response', _, _, _, _} = R0 -> erlang:delete_element(1, R0)
	after 1000 -> ct:fail(no_response)
	end,
    ?equal(ok, Resp0),

    H = meck:history(ergw_aaa_session),
    CCR =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke, [_, _, {gy,_}, _]}, _}) ->
		  true;
	     (_) ->
		  false
	  end, H),
    ct:pal("CCR: ~p", [CCR]),
    ?match(X when X == 2, length(CCR)),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    ok.

%%--------------------------------------------------------------------

volume_threshold() ->
    [{doc, "Test Gy interaction when volume threshold is reached"}].
volume_threshold(Config) ->
    {GtpC, _, _} = create_session(Config),

    [#{'Process' := Pid}|_] = ergw_api:tunnel(all),
    #{pfcp:= PCtx} = gtp_context:info(Pid),

    MatchSpec = ets:fun2ms(fun({Id, {'online', _}}) -> Id end),

    ergw_test_sx_up:usage_report('pgw-u01', PCtx, MatchSpec, [#usage_report_trigger{volth = 1}]),
    ergw_test_sx_up:usage_report('pgw-u01', PCtx, MatchSpec, [#usage_report_trigger{volqu = 1}]),

    ct:sleep({seconds, 1}),

    delete_session(GtpC),

    [Sx1, Sx2 | _] =
	lists:filter(
	  fun(#pfcp{type = session_modification_request}) -> true;
	     (_) ->false
	  end, ergw_test_sx_up:history('pgw-u01')),

    ?equal([0, 0, 0, 0, 0, 1, 0, 0, 0],
	   [maps_key_length(X1, Sx1#pfcp.ie)
	    || X1 <- [create_pdr, create_far, create_urr,
		      update_pdr, update_far, update_urr,
		      remove_pdr, remove_far, remove_urr]]),

    ?equal([0, 0, 0, 0, 0, 1, 0, 0, 0],
	   [maps_key_length(X2, Sx2#pfcp.ie)
	    || X2 <- [create_pdr, create_far, create_urr,
		      update_pdr, update_far, update_urr,
		      remove_pdr, remove_far, remove_urr]]),

    H = meck:history(ergw_aaa_session),
    CCRUvolth =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke,
		   [_,
		    #{used_credits :=
			  [{3000,
			    #{'Reporting-Reason' :=
				  [?'DIAMETER_3GPP_CHARGING_REPORTING-REASON_THRESHOLD']}}]},
		    {gy,'CCR-Update'}, _]}, _}) ->
		  true;
	     (_) ->
		  false
	  end, H),
    ?match(X when X == 1, length(CCRUvolth)),

    CCRUvolqu =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke,
		   [_,
		    #{used_credits :=
			  [{3000,
			    #{'Reporting-Reason' :=
				  [?'DIAMETER_3GPP_CHARGING_REPORTING-REASON_QUOTA_EXHAUSTED']}}]},
		    {gy,'CCR-Update'}, _]}, _}) ->
		  true;
	     (_) ->
		  false
	  end, H),
    ?match(X when X == 1, length(CCRUvolqu)),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    ok.

%%--------------------------------------------------------------------
gx_rar_gy_interaction() ->
    [{doc, "Check that a Gx RAR triggers a Gy request"}].
gx_rar_gy_interaction(Config) ->
    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx-socket', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),

    {ok, Session} = gtp_context:test_cmd(Server, session),
    SessionOpts = ergw_aaa_session:get(Session),

    {ok, #pfcp_ctx{timers = T1}} = gtp_context:test_cmd(Server, pfcp_ctx),
    ?equal(1, maps:size(T1)),

    Self = self(),
    ResponseFun =
	fun(Request, Result, Avps, SOpts) ->
		Self ! {'$response', Request, Result, Avps, SOpts} end,
    AAAReq = #aaa_request{from = ResponseFun, procedure = {gx, 'RAR'},
			  session = SessionOpts, events = []},

    InstCR =
	[{pcc, install, [#{'Charging-Rule-Name' => [<<"r-0002">>]}]}],
    ?LOG(debug, "Sending RAR"),
    Server ! AAAReq#aaa_request{events = InstCR},
    {_, Resp1, _, _} =
	receive {'$response', _, _, _, _} = R1 -> erlang:delete_element(1, R1) end,
    ?equal(ok, Resp1),
    {ok, PCR1} = gtp_context:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{}, <<"r-0002">> := #{}}, PCR1),

    {ok, #pfcp_ctx{timers = T2}} = gtp_context:test_cmd(Server, pfcp_ctx),
    ?equal(2, maps:size(T2)),

    SOpts1 = ergw_aaa_session:get(Session),
    RemoveCR =
	[{pcc, remove, [#{'Charging-Rule-Name' => [<<"r-0002">>]}]}],
    Server ! AAAReq#aaa_request{session = SOpts1, events = RemoveCR},
    {_, Resp2, _, _} =
	receive {'$response', _, _, _, _} = R2 -> erlang:delete_element(1, R2) end,
    ?equal(ok, Resp2),
    {ok, PCR2} = gtp_context:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{}}, PCR2),
    ?equal(false, maps:is_key(<<"r-0002">>, PCR2)),

    {ok, #pfcp_ctx{timers = T3}} = gtp_context:test_cmd(Server, pfcp_ctx),
    ?equal(1, maps:size(T3)),
    ?equal(maps:keys(T1), maps:keys(T3)),

    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
redirect_info() ->
    [{doc, "Check Session with Gx redirect info"}].
redirect_info(Config) ->
    {GtpC, _, _} = create_session(ipv4, Config),
    delete_session(GtpC),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    [SER|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) ->false
		end, ergw_test_sx_up:history('pgw-u01')),

    #{create_pdr := PDRs0,
      create_far := FARs0,
      create_urr := URR
     } = SER#pfcp.ie,

    PDRs = lists:sort(PDRs0),
    FARs = lists:sort(FARs0),

    ?LOG(debug, "PDRs: ~p", [pfcp_packet:pretty_print(PDRs)]),
    ?LOG(debug, "FARs: ~p", [pfcp_packet:pretty_print(FARs)]),
    ?LOG(debug, "URR: ~p", [pfcp_packet:pretty_print([URR])]),

    ?match(
       [#create_pdr{
	   group =
	       #{pdr_id := #pdr_id{id = _},
		 precedence := #precedence{precedence = 100},
		 pdi :=
		     #pdi{
			group =
			    #{network_instance :=
				  #network_instance{instance = <<3, "sgi">>},
			      sdf_filter :=
				  #sdf_filter{
				     flow_description =
					 <<"permit out ip from any to assigned">>},
			      source_interface :=
				  #source_interface{interface='SGi-LAN'},
			      ue_ip_address := #ue_ip_address{type = dst}
			     }
		       },
		 far_id := #far_id{id = _},
		 urr_id := #urr_id{id = _}
		}
	  },
	#create_pdr{
	   group =
	       #{
		 pdr_id := #pdr_id{id = _},
		 precedence := #precedence{precedence = 100},
		 pdi :=
		     #pdi{
			group =
			    #{network_instance :=
				  #network_instance{instance = <<3, "irx">>},
			      sdf_filter :=
				  #sdf_filter{
				     flow_description =
					 <<"permit out ip from any to assigned">>},
			      source_interface :=
				  #source_interface{interface='Access'},
			      ue_ip_address := #ue_ip_address{type = src}
			     }
		       },
		 far_id := #far_id{id = _},
		 urr_id := #urr_id{id = _}
		}
	  }], PDRs),

    ?match(
       [#create_far{
	   group =
	       #{far_id := #far_id{id = _},
		 apply_action :=
		     #apply_action{forw = 1},
		 forwarding_parameters :=
		     #forwarding_parameters{
			group =
			    #{destination_interface :=
				  #destination_interface{interface='Access'},
			      network_instance :=
				  #network_instance{instance = <<3, "irx">>}
			     }
		       }
		}
	  },
	#create_far{
	   group =
	       #{far_id := #far_id{id = _},
		 apply_action :=
		     #apply_action{forw = 1},
		 forwarding_parameters :=
		     #forwarding_parameters{
			group =
			    #{destination_interface :=
				  #destination_interface{interface='SGi-LAN'},
			      redirect_information :=
				  #redirect_information{type = 'URL',
							address = <<"http://www.heise.de/">>},
			      network_instance :=
				  #network_instance{instance = <<3, "sgi">>}
			     }
		       }
		}
	  }], FARs),

    ?match(
       #create_urr{
	  group =
	      #{urr_id := #urr_id{id = _},
		measurement_method :=
		    #measurement_method{volum = 1}
	       }
	 }, URR),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_asr() ->
    [{doc, "Check that ASR on Gx terminates the session"}].
gx_asr(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx-socket', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),

    ResponseFun = fun(_, _, _, _) -> ok end,
    Server ! #aaa_request{from = ResponseFun, procedure = {gx, 'ASR'},
			  session = #{}, events = []},

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_rar() ->
    [{doc, "Check that RAR on Gx changes the session"}].
gx_rar(Config) ->
    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx-socket', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),

    #{'Session' := Session} = gtp_context:info(Server),
    SessionOpts = ergw_aaa_session:get(Session),

    Self = self(),
    ResponseFun =
	fun(Request, Result, Avps, SOpts) ->
		Self ! {'$response', Request, Result, Avps, SOpts} end,
    AAAReq = #aaa_request{from = ResponseFun, procedure = {gx, 'RAR'},
			  session = SessionOpts, events = []},

    Server ! AAAReq,
    {_, Resp0, _, _} =
	receive {'$response', _, _, _, _} = R0 -> erlang:delete_element(1, R0) end,
    ?equal(ok, Resp0),
    {ok, PCR0} = gtp_context:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{}}, PCR0),

    InstCR =
	[{pcc, install, [#{'Charging-Rule-Name' => [<<"r-0002">>]}]}],
    Server ! AAAReq#aaa_request{events = InstCR},
    {_, Resp1, _, SOpts1} =
	receive {'$response', _, _, _, _} = R1 -> erlang:delete_element(1, R1) end,
    ?equal(ok, Resp1),
    {ok, PCR1} = gtp_context:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{}, <<"r-0002">> := #{}}, PCR1),

    RemoveCR =
	[{pcc, remove, [#{'Charging-Rule-Name' => [<<"r-0002">>]}]}],
    Server ! AAAReq#aaa_request{session = SOpts1, events = RemoveCR},
    {_, Resp2, _, _SOpts2} =
	receive {'$response', _, _, _, _} = R2 -> erlang:delete_element(1, R2) end,
    ?equal(ok, Resp2),
    {ok, PCR2} = gtp_context:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{}}, PCR2),
    ?equal(false, maps:is_key(<<"r-0002">>, PCR2)),

    InstCRB =
	[{pcc, install, [#{'Charging-Rule-Base-Name' => [<<"m2m0002">>]}]}],
    Server ! AAAReq#aaa_request{events = InstCRB},
    {_, Resp3, _, SOpts3} =
	receive {'$response', _, _, _, _} = R3 -> erlang:delete_element(1, R3) end,
    ?equal(ok, Resp3),
    {ok, PCR3} = gtp_context:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{},
	     <<"r-0002">> := #{'Charging-Rule-Base-Name' := _}}, PCR3),

    RemoveCRB =
	[{pcc, remove, [#{'Charging-Rule-Base-Name' => [<<"m2m0002">>]}]}],
    Server ! AAAReq#aaa_request{session = SOpts3, events = RemoveCRB},
    {_, Resp4, _, _SOpts4} =
	receive {'$response', _, _, _, _} = R4 -> erlang:delete_element(1, R4) end,
    ?equal(ok, Resp4),
    {ok, PCR4} = gtp_context:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{}}, PCR4),
    ?equal(false, maps:is_key(<<"r-0002">>, PCR4)),

    delete_session(GtpC),

    H = ergw_test_sx_up:history('pgw-u01'),
    ct:pal("H: ~s~n",
	   [[[pfcp_packet:pretty_print(X), "\n\n"] || X <- H]]),

    [Sx1, Sx2, Sx3, Sx4 | _] =
	lists:filter(
	  fun(#pfcp{type = session_modification_request}) -> true;
	     (_) ->false
	  end, ergw_test_sx_up:history('pgw-u01')),

    ct:pal("Sx1: ~p", [Sx1]),
    ?equal([2, 2, 1, 0, 0, 0, 0, 0, 0],
	   [maps_key_length(X1, Sx1#pfcp.ie)
	    || X1 <- [create_pdr, create_far, create_urr,
		      update_pdr, update_far, update_urr,
		      remove_pdr, remove_far, remove_urr]]),

    ct:pal("Sx2: ~p", [Sx2]),
    ?equal([0, 0, 0, 0, 0, 0, 2, 2, 1],
	   [maps_key_length(X2, Sx2#pfcp.ie)
	    || X2 <- [create_pdr, create_far, create_urr,
		      update_pdr, update_far, update_urr,
		      remove_pdr, remove_far, remove_urr]]),

    ct:pal("Sx3: ~p", [Sx3]),
    ?equal([2, 2, 1, 0, 0, 0, 0, 0, 0],
	   [maps_key_length(X3, Sx3#pfcp.ie)
	    || X3 <- [create_pdr, create_far, create_urr,
		      update_pdr, update_far, update_urr,
		      remove_pdr, remove_far, remove_urr]]),

    ct:pal("Sx4: ~p", [Sx4]),
    ?equal([0,0,0,0,0,0,2,2,1],
	   [maps_key_length(X4, Sx4#pfcp.ie)
	    || X4 <- [create_pdr, create_far, create_urr,
		      update_pdr, update_far, update_urr,
		      remove_pdr, remove_far, remove_urr]]),

    %% TBD, should be 5
    %% ?match(2, meck:num_calls(ergw_aaa_session, invoke,
    %% 			     ['_', '_', {gy, 'CCR-Update'}, '_'])),

    Hs = meck:history(ergw_aaa_session),
    CCR =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke, [_, _, {gy,'CCR-Update'}, _]}, _}) ->
		  true;
	     (_) ->
		  false
	  end, Hs),
    ct:pal("CCR: ~p", [[Call || {_, Call, _} <- CCR]]),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gy_asr() ->
    [{doc, "Check that ASR on Gy terminates the session"}].
gy_asr(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_session(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx-socket', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),

    ResponseFun = fun(_, _, _, _) -> ok end,
    Server ! #aaa_request{from = ResponseFun, procedure = {gy, 'ASR'},
			  session = #{}, events = []},

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gy_async_stop() ->
    [{doc, "Check that a error/stop from async session call terminates the context"}].
gy_async_stop(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_session(Config),

    %% wait up to 10 secs for DBR
    Req = recv_pdu(Cntl, 10000),
    ?match(#gtp{type = delete_bearer_request}, Req),
    Resp = make_response(Req, simple, GtpC),
    send_pdu(Cntl, GtpC, Resp),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
tdf_app_id() ->
    [{doc, "Check Session with Gx TDF-Application-Identifier"}].
tdf_app_id(Config) ->
    {GtpC, _, _} = create_session(ipv4, Config),
    delete_session(GtpC),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    [SER|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) ->false
		end, ergw_test_sx_up:history('pgw-u01')),

    #{create_pdr := PDRs0,
      create_far := FARs0,
      create_urr := URR
     } = SER#pfcp.ie,

    PDRs = lists:sort(PDRs0),
    FARs = lists:sort(FARs0),

    ?LOG(debug, "PDRs: ~p", [pfcp_packet:pretty_print(PDRs)]),
    ?LOG(debug, "FARs: ~p", [pfcp_packet:pretty_print(FARs)]),
    ?LOG(debug, "URR: ~p", [pfcp_packet:pretty_print([URR])]),

    ?match(
       [#create_pdr{
	   group =
	       #{pdr_id := #pdr_id{id = _},
		 precedence := #precedence{precedence = 100},
		 pdi :=
		     #pdi{
			group =
			    #{network_instance :=
				  #network_instance{instance = <<3, "sgi">>},
			      application_id :=
				  #application_id{id = <<"Gold">>},
			      source_interface :=
				  #source_interface{interface='SGi-LAN'},
			      ue_ip_address := #ue_ip_address{type = dst}
			     }
		       },
		 far_id := #far_id{id = _},
		 urr_id := #urr_id{id = _}
		}
	  },
	#create_pdr{
	   group =
	       #{
		 pdr_id := #pdr_id{id = _},
		 precedence := #precedence{precedence = 100},
		 pdi :=
		     #pdi{
			group =
			    #{network_instance :=
				  #network_instance{instance = <<3, "irx">>},
			      application_id :=
				  #application_id{id = <<"Gold">>},
			      source_interface :=
				  #source_interface{interface='Access'},
			      ue_ip_address := #ue_ip_address{type = src}
			     }
		       },
		 far_id := #far_id{id = _},
		 urr_id := #urr_id{id = _}
		}
	  }], PDRs),

    ?match(
       [#create_far{
	   group =
	       #{far_id := #far_id{id = _},
		 apply_action :=
		     #apply_action{forw = 1},
		 forwarding_parameters :=
		     #forwarding_parameters{
			group =
			    #{destination_interface :=
				  #destination_interface{interface='Access'},
			      network_instance :=
				  #network_instance{instance = <<3, "irx">>}
			     }
		       }
		}
	  },
	#create_far{
	   group =
	       #{far_id := #far_id{id = _},
		 apply_action :=
		     #apply_action{forw = 1},
		 forwarding_parameters :=
		     #forwarding_parameters{
			group =
			    #{destination_interface :=
				  #destination_interface{interface='SGi-LAN'},
			      network_instance :=
				  #network_instance{instance = <<3, "sgi">>}
			     }
		       }
		}
	  }], FARs),

    ?match(
       #create_urr{
	  group =
	      #{urr_id := #urr_id{id = _},
		measurement_method :=
		    #measurement_method{volum = 1}
	       }
	 }, URR),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
apn_lookup() ->
    [{doc, "Check that the APN and wildcard APN lookup works"}].
apn_lookup(_Config) ->
    NodeCaps = {#{<<3, "sgi">>      => #vrf{name = <<3, "sgi">>},
		  <<8, "wildcard">> => #vrf{name = <<8, "wildcard">>}},
		[]},

    ct:pal("VRF: ~p", [ergw_gsn_lib:select_vrf(NodeCaps, ?'APN-EXAMPLE')]),
    ?match(<<3, "sgi">>, ergw_gsn_lib:select_vrf(NodeCaps, ?'APN-EXAMPLE')),
    ?match(<<3, "sgi">>, ergw_gsn_lib:select_vrf(NodeCaps, [<<"exa">>, <<"mple">>, <<"net">>])),
    ?match(<<3, "sgi">>, ergw_gsn_lib:select_vrf(NodeCaps, [<<"APN1">>])),
    ?match(<<3, "sgi">>, ergw_gsn_lib:select_vrf(NodeCaps, [<<"APN1">>, <<"mnc001">>, <<"mcc001">>, <<"gprs">>])),
    ?match(<<3, "sgi">>, ergw_gsn_lib:select_vrf(NodeCaps, [<<"APN2">>])),
    ?match(<<3, "sgi">>, ergw_gsn_lib:select_vrf(NodeCaps, [<<"APN2">>, <<"mnc001">>, <<"mcc001">>, <<"gprs">>])),
    %% ?match(<<8, "wildcard">>, ergw_gsn_lib:select_vrf(NodeCaps, [<<"APN3">>])),
    %% ?match(<<8, "wildcard">>, ergw_gsn_lib:select_vrf(NodeCaps, [<<"APN3">>, <<"mnc001">>, <<"mcc001">>, <<"gprs">>])),
    %% ?match(<<8, "wildcard">>, ergw_gsn_lib:select_vrf(NodeCaps, [<<"APN4">>, <<"mnc001">>, <<"mcc901">>, <<"gprs">>])),
    ok.

%%--------------------------------------------------------------------
gx_invalid_charging_rulebase() ->
    [{doc, "Check the reaction to a Gx CCA-I with an invalid Charging-Rule-Base-Name"}].
gx_invalid_charging_rulebase(Config) ->
    ClientIP = proplists:get_value(client_ip, Config),
    {GtpC, _, _} = create_session(Config),

    ?match([#{tunnels := 1}], [X || X = #{version := Version} <- ergw_api:peer(ClientIP),
				    Version == v2]),

    CCRU =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke,
		   [_, R, {gx,'CCR-Update'}, _]}, _}) ->
		  ?match(
		     #{'Charging-Rule-Report' :=
			   [#{'Charging-Rule-Base-Name' := [_]}]}, R),
		  true;
	     (_) ->
		  false
	  end, meck:history(ergw_aaa_session)),
    ?match(X when X == 1, length(CCRU)),

    delete_session(GtpC),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_invalid_charging_rule() ->
    [{doc, "Check the reaction to a Gx CCA-I with an invalid Charging-Rule-Name"}].
gx_invalid_charging_rule(Config) ->
    ClientIP = proplists:get_value(client_ip, Config),
    {GtpC, _, _} = create_session(Config),

    ?match([#{tunnels := 1}], [X || X = #{version := Version} <- ergw_api:peer(ClientIP),
				    Version == v2]),

    CCRU =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke,
		   [_, R, {gx,'CCR-Update'}, _]}, _}) ->
		  ?match(
		     #{'Charging-Rule-Report' :=
			   [#{'Charging-Rule-Name' := [_]}]}, R),
		  true;
	     (_) ->
		  false
	  end, meck:history(ergw_aaa_session)),
    ?match(X when X == 1, length(CCRU)),

    delete_session(GtpC),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gtp_idle_timeout() ->
    [{doc, "Checks if the gtp idle timeout is triggered"}].
gtp_idle_timeout(Config) ->
    Cntl = whereis(gtpc_client_server),
    {GtpC, _, _} = create_session(Config),
    %% The meck wait timeout (400 ms) has to be more than then the Idle-Timeout
    ok = meck:wait(?HUT, handle_event,
		   [{timeout, context_idle}, stop_session, '_', '_'], 400),

    %% Timeout triggers a delete_bearer_request towards the S-GW.
    Req = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Req),
    Resp = make_response(Req, simple, GtpC),
    send_pdu(Cntl, GtpC, Resp),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

maps_recusive_merge(Key, Value, Map) ->
    maps:update_with(Key, fun(V) -> maps_recusive_merge(V, Value) end, Value, Map).

maps_recusive_merge(M1, M2)
  when is_map(M1) andalso is_map(M1) ->
    maps:fold(fun maps_recusive_merge/3, M1, M2);
maps_recusive_merge(_, New) ->
    New.

cfg_get_value([], Cfg) ->
    Cfg;
cfg_get_value([H|T], Cfg) when is_map(Cfg) ->
    cfg_get_value(T, maps:get(H, Cfg));
cfg_get_value([H|T], Cfg) when is_list(Cfg) ->
    cfg_get_value(T, proplists:get_value(H, Cfg)).

load_aaa_answer_config(AnswerCfg) ->
    {ok, Cfg0} = application:get_env(ergw_aaa, apps),
    Session = cfg_get_value([default, session, 'Default'], Cfg0),
    Answers =
	[{Proc, [{'Default', Session#{answer => Answer}}]}
	 || {Proc, Answer} <- AnswerCfg],
    UpdCfg =
	#{default =>
	      #{procedures => maps:from_list(Answers)}},
    Cfg = maps_recusive_merge(Cfg0, UpdCfg),
    ok = application:set_env(ergw_aaa, apps, Cfg).

set_online_charging([], true, Cfg)
  when is_map(Cfg) ->
    maps:put('Online', [1], Cfg);
set_online_charging([], _, Cfg)
  when is_map(Cfg) ->
    maps:remove('Online', Cfg);
set_online_charging([], _, Cfg) ->
    Cfg;

set_online_charging([Key|Next], Set, [{_, _}|_] = Cfg)
  when Key =:= '_' ->
    lists:map(
      fun({K, V}) -> {K, set_online_charging(Next, Set, V)} end, Cfg);
set_online_charging([Key|Next], Set, [{_, _}|_] = Cfg) ->
    New = {Key, set_online_charging(Next, Set, proplists:get_value(Key, Cfg))},
    lists:keystore(Key, 1, Cfg, New);
%% set_online_charging(_, _Set, Cfg) when is_list(Cfg) ->
%%     Cfg;

set_online_charging([Key|Next], Set, Cfg)
  when Key =:= '_', is_map(Cfg) ->
    maps:map(
      fun(_, V) -> set_online_charging(Next, Set, V) end, Cfg);
set_online_charging([Key|Next], Set, Cfg)
  when is_map(Cfg) ->
    Cfg#{Key => set_online_charging(Next, Set, maps:get(Key, Cfg))}.

set_online_charging(Set) ->
    {ok, Cfg0} = application:get_env(ergw, charging),
    Cfg = set_online_charging(['_', rulebase, '_'], Set, Cfg0),
	ok = application:set_env(ergw, charging, Cfg).
	
%% Set APN key data
set_apn_key(Key, Value) ->
    {ok, APNs0} = application:get_env(ergw, apns),
    Upd = fun(_APN, Val_map) -> maps:put(Key, Value, Val_map) end,
    APNs = maps:map(Upd, APNs0),
    ok = application:set_env(ergw, apns, APNs).
