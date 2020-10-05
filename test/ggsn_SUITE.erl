%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("kernel/include/logger.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_ggsn_test_lib.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-define(TIMEOUT, 2000).
-define(HUT, ggsn_gn).				%% Handler Under Test

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
		  [{cp, [{type, 'gtp-u'},
			 {ip, ?MUST_BE_UPDATED},
			 {reuseaddr, true}
			]},
		   {irx, [{type, 'gtp-c'},
			  {ip,  ?MUST_BE_UPDATED},
			  {reuseaddr, true}
			 ]},

		   {sx, [{type, 'pfcp'},
			 {node, 'ergw'},
			 {name, 'ergw'},
			 {socket, cp},
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
		      {"async-sx.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.prox01.$ORIGIN"},
		      {"async-sx.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.prox02.$ORIGIN"},

		      %% A/AAAA record alternatives
		      {"topon.gn.ggsn.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.prox01.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.prox02.$ORIGIN", ?MUST_BE_UPDATED, []}
		     ]
		    }
		   }
		  ]
		 },

		 {apns,
		  [{?'APN-EXAMPLE',
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']},
		     {'Idle-Timeout', 21600000}]}, % Idle timeout 6 hours
		   {[<<"exa">>, <<"mple">>, <<"net">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]},
		   {[<<"APN1">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']},
		     {'Idle-Timeout', 28800000}]}, % Idle timeout 8 hours
		   {[<<"v6only">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']},
		     {bearer_type, 'IPv6'},
		     {'Idle-Timeout', infinity}]},
		   {[<<"v4only">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']},
		     {bearer_type, 'IPv4'}]},
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
		   {"topon.sx.prox01.$ORIGIN", [connect]}
		  ]
		 }
		]},

	 {ergw_aaa,
	  [
	   {handlers,
	    [{ergw_aaa_static,
	      [{'NAS-Identifier',          <<"NAS-Identifier">>},
	       {'Node-Id',                 <<"PGW-001">>},
	       {'Acct-Interim-Interval',   600},
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
	[{[sockets, cp, ip], localhost},
	 {[sockets, irx, ip], test_gsn},
	 {[sockets, sx, ip], localhost},
	 {[node_selection, {default, 2}, 2, "topon.gn.ggsn.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox01.$ORIGIN"],
	  {fun node_sel_update/2, pgw_u01_sx}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox02.$ORIGIN"],
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
     invalid_gtp_msg,
     create_pdp_context_request_missing_ie,
     create_pdp_context_request_aaa_reject,
     create_pdp_context_request_gx_fail,
     create_pdp_context_request_gy_fail,
     create_pdp_context_request_rf_fail,
     create_pdp_context_request_invalid_apn,
     create_pdp_context_request_pool_exhausted,
     create_pdp_context_request_dotted_apn,
     create_pdp_context_request_accept_new,
     path_restart, path_restart_recovery, path_restart_multi,
     path_failure,
     simple_pdp_context_request,
     change_reporting_indication,
     duplicate_pdp_context_request,
     error_indication,
     pdp_context_request_bearer_types,
     %% request_fast_resend, TODO, FIXME
     create_pdp_context_request_resend,
     delete_pdp_context_request_resend,
     update_pdp_context_request_ra_update,
     update_pdp_context_request_rat_update,
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
     session_options,
     session_accounting,
     sx_ondemand,
     gy_validity_timer,
     simple_aaa,
     simple_ofcs,
     simple_ocs,
     gy_ccr_asr_overlap,
     volume_threshold,
     gx_asr,
     gx_rar,
     gy_asr,
     gy_async_stop,
     gx_invalid_charging_rulebase,
     gx_invalid_charging_rule,
     gx_rar_gy_interaction,
     gtp_idle_timeout,
     up_inactivity_timer].

groups() ->
    [{ipv4, [], common()},
     {ipv6, [], common()}].

all() ->
    [{group, ipv4},
     {group, ipv6}].

%%%===================================================================
%%% Tests
%%%===================================================================

setup_per_testcase(Config) ->
    setup_per_testcase(Config, true).

setup_per_testcase(Config, ClearSxHist) ->
    ct:pal("Sockets: ~p", [ergw_socket_reg:all()]),
    ergw_test_sx_up:reset('pgw-u01'),
    meck_reset(Config),
    start_gtpc_server(Config),
    reconnect_all_sx_nodes(),
    ClearSxHist andalso ergw_test_sx_up:history('pgw-u01', true),
    ok.

init_per_testcase(create_pdp_context_request_aaa_reject, Config) ->
    setup_per_testcase(Config),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(_, _, authenticate, _) ->
			     {fail, #{}, []};
			(Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),
    Config;
init_per_testcase(create_pdp_context_request_gx_fail, Config) ->
    setup_per_testcase(Config),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(_, _, {gx, 'CCR-Initial'}, _) ->
			     {fail, #{}, []};
			(Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),
    Config;
init_per_testcase(create_pdp_context_request_gy_fail, Config) ->
    setup_per_testcase(Config),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(_, _, {gy, 'CCR-Initial'}, _) ->
			     {fail, #{}, []};
			(Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),
    Config;
init_per_testcase(create_pdp_context_request_rf_fail, Config) ->
    setup_per_testcase(Config),
    ok = meck:expect(ergw_aaa_session, invoke,
		     fun(_, _, start, _) ->
			     {fail, #{}, []};
			(Session, SessionOpts, Procedure, Opts) ->
			     meck:passthrough([Session, SessionOpts, Procedure, Opts])
		     end),
    Config;
init_per_testcase(create_pdp_context_request_pool_exhausted, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(ergw_local_pool, [passthrough, no_link]),
    Config;
init_per_testcase(path_restart, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(gtp_path, [passthrough, no_link]),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == delete_pdp_context_requested_resend ->
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
    ok = meck:expect(?HUT, handle_request,
		     fun(Request, Msg, Resent, State, Data) ->
			     if Resent -> ok;
				true   -> ct:sleep(1000)
			     end,
			     meck:passthrough([Request, Msg, Resent, State, Data])
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
init_per_testcase(gy_validity_timer, Config) ->
    setup_per_testcase(Config),
    set_online_charging(true),
    load_ocs_config('Initial-OCS-VT', 'Update-OCS-VT'),
    Config;
init_per_testcase(gy_async_stop, Config) ->
    setup_per_testcase(Config),
    set_online_charging(true),
    load_ocs_config('Initial-OCS-VT', 'Update-OCS-Fail'),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == simple_ocs;
       TestCase == gy_ccr_asr_overlap;
       TestCase == volume_threshold ->
    setup_per_testcase(Config),
    set_online_charging(true),
    load_ocs_config('Initial-OCS', 'Update-OCS'),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == gx_rar_gy_interaction ->
    setup_per_testcase(Config),
    set_online_charging(true),
    load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS'},
			    {{gy, 'CCR-Update'},  'Update-OCS-GxGy'}]),
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
    ?match_metric(prometheus_gauge, ergw_local_pool_free, PoolId, 65534),

    AppsCfg = proplists:get_value(aaa_cfg, Config),
    ok = application:set_env(ergw_aaa, apps, AppsCfg),
    set_online_charging(false),
    ok.

end_per_testcase(TestCase, Config)
  when TestCase == create_pdp_context_request_aaa_reject;
       TestCase == create_pdp_context_request_gx_fail;
       TestCase == create_pdp_context_request_gy_fail;
       TestCase == create_pdp_context_request_rf_fail;
       TestCase == gy_ccr_asr_overlap;
       TestCase == simple_aaa;
       TestCase == simple_ofcs ->
    ok = meck:delete(ergw_aaa_session, invoke, 4),
    end_per_testcase(Config),
    Config;
end_per_testcase(create_pdp_context_request_pool_exhausted, Config) ->
    meck:unload(ergw_local_pool),
    end_per_testcase(Config),
    Config;
end_per_testcase(path_restart, Config) ->
    meck:unload(gtp_path),
    end_per_testcase(Config),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == delete_pdp_context_requested_resend ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 7),
    end_per_testcase(Config),
    Config;
end_per_testcase(request_fast_resend, Config) ->
    ok = meck:delete(?HUT, handle_request, 5),
    end_per_testcase(Config),
    Config;
end_per_testcase(create_pdp_context_overload, Config) ->
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
    MfrId = ['irx', rx, 'malformed-requests'],
    MfrCnt = get_metric(prometheus_counter, gtp_c_socket_errors_total, MfrId, 0),

    S = make_gtp_socket(Config),
    gen_udp:send(S, TestGSN, ?GTP1c_PORT, <<"TESTDATA">>),

    ?equal({error,timeout}, gen_udp:recv(S, 4096, ?TIMEOUT)),
    ?match_metric(prometheus_counter, gtp_c_socket_errors_total, MfrId, MfrCnt + 1),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
invalid_gtp_msg() ->
    [{doc, "Test that an invalid message is silently ignored"
      " and that the GTP socket is not crashing"}].
invalid_gtp_msg(Config) ->
    TestGSN = proplists:get_value(test_gsn, Config),
    MfrId = ['irx', rx, 'malformed-requests'],
    MfrCnt = get_metric(prometheus_counter, gtp_c_socket_errors_total, MfrId, 0),

    Msg = hexstr2bin("320000040000000044000000"),

    S = make_gtp_socket(Config),
    gen_udp:send(S, TestGSN, ?GTP1c_PORT, Msg),

    ?equal({error,timeout}, gen_udp:recv(S, 4096, ?TIMEOUT)),
    ?match_metric(prometheus_counter, gtp_c_socket_errors_total, MfrId, MfrCnt + 1),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_missing_ie() ->
    [{doc, "Check that Create Session Request IE validation works"}].
create_pdp_context_request_missing_ie(Config) ->
    MetricsBefore = socket_counter_metrics(),

    create_pdp_context(missing_ie, Config),

    MetricsAfter = socket_counter_metrics(),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, create_pdp_context_request),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, mandatory_ie_missing), % In response
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_aaa_reject() ->
    [{doc, "Check AAA reject return on Create PDP Context Request"}].
create_pdp_context_request_aaa_reject(Config) ->
    MetricsBefore = socket_counter_metrics(),

    create_pdp_context(aaa_reject, Config),

    MetricsAfter = socket_counter_metrics(),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, create_pdp_context_request),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, user_authentication_failed), % In response
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_gx_fail() ->
    [{doc, "Check Gx failure on Create PDP Context Request"}].
create_pdp_context_request_gx_fail(Config) ->
    MetricsBefore = socket_counter_metrics(),

    create_pdp_context(gx_fail, Config),

    MetricsAfter = socket_counter_metrics(),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, create_pdp_context_request),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, system_failure), % In response
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_gy_fail() ->
    [{doc, "Check Gy failure on Create PDP Context Request"}].
create_pdp_context_request_gy_fail(Config) ->
    PoolId = [<<"pool-A">>, ipv4, "10.180.0.1"],

    ?match_metric(prometheus_gauge, ergw_local_pool_free, PoolId, 65534),
    ?match_metric(prometheus_gauge, ergw_local_pool_used, PoolId, 0),

    MetricsBefore = socket_counter_metrics(),

    create_pdp_context(gy_fail, Config),

    MetricsAfter = socket_counter_metrics(),
    ?equal([], outstanding_requests()),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    ?match_metric(prometheus_gauge, ergw_local_pool_free, PoolId, 65534),
    ?match_metric(prometheus_gauge, ergw_local_pool_used, PoolId, 0),

    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, create_pdp_context_request),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, system_failure), % In response

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_rf_fail() ->
    [{doc, "Check Rf failure on Create PDP Context Request"}].
create_pdp_context_request_rf_fail(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),
    delete_pdp_context(GtpC),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_invalid_apn() ->
    [{doc, "Check invalid APN return on Create PDP Context Request"}].
create_pdp_context_request_invalid_apn(Config) ->
    MetricsBefore = socket_counter_metrics(),

    create_pdp_context(invalid_apn, Config),

    MetricsAfter = socket_counter_metrics(),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, create_pdp_context_request),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, missing_or_unknown_apn), % In response
    ok.

%%--------------------------------------------------------------------

create_pdp_context_request_pool_exhausted() ->
    [{doc, "Dynamic IP pool exhausted"}].
create_pdp_context_request_pool_exhausted(Config) ->
    ok = meck:expect(ergw_gsn_lib, allocate_ips,
		     fun(AllocInfo, APNOpts, SOpts, DualAddressBearerFlag, Context) ->
			     try
				 meck:passthrough([AllocInfo, APNOpts, SOpts, DualAddressBearerFlag, Context])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),
    ok = meck:expect(ergw_local_pool, wait_pool_response,
		     fun({error, empty} = Error) ->
			     Error;
			(ReqId) ->
			     meck:passthrough([ReqId])
		     end),

    MetricsBefore = socket_counter_metrics(),

    ok = meck:expect(ergw_local_pool, send_pool_request,
		     fun(_ClientId, {_, ipv6, _, _}) ->
			     {error, empty};
			(ClientId, Req) ->
			     meck:passthrough([ClientId, Req])
		     end),
    create_pdp_context(pool_exhausted, Config),

    MetricsAfter = socket_counter_metrics(),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, create_pdp_context_request),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, all_dynamic_pdp_addresses_are_occupied), % In response

    ok = meck:expect(ergw_local_pool, send_pool_request,
		     fun(_ClientId, {_, ipv4, _, _}) ->
			     {error, empty};
			(ClientId, Req) ->
			     meck:passthrough([ClientId, Req])
		     end),
    create_pdp_context(pool_exhausted, Config),

    ok = meck:expect(ergw_local_pool, send_pool_request,
		     fun(_ClientId, _Req) ->
			     {error, empty}
		     end),
    create_pdp_context(pool_exhausted, Config),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_dotted_apn() ->
    [{doc, "Check dotted APN return on Create PDP Context Request"}].
create_pdp_context_request_dotted_apn(Config) ->
    {GtpC, _, _} = create_pdp_context(dotted_apn, Config),
    delete_pdp_context(GtpC),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
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
path_failure() ->
    [{doc, "Check that Create PDP Context works and "
      "that a path failure (Echo timeout) terminates the session"}].
path_failure(Config) ->
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
    PoolId = [<<"pool-A">>, ipv4, "10.180.0.1"],

    ?match_metric(prometheus_gauge, ergw_local_pool_free, PoolId, 65534),
    ?match_metric(prometheus_gauge, ergw_local_pool_used, PoolId, 0),

    MetricsBefore = socket_counter_metrics(),
    {GtpC, _, _} = create_pdp_context(Config),
    MetricsAfter = socket_counter_metrics(),

    ?match_metric(prometheus_gauge, ergw_local_pool_free, PoolId, 65533),
    ?match_metric(prometheus_gauge, ergw_local_pool_used, PoolId, 1),

    delete_pdp_context(GtpC),

    ?match({_, {<<_:64, 1:64>>, _}}, GtpC#gtpc.ue_ip),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, create_pdp_context_request),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, request_accepted), % In response

    ?match_metric(prometheus_gauge, ergw_local_pool_free, PoolId, 65534),
    ?match_metric(prometheus_gauge, ergw_local_pool_used, PoolId, 0),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
change_reporting_indication() ->
    [{doc, "Check MS Info Change Reporting support indication in Create PDP Context"}].
change_reporting_indication(Config) ->
    {GtpC, _, _} = create_pdp_context(crsi, Config),
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

    ergw_test_sx_up:send('pgw-u01', make_error_indication_report(GtpC)),

    ct:sleep(100),
    delete_pdp_context(not_found, GtpC),

    [?match(#{tunnels := 0}, X) || X <- ergw_api:peer(all)],

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
pdp_context_request_bearer_types() ->
    [{doc, "Create different IP bearers against APNs with restrictions/preferences"}].

pdp_context_request_bearer_types(Config) ->
    ok = meck:expect(ergw_gsn_lib, allocate_ips,
		     fun(AllocInfo, APNOpts, SOpts, DualAddressBearerFlag, Context) ->
			     try
				 meck:passthrough([AllocInfo, APNOpts, SOpts, DualAddressBearerFlag, Context])
			     catch
				 throw:#ctx_err{} = CtxErr ->
				     meck:exception(throw, CtxErr)
			     end
		     end),

    {GtpC1, _, _} = create_pdp_context({ipv4, false, default}, Config),
    delete_pdp_context(GtpC1),

    {GtpC2, _, _} = create_pdp_context({ipv6, false, default}, Config),
    delete_pdp_context(GtpC2),

    {GtpC3, _, _} = create_pdp_context({ipv4v6, true, default}, Config),
    delete_pdp_context(GtpC3),

    {GtpC4, _, _} = create_pdp_context({ipv4v6, true, v4only}, Config),
    delete_pdp_context(GtpC4),

    {GtpC5, _, _} = create_pdp_context({ipv4v6, true, v6only}, Config),
    delete_pdp_context(GtpC5),

    {GtpC6, _, _} = create_pdp_context({ipv4,   false, prefV4}, Config),
    delete_pdp_context(GtpC6),

    {GtpC7, _, _} = create_pdp_context({ipv4,   false, prefV6}, Config),
    delete_pdp_context(GtpC7),

    {GtpC8, _, _} = create_pdp_context({ipv6,   false, prefV4}, Config),
    delete_pdp_context(GtpC8),

    {GtpC9, _, _} = create_pdp_context({ipv6,   false, prefV6}, Config),
    delete_pdp_context(GtpC9),

    {GtpC10, _, _} = create_pdp_context({ipv4v6, false, v4only}, Config),
    delete_pdp_context(GtpC10),

    {GtpC11, _, _} = create_pdp_context({ipv4v6, false, v6only}, Config),
    delete_pdp_context(GtpC11),

    {GtpC12, _, _} = create_pdp_context({ipv4v6, false, prefV4}, Config),
    delete_pdp_context(GtpC12),

    {GtpC13, _, _} = create_pdp_context({ipv4v6, false, prefV6}, Config),
    delete_pdp_context(GtpC13),

    create_pdp_context({ipv4, false, v6only}, Config),
    create_pdp_context({ipv6, false, v4only}, Config),

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
    ?equal(timeout, recv_pdu(GtpC1, undefined, 100, fun(Why) -> Why end)),

    GtpC2 = Send(ms_info_change_notification_request, simple, GtpC1),
    ?equal(timeout, recv_pdu(GtpC2, undefined, 100, fun(Why) -> Why end)),

    GtpC3 = Send(ms_info_change_notification_request, without_tei, GtpC2),
    ?equal(timeout, recv_pdu(GtpC3, undefined, 100, fun(Why) -> Why end)),

    delete_pdp_context(GtpC3),

    ?match(3, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_resend() ->
    [{doc, "Check that a retransmission of a Create PDP Context Request works"}].
create_pdp_context_request_resend(Config) ->
    CntId = [irx, rx, v1, create_pdp_context_request],
    DupId = [irx, v1, create_pdp_context_request],

    Cnt0 = get_metric(prometheus_counter, gtp_c_socket_messages_processed_total, CntId, 0),
    Dup0 = get_metric(prometheus_counter, gtp_c_socket_messages_duplicates_total, DupId, 0),

    {GtpC, Msg, Response} = create_pdp_context(Config),
    ?match_metric(prometheus_counter, gtp_c_socket_messages_processed_total, CntId, Cnt0 + 1),
    ?equal(Response, send_recv_pdu(GtpC, Msg)),
    ?equal([], outstanding_requests()),

    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),

    ?match_metric(prometheus_counter, gtp_c_socket_messages_duplicates_total, DupId, Dup0 + 1),
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
update_pdp_context_request_ra_update() ->
    [{doc, "Check Update PDP Context with Routing Area Update"}].
update_pdp_context_request_ra_update(Config) ->
    UpdateCount = 4,

    {GtpC1, _, _} = create_pdp_context(Config),

    GtpC2 =
	lists:foldl(
	  fun(_, GtpCtxIn) ->
		  {GtpCtxOut, _, _} = update_pdp_context(ra_update, GtpCtxIn),
		  ?equal([], outstanding_requests()),
		  ct:sleep(1000),
		  GtpCtxOut
	  end, GtpC1, lists:seq(1, UpdateCount)),

    delete_pdp_context(GtpC2),

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
update_pdp_context_request_rat_update() ->
    [{doc, "Check Update PDP Context with Routing Area Update and RAT change"}].
update_pdp_context_request_rat_update(Config) ->
    UpdateCount = 4,

    {GtpC1, _, _} = create_pdp_context(Config),

    GtpC2 =
	lists:foldl(
	  fun(_, GtpCtxIn) ->
		  {GtpCtxOut, _, _} = update_pdp_context(ra_update, GtpCtxIn),
		  ?equal([], outstanding_requests()),
		  ct:sleep(1000),
		  GtpCtxOut
	  end, GtpC1, lists:seq(1, UpdateCount)),

    {GtpC3, _, _} = update_pdp_context(ra_update, GtpC2#gtpc{rat_type = 2}),
    ?equal([], outstanding_requests()),
    ct:sleep(1000),

    delete_pdp_context(GtpC3),

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
update_pdp_context_request_tei_update() ->
    [{doc, "Check Update PDP Context with TEID update (e.g. SGSN change)"}].
update_pdp_context_request_tei_update(Config) ->
    {GtpC1, _, _} = create_pdp_context(Config),
    #gtpc{local_ip = IP} = GtpC1,
    {GtpC2, _, _} = update_pdp_context(tei_update,
				       GtpC1#gtpc{
					 local_ip = setelement(1, IP, element(1, IP) + 1)}),
    ?equal([], outstanding_requests()),
    ct:sleep(1000),
    delete_pdp_context(GtpC2),

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
    ?match(#sxsmreq_flags{sndem = 0},
	   maps:get(sxsmreq_flags, UFP, #sxsmreq_flags{sndem = 0})),

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

    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
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

    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
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

    wait4tunnels(?TIMEOUT),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_overload() ->
    [{doc, "Check that the overload protection works"}].
create_pdp_context_overload(Config) ->
    MetricsBefore = socket_counter_metrics(),

    create_pdp_context(overload, Config),

    MetricsAfter = socket_counter_metrics(),
    ?equal([], outstanding_requests()),
    meck_validate(Config),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, create_pdp_context_request),
    socket_counter_metrics_ok(MetricsBefore, MetricsAfter, no_resources_available), % In response
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
    GtpPort = ergw_socket_reg:lookup('gtp-c', 'irx'),
    {GtpC, _, _} = create_pdp_context(Config),
    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    {T0, Q0} = ergw_gtp_c_socket:get_response_q(GtpPort),
    ?match(X when X /= 0, length(T0)),
    ?match(X when X /= 0, length(Q0)),

    ct:sleep({seconds, 120}),

    {T1, Q1} = ergw_gtp_c_socket:get_response_q(GtpPort),
    ?equal(0, length(T1)),
    ?equal(0, length(Q1)),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------

session_options() ->
    [{doc, "Check that all required session options are present"}].
session_options(Config) ->
    {GtpC, _, _} = create_pdp_context(ipv4v6, Config),

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
		   '3GPP-Allocation-Retention-Priority' => 2,
		   '3GPP-Selection-Mode' => 0,
		   '3GPP-IMEISV' => <<"1234567890123456">>,
		   '3GPP-GGSN-MCC-MNC' => <<"00101">>,
		   '3GPP-NSAPI' => 5,
		   '3GPP-GPRS-Negotiated-QoS-Profile' => '_',
		   '3GPP-IMSI-MCC-MNC' => <<"11111">>,
		   '3GPP-PDP-Type' => 'IPv4v6',
		   '3GPP-MSISDN' => ?MSISDN,
		   '3GPP-RAT-Type' => 1,
		   '3GPP-IMSI' => ?IMSI,
		   '3GPP-User-Location-Info' => '_',

		   'QoS-Information' =>
		       #{
			 'QoS-Class-Identifier' => 6,
			 'Max-Requested-Bandwidth-DL' => '_',
			 'Max-Requested-Bandwidth-UL' => '_',
			 'Guaranteed-Bitrate-DL' => 0,
			 'Guaranteed-Bitrate-UL' => 0,
			 'Allocation-Retention-Priority' =>
			     #{'Priority-Level' => 2,
			       'Pre-emption-Capability' => 1,
			       'Pre-emption-Vulnerability' => 0},
			 'APN-Aggregate-Max-Bitrate-UL' => '_',
			 'APN-Aggregate-Max-Bitrate-DL' => '_'
			},

		   credits => '_',

		   'Session-Id' => '_',
		   'Multi-Session-Id' => '_',
		   'Diameter-Session-Id' => '_',
		   'Called-Station-Id' => unicode:characters_to_binary(lists:join($., ?'APN-EXAMPLE')),
		   'Calling-Station-Id' => ?MSISDN,
		   'Service-Type' => 'Framed-User',
		   'Framed-Protocol' => 'GPRS-PDP-Context',
		   'Username' => '_',
		   'Password' => '_',

		   'PDP-Context-Type' => primary,
		   'Framed-IP-Address' => {10, 180, '_', '_'},
		   'Framed-IPv6-Prefix' => {{16#8001, 0, 1, '_', '_', '_', '_', '_'},64},

		   'Charging-Rule-Base-Name' => <<"m2m0001">>,

		   'Accounting-Start' => '_',
		   'Session-Start' => '_',
		   'Acct-Interim-Interval' => 600
		  },
    ?match_map(Expected, Opts),

    delete_pdp_context(GtpC),

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
    {GtpC, _, _} = create_pdp_context(Config),

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

    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
sx_ondemand() ->
    [{doc, "Connect to Sx Node on demand"}].
sx_ondemand(Config) ->
    ?equal(1, maps:size(ergw_sx_node_reg:available())),

    {GtpC, _, _} = create_pdp_context(async_sx, Config),
    delete_pdp_context(GtpC),

    ?equal(2, maps:size(ergw_sx_node_reg:available())),
    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT).

%%--------------------------------------------------------------------

gy_validity_timer() ->
    [{doc, "Check Validity-Timer attached to MSCC"}].
gy_validity_timer(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),
    ct:sleep({seconds, 10}),
    delete_pdp_context(GtpC),

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

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),
    {ok, PCtx} = gtp_context:test_cmd(Server, pfcp_ctx),

    [SER|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) ->false
		end, ergw_test_sx_up:history('pgw-u01')),

    URR = lists:sort(maps:get(create_urr, SER#pfcp.ie)),
    ?match(
       [%% IP-CAN offline URR
	#create_urr{
	   group =
	       #{urr_id := #urr_id{id = _},
		 measurement_method :=
		     #measurement_method{volum = 1, durat = 1},
		 reporting_triggers := #reporting_triggers{}
		}
	  },
	%% offline charging URR
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
    delete_pdp_context(GtpC),

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
	 'Termination-Cause' => '_',
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

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),
    {ok, PCtx} = gtp_context:test_cmd(Server, pfcp_ctx),

    [SER|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) ->false
		end, ergw_test_sx_up:history('pgw-u01')),

    {[URR], [Linked]} =
	lists:partition(fun(X) -> not maps:is_key(linked_urr_id, X#create_urr.group) end,
			maps:get(create_urr, SER#pfcp.ie)),
    ?match_map(
       %% offline charging URR
       #{urr_id => #urr_id{id = '_'},
	 measurement_method =>
	     #measurement_method{volum = 1, durat = 1},
	 measurement_period =>
	     #measurement_period{period = Interim},
	 reporting_triggers =>
	     #reporting_triggers{periodic_reporting = 1}
	}, URR#create_urr.group),

    ?match_map(
       %% offline charging URR
       #{urr_id => #urr_id{id = '_'},
	 linked_urr_id => #linked_urr_id{id = '_'},
	 measurement_method =>
	     #measurement_method{volum = 1},
	 reporting_triggers =>
	     #reporting_triggers{linked_usage_reporting = 1}
	}, Linked#create_urr.group),
    ?equal(false, maps:is_key(measurement_period, Linked#create_urr.group)),

    StartTS = calendar:datetime_to_gregorian_seconds({{2020,2,20},{13,24,00}})
	- ?SECONDS_FROM_0_TO_1970,

    Report =
	[
	 #volume_measurement{total = 5, uplink = 2, downlink = 3},
	 #time_of_first_packet{time = ergw_sx_node:seconds_to_sntp_time(StartTS + 24)},
	 #time_of_last_packet{time = ergw_sx_node:seconds_to_sntp_time(StartTS + 180)},
	 #start_time{time = ergw_sx_node:seconds_to_sntp_time(StartTS)},
	 #end_time{time = ergw_sx_node:seconds_to_sntp_time(StartTS + 600)},
	 #tp_packet_measurement{total = 12, uplink = 5, downlink = 7}],
    ReportFun =
	fun({Id, Type}, Reports) ->
		Trigger =
		    case Type of
			{offline, RG} when is_integer(RG) ->
			    #usage_report_trigger{liusa = 1};
			{offline, 'IP-CAN'} ->
			    #usage_report_trigger{perio = 1}
		    end,
		[#usage_report_srr{group = [#urr_id{id = Id}, Trigger|Report]}|Reports]
	end,
    MatchSpec = ets:fun2ms(fun(Id) -> Id end),
    ergw_test_sx_up:usage_report('pgw-u01', PCtx, MatchSpec, ReportFun),

    ct:sleep(100),
    delete_pdp_context(GtpC),

    H = meck:history(ergw_aaa_session),
    SInv =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke, [_, _, {rf, _}, _]}, _}) ->
		  true;
	     ({_, {ergw_aaa_session, invoke, [_, _, stop, _]}, _}) ->
		  true;
	     (_) ->
		  false
	  end, H),
    ?match(X when X == 4, length(SInv)),

    [Start, SInterim, AcctStop, Stop] =
	lists:map(fun({_, {_, _, [_, SOpts, _, _]}, _}) -> SOpts end, SInv),

    ?equal(false, maps:is_key('service_data', Start)),
    ?equal(false, maps:is_key('service_data', AcctStop)),
    ?equal(true, maps:is_key('service_data', Stop)),

    ?equal(false, maps:is_key('traffic_data', Start)),
    ?equal(false, maps:is_key('traffic_data', AcctStop)),
    ?equal(true, maps:is_key('traffic_data', Stop)),

    SInterimSD = maps:get(service_data, SInterim),
    ?match([_], SInterimSD),
    ?match_map(
       #{'Accounting-Input-Octets' => ['_'],
	 'Accounting-Output-Octets' => ['_'],
	 'Change-Condition' => [4],
	 'Change-Time'      => [{{2020,2,20},{13,34,00}}],  %% StartTS + 600s
	 'Time-First-Usage' => [{{2020,2,20},{13,24,24}}],  %% StartTS +  24s
	 'Time-Last-Usage'  => [{{2020,2,20},{13,27,00}}]   %% StartTS + 180s
	}, hd(SInterimSD)),
    SInterimTD = maps:get(traffic_data, SInterim),
    ?match([_], SInterimSD),
    ?match_map(
       #{'3GPP-Charging-Id' => ['_'],
	 'Accounting-Input-Octets' => ['_'],
	 'Accounting-Output-Octets' => ['_'],
	 'Change-Condition' => [4],
	 'Change-Time'      => [{{2020,2,20},{13,34,00}}]   %% StartTS + 600s
	}, hd(SInterimTD)),

    StopSD = maps:get(service_data, Stop),
    ?match([_], StopSD),
    ?match_map(
       #{'Accounting-Input-Octets' => ['_'],
	 'Accounting-Output-Octets' => ['_'],
	 'Change-Condition' => [0]
	}, hd(StopSD)),
    StopTD = maps:get(traffic_data, Stop),
    ?match([_], StopTD),
    ?match_map(
       #{'3GPP-Charging-Id' => ['_'],
	 'Accounting-Input-Octets' => ['_'],
	 'Accounting-Output-Octets' => ['_'],
	 'Change-Condition' => [0]
	}, hd(StopTD)),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------

simple_ocs() ->
    [{doc, "Test Gy a simple interaction"}].
simple_ocs(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),
    {ok, PCtx} = gtp_context:test_cmd(Server, pfcp_ctx),

    [SER|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) ->false
		end, ergw_test_sx_up:history('pgw-u01')),

    [URR1, URR2, URR3] = lists:sort(maps:get(create_urr, SER#pfcp.ie)),
    ?match_map(
       %% IP-CAN offline URR
       #{urr_id => #urr_id{id = '_'},
	 measurement_method =>
	     #measurement_method{volum = 1, durat = 1},
	 reporting_triggers => #reporting_triggers{}
	}, URR1#create_urr.group),

    ?match_map(
       %% offline charging URR
       #{urr_id => #urr_id{id = '_'},
	 measurement_method =>
	     #measurement_method{volum = 1},
	 reporting_triggers =>
	     #reporting_triggers{linked_usage_reporting = 1}
	}, URR2#create_urr.group),

    %% online charging URR
    ?match_map(
       #{urr_id => #urr_id{id = '_'},
	 measurement_method =>
	     #measurement_method{volum = 1, durat = 1},
	 reporting_triggers =>
	     #reporting_triggers{
		linked_usage_reporting = 1,
		time_quota = 1,   time_threshold = 1,
		volume_quota = 1, volume_threshold = 1},
	 time_quota =>
	     #time_quota{quota = 3600},
	 time_threshold =>
	     #time_threshold{threshold = 3540},
	 volume_quota =>
	     #volume_quota{total = 102400},
	 volume_threshold =>
	     #volume_threshold{total = 92160}
	}, URR3#create_urr.group),

    MatchSpec = ets:fun2ms(fun({Id, {'online', _}}) -> Id end),
    Report =
	[#usage_report_trigger{volqu = 1},
	 #volume_measurement{total = 5, uplink = 2, downlink = 3},
	 #tp_packet_measurement{total = 12, uplink = 5, downlink = 7}],
    ergw_test_sx_up:usage_report('pgw-u01', PCtx, MatchSpec, Report),

    ct:sleep(100),
    delete_pdp_context(GtpC),

    H = meck:history(ergw_aaa_session),
    CCR =
	lists:filter(
	  fun({_, {ergw_aaa_session, invoke, [_, _, {gy,_}, _]}, _}) ->
		  true;
	     ({_, {ergw_aaa_session, invoke, [_, _, stop, _]}, _}) ->
		  true;
	     (_) ->
		  false
	  end, H),
    ?match(X when X == 4, length(CCR)),

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
	  '3GPP-Allocation-Retention-Priority' => 2,
	  %% '3GPP-Charging-Id' => '?????',
	  '3GPP-GGSN-MCC-MNC' => <<"00101">>,
	  '3GPP-GPRS-Negotiated-QoS-Profile' => '_',
	  %% '3GPP-IMEISV' => '?????',
	  '3GPP-IMEISV' => <<"1234567890123456">>,
	  %% '3GPP-IMSI' => '?????',
	  '3GPP-IMSI' => ?IMSI,
	  '3GPP-IMSI-MCC-MNC' => <<"11111">>,
	  %% '3GPP-MS-TimeZone' => '?????',
	  '3GPP-MSISDN' => ?MSISDN,
	  '3GPP-NSAPI' => 5,
	  '3GPP-PDP-Type' => 'IPv4v6',
	  '3GPP-RAT-Type' => 1,
	  '3GPP-Selection-Mode' => 0,
	  %% '3GPP-SGSN-MCC-MNC' => '?????',
	  '3GPP-User-Location-Info' => '_',
	  'Acct-Interim-Interval' => 600,
	  'Bearer-Operation' => '_',
	  'Called-Station-Id' => unicode:characters_to_binary(lists:join($., ?'APN-EXAMPLE')),
	  'Calling-Station-Id' => ?MSISDN,
	  'Charging-Rule-Base-Name' => <<"m2m0001">>,
	  'Diameter-Session-Id' => '_',
	  %% 'ECGI' => '?????',
	  %% 'Event-Trigger' => '?????',
	  'Framed-IP-Address' => {10, 180, '_', '_'},
	  'Framed-IPv6-Prefix' => {{16#8001, 0, 1, '_', '_', '_', '_', '_'},64},
	  'Framed-Protocol' => 'GPRS-PDP-Context',
	  'Multi-Session-Id' => '_',
	  'NAS-Identifier' => <<"NAS-Identifier">>,
	  'Node-Id' => <<"PGW-001">>,
	  'PDP-Context-Type' => primary,
	  'QoS-Information' =>
	      #{
		'QoS-Class-Identifier' => 6,
		'Max-Requested-Bandwidth-DL' => '_',
		'Max-Requested-Bandwidth-UL' => '_',
		'Guaranteed-Bitrate-DL' => 0,
		'Guaranteed-Bitrate-UL' => 0,
		'Allocation-Retention-Priority' =>
		    #{'Priority-Level' => 2,
		      'Pre-emption-Capability' => 1,
		      'Pre-emption-Vulnerability' => 0},
		'APN-Aggregate-Max-Bitrate-UL' => '_',
		'APN-Aggregate-Max-Bitrate-DL' => '_'
	       },
	  %% 'Requested-IP-Address' => '?????',
	  'SAI' => '_',
	  'Service-Type' => 'Framed-User',
	  'Session-Id' => '_',
	  'Session-Start' => '_',
	  %% 'TAI' => '?????',
	  'Username' => '_'
	 },
    ?match_map(Expected, Session),

    [Start, SInterim, AcctStop, Stop] =
	lists:map(fun({_, {_, _, [_, SOpts, _, _]}, _}) -> SOpts end, CCR),

    ?equal(false, maps:is_key('credits', AcctStop)),
    ?equal(false, maps:is_key('used_credits', AcctStop)),

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
       #{'Termination-Cause' => normal,
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

gy_ccr_asr_overlap() ->
    [{doc, "Test that ASR is answered when it arrives during CCR-T"}].
gy_ccr_asr_overlap(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
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
    delete_pdp_context(GtpC),

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
    ?match(X when X == 2, length(CCR)),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    ok.

%%--------------------------------------------------------------------

volume_threshold() ->
    [{doc, "Test Gy interaction when volume threshold is reached"}].
volume_threshold(Config) ->
    {GtpC, _, _} = create_pdp_context(Config),

    [#{'Process' := Pid}|_] = ergw_api:tunnel(all),
    #{pfcp:= PCtx} = gtp_context:info(Pid),

    MatchSpec = ets:fun2ms(fun({Id, {'online', _}}) -> Id end),

    ergw_test_sx_up:usage_report('pgw-u01', PCtx, MatchSpec, [#usage_report_trigger{volth = 1}]),
    ergw_test_sx_up:usage_report('pgw-u01', PCtx, MatchSpec, [#usage_report_trigger{volqu = 1}]),

    ct:sleep({seconds, 1}),

    delete_pdp_context(GtpC),

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
    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
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

    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_asr() ->
    [{doc, "Check that ASR on Gx terminates the session"}].
gx_asr(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),

    ResponseFun = fun(_, _, _, _) -> ok end,
    Server ! #aaa_request{from = ResponseFun, procedure = {gx, 'ASR'},
			  session = #{}, events = []},

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
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
    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
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

    delete_pdp_context(GtpC),

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

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gy_asr() ->
    [{doc, "Check that ASR on Gy terminates the session"}].
gy_asr(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),

    ResponseFun = fun(_, _, _, _) -> ok end,
    Server ! #aaa_request{from = ResponseFun, procedure = {gy, 'ASR'},
			  session = #{}, events = []},

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
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

    {GtpC, _, _} = create_pdp_context(Config),

    %% wait up to 10 secs for DPCR
    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_invalid_charging_rulebase() ->
    [{doc, "Check the reaction to a Gx CCA-I with an invalid Charging-Rule-Base-Name"}].
gx_invalid_charging_rulebase(Config) ->
    ClientIP = proplists:get_value(client_ip, Config),
    {GtpC, _, _} = create_pdp_context(Config),

    ?match([#{tunnels := 1}], [X || X = #{version := Version} <- ergw_api:peer(ClientIP),
				    Version == v1]),

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

    delete_pdp_context(GtpC),

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
    {GtpC, _, _} = create_pdp_context(Config),

    ?match([#{tunnels := 1}], [X || X = #{version := Version} <- ergw_api:peer(ClientIP),
				    Version == v1]),

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

    delete_pdp_context(GtpC),

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
    {GtpC, _, _} = create_pdp_context(Config),
    %% The meck wait timeout (400 ms) has to be more than then the Idle-Timeout
    ok = meck:wait(?HUT, handle_event,
		   [{timeout, context_idle}, stop_session, '_', '_'], 3000),

    %% Timeout triggers a delete_pdp_context_request towards the SGSN
    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
up_inactivity_timer() ->
    [{doc, "Test expiry of the User Plane Inactivity Timer"}].
up_inactivity_timer(Config) ->
    Interim = rand:uniform(1800) + 1800,
    AAAReply = #{'Acct-Interim-Interval' => Interim},

    ok = meck:expect(
	   ergw_aaa_session, invoke,
	   fun (Session, SessionOpts, Procedure = authenticate, Opts) ->
		   {_, SIn, EvIn} =
		       meck:passthrough([Session, SessionOpts, Procedure, Opts]),
		   {SOut, EvOut} =
		       ergw_aaa_radius:to_session(authenticate, {SIn, EvIn},
						  AAAReply),
		   {ok, SOut, EvOut};
	       (Session, SessionOpts, Procedure, Opts) ->
		   meck:passthrough([Session, SessionOpts, Procedure, Opts])
	   end),

    create_pdp_context(Config),
    {_Handler, Server} = gtp_context_reg:lookup({'irx', {imsi, ?'IMSI', 5}}),
    true = is_pid(Server),
    {ok, PCtx} = gtp_context:test_cmd(Server, pfcp_ctx),
    [SER|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) ->false
		end, ergw_test_sx_up:history('pgw-u01')),

    ?match(#user_plane_inactivity_timer{},
	   maps:get(user_plane_inactivity_timer, SER#pfcp.ie)),

    ergw_test_sx_up:up_inactivity_timer_expiry('pgw-u01', PCtx),

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

load_ocs_config(Initial, Update) ->
    load_aaa_answer_config([{{gy, 'CCR-Initial'}, Initial},
			    {{gy, 'CCR-Update'},  Update}]).

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

socket_counter_metrics() ->
    Metrics =
	lists:foldl(
	  fun(Key, M) ->
		  V0 = prometheus_counter:values(default, Key),
		  V1 = lists:map(
			 fun({K, V}) -> {[Tag || {_, Tag} <- K], V} end, V0),
		  M ++ V1
	  end, [],
	  [gtp_c_socket_messages_processed_total,
	   gtp_c_socket_messages_duplicates_total,
	   gtp_c_socket_messages_retransmits_total,
	   gtp_c_socket_messages_timeouts_total,
	   gtp_c_socket_messages_replies_total]),
    [X || X = {Tag, _} <- Metrics,
	  not lists:member(echo_request, Tag) andalso not lists:member(echo_response, Tag)].

socket_counter_metrics_ok(MetricsBefore, MetricsAfter, Part) ->
	%% Remove the ones that have not changed.
	ValueBefore = socket_counter_metrics_ok_value(MetricsBefore -- MetricsAfter, Part),
	ValueAfter = socket_counter_metrics_ok_value(MetricsAfter -- MetricsBefore, Part),
	?equal(1, ValueAfter - ValueBefore).

socket_counter_metrics_ok_value(Metrics, Part) ->
	socket_counter_metrics_ok_value_0([Value || {Name, Value} <- Metrics, lists:member(Part, Name)]).

socket_counter_metrics_ok_value_0([Value]) -> Value;
socket_counter_metrics_ok_value_0([]) -> 0.

%% Set APN key data
set_apn_key(Key, Value) ->
    {ok, APNs0} = application:get_env(ergw, apns),
    Upd = fun(_APN, Val_map) -> maps:put(Key, Value, Val_map) end,
    APNs = maps:map(Upd, APNs0),
    ok = application:set_env(ergw, apns, APNs).
