%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(tdf_SUITE).

-compile([export_all, nowarn_export_all, {parse_transform, lager_transform}]).

-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
%%-include("ergw_pgw_test_lib.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-define(TIMEOUT, 2000).
-define(HUT, tdf).				%% Handler Under Test

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
		  [{'cp-socket', [{type, 'gtp-u'},
				  {vrf, cp},
				  {ip, ?MUST_BE_UPDATED},
				  {reuseaddr, true}
				 ]}
		  ]},

		 {vrfs,
		  [{sgi, [{pools,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
					 {?IPv6PoolStart, ?IPv6PoolEnd, 64},
					 {?IPv6HostPoolStart, ?IPv6HostPoolEnd, 128}
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
		  [{?'APN-EXAMPLE', [{vrf, sgi}]},
		   {[<<"exa">>, <<"mple">>, <<"net">>], [{vrf, sgi}]},
		   {[<<"APN1">>], [{vrf, sgi}]}
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

		 {nodes,
		  [{default,
		    [{vrfs,
		      [{cp, [{features, ['CP-Function']}]},
		       {epc, [{features, ['TDF-Source', 'Access']}]},
		       {sgi, [{features, ['SGi-LAN']}]}]
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
     volume_threshold,
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

init_per_testcase(Config) ->
    ct:pal("Sockets: ~p", [ergw_gtp_socket_reg:all()]),
    {ok, AppsCfg} = application:get_env(ergw_aaa, apps),
    ergw_test_sx_up:reset('tdf-u'),
    meck_reset(Config),

    Node = tdf_node_pid(),
    ok = ergw_sx_node:test_cmd(Node, reconnect),
    ok = ergw_sx_node:test_cmd(Node, wait4nodeup),
    ct:sleep(500),
    [{seid, tdf_seid()}, {tdf_node, Node},
     {aaa_cfg, AppsCfg} | Config].

init_per_testcase(setup_upf, Config) ->
    {ok, AppsCfg} = application:get_env(ergw_aaa, apps),
    meck_reset(Config),

    Node = tdf_node_pid(),
    ok = ergw_sx_node:test_cmd(Node, wait4nodeup),
    ct:sleep(500),
    [{seid, tdf_seid()}, {tdf_node, Node},
     {aaa_cfg, AppsCfg} | Config];
init_per_testcase(gy_validity_timer, Config0) ->
    Config = init_per_testcase(Config0),
    load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS-VT'},
			    {{gy, 'CCR-Update'},  'Update-OCS-VT'}]),
    Config;
init_per_testcase(volume_threshold, Config0) ->
    Config = init_per_testcase(Config0),
    load_aaa_answer_config([{{gy, 'CCR-Initial'}, 'Initial-OCS'},
			    {{gy, 'CCR-Update'},  'Update-OCS'}]),
    Config;
init_per_testcase(redirect_info, Config0) ->
    Config = init_per_testcase(Config0),
    load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-Redirect'}]),
    Config;
init_per_testcase(tdf_app_id, Config0) ->
    Config = init_per_testcase(Config0),
    load_aaa_answer_config([{{gx, 'CCR-Initial'}, 'Initial-Gx-TDF-App'}]),
    Config;
init_per_testcase(_, Config) ->
    init_per_testcase(Config).

end_per_testcase(Config) ->
    AppsCfg = proplists:get_value(aaa_cfg, Config),
    ok = application:set_env(ergw_aaa, apps, AppsCfg),
    ok.

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

    lager:debug("PDRs: ~p", [pfcp_packet:lager_pr(PDRs)]),
    lager:debug("FARs: ~p", [pfcp_packet:lager_pr(FARs)]),
    lager:debug("URR: ~p", [pfcp_packet:lager_pr([URR])]),

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
		    #measurement_method{volum = 1},
		measurement_period :=
		    #measurement_period{period = 600},
		reporting_triggers :=
		    #reporting_triggers{periodic_reporting=1}
	       }
	 }, URR),

    {tdf, Pid} = gtp_context_reg:lookup({ue, <<3, "sgi">>, UeIP}),
    Pid ! stop_from_session,

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

    ?match(X when X >= 3, meck:num_calls(?HUT, handle_info, [{timeout, '_', pfcp_timer}, '_'])),

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
    ?match(X when X >= 3, length(CCRU)),

    {tdf, Pid} = gtp_context_reg:lookup({ue, <<3, "sgi">>, UeIP}),
    Pid ! stop_from_session,

    ct:sleep({seconds, 1}),

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
    Pid ! stop_from_session,

    ct:sleep({seconds, 1}),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
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

    lager:debug("PDRs: ~p", [pfcp_packet:lager_pr(PDRs)]),
    lager:debug("FARs: ~p", [pfcp_packet:lager_pr(FARs)]),
    lager:debug("URR: ~p", [pfcp_packet:lager_pr([URR])]),

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
		    #measurement_method{volum = 1},
		measurement_period :=
		    #measurement_period{period = 600},
		reporting_triggers :=
		    #reporting_triggers{periodic_reporting=1}
	       }
	 }, URR),

    {tdf, Pid} = gtp_context_reg:lookup({ue, <<3, "sgi">>, UeIP}),
    Pid ! stop_from_session,

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

    lager:debug("PDRs: ~p", [pfcp_packet:lager_pr(PDRs)]),
    lager:debug("FARs: ~p", [pfcp_packet:lager_pr(FARs)]),
    lager:debug("URR: ~p", [pfcp_packet:lager_pr([URR])]),

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
		    #measurement_method{volum = 1},
		measurement_period :=
		    #measurement_period{period = 600},
		reporting_triggers :=
		    #reporting_triggers{periodic_reporting=1}
	       }
	 }, URR),

    {tdf, Pid} = gtp_context_reg:lookup({ue, <<3, "sgi">>, UeIP}),
    Pid ! stop_from_session,

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
