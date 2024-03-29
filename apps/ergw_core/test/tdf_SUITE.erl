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

	 {ergw_core,
	  #{node =>
		[{node_id, <<"TDF.epc.mnc001.mcc001.3gppnetwork.org">>}],
	    sockets =>
		[{'cp-socket', [{type, 'gtp-u'},
				{vrf, cp},
				{ip, ?MUST_BE_UPDATED},
				{reuseaddr, true}
			       ]},

		 {sx, [{type, 'pfcp'},
		       {socket, 'cp-socket'},
		       {ip, ?MUST_BE_UPDATED},
		       {reuseaddr, true}
		      ]}
		],

	    ip_pools =>
		[{<<"pool-A">>, [{ranges, [#{start => ?IPv4PoolStart, 'end' => ?IPv4PoolEnd, prefix_len => 32},
					   #{start => ?IPv6PoolStart, 'end' => ?IPv6PoolEnd, prefix_len => 64},
					   #{start => ?IPv6HostPoolStart, 'end' => ?IPv6HostPoolEnd, prefix_len => 128}]},
				 {'MS-Primary-DNS-Server', {8,8,8,8}},
				 {'MS-Secondary-DNS-Server', {8,8,4,4}},
				 {'MS-Primary-NBNS-Server', {127,0,0,1}},
				 {'MS-Secondary-NBNS-Server', {127,0,0,1}},
				 {'DNS-Server-IPv6-Address',
				  [{16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8888},
				   {16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8844}]}
				]}
		],

	    handlers =>
		#{'h1' =>
		      [{handler, ?HUT},
		       {protocol, ip},
		       {apn, ?'APN-EXAMPLE'},
		       {nodes, [<<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>]},
		       {node_selection, [default]}
		      ]},

	    node_selection =>
		#{default =>
		      #{type => static,
			entries =>
			    [
			     %% APN NAPTR alternative
			     #{type        => naptr,
			       name        => <<"_default.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-pgw',
			       protocols   => ['x-s5-gtp', 'x-s8-gtp', 'x-gn', 'x-gp'],
			       replacement => <<"topon.tdf.epc.mnc001.mcc001.3gppnetwork.org">>},

			     #{type        => naptr,
			       name        => <<"_default.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-upf',
			       protocols   => ['x-sxb', 'x-sxc'],
			       replacement => <<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>},

			     %% A/AAAA record alternatives
			     #{type => host,
			       name => <<"topon.tdf.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED}
			    ]}
		 },

	    apns =>
		[{?'APN-EXAMPLE',
		  [{vrfs, [sgi]},
		   {ip_pools, [<<"pool-A">>]}]},
		 {[<<"exa">>, <<"mple">>, <<"net">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]}]},
		 {[<<"APN1">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]}]}
		],

	    charging =>
		#{profiles =>
		      [{default, []}],
		  rules =>
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
			 }}],
		  rulebase =>
		      [{<<"m2m0001">>, [<<"r-0001">>]},
		       {<<"m2m0002">>, [<<"r-0002">>]}]
		 },

	    upf_nodes =>
		#{default =>
		      [{vrfs,
			[{cp, [{features, ['CP-Function']}]},
			 {epc, [{features, ['TDF-Source', 'Access']}]},
			 {sgi, [{features, ['SGi-LAN']}]}
			]},
		       {ue_ip_pools,
			[[{ip_pools, [<<"pool-A">>]},
			  {vrf, sgi},
			   {ip_versions, [v4, v6]}]]}
		      ],
		  nodes =>
		      [{<<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]}]
		 }
	   }
	 },

	 {ergw_aaa,
	  [
	   {handlers,
	    [{ergw_aaa_static,
	      #{defaults =>
		    [{'NAS-Identifier',          <<"NAS-Identifier">>},
		     {'Node-Id',                 <<"PGW-001">>},
		     {'Acct-Interim-Interval',   600},
		     {'Charging-Rule-Base-Name', <<"m2m0001">>}]
	       }}
	    ]},
	   {services,
	    [{'Default',
	      [{handler, 'ergw_aaa_static'},
	       {answers,
		#{'Initial-Gx' =>
		      #{avps =>
			    #{'Result-Code' => 2001,
			      'Charging-Rule-Install' =>
				  [#{'Charging-Rule-Base-Name' => [<<"m2m0001">>]}]
			     }},
		  'Initial-Gx-Redirect' =>
		      #{avps =>
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
			     }},
		  'Initial-Gx-TDF-App' =>
		      #{avps =>
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
			     }},
		  'Update-Gx' => #{avps => #{'Result-Code' => 2001}},
		  'Final-Gx' => #{avps => #{'Result-Code' => 2001}},

		  'Initial-Gx-Fail-1' =>
		      #{avps =>
			    #{'Result-Code' => 2001,
			      'Charging-Rule-Install' =>
				  [#{'Charging-Rule-Base-Name' =>
					 [<<"m2m0001">>, <<"unknown-rulebase">>]}]
			     }},
		  'Initial-Gx-Fail-2' =>
		      #{avps =>
			    #{'Result-Code' => 2001,
			      'Charging-Rule-Install' =>
				  [#{'Charging-Rule-Name' => [<<"r-0001">>, <<"unknown-rule">>]}]
			     }},

		  'Initial-OCS' =>
		      #{avps =>
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
			     }},
		  'Update-OCS' =>
		      #{avps =>
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
			     }},
		  'Update-OCS-GxGy' =>
		      #{avps =>
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
			     }},
		  'Initial-OCS-VT' =>
		      #{avps =>
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
			     }},
		  'Update-OCS-VT' =>
		      #{avps =>
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
			     }},
		  'Final-OCS' => #{avps => #{'Result-Code' => 2001}}
		 }
	       }
	      ]}
	    ]},
	   {apps,
	    [{default,
	      [{init, [#{service => 'Default'}]},
	       {authenticate, []},
	       {authorize, []},
	       {start, []},
	       {interim, []},
	       {stop, []},
	       {{gx,'CCR-Initial'},   [#{service => 'Default', answer => 'Initial-Gx'}]},
	       {{gx,'CCR-Terminate'}, [#{service => 'Default', answer => 'Final-Gx'}]},
	       {{gx,'CCR-Update'},    [#{service => 'Default', answer => 'Update-Gx'}]},
	       {{gy, 'CCR-Initial'},   []},
	       {{gy, 'CCR-Update'},    []},
	       {{gy, 'CCR-Terminate'}, []}
	      ]}
	    ]}
	  ]}
	]).

-define(CONFIG_UPDATE,
	[{[sockets, 'cp-socket', ip], localhost},
	 {[sockets, sx, ip], localhost},
	 {[node_selection, default, entries, {name, <<"topon.tdf.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, default, entries, {name, <<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, tdf_u_sx}}
	]).

node_sel_update(Node, {_,_,_,_} = IP) ->
    Node#{ip4 => [IP], ip6 => []};
node_sel_update(Node, {_,_,_,_,_,_,_,_} = IP) ->
    Node#{ip4 => [], ip6 => [IP]}.

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
	    lib_init_per_group(Config);
	_ ->
	    {skip, "IPv6 test IPs not configured"}
    end;
init_per_group(ipv4, Config0) ->
    Config = update_app_config(ipv4, ?CONFIG_UPDATE, Config0),
    lib_init_per_group(Config).

end_per_group(Group, Config)
  when Group == ipv4; Group == ipv6 ->
    ok = lib_end_per_group(Config).

common() ->
    [simple_session,
     setup_upf,
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

only(ipv4) ->
    [aa_nat_select, aa_nat_select_fail];
only(_) ->
    [].

groups() ->
    [{ipv4, [], common() ++ only(ipv4)},
     {ipv6, [], common() ++ only(ipv6)}].

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
    ergw_test_lib:set_online_charging(true),
    ergw_test_lib:load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS-VT'},
			    {{gy, 'CCR-Update'},  'Update-OCS-VT'}]),
    Config;
init_per_testcase(TestCase, Config0)
  when TestCase == simple_ocs;
       TestCase == gy_ccr_asr_overlap;
       TestCase == volume_threshold ->
    Config = setup_per_testcase(Config0),
    ergw_test_lib:set_online_charging(true),
    ergw_test_lib:load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS'},
			    {{gy, 'CCR-Update'},  'Update-OCS'}]),
    Config;
init_per_testcase(TestCase, Config0)
  when TestCase == gx_rar_gy_interaction ->
    Config = setup_per_testcase(Config0),
    ergw_test_lib:set_online_charging(true),
    ergw_test_lib:load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS'},
			    {{gy, 'CCR-Update'},  'Update-OCS-GxGy'}]),
    Config;
init_per_testcase(gx_invalid_charging_rulebase, Config0) ->
    Config = setup_per_testcase(Config0),
    ergw_test_lib:load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-Fail-1'}]),
    Config;
init_per_testcase(gx_invalid_charging_rule, Config0) ->
    Config = setup_per_testcase(Config0),
    ergw_test_lib:load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-Fail-2'}]),
    Config;
init_per_testcase(redirect_info, Config0) ->
    Config = setup_per_testcase(Config0),
    ergw_test_lib:load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-Redirect'}]),
    Config;
init_per_testcase(tdf_app_id, Config0) ->
    Config = setup_per_testcase(Config0),
    ergw_test_lib:load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-TDF-App'}]),
    Config;
init_per_testcase(aa_pool_select, Config) ->
    ergw_test_sx_up:ue_ip_pools('tdf-u', [<<"pool-A">>, <<"pool-C">>,
					  <<"pool-D">>, <<"pool-B">>]),
    setup_per_testcase(Config);
init_per_testcase(TestCase, Config)
  when TestCase == aa_nat_select;
       TestCase == aa_nat_select_fail ->
    ergw_test_sx_up:nat_port_blocks('tdf-u', sgi, [<<"nat-A">>, <<"nat-C">>,
						   <<"nat-D">>, <<"nat-B">>]),
    ergw_test_sx_up:nat_port_blocks('tdf-u', example, [<<"nat-E">>]),
    setup_per_testcase(Config);
init_per_testcase(_, Config) ->
    setup_per_testcase(Config).

end_per_testcase(Config) ->
    AppsCfg = proplists:get_value(aaa_cfg, Config),
    ok = application:set_env(ergw_aaa, apps, AppsCfg),
    ergw_test_lib:set_online_charging(false),
    ok.

end_per_testcase(TestCase, Config)
  when TestCase == gy_ccr_asr_overlap;
       TestCase == simple_aaa;
       TestCase == simple_ofcs ->
    ok = meck:delete(ergw_aaa_session, invoke, 4),
    end_per_testcase(Config),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == aa_nat_select;
       TestCase == aa_nat_select_fail ->
    ergw_test_sx_up:nat_port_blocks('tdf-u', sgi, []),
    ergw_test_sx_up:nat_port_blocks('tdf-u', example, []),
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
    H = ergw_test_sx_up:history('tdf-u'),
    [ASR0, SER0 |_] =
	lists:dropwhile(fun(#pfcp{type = Type}) -> Type /= association_setup_request end, H),
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
    CtxKey = {ue, <<3, "sgi">>, UeIP},
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
		 urr_id := [#urr_id{id = _}|_]
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
		 urr_id := [#urr_id{id = _}|_]
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
       [#create_urr{
	   group =
	       #{urr_id := #urr_id{id = _},
		 measurement_method :=
		     #measurement_method{volum = 1, durat = 1},
		reporting_triggers :=
		    #reporting_triggers{}
	       }
	  },
	#create_urr{
	   group =
	       #{urr_id := #urr_id{id = _},
		 measurement_method :=
		     #measurement_method{volum = 1}
		}
	  }
       ], URR),

    ergw_context:test_cmd(tdf, CtxKey, stop_session),

    ct:sleep({seconds, 1}),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------

gy_validity_timer() ->
    [{doc, "Check Validity-Timer attached to MSCC"}].
gy_validity_timer(Config) ->
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    CtxKey = {ue, <<3, "sgi">>, UeIP},

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

    ergw_context:test_cmd(tdf, CtxKey, stop_session),

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
    CtxKey = {ue, <<3, "sgi">>, UeIP},

    packet_in(Config),
    ct:sleep(100),

    ?equal(true, ergw_context:test_cmd(tdf, CtxKey, is_alive)),
    {ok, PCtx} = ergw_context:test_cmd(tdf, CtxKey, pfcp_ctx),

    [SER|_] =
	lists:filter(
	  fun(#pfcp{type = session_establishment_request,
		    ie = #{f_seid := #f_seid{seid = FSeid}}}) -> FSeid /= SEID;
	     (_) ->false
	  end, ergw_test_sx_up:history('tdf-u')),

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
    ergw_test_sx_up:usage_report('tdf-u', PCtx, MatchSpec, Report),

    ct:sleep(100),
    ergw_context:test_cmd(tdf, CtxKey, stop_session),
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
    CtxKey = {ue, <<3, "sgi">>, UeIP},

    packet_in(Config),
    ct:sleep(100),

    ?equal(true, ergw_context:test_cmd(tdf, CtxKey, is_alive)),
    {ok, PCtx} = ergw_context:test_cmd(tdf, CtxKey, pfcp_ctx),

    [SER|_] =
	lists:filter(
	  fun(#pfcp{type = session_establishment_request,
		    ie = #{f_seid := #f_seid{seid = FSeid}}}) -> FSeid /= SEID;
	     (_) ->false
	  end, ergw_test_sx_up:history('tdf-u')),

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
	 #time_of_first_packet{time = ergw_gsn_lib:seconds_to_sntp_time(StartTS + 24)},
	 #time_of_last_packet{time = ergw_gsn_lib:seconds_to_sntp_time(StartTS + 180)},
	 #start_time{time = ergw_gsn_lib:seconds_to_sntp_time(StartTS)},
	 #end_time{time = ergw_gsn_lib:seconds_to_sntp_time(StartTS + 600)},
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
    ergw_test_sx_up:usage_report('tdf-u', PCtx, MatchSpec, ReportFun),

    ct:sleep(100),
    ergw_context:test_cmd(tdf, CtxKey, stop_session),
    ct:sleep(100),

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

    %% TDB: having traffic_data in TDF CDRs is not correct
    %%
    %% There is no IP-CAN bearer in a TDF session, ...
    %%
    ?equal(false, maps:is_key('traffic_data', Start)),
    ?equal(false, maps:is_key('traffic_data', AcctStop)),
    %% ?equal(false, maps:is_key('traffic_data', SInterim)),
    %% ?equal(false, maps:is_key('traffic_data', Stop)),

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

    StopSD = maps:get(service_data, Stop),
    ?match([_], StopSD),
    ?match_map(
       #{'Accounting-Input-Octets' => ['_'],
	 'Accounting-Output-Octets' => ['_'],
	 'Change-Condition' => [0]
	}, hd(StopSD)),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------

simple_ocs() ->
    [{doc, "Test Gy a simple interaction"}].
simple_ocs(Config) ->
    SEID = proplists:get_value(seid, Config),
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    CtxKey = {ue, <<3, "sgi">>, UeIP},

    packet_in(Config),
    ct:sleep(100),

    ?equal(true, ergw_context:test_cmd(tdf, CtxKey, is_alive)),
    {ok, PCtx} = ergw_context:test_cmd(tdf, CtxKey, pfcp_ctx),

    [SER|_] =
	lists:filter(
	  fun(#pfcp{type = session_establishment_request,
		    ie = #{f_seid := #f_seid{seid = FSeid}}}) -> FSeid /= SEID;
	     (_) ->false
	  end, ergw_test_sx_up:history('tdf-u')),

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
    ergw_test_sx_up:usage_report('tdf-u', PCtx, MatchSpec, Report),

    ct:sleep(100),
    ergw_context:test_cmd(tdf, CtxKey, stop_session),
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
	case ergw_inet:bin2ip(UeIP) of
	    {_,_,_,_,_,_,_,_} = IPv6 ->
		#{'Framed-IPv6-Prefix' => IPv6,
		  'Requested-IPv6-Prefix' => '_'};
	    IPv4 ->
		#{'Framed-IP-Address' => IPv4,
		  'Requested-IP-Address' => '_'}
	end,

    %% TBD: the comment elements are present in the PGW handler,
    %%      but not in the GGSN. Check if that is correct.
    Expected =
	Expected0
	#{
	  %% '3GPP-Allocation-Retention-Priority' => '?????',
	  %% '3GPP-Charging-Id' => '_',  ??????
	  '3GPP-GGSN-MCC-MNC' => {<<"001">>, <<"01">>},
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
       #{'Termination-Cause' => normal,
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
    CtxKey = {ue, <<3, "sgi">>, UeIP},

    packet_in(Config),
    ct:sleep({seconds, 1}),

    ?equal(true, ergw_context:test_cmd(tdf, CtxKey, is_alive)),
    {ok, Session} = ergw_context:test_cmd(tdf, CtxKey, session),
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
			     self() ! AAAReq,
			     meck:passthrough([MSession, MSessionOpts, Procedure, Opts]);
			(MSession, MSessionOpts, Procedure, Opts) ->
			     meck:passthrough([MSession, MSessionOpts, Procedure, Opts])
		     end),

    ergw_context:test_cmd(tdf, CtxKey, stop_session),

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
    CtxKey = {ue, <<3, "sgi">>, UeIP},

    packet_in(Config),
    ct:sleep({seconds, 2}),

    ?equal(true, ergw_context:test_cmd(tdf, CtxKey, is_alive)),
    {ok, PCtx} = ergw_context:test_cmd(tdf, CtxKey, pfcp_ctx),

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

    ergw_context:test_cmd(tdf, CtxKey, stop_session),

    ct:sleep({seconds, 1}),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    ok.

%%--------------------------------------------------------------------
gx_asr() ->
    [{doc, "Check that ASR on Gx terminates the session"}].
gx_asr(Config) ->
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    CtxKey = {ue, <<3, "sgi">>, UeIP},

    packet_in(Config),
    ct:sleep({seconds, 1}),

    ResponseFun = fun(_, _, _, _) -> ok end,
    ergw_context:test_cmd(tdf, CtxKey,
			  {send, #aaa_request{from = ResponseFun, procedure = {gx, 'ASR'},
					      session = #{}, events = []}}),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_rar() ->
    [{doc, "Check that RAR on Gx changes the session"}].
gx_rar(Config) ->
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    CtxKey = {ue, <<3, "sgi">>, UeIP},

    packet_in(Config),
    ct:sleep({seconds, 1}),

    {ok, Session} = ergw_context:test_cmd(tdf, CtxKey, session),
    SessionOpts = ergw_aaa_session:get(Session),

    Self = self(),
    ResponseFun =
	fun(Request, Result, Avps, SOpts) ->
		Self ! {'$response', Request, Result, Avps, SOpts} end,
    AAAReq = #aaa_request{from = ResponseFun, procedure = {gx, 'RAR'},
			  session = SessionOpts, events = []},

    ergw_context:test_cmd(tdf, CtxKey, {send, AAAReq}),
    {_, Resp0, _, _} =
	receive {'$response', _, _, _, _} = R0 -> erlang:delete_element(1, R0) end,
    ?equal(ok, Resp0),
    {ok, PCR0} = ergw_context:test_cmd(tdf, CtxKey, pcc_rules),
    ?match(#{<<"r-0001">> := #{}}, PCR0),

    InstCR =
	[{pcc, install, [#{'Charging-Rule-Name' => [<<"r-0002">>]}]}],
    ergw_context:test_cmd(tdf, CtxKey, {send, AAAReq#aaa_request{events = InstCR}}),
    {_, Resp1, _, _} =
	receive {'$response', _, _, _, _} = R1 -> erlang:delete_element(1, R1) end,
    ?equal(ok, Resp1),
    {ok, PCR1} = ergw_context:test_cmd(tdf, CtxKey, pcc_rules),
    ?match(#{<<"r-0001">> := #{}, <<"r-0002">> := #{}}, PCR1),

    SOpts1 = ergw_aaa_session:get(Session),
    RemoveCR =
	[{pcc, remove, [#{'Charging-Rule-Name' => [<<"r-0002">>]}]}],
    ergw_context:test_cmd(tdf, CtxKey,
			  {send, AAAReq#aaa_request{session = SOpts1, events = RemoveCR}}),
    {_, Resp2, _, _} =
	receive {'$response', _, _, _, _} = R2 -> erlang:delete_element(1, R2) end,
    ?equal(ok, Resp2),
    {ok, PCR2} = ergw_context:test_cmd(tdf, CtxKey, pcc_rules),
    ?match(#{<<"r-0001">> := #{}}, PCR2),
    ?equal(false, maps:is_key(<<"r-0002">>, PCR2)),

    InstCRB =
	[{pcc, install, [#{'Charging-Rule-Base-Name' => [<<"m2m0002">>]}]}],
    ergw_context:test_cmd(tdf, CtxKey, {send, AAAReq#aaa_request{events = InstCRB}}),
    {_, Resp3, _, _} =
	receive {'$response', _, _, _, _} = R3 -> erlang:delete_element(1, R3) end,
    ?equal(ok, Resp3),
    {ok, PCR3} = ergw_context:test_cmd(tdf, CtxKey, pcc_rules),
    ?match(#{<<"r-0001">> := #{},
	     <<"r-0002">> := #{'Charging-Rule-Base-Name' := _}}, PCR3),

    SOpts3 = ergw_aaa_session:get(Session),
    RemoveCRB =
	[{pcc, remove, [#{'Charging-Rule-Base-Name' => [<<"m2m0002">>]}]}],
    ergw_context:test_cmd(tdf, CtxKey,
			  {send, AAAReq#aaa_request{session = SOpts3, events = RemoveCRB}}),
    {_, Resp4, _, _} =
	receive {'$response', _, _, _, _} = R4 -> erlang:delete_element(1, R4) end,
    ?equal(ok, Resp4),
    {ok, PCR4} = ergw_context:test_cmd(tdf, CtxKey, pcc_rules),
    ?match(#{<<"r-0001">> := #{}}, PCR4),
    ?equal(false, maps:is_key(<<"r-0002">>, PCR4)),

    ergw_context:test_cmd(tdf, CtxKey, stop_session),

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
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    CtxKey = {ue, <<3, "sgi">>, UeIP},

    packet_in(Config),
    ct:sleep({seconds, 1}),

    ResponseFun = fun(_, _, _, _) -> ok end,
    ergw_context:test_cmd(tdf, CtxKey,
			  {send, #aaa_request{from = ResponseFun, procedure = {gy, 'ASR'},
					      session = #{}, events = []}}),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_invalid_charging_rulebase() ->
    [{doc, "Check the reaction to a Gx CCA-I with an invalid Charging-Rule-Base-Name"}].
gx_invalid_charging_rulebase(Config) ->
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    CtxKey = {ue, <<3, "sgi">>, UeIP},

    packet_in(Config),
    ct:sleep({seconds, 1}),

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

    ergw_context:test_cmd(tdf, CtxKey, stop_session),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_invalid_charging_rule() ->
    [{doc, "Check the reaction to a Gx CCA-I with an invalid Charging-Rule-Name"}].
gx_invalid_charging_rule(Config) ->
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    CtxKey = {ue, <<3, "sgi">>, UeIP},

    packet_in(Config),
    ct:sleep({seconds, 1}),

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

    ergw_context:test_cmd(tdf, CtxKey, stop_session),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
gx_rar_gy_interaction() ->
    [{doc, "Check that a Gx RAR triggers a Gy request"}].
gx_rar_gy_interaction(Config) ->
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    CtxKey = {ue, <<3, "sgi">>, UeIP},

    packet_in(Config),
    ct:sleep({seconds, 1}),

    {ok, Session} = ergw_context:test_cmd(tdf, CtxKey, session),
    SessionOpts = ergw_aaa_session:get(Session),

    {ok, #pfcp_ctx{timers = T1}} = ergw_context:test_cmd(tdf, CtxKey, pfcp_ctx),
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
    ergw_context:test_cmd(tdf, CtxKey, {send, AAAReq#aaa_request{events = InstCR}}),
    {_, Resp1, _, _} =
	receive {'$response', _, _, _, _} = R1 -> erlang:delete_element(1, R1) end,
    ?equal(ok, Resp1),
    {ok, PCR1} = ergw_context:test_cmd(tdf, CtxKey, pcc_rules),
    ?match(#{<<"r-0001">> := #{}, <<"r-0002">> := #{}}, PCR1),

    {ok, #pfcp_ctx{timers = T2}} = ergw_context:test_cmd(tdf, CtxKey, pfcp_ctx),
    ?equal(2, maps:size(T2)),

    SOpts1 = ergw_aaa_session:get(Session),
    RemoveCR =
	[{pcc, remove, [#{'Charging-Rule-Name' => [<<"r-0002">>]}]}],
    ergw_context:test_cmd(tdf, CtxKey,
			  {send, AAAReq#aaa_request{session = SOpts1, events = RemoveCR}}),
    {_, Resp2, _, _} =
	receive {'$response', _, _, _, _} = R2 -> erlang:delete_element(1, R2) end,
    ?equal(ok, Resp2),
    {ok, PCR2} = ergw_context:test_cmd(tdf, CtxKey, pcc_rules),
    ?match(#{<<"r-0001">> := #{}}, PCR2),
    ?equal(false, maps:is_key(<<"r-0002">>, PCR2)),

    {ok, #pfcp_ctx{timers = T3}} = ergw_context:test_cmd(tdf, CtxKey, pfcp_ctx),
    ?equal(1, maps:size(T3)),
    ?equal(maps:keys(T1), maps:keys(T3)),

    ergw_context:test_cmd(tdf, CtxKey, stop_session),

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
    CtxKey = {ue, <<3, "sgi">>, UeIP},
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
		 urr_id := [#urr_id{id = _}|_]
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
		 urr_id := [#urr_id{id = _}|_]
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
       [#create_urr{
	   group =
	       #{urr_id := #urr_id{id = _},
		 measurement_method :=
		    #measurement_method{volum = 1, durat = 1},
		 reporting_triggers :=
		     #reporting_triggers{}
		}
	  },
	#create_urr{
	   group =
	       #{urr_id := #urr_id{id = _},
		 measurement_method :=
		     #measurement_method{volum = 1}
		}
	  }
       ], URR),

    ergw_context:test_cmd(tdf, CtxKey, stop_session),

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
    CtxKey = {ue, <<3, "sgi">>, UeIP},
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
		 urr_id := [#urr_id{id = _}|_]
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
		 urr_id := [#urr_id{id = _}|_]
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
       [#create_urr{
	   group =
	       #{urr_id := #urr_id{id = _},
		 measurement_method :=
		     #measurement_method{volum = 1, durat = 1},
		 reporting_triggers :=
		     #reporting_triggers{}
		}
	  },
	#create_urr{
	   group =
	       #{urr_id := #urr_id{id = _},
		 measurement_method :=
		     #measurement_method{volum = 1}
		}
	  }
       ], URR),

    ergw_context:test_cmd(tdf, CtxKey, stop_session),

    ct:sleep({seconds, 1}),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
aa_nat_select() ->
    [{doc, "Select IP-NAT through AAA"}].
aa_nat_select(Config) ->
    AAAReply = #{'NAT-Pool-Id' => <<"nat-A">>},

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

    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    CtxKey = {ue, <<3, "sgi">>, UeIP},

    packet_in(Config),
    ct:sleep(100),

    ?equal(true, ergw_context:test_cmd(tdf, CtxKey, is_alive)),

    ct:sleep(100),
    ergw_context:test_cmd(tdf, CtxKey, stop_session),
    ct:sleep(100),

    H = meck:history(ergw_aaa_session),
    [SInv|_] =
	lists:foldr(
	  fun({_, {ergw_aaa_session, invoke, [_, _, start, _]}, {ok, Opts}}, Acc) ->
		  [Opts|Acc];
	     (_, Acc) ->
		  Acc
	  end, [], H),
    ?match(#{'NAT-Pool-Id' := _,
	     'NAT-IP-Address' := _,
	     'NAT-Port-Start' := _}, SInv),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
aa_nat_select_fail() ->
    [{doc, "Select IP-NAT through AAA"}].
aa_nat_select_fail(Config) ->
    AAAReply = #{'NAT-Pool-Id' => <<"nat-E">>},
    UeIP = ergw_inet:ip2bin(proplists:get_value(ue_ip, Config)),
    CtxKey = {ue, <<3, "sgi">>, UeIP},

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


    packet_in(Config),
    ct:sleep(100),

    ?equal(false, ergw_context:test_cmd(tdf, CtxKey, is_alive)),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%%===================================================================
%%% Helper
%%%===================================================================

tdf_node_pid() ->
    TEIDMatch = #socket_teid_key{name = 'cp-socket', type = 'gtp-u', _ = '_'},
    [[Pid]] = ets:match(gtp_context_reg, {TEIDMatch, {ergw_sx_node, '$1'}}),
    Pid.

tdf_seid() ->
    [[SEID]] = ets:match(gtp_context_reg, {#seid_key{seid = '$1'}, {ergw_sx_node, '_'}}),
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
