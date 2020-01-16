%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(tdf_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("kernel/include/logger.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
%%-include("ergw_pgw_test_lib.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-define(TIMEOUT, 2000).
-define(HUT, tdf).				%% Handler Under Test

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
		  [{'cp-socket', [{type, 'gtp-u'},
				  {vrf, cp},
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
		  [{'h1', [{handler, ?HUT},
			   {protocol, ip},
			   {apn, ?'APN-EXAMPLE'},
			   {nodes, ["topon.sx.prox01.$ORIGIN"]},
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
		       "topon.tdf.$ORIGIN"},
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}, {"x-3gpp-upf","x-sxc"}],
		       "topon.sx.prox01.$ORIGIN"},

		      %% A/AAAA record alternatives
		      {"topon.tdf.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.prox01.$ORIGIN", ?MUST_BE_UPDATED, []}
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
		     {ip_pools, ['pool-A']}]},
		   {[<<"exa">>, <<"mple">>, <<"net">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]},
		   {[<<"APN1">>],
		    [{vrf, sgi},
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
		       {epc, [{features, ['TDF-Source', 'Access']}]},
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
	[{[sockets, 'cp-socket', ip], localhost},
	 {[sx_socket, ip], localhost},
	 {[node_selection, {default, 2}, 2, "topon.tdf.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox01.$ORIGIN"],
	  {fun node_sel_update/2, tdf_u_sx}}
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
    [setup_upf,  %% <- keep this first
     simple_session,
     gy_validity_timer,
     simple_aaa,
     simple_ofcs,
     simple_ocs,
     gy_ccr_asr_overlap,
     volume_threshold,
     gx_asr,
     gx_rar,
     gy_asr,
     gx_invalid_charging_rulebase,
     gx_invalid_charging_rule,
     gx_rar_gy_interaction,
     redirect_info,
     tdf_app_id
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

setup_per_testcase(Config) ->
    setup_per_testcase(Config, true).

setup_per_testcase(Config, ClearSxHist) ->
    ct:pal("Sockets: ~p", [ergw_gtp_socket_reg:all()]),
    {ok, AppsCfg} = application:get_env(ergw_aaa, apps),
    meck_reset(Config),
    reconnect_all_sx_nodes(),
    ClearSxHist andalso ergw_test_sx_up:history('tdf-u', true),
    [{seid, tdf_seid()},
     {tdf_node, tdf_node_pid()},
     {aaa_cfg, AppsCfg} | Config].

init_per_testcase(setup_upf, Config) ->
    {ok, AppsCfg} = application:get_env(ergw_aaa, apps),
    meck_reset(Config),
    ergw_test_sx_up:history('tdf-u', true),
    reconnect_all_sx_nodes(),

    [{seid, tdf_seid()},
     {tdf_node, tdf_node_pid()},
     {aaa_cfg, AppsCfg} | Config];
init_per_testcase(gy_validity_timer, Config0) ->
    Config = setup_per_testcase(Config0),
    set_online_charging(true),
    load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS-VT'},
			    {{gy, 'CCR-Update'},  'Update-OCS-VT'}]),
    Config;
init_per_testcase(TestCase, Config0)
  when TestCase == simple_ocs;
       TestCase == gy_ccr_asr_overlap;
       TestCase == volume_threshold ->
    Config = setup_per_testcase(Config0),
    set_online_charging(true),
    load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS'},
			    {{gy, 'CCR-Update'},  'Update-OCS'}]),
    Config;
init_per_testcase(TestCase, Config0)
  when TestCase == gx_rar_gy_interaction ->
    Config = setup_per_testcase(Config0),
    set_online_charging(true),
    load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS'},
			    {{gy, 'CCR-Update'},  'Update-OCS-GxGy'}]),
    Config;
init_per_testcase(gx_invalid_charging_rulebase, Config0) ->
    Config = setup_per_testcase(Config0),
    load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-Fail-1'}]),
    Config;
init_per_testcase(gx_invalid_charging_rule, Config0) ->
    Config = setup_per_testcase(Config0),
    load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-Fail-2'}]),
    Config;
init_per_testcase(redirect_info, Config0) ->
    Config = setup_per_testcase(Config0),
    load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-Redirect'}]),
    Config;
init_per_testcase(tdf_app_id, Config0) ->
    Config = setup_per_testcase(Config0),
    load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-TDF-App'}]),
    Config;
init_per_testcase(_, Config) ->
    setup_per_testcase(Config).

end_per_testcase(Config) ->
    AppsCfg = proplists:get_value(aaa_cfg, Config),
    ok = application:set_env(ergw_aaa, apps, AppsCfg),
    set_online_charging(false),
    ok.

end_per_testcase(TestCase, Config)
  when TestCase == gy_ccr_asr_overlap;
       TestCase == simple_aaa;
       TestCase == simple_ofcs ->
    ok = meck:delete(ergw_aaa_session, invoke, 4),
    end_per_testcase(Config),
    Config;
end_per_testcase(_, Config) ->
    end_per_testcase(Config),
    Config.

%%--------------------------------------------------------------------

setup_upf() ->
    [{doc, "Test initial UPF rules installation"}].
setup_upf(Config) ->
    [ASR0, SER0 |_] = ergw_test_sx_up:history('tdf-u'),
    ASR = pfcp_packet:to_map(ASR0),
    ?match(#pfcp{type = association_setup_request}, ASR),

    SER = pfcp_packet:to_map(SER0),
    ?match(#pfcp{type = session_establishment_request}, SER),

    #{create_pdr := PDRs,
      create_far := FARs,
      create_urr := URR
     } = SER#pfcp.ie,
    [PDR|_] = lists:filter(
		fun(#create_pdr{group = #{urr_id := _}}) -> true;
		   (_) ->false
		end, PDRs),
    [FAR|_] = lists:filter(
		fun(#create_far{
		       group = #{apply_action := #apply_action{drop = 1}}}) -> true;
		   (_) ->false
		end, FARs),
    #create_pdr{
       group = #{far_id := FARId, urr_id := URRId}} = PDR,
    ?match(#create_far{
	      group =
		  #{far_id := FARId}}, FAR),
    ?match(#create_urr{
	      group =
		  #{urr_id := URRId,
		    measurement_method :=
			#measurement_method{event = 1},
		    reporting_triggers :=
			#reporting_triggers{start_of_traffic = 1}
		   }}, URR),

    meck_validate(Config),
    ok.

simple_session() ->
    [{doc, "Test session detection, creation and tear down"}].
simple_session(Config) ->
    SEID = proplists:get_value(seid, Config),
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    UeIPSrcIe = ue_ip_address(src, Config),
    UeIPDstIe = ue_ip_address(dst, Config),

    packet_in(Config),
    ct:sleep({seconds, 1}),

    History = ergw_test_sx_up:history('tdf-u'),
    [SRresp|_] =
	lists:filter(
	  fun(#pfcp{type = session_report_response}) -> true;
	     (_) ->false
	  end, History),
    ?match(#pfcp{ie = #{pfcp_cause :=
			     #pfcp_cause{cause = 'Request accepted'}}}, SRresp),

    ct:pal("H: ~p", [History]),
    [SER|_] =
	lists:filter(
	  fun(#pfcp{type = session_establishment_request,
		    ie = #{f_seid := #f_seid{seid = FSeid}}}) -> FSeid /= SEID;
	     (_) ->false
	  end, History),

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
			      ue_ip_address := UeIPDstIe
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
				  #network_instance{instance = <<3, "epc">>},
			      sdf_filter :=
				  #sdf_filter{
				     flow_description =
					 <<"permit out ip from any to assigned">>},
			      source_interface :=
				  #source_interface{interface='Access'},
			      ue_ip_address := UeIPSrcIe
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
				  #network_instance{instance = <<3, "epc">>}
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

    {tdf, Pid} = gtp_context_reg:lookup({ue, <<3, "sgi">>, UeIP}),
    stop_session(Pid),

    ct:sleep({seconds, 1}),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------

gy_validity_timer() ->
    [{doc, "Check Validity-Timer attached to MSCC"}].
gy_validity_timer(Config) ->
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),

    packet_in(Config),
    ct:sleep({seconds, 10}),

    ?match(X when X >= 3 andalso X < 10,
		  meck:num_calls(?HUT, handle_event, [info, {timeout, '_', pfcp_timer}, '_', '_'])),

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

    {tdf, Pid} = gtp_context_reg:lookup({ue, <<3, "sgi">>, UeIP}),
    stop_session(Pid),

    ct:sleep({seconds, 1}),

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

    SEID = proplists:get_value(seid, Config),
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),

    packet_in(Config),
    ct:sleep(100),

    {tdf, Server} = gtp_context_reg:lookup({ue, <<3, "sgi">>, UeIP}),
    true = is_pid(Server),
    {ok, PCtx} = gtp_context:test_cmd(Server, pfcp_ctx),

    [SER|_] =
	lists:filter(
	  fun(#pfcp{type = session_establishment_request,
		    ie = #{f_seid := #f_seid{seid = FSeid}}}) -> FSeid /= SEID;
	     (_) ->false
	  end, ergw_test_sx_up:history('tdf-u')),

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
    ergw_test_sx_up:usage_report('tdf-u', PCtx, MatchSpec, Report),

    ct:sleep(100),
    stop_session(Server),
    ct:sleep(100),

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

    SEID = proplists:get_value(seid, Config),
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),

    packet_in(Config),
    ct:sleep(100),

    {tdf, Server} = gtp_context_reg:lookup({ue, <<3, "sgi">>, UeIP}),
    true = is_pid(Server),
    {ok, PCtx} = gtp_context:test_cmd(Server, pfcp_ctx),

    [SER|_] =
	lists:filter(
	  fun(#pfcp{type = session_establishment_request,
		    ie = #{f_seid := #f_seid{seid = FSeid}}}) -> FSeid /= SEID;
	     (_) ->false
	  end, ergw_test_sx_up:history('tdf-u')),

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
    ergw_test_sx_up:usage_report('tdf-u', PCtx, MatchSpec, Report),

    ct:sleep(100),
    stop_session(Server),
    ct:sleep(100),

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

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------

simple_ocs() ->
    [{doc, "Test Gy a simple interaction"}].
simple_ocs(Config) ->
    SEID = proplists:get_value(seid, Config),
    UeIP = proplists:get_value(ue_ip, Config),

    packet_in(Config),
    ct:sleep(100),

    {tdf, Server} = gtp_context_reg:lookup({ue, <<3, "sgi">>, ergw_inet:ip2bin(UeIP)}),
    true = is_pid(Server),
    {ok, PCtx} = gtp_context:test_cmd(Server, pfcp_ctx),

    [SER|_] =
	lists:filter(
	  fun(#pfcp{type = session_establishment_request,
		    ie = #{f_seid := #f_seid{seid = FSeid}}}) -> FSeid /= SEID;
	     (_) ->false
	  end, ergw_test_sx_up:history('tdf-u')),

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
    ergw_test_sx_up:usage_report('tdf-u', PCtx, MatchSpec, Report),

    ct:sleep(100),
    stop_session(Server),
    ct:sleep(100),

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
	case UeIP of
	    {_,_,_,_,_,_,_,_} ->
		#{'Framed-IPv6-Prefix' => UeIP,
		  'Requested-IPv6-Prefix' => '_'};
	    _ ->
		#{'Framed-IP-Address' => UeIP,
		  'Requested-IP-Address' => '_'}
	end,

    %% TBD: the comment elements are present in the PGW handler,
    %%      but not in the GGSN. Check if that is correct.
    Expected =
	Expected0
	#{
	  %% '3GPP-Allocation-Retention-Priority' => '?????',
	  %% '3GPP-Charging-Id' => '_',  ??????
	  '3GPP-GGSN-MCC-MNC' => <<"00101">>,
	  %% '3GPP-GPRS-Negotiated-QoS-Profile' => '?????',
	  %% '3GPP-NSAPI' => 5,
	  %% '3GPP-PDP-Type' => 'IPv4v6',
	  %% '3GPP-RAT-Type' => 6,
	  %% 'Acct-Interim-Interval' => '?????',
	  %% 'Bearer-Operation' => '?????',
	  %% 'Called-Station-Id' =>
	  %%     unicode:characters_to_binary(lists:join($., ?'APN-ExAmPlE')),
	  'Charging-Rule-Base-Name' => <<"m2m0001">>,
	  'Diameter-Session-Id' => '_',
	  'Event-Trigger' => '_',
	  %% 'Framed-IPv6-Prefix' => {{16#8001, 0, 1, '_', '_', '_', '_', '_'},64},
	  'Framed-Protocol' => 'PPP',
	  'Multi-Session-Id' => '_',
	  'NAS-Identifier' => '_',
	  'Node-Id' => <<"PGW-001">>,

	  %% 'SAI' => '?????',
	  'Service-Type' => 'Framed-User',
	  'Session-Id' => '_',
	  'Session-Start' => '_',
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

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    ok.

%%--------------------------------------------------------------------

gy_ccr_asr_overlap() ->
    [{doc, "Test that ASR is answered when it arrives during CCR-T"}].
gy_ccr_asr_overlap(Config) ->
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),

    packet_in(Config),
    ct:sleep({seconds, 1}),

    {tdf, Server} = gtp_context_reg:lookup({ue, <<3, "sgi">>, UeIP}),
    true = is_pid(Server),

    {ok, Session} = tdf:test_cmd(Server, session),
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

    stop_session(Server),

    ct:sleep({seconds, 1}),

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

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    ok.

%%--------------------------------------------------------------------

volume_threshold() ->
    [{doc, "Test Gy interaction when volume threshold is reached"}].
volume_threshold(Config) ->
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),

    packet_in(Config),
    ct:sleep({seconds, 2}),

    Session = tdf_session_pid(),
    {ok, PCtx} = tdf:test_cmd(Session, pfcp_ctx),

    MatchSpec = ets:fun2ms(fun({Id, {'online', _}}) -> Id end),

    ergw_test_sx_up:usage_report('tdf-u', PCtx, MatchSpec, [#usage_report_trigger{volth = 1}]),
    ergw_test_sx_up:usage_report('tdf-u', PCtx, MatchSpec, [#usage_report_trigger{volqu = 1}]),

    ct:sleep({seconds, 1}),

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

    {tdf, Pid} = gtp_context_reg:lookup({ue, <<3, "sgi">>, UeIP}),
    stop_session(Pid),

    ct:sleep({seconds, 1}),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    ok.

%%--------------------------------------------------------------------
gx_asr() ->
    [{doc, "Check that ASR on Gx terminates the session"}].
gx_asr(Config) ->
    packet_in(Config),
    ct:sleep({seconds, 1}),

    Server = tdf_session_pid(),

    ResponseFun = fun(_, _, _, _) -> ok end,
    Server ! #aaa_request{from = ResponseFun, procedure = {gx, 'ASR'},
			  session = #{}, events = []},

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_rar() ->
    [{doc, "Check that RAR on Gx changes the session"}].
gx_rar(Config) ->
    packet_in(Config),
    ct:sleep({seconds, 1}),

    Server = tdf_session_pid(),
    {ok, Session} = tdf:test_cmd(Server, session),
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
    {ok, PCR0} = tdf:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{}}, PCR0),

    InstCR =
	[{pcc, install, [#{'Charging-Rule-Name' => [<<"r-0002">>]}]}],
    Server ! AAAReq#aaa_request{events = InstCR},
    {_, Resp1, _, _} =
	receive {'$response', _, _, _, _} = R1 -> erlang:delete_element(1, R1) end,
    ?equal(ok, Resp1),
    {ok, PCR1} = tdf:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{}, <<"r-0002">> := #{}}, PCR1),

    SOpts1 = ergw_aaa_session:get(Session),
    RemoveCR =
	[{pcc, remove, [#{'Charging-Rule-Name' => [<<"r-0002">>]}]}],
    Server ! AAAReq#aaa_request{session = SOpts1, events = RemoveCR},
    {_, Resp2, _, _} =
	receive {'$response', _, _, _, _} = R2 -> erlang:delete_element(1, R2) end,
    ?equal(ok, Resp2),
    {ok, PCR2} = tdf:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{}}, PCR2),
    ?equal(false, maps:is_key(<<"r-0002">>, PCR2)),

    InstCRB =
	[{pcc, install, [#{'Charging-Rule-Base-Name' => [<<"m2m0002">>]}]}],
    Server ! AAAReq#aaa_request{events = InstCRB},
    {_, Resp3, _, _} =
	receive {'$response', _, _, _, _} = R3 -> erlang:delete_element(1, R3) end,
    ?equal(ok, Resp3),
    {ok, PCR3} = tdf:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{},
	     <<"r-0002">> := #{'Charging-Rule-Base-Name' := _}}, PCR3),

    SOpts3 = ergw_aaa_session:get(Session),
    RemoveCRB =
	[{pcc, remove, [#{'Charging-Rule-Base-Name' => [<<"m2m0002">>]}]}],
    Server ! AAAReq#aaa_request{session = SOpts3, events = RemoveCRB},
    {_, Resp4, _, _} =
	receive {'$response', _, _, _, _} = R4 -> erlang:delete_element(1, R4) end,
    ?equal(ok, Resp4),
    {ok, PCR4} = tdf:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{}}, PCR4),
    ?equal(false, maps:is_key(<<"r-0002">>, PCR4)),

    stop_session(Server),

    [Sx1, Sx2, Sx3, Sx4 | _] =
	lists:filter(
	  fun(#pfcp{type = session_modification_request}) -> true;
	     (_) ->false
	  end, ergw_test_sx_up:history('tdf-u')),

    SxLength =
	fun (Key, SxReq) ->
		case maps:get(Key, SxReq, undefined) of
		    X when is_list(X) -> length(X);
		    X when is_tuple(X) -> 1;
		    _ -> 0
		end
	end,
    ct:pal("Sx1: ~p", [Sx1]),
    ?equal([2, 2, 1, 0, 0, 0, 0, 0, 0],
	   [SxLength(X1, Sx1#pfcp.ie) || X1 <-
		[create_pdr, create_far, create_urr,
		 update_pdr, update_far, update_urr,
		 remove_pdr, remove_far, remove_urr]]),

    ct:pal("Sx2: ~p", [Sx2]),
    ?equal([0, 0, 0, 0, 0, 0, 2, 2, 1],
	   [SxLength(X2, Sx2#pfcp.ie) || X2 <-
		[create_pdr, create_far, create_urr,
		 update_pdr, update_far, update_urr,
		 remove_pdr, remove_far, remove_urr]]),

    ct:pal("Sx3: ~p", [Sx3]),
    ?equal([2, 2, 1, 0, 0, 0, 0, 0, 0],
	   [SxLength(X3, Sx3#pfcp.ie) || X3 <-
		[create_pdr, create_far, create_urr,
		 update_pdr, update_far, update_urr,
		 remove_pdr, remove_far, remove_urr]]),

    ct:pal("Sx4: ~p", [Sx4]),
    ?equal([0,0,0,0,0,0,2,2,1],
	   [SxLength(X4, Sx4#pfcp.ie) || X4 <-
		[create_pdr, create_far, create_urr,
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
    packet_in(Config),
    ct:sleep({seconds, 1}),

    Server = tdf_session_pid(),

    ResponseFun = fun(_, _, _, _) -> ok end,
    Server ! #aaa_request{from = ResponseFun, procedure = {gy, 'ASR'},
			  session = #{}, events = []},

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_invalid_charging_rulebase() ->
    [{doc, "Check the reaction to a Gx CCA-I with an invalid Charging-Rule-Base-Name"}].
gx_invalid_charging_rulebase(Config) ->
    packet_in(Config),
    ct:sleep({seconds, 1}),

    Server = tdf_session_pid(),

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

    stop_session(Server),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_invalid_charging_rule() ->
    [{doc, "Check the reaction to a Gx CCA-I with an invalid Charging-Rule-Name"}].
gx_invalid_charging_rule(Config) ->
    packet_in(Config),
    ct:sleep({seconds, 1}),

    Server = tdf_session_pid(),

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

    stop_session(Server),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_rar_gy_interaction() ->
    [{doc, "Check that a Gx RAR triggers a Gy request"}].
gx_rar_gy_interaction(Config) ->
    packet_in(Config),
    ct:sleep({seconds, 1}),

    Server = tdf_session_pid(),
    {ok, Session} = tdf:test_cmd(Server, session),
    SessionOpts = ergw_aaa_session:get(Session),

    {ok, #pfcp_ctx{timers = T1}} = tdf:test_cmd(Server, pfcp_ctx),
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
    {ok, PCR1} = tdf:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{}, <<"r-0002">> := #{}}, PCR1),

    {ok, #pfcp_ctx{timers = T2}} = tdf:test_cmd(Server, pfcp_ctx),
    ?equal(2, maps:size(T2)),

    SOpts1 = ergw_aaa_session:get(Session),
    RemoveCR =
	[{pcc, remove, [#{'Charging-Rule-Name' => [<<"r-0002">>]}]}],
    Server ! AAAReq#aaa_request{session = SOpts1, events = RemoveCR},
    {_, Resp2, _, _} =
	receive {'$response', _, _, _, _} = R2 -> erlang:delete_element(1, R2) end,
    ?equal(ok, Resp2),
    {ok, PCR2} = tdf:test_cmd(Server, pcc_rules),
    ?match(#{<<"r-0001">> := #{}}, PCR2),
    ?equal(false, maps:is_key(<<"r-0002">>, PCR2)),

    {ok, #pfcp_ctx{timers = T3}} = tdf:test_cmd(Server, pfcp_ctx),
    ?equal(1, maps:size(T3)),
    ?equal(maps:keys(T1), maps:keys(T3)),

    stop_session(Server),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
redirect_info() ->
    [{doc, "Check Session with Gx redirect info"}].
redirect_info(Config) ->
    SEID = proplists:get_value(seid, Config),
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    UeIPSrcIe = ue_ip_address(src, Config),
    UeIPDstIe = ue_ip_address(dst, Config),

    packet_in(Config),
    ct:sleep({seconds, 1}),

    History = ergw_test_sx_up:history('tdf-u'),
    [SRresp|_] =
	lists:filter(
	  fun(#pfcp{type = session_report_response}) -> true;
	     (_) ->false
	  end, History),
    ?match(#pfcp{ie = #{pfcp_cause :=
			     #pfcp_cause{cause = 'Request accepted'}}}, SRresp),

    ct:pal("H: ~p", [History]),
    [SER|_] =
	lists:filter(
	  fun(#pfcp{type = session_establishment_request,
		    ie = #{f_seid := #f_seid{seid = FSeid}}}) -> FSeid /= SEID;
	     (_) ->false
	  end, History),

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
			      ue_ip_address := UeIPDstIe
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
				  #network_instance{instance = <<3, "epc">>},
			      sdf_filter :=
				  #sdf_filter{
				     flow_description =
					 <<"permit out ip from any to assigned">>},
			      source_interface :=
				  #source_interface{interface='Access'},
			      ue_ip_address := UeIPSrcIe
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
				  #network_instance{instance = <<3, "epc">>}
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

    {tdf, Pid} = gtp_context_reg:lookup({ue, <<3, "sgi">>, UeIP}),
    stop_session(Pid),

    ct:sleep({seconds, 1}),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
tdf_app_id() ->
    [{doc, "Check Session with Gx TDF-Application-Identifier"}].
tdf_app_id(Config) ->
    SEID = proplists:get_value(seid, Config),
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    UeIPSrcIe = ue_ip_address(src, Config),
    UeIPDstIe = ue_ip_address(dst, Config),

    packet_in(Config),
    ct:sleep({seconds, 1}),

    History = ergw_test_sx_up:history('tdf-u'),
    [SRresp|_] =
	lists:filter(
	  fun(#pfcp{type = session_report_response}) -> true;
	     (_) ->false
	  end, History),
    ?match(#pfcp{ie = #{pfcp_cause :=
			     #pfcp_cause{cause = 'Request accepted'}}}, SRresp),

    ct:pal("H: ~p", [History]),
    [SER|_] =
	lists:filter(
	  fun(#pfcp{type = session_establishment_request,
		    ie = #{f_seid := #f_seid{seid = FSeid}}}) -> FSeid /= SEID;
	     (_) ->false
	  end, History),

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
			      ue_ip_address := UeIPDstIe
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
				  #network_instance{instance = <<3, "epc">>},
			      application_id :=
				  #application_id{id = <<"Gold">>},
			      source_interface :=
				  #source_interface{interface='Access'},
			      ue_ip_address := UeIPSrcIe
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
				  #network_instance{instance = <<3, "epc">>}
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

    {tdf, Pid} = gtp_context_reg:lookup({ue, <<3, "sgi">>, UeIP}),
    stop_session(Pid),

    ct:sleep({seconds, 1}),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%%===================================================================
%%% Helper
%%%===================================================================

tdf_node_pid() ->
    [[Pid]] = ets:match(gtp_context_reg, {{'cp-socket',{teid,'gtp-u','_'}},{ergw_sx_node, '$1'}}),
    Pid.

tdf_seid() ->
    [[SEID]] = ets:match(gtp_context_reg, {{seid, '$1'},{ergw_sx_node, '_'}}),
    SEID.

tdf_session_pid() ->
    [[SEID]] = ets:match(gtp_context_reg, {{seid, '_'},{tdf, '$1'}}),
    SEID.

ue_ip_address(Type, Config) ->
    case proplists:get_value(ue_ip, Config) of
	{_,_,_,_} = IP4 ->
	    #ue_ip_address{type = Type, ipv4 = ergw_inet:ip2bin(IP4)};
	{_,_,_,_,_,_,_,_} = IP6 ->
	    #ue_ip_address{type = Type, ipv6 = ergw_inet:ip2bin(IP6)}
    end.

packet_in(Config) ->
    VRF = <<3, "epc">>,
    Node = proplists:get_value(tdf_node, Config),
    PCtx = ergw_sx_node:test_cmd(Node, pfcp_ctx),

    IEs = [#usage_report_trigger{start = 1},
	   ue_ip_address(src, Config)],
    MatchSpec = ets:fun2ms(fun({Id, {'tdf', V}}) when V =:= VRF -> Id end),
    ergw_test_sx_up:usage_report('tdf-u', PCtx, MatchSpec, IEs).

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

stop_session(Pid) when is_pid(Pid) ->
    Pid ! {update_session, #{}, [stop]}.
