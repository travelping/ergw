%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_dist_SUITE).

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
-include("ergw_dist_test_lib.hrl").
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
	    [%% force log to async mode, never block the tests
	     {handler, cth_log_redirect, cth_log_redirect,
	      #{level => all,
		config =>
		    #{sync_mode_qlen => 10000,
		      drop_mode_qlen => 10000,
		      flush_qlen     => 10000}
	       }
	     },
	     {handler, write_to_file, logger_std_h,
	      #{level => all,
		config =>
		    #{type => file,
		      file => "pgw-erlang.log",
		      sync_mode_qlen => 10000,
		      drop_mode_qlen => 10000,
		      flush_qlen     => 10000}
	       }
	     }
	    ]}
	  ]},

	 {riak_core,
	  [{ring_state_dir, "<nostore>"},
	   {handoff_ip, {127,0,1,1}},
	   {handoff_port, 8099}
	  ]},

	 {ergw_core,
	  #{node =>
		[{node_id, <<"PGW.epc.mnc001.mcc001.3gppnetwork.org">>}],
	    sockets =>
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
				]},
		 {<<"pool-B">>, [{ranges, [#{start => ?IPv4PoolStart, 'end' => ?IPv4PoolEnd, prefix_len => 32},
					   #{start => ?IPv6PoolStart, 'end' => ?IPv6PoolEnd, prefix_len => 64},
					   #{start => ?IPv6HostPoolStart, 'end' => ?IPv6HostPoolEnd, prefix_len => 128}]},
				 {'MS-Primary-DNS-Server', {8,8,8,8}},
				 {'MS-Secondary-DNS-Server', {8,8,4,4}},
				 {'MS-Primary-NBNS-Server', {127,0,0,1}},
				 {'MS-Secondary-NBNS-Server', {127,0,0,1}},
				 {'DNS-Server-IPv6-Address',
				  [{16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8888},
				   {16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8844}]}
				]},
		 {<<"pool-C">>, [{ranges, [#{start => ?IPv4PoolStart, 'end' => ?IPv4PoolEnd, prefix_len => 32},
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
		#{gn =>
		      [{handler, ?HUT},
		       {protocol, gn},
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
		      ],
		  s5s8 =>
		      [{handler, ?HUT},
		       {protocol, s5s8},
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
			       replacement => <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>},

			     #{type        => naptr,
			       name        => <<"_default.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-upf',
			       protocols   => ['x-sxb'],
			       replacement => <<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>},

			     #{type        => naptr,
			       name        => <<"_default.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 400,
			       preference  => 64536,
			       service     => 'x-3gpp-upf',
			       protocols   => ['x-sxb'],
			       replacement => <<"topon.sx.prox03.epc.mnc001.mcc001.3gppnetwork.org">>},

			     #{type        => naptr,
			       name        => <<"async-sx.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-upf',
			       protocols   => ['x-sxb'],
			       replacement => <<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>},

			     #{type        => naptr,
			       name        => <<"async-sx.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-upf',
			       protocols   => ['x-sxb'],
			       replacement => <<"topon.sx.prox02.epc.mnc001.mcc001.3gppnetwork.org">>},

			     %% A/AAAA record alternatives
			     #{type => host,
			       name => <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.sx.prox02.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.sx.prox03.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED}
			    ]}
		 },

	    apns =>
		[{?'APN-EXAMPLE',
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>, <<"pool-B">>]},
		   {'Idle-Timeout', 21600000}]}, % Idle timeout 6 hours
		 {[<<"exa">>, <<"mple">>, <<"net">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]}]},
		 {[<<"APN1">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]},
		   {'Idle-Timeout', 28800000}]}, % Idle timeout 8 hours
		 {[<<"APN2">>, <<"mnc001">>, <<"mcc001">>, <<"gprs">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]}]},
		 {[<<"v6only">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]},
		   {bearer_type, 'IPv6'},
		   {'Idle-Timeout', infinity}]},
		 {[<<"v4only">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]},
		   {bearer_type, 'IPv4'},
		   {'Idle-Timeout', 21600000}]},
		 {[<<"prefV6">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]},
		   {prefered_bearer_type, 'IPv6'}]},
		 {[<<"prefV4">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]},
		   {prefered_bearer_type, 'IPv4'}]},
		 {[<<"async-sx">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]}]}
		 %% {'_', [{vrf, wildcard}]}
		],

	    charging =>
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
		     {<<"r-0001-split">>,
		      #{'Online-Rating-Group' => [3000],
			'Offline-Rating-Group' => [3001],
			'Flow-Information' =>
			    [#{'Flow-Description' => [<<"permit out ip from any to assigned">>],
			       'Flow-Direction'   => [1]    %% DownLink
			      },
			     #{'Flow-Description' => [<<"permit out ip from any to assigned">>],
			       'Flow-Direction'   => [2]    %% UpLink
			      }],
			'Metering-Method'  => [1],
			'Precedence' => [100],
			'Online'  => [1],
			'Offline'  => [1]
		       }},
		     {<<"r-0002-split">>,
		      #{'Online-Rating-Group' => [3000],
			'Offline-Rating-Group' => [3002],
			'Flow-Information' =>
			    [#{'Flow-Description' => [<<"permit out ip from any to assigned">>],
			       'Flow-Direction'   => [1]    %% DownLink
			      },
			     #{'Flow-Description' => [<<"permit out ip from any to assigned">>],
			       'Flow-Direction'   => [2]    %% UpLink
			      }],
			'Metering-Method'  => [1],
			'Precedence' => [100],
			'Online'  => [1],
			'Offline'  => [1]
		       }},
		     {<<"m2m0001">>, [<<"r-0001">>]},
		     {<<"m2m0002">>, [<<"r-0002">>]},
		     {<<"m2m0001-split1">>, [<<"r-0001-split">>, <<"r-0002-split">>]},
		     {<<"m2m0001-split2">>, [<<"r-0001">>, <<"r-0001-split">>, <<"r-0002-split">>]}
		    ]}
		  ]}
		],

	    upf_nodes =>
		#{default =>
		      [{vrfs,
			[{cp, [{features, ['CP-Function']}]},
			 {irx, [{features, ['Access']}]},
			 {sgi, [{features, ['SGi-LAN']}]}
			]},
		       {ip_pools, [<<"pool-A">>]}],
		  nodes =>
		      [{<<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]},
		       {<<"topon.sx.prox03.epc.mnc001.mcc001.3gppnetwork.org">>, [connect, {ip_pools, [<<"pool-B">>, <<"pool-C">>]}]}]
		 }
	   }
	 },

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
		  'Initial-Gx-Split1' =>
		      #{'Result-Code' => 2001,
			'Charging-Rule-Install' =>
			    [#{'Charging-Rule-Base-Name' => [<<"m2m0001-split1">>]}]
		       },
		  'Initial-Gx-Split2' =>
		      #{'Result-Code' => 2001,
			'Charging-Rule-Install' =>
			    [#{'Charging-Rule-Base-Name' => [<<"m2m0001-split2">>]}]
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
	      [{init, ['Default']},
	       {authenticate, []},
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
	]).

-define(CONFIG_UPDATE,
	[{[sockets, 'cp-socket', ip], localhost},
	 {[sockets, 'irx-socket', ip], test_gsn},
	 {[sockets, sx, ip], localhost},
	 {[node_selection, default, entries, {name, <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2,  final_gsn}},
	 {[node_selection, default, entries, {name, <<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2,  pgw_u01_sx}},
	 {[node_selection, default, entries, {name, <<"topon.sx.prox02.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2,  sgw_u_sx}},
	 {[node_selection, default, entries, {name, <<"topon.sx.prox03.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, pgw_u02_sx}}
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
    case erlang:is_alive() of
	true ->
	    %% ok = logger:set_primary_config(level, debug),
	    Config = ergw_dist_test_lib:init_per_suite(Config0),
	    [{handler_under_test, ?HUT},
	     {app_cfg, ?TEST_CONFIG} | Config];
	false ->
	    {skip, "distribution not enabled"}
    end.

end_per_suite(Config) ->
    ergw_dist_test_lib:end_per_suite(Config).

init_per_group(common, Config) ->
    ergw_dist_test_lib:init_per_group(Config);
init_per_group(single_socket, Config0) ->
    AppCfg0 = proplists:get_value(app_cfg, Config0),
    AppCfg = set_cfg_value([ergw_core, sockets, 'irx-socket', send_port], false, AppCfg0),
    Config = lists:keystore(app_cfg, 1, Config0, {app_cfg, AppCfg}),
    ergw_dist_test_lib:init_per_group(Config);
init_per_group(ipv6, Config) ->
    case ergw_test_lib:has_ipv6_test_config() of
	true ->
	    update_app_config(ipv6, ?CONFIG_UPDATE, Config);
	_ ->
	    {skip, "IPv6 test IPs not configured"}
    end;
init_per_group(ipv4, Config) ->
    update_app_config(ipv4, ?CONFIG_UPDATE, Config).

end_per_group(Group, _Config)
  when Group == ipv4; Group == ipv6 ->
    ok;
end_per_group(Group, Config)
  when Group == common;
       Group == single_socket ->
    ok = ergw_dist_test_lib:end_per_group(Config).

common() ->
    [create_session_request_accept_new,
     path_restart, path_restart_recovery, path_restart_multi,
     simple_session_request,
     simple_session_request_cp_teid,
     duplicate_session_request,
     error_indication,
     %% request_fast_resend, TODO, FIXME
     change_notification_request_with_tei,
     change_notification_request_without_tei,
     change_notification_request_invalid_imsi].

single_socket() ->
    [simple_session_request].

groups() ->
    [{common, [], common()},
     {single_socket, [], single_socket()},
     {ipv4, [], [{group, common}, {group, single_socket}]},
     {ipv6, [], [{group, common}, {group, single_socket}]}].

all() ->
    [{group, ipv4},
     {group, ipv6}].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(TestCase, Config0) ->
    Config = master_init_per_testcase(TestCase, Config0),
    ergw_dist_test_lib:foreach_node(Config, ?MODULE, node_init_per_testcase, [TestCase, Config]),
    Config.

end_per_testcase(TestCase, Config) ->
    Result = master_end_per_testcase(TestCase, Config),

    Fun = fun(Id) ->
		  AppsCfg = proplists:get_value({aaa_cfg, Id}, Config),
		  node_end_per_testcase(Id, TestCase, AppsCfg)
	  end,
    ergw_dist_test_lib:foreach_node(Config, Fun),
    Result.

master_setup_per_testcase(Config) ->
    master_setup_per_testcase(Config, true).

master_setup_per_testcase(Config, ClearSxHist) ->
    logger:set_primary_config(level, debug),
    ergw_test_sx_up:reset('pgw-u01'),
    start_gtpc_server(Config),
    ergw_dist_test_lib:reconnect_all_sx_nodes(Config),
    ClearSxHist andalso ergw_test_sx_up:history('pgw-u01', true),
    ok.

master_init_per_testcase(simple_session_request_cp_teid, Config) ->
    {ok, _} = ergw_test_sx_up:feature('pgw-u01', ftup, 0),
    master_setup_per_testcase(Config),
    Config;
master_init_per_testcase(_, Config) ->
    master_setup_per_testcase(Config),
    Config.

master_end_per_testcase(Config) ->
    PoolId = [<<"pool-A">>, ipv4, "10.180.0.1"],
    ?match_dist_metric(prometheus_gauge, ergw_local_pool_free, PoolId, all, ?IPv4PoolSize),

    stop_gtpc_server(),
    ok.

master_end_per_testcase(simple_session_request_cp_teid, Config) ->
    {ok, _} = ergw_test_sx_up:feature('pgw-u01', ftup, 1),
    master_end_per_testcase(Config);
master_end_per_testcase(_, Config) ->
    master_end_per_testcase(Config).

node_setup_per_testcase(_Id, _Config) ->
    logger:set_primary_config(level, debug),
    ok.

node_init_per_testcase(Id, _, Config) ->
    node_setup_per_testcase(Id, Config),
    Config.

node_end_per_testcase(_Id, AppsCfg) ->
    ok = application:set_env(ergw_aaa, apps, AppsCfg),
    ergw_test_lib:set_online_charging(false),
    ok.

node_end_per_testcase(Id, create_session_request_accept_new, AppsCfg) ->
    ergw_core:system_info(accept_new, true),
    node_end_per_testcase(Id, AppsCfg),
    ok;
node_end_per_testcase(Id, _, AppsCfg) ->
    node_end_per_testcase(Id, AppsCfg),
    ok.

%%--------------------------------------------------------------------
create_session_request_accept_new() ->
    [{doc, "Check the accept_new = false can block new session"}].
create_session_request_accept_new(Config) ->
    ergw_dist_test_lib:foreach_node
      (Config, fun (_) -> ergw_core:system_info(accept_new, false) end),
    create_session(reject_new, Config),
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

    ergw_dist_test_lib:wait4contexts(?TIMEOUT, Config),
    ok.

%%--------------------------------------------------------------------
path_restart_recovery() ->
    [{doc, "Check that Create Session Request works and "
	   "that a Path Restart terminates the session"}].
path_restart_recovery(Config) ->
    {GtpC1, _, _} = create_session(Config),

    %% create 2nd session with new restart_counter (simulate SGW restart)
    {GtpC2, _, _} = create_session(gtp_context_inc_restart_counter(GtpC1)),

    {ok, AllPaths} = ergw_dist_test_lib:random_node(Config, gtp_path_db_vnode, all, []),
    ct:pal("Paths: ~p", [AllPaths]),
    ?match(1, length(AllPaths)),

    {ok, AllCtx} =
	ergw_dist_test_lib:random_node(Config, gtp_context_reg_vnode, all, [<<"context">>]),
    ct:pal("AllCtx: ~p", [AllCtx]),
    ?match(1, length(AllCtx)),

    delete_session(GtpC2),

    ergw_dist_test_lib:wait4contexts(?TIMEOUT, Config),
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

    {ok, AllCtx} =
	ergw_dist_test_lib:random_node(Config, gtp_context_reg_vnode, all, [<<"context">>]),
    ct:pal("AllCtx: ~p", [AllCtx]),
    ?match(5, length(AllCtx)),

    %% simulate patch restart to kill the PDP context
    Echo = make_request(echo_request, simple,
			gtp_context_inc_seq(
			  gtp_context_inc_restart_counter(GtpC4))),
    send_recv_pdu(ergw_dist_test_lib:gtp_context_node(2, GtpC4), Echo),

    ergw_dist_test_lib:wait4contexts(?TIMEOUT, Config),
    ok.

%%--------------------------------------------------------------------
simple_session_request() ->
    [{doc, "Check simple Create Session, Delete Session sequence"}].
simple_session_request(Config) ->
    PoolId = [<<"pool-A">>, ipv4, "10.180.0.1"],

    ?match_dist_metric(prometheus_gauge, ergw_local_pool_free, PoolId, all, ?IPv4PoolSize),
    ?match_dist_metric(prometheus_gauge, ergw_local_pool_used, PoolId, all, 0),

    {GtpC, _, _} = create_session(ipv4, Config),

    ?match_dist_metric(prometheus_gauge, ergw_local_pool_free, PoolId, one, ?IPv4PoolSize - 1),
    ?match_dist_metric(prometheus_gauge, ergw_local_pool_used, PoolId, one, 1),

    delete_session(GtpC),

    ergw_dist_test_lib:wait4contexts(?TIMEOUT, Config),

    ?match_dist_metric(prometheus_gauge, ergw_local_pool_free, PoolId, all, ?IPv4PoolSize),
    ?match_dist_metric(prometheus_gauge, ergw_local_pool_used, PoolId, all, 0),

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
			    #{f_teid := #f_teid{teid = choose},
			      network_instance :=
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
		 %% measurement_period :=
		 %%     #measurement_period{period = 600},
		 %% reporting_triggers :=
		 %%     #reporting_triggers{periodic_reporting=1}
		}
	  }
       ], URR),

    ok.

%%--------------------------------------------------------------------
simple_session_request_cp_teid() ->
    [{doc, "Check simple Create Session, Delete Session sequence"}].
simple_session_request_cp_teid(Config) ->
    PoolId = [<<"pool-A">>, ipv4, "10.180.0.1"],

    ?match_dist_metric(prometheus_gauge, ergw_local_pool_free, PoolId, all, ?IPv4PoolSize),
    ?match_dist_metric(prometheus_gauge, ergw_local_pool_used, PoolId, all, 0),

    {GtpC, _, _} = create_session(ipv4, Config),

    ?match_dist_metric(prometheus_gauge, ergw_local_pool_free, PoolId, one, ?IPv4PoolSize - 1),
    ?match_dist_metric(prometheus_gauge, ergw_local_pool_used, PoolId, one, 1),

    delete_session(GtpC),

    ergw_dist_test_lib:wait4contexts(?TIMEOUT, Config),

    ?match_dist_metric(prometheus_gauge, ergw_local_pool_free, PoolId, all, ?IPv4PoolSize),
    ?match_dist_metric(prometheus_gauge, ergw_local_pool_used, PoolId, all, 0),

    [SER|_] = lists:filter(
		fun(#pfcp{type = session_establishment_request}) -> true;
		   (_) ->false
		end, ergw_test_sx_up:history('pgw-u01')),

    ?match_map(#{create_pdr => '_', create_far => '_',  create_urr => '_'}, SER#pfcp.ie),
    #{create_pdr := PDRs0} = SER#pfcp.ie,

    PDRs = lists:sort(PDRs0),

    ?LOG(debug, "PDRs: ~s", [pfcp_packet:pretty_print(PDRs)]),

    ?match(
       [#create_pdr{},
	#create_pdr{group =
			#{pdi :=
			      #pdi{group =
				       #{f_teid :=
					     #f_teid{choose_id = undefined}}}}}],
       PDRs),
    ok.

%%--------------------------------------------------------------------
duplicate_session_request() ->
    [{doc, "Check the a new incomming request for the same IMSI terminates the first"}].
duplicate_session_request(Config) ->
    {GtpC1, _, _} = create_session(Config),

    %% TBD: send to other instance
    %% create 2nd session with the same IMSI
    {GtpC2, _, _} = create_session(GtpC1),

    {ok, AllCtx} =
	ergw_dist_test_lib:random_node(Config, gtp_context_reg_vnode, all, [<<"context">>]),
    ct:pal("AllCtx: ~p", [AllCtx]),
    ?match(1, length(AllCtx)),

    delete_session(not_found, GtpC1),
    delete_session(GtpC2),

    ergw_dist_test_lib:wait4contexts(?TIMEOUT, Config),
    ok.

%%--------------------------------------------------------------------
error_indication() ->
    [{doc, "Check the a GTP-U error indication terminates the session"}].
error_indication(Config) ->
    {GtpC, _, _} = create_session(Config),

    ergw_test_sx_up:send('pgw-u01', make_error_indication_report(GtpC)),

    ct:sleep(100),
    delete_session(not_found, GtpC),

    ergw_dist_test_lib:wait4contexts(?TIMEOUT, Config),
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

    ergw_dist_test_lib:wait4contexts(?TIMEOUT, Config),
    ok.

%%--------------------------------------------------------------------
change_notification_request_with_tei() ->
    [{doc, "Check Change Notification request with TEID"}].
change_notification_request_with_tei(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = change_notification(simple, GtpC1),
    delete_session(GtpC2),

    ergw_dist_test_lib:wait4contexts(?TIMEOUT, Config),
    ok.

%%--------------------------------------------------------------------
change_notification_request_without_tei() ->
    [{doc, "Check Change Notification request without TEID "
	   "include IMEI and IMSI instead"}].
change_notification_request_without_tei(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = change_notification(without_tei, GtpC1),
    delete_session(GtpC2),

    ergw_dist_test_lib:wait4contexts(?TIMEOUT, Config),
    ok.

%%--------------------------------------------------------------------
change_notification_request_invalid_imsi() ->
    [{doc, "Check Change Notification request without TEID "
	   "include a invalid IMEI and IMSI instead"}].
change_notification_request_invalid_imsi(Config) ->
    {GtpC1, _, _} = create_session(Config),
    {GtpC2, _, _} = change_notification(invalid_imsi, GtpC1),
    delete_session(GtpC2),

    ergw_dist_test_lib:wait4contexts(?TIMEOUT, Config),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
