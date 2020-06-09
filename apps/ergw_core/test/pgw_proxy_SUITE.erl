%% Copyright 2017-2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_proxy_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("kernel/include/logger.hrl").
-include_lib("prometheus/include/prometheus.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_pgw_test_lib.hrl").

-define(TIMEOUT, 2000).
-define(NUM_OF_CLIENTS, 8). %% Num of IP clients for multi contexts max = 10

-define(HUT, pgw_s5s8_proxy).			%% Handler Under Test

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

	 {ergw_core,
	  #{node =>
		[{node_id, <<"PGW.epc.mnc001.mcc001.3gppnetwork.org">>}],
	    sockets =>
		[{cp, [{type, 'gtp-u'},
		       {vrf, cp},
		       {ip, ?MUST_BE_UPDATED},
		       {reuseaddr, true}
		      ]},
		 {irx, [{type, 'gtp-c'},
			{vrf, irx},
			{ip, ?MUST_BE_UPDATED},
			{reuseaddr, true}
		       ]},
		 {'proxy-irx', [{type, 'gtp-c'},
				{vrf, irx},
				{ip, ?MUST_BE_UPDATED},
				{reuseaddr, true}
			       ]},
		 {'remote-irx', [{type, 'gtp-c'},
				 {vrf, irx},
				 {ip, ?MUST_BE_UPDATED},
				 {reuseaddr, true}
				]},
		 {'remote-irx2', [{type, 'gtp-c'},
				  {vrf, irx},
				  {ip, ?MUST_BE_UPDATED},
				  {reuseaddr, true}
				 ]},

		 {sx, [{type, 'pfcp'},
		       {socket, cp},
		       {ip, ?MUST_BE_UPDATED},
		       {reuseaddr, true}
		      ]}
		],

	    ip_pools =>
		[{<<"pool-A">>, [{ranges,  [#{start => ?IPv4PoolStart, 'end' => ?IPv4PoolEnd, prefix_len => 32},
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
		%% proxy handler
		#{gn =>
		      [{handler, ?HUT},
		       {protocol, gn},
		       {sockets, [irx]},
		       {proxy_sockets, ['proxy-irx']},
		       {node_selection, [default]}
		      ],
		  s5s8 =>
		      [{handler, ?HUT},
		       {protocol, s5s8},
		       {sockets, [irx]},
		       {proxy_sockets, ['proxy-irx']},
		       {node_selection, [default]},
		       {contexts,
			[{<<"ams">>,
			  [{proxy_sockets, ['proxy-irx']}]}]}
		      ],
		  %% remote PGW handler
		  'gn-remote' =>
		      [{handler, pgw_s5s8},
		       {protocol, gn},
		       {sockets, ['remote-irx', 'remote-irx2']},
		       {node_selection, [default]},
		       {aaa, [{'Username',
			       [{default, ['IMSI', <<"@">>, 'APN']}]}]}
		      ],
		  's5s8-remote' =>
		      [{handler, pgw_s5s8},
		       {protocol, s5s8},
		       {sockets, ['remote-irx', 'remote-irx2']},
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
			       replacement => <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>},
			     #{type        => naptr,
			       name        => <<"_default.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-upf',
			       protocols   => ['x-sxa'],
			       replacement => <<"topon.sx.sgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>},
			     #{type        => naptr,
			       name        => <<"_default.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-upf',
			       protocols   => ['x-sxb'],
			       replacement => <<"topon.sx.pgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>},

			     #{type        => naptr,
			       name        => <<"pgw-1.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-ggsn',
			       protocols   => ['x-gn', 'x-gp'],
			       replacement => <<"topon.pgw-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>},
			     #{type        => naptr,
			       name        => <<"upf-1.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-upf',
			       protocols   => ['x-sxb'],
			       replacement => <<"topon.pgw-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>},

			     #{type        => naptr,
			       name        => <<"lb-1.apn.epc.mnc000.mcc700.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-pgw',
			       protocols   => ['x-s5-gtp', 'x-s8-gtp', 'x-gn', 'x-gp'],
			       replacement => <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>},
			     #{type        => naptr,
			       name        => <<"lb-1.apn.epc.mnc000.mcc700.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-pgw',
			       protocols   => ['x-s5-gtp', 'x-s8-gtp', 'x-gn', 'x-gp'],
			       replacement => <<"topon.s5s8.pgw-2.epc.mnc001.mcc001.3gppnetwork.org">>},

			     %% A/AAAA record alternatives
			     #{type => host,
			       name => <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.s5s8.pgw-2.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.sx.sgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.sx.pgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.pgw-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.upf-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED}
			    ]},
		  mydns =>
		      #{type   => dns,
			server => {127,0,0,1},
			port   => 53}
		  },

	    apns =>
		[{?'APN-PROXY',
		  [{vrf, example},
		   {ip_pools, [<<"pool-A">>]}]},
		 {?'APN-LB-1', [{vrf, example}, {ip_pools, [<<"pool-A">>]}]}
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
			 }}],
		  rulebase =>
		      [{<<"m2m0001">>, [<<"r-0001">>]}]
		 },

	    proxy_map =>
		[{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
		 {imsi, [{?'IMSI', [{imsi, ?'PROXY-IMSI'}, {msisdn, ?'PROXY-MSISDN'}]}]}],

	    upf_nodes =>
		#{default =>
		      [{vrfs,
			[{cp, [{features, ['CP-Function']}]},
			 {irx, [{features, ['Access']}]},
			 {'proxy-irx', [{features, ['Core']}]},
			 {'remote-irx', [{features, ['Access']}]},
			 {'remote-irx2', [{features, ['Access']}]},
			 {example, [{features, ['SGi-LAN']}]}]
		       },
		       {ue_ip_pools,
			[[{ip_pools, [<<"pool-A">>]},
			  {vrf, example},
			   {ip_versions, [v4, v6]}]]}
		      ],
		  nodes =>
		      [{<<"topon.sx.sgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]},
		       {<<"topon.sx.pgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]},
		       {<<"topon.upf-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]}]
		 },

	    path_management =>
		[{busy, [{echo, 60 * 1000}]},
		 {idle, [{timeout, 1800 * 1000},
			 {echo,     600 * 1000}]},
		 {suspect, [{timeout, 0}]},
		 {down, [{timeout, 3600 * 1000},
			 {echo,     600 * 1000}]}]
	   }
	 },

	 {ergw_aaa,
	  [
	   {handlers,
	    [{ergw_aaa_static,
	      #{defaults =>
		    [{'NAS-Identifier',          <<"NAS-Identifier">>},
		     {'Node-Id',                 <<"PGW-001">>},
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
		  'Update-Gx' => #{avps => #{'Result-Code' => 2001}},
		  'Final-Gx' => #{avps => #{'Result-Code' => 2001}}
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

	 {ergw_core,
	  #{node =>
		[{node_id, <<"PGW.epc.mnc001.mcc001.3gppnetwork.org">>}],
	    sockets =>
		[{cp, [{type, 'gtp-u'},
		       {vrf, cp},
		       {ip, ?MUST_BE_UPDATED},
		       {reuseaddr, true}
		      ]},
		 {irx, [{type, 'gtp-c'},
			{vrf, irx},
			{ip, ?MUST_BE_UPDATED},
			{reuseaddr, true}
		       ]},
		 {'remote-irx', [{type, 'gtp-c'},
				 {vrf, irx},
				 {ip, ?MUST_BE_UPDATED},
				 {reuseaddr, true}
				]},
		 {'remote-irx2', [{type, 'gtp-c'},
				  {vrf, irx},
				  {ip, ?MUST_BE_UPDATED},
				  {reuseaddr, true}
				 ]},

		 {sx, [{type, 'pfcp'},
		       {socket, cp},
		       {ip, ?MUST_BE_UPDATED},
		       {reuseaddr, true}
		      ]}
		],

	    ip_pools =>
		[{<<"pool-A">>, [{ranges,  [#{start => ?IPv4PoolStart, 'end' => ?IPv4PoolEnd, prefix_len => 32},
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
		%% proxy handler
		#{gn =>
		      [{handler, ?HUT},
		       {protocol, gn},
		       {sockets, [irx]},
		       {proxy_sockets, ['irx']},
		       {node_selection, [default]}
		      ],
		  s5s8 =>
		      [{handler, ?HUT},
		       {protocol, s5s8},
		       {sockets, [irx]},
		       {proxy_sockets, ['irx']},
		       {node_selection, [default]},
		       {contexts,
			[{<<"ams">>,
			  [{proxy_sockets, ['irx']}]}]}
		      ],
		  %% remote PGW handler
		  'gn-remote' =>
		      [{handler, pgw_s5s8},
		       {protocol, gn},
		       {sockets, ['remote-irx', 'remote-irx2']},
		       {node_selection, [default]},
		       {aaa, [{'Username',
			       [{default, ['IMSI', <<"@">>, 'APN']}]}]}
		      ],
		  's5s8-remote' =>
		      [{handler, pgw_s5s8},
		       {protocol, s5s8},
		       {sockets, ['remote-irx', 'remote-irx2']},
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
			       replacement => <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>},
			     #{type        => naptr,
			       name        => <<"_default.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-upf',
			       protocols   => ['x-sxa'],
			       replacement => <<"topon.sx.sgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>},
			     #{type        => naptr,
			       name        => <<"_default.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-upf',
			       protocols   => ['x-sxb'],
			       replacement => <<"topon.sx.pgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>},

			     #{type        => naptr,
			       name        => <<"pgw-1.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-ggsn',
			       protocols   => ['x-gn', 'x-gp'],
			       replacement => <<"topon.pgw-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>},
			     #{type        => naptr,
			       name        => <<"upf-1.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-upf',
			       protocols   => ['x-sxb'],
			       replacement => <<"topon.pgw-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>},

			     #{type        => naptr,
			       name        => <<"lb-1.apn.epc.mnc000.mcc700.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-pgw',
			       protocols   => ['x-s5-gtp', 'x-s8-gtp', 'x-gn', 'x-gp'],
			       replacement => <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>},
			     #{type        => naptr,
			       name        => <<"lb-1.apn.epc.mnc000.mcc700.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-pgw',
			       protocols   => ['x-s5-gtp', 'x-s8-gtp', 'x-gn', 'x-gp'],
			       replacement => <<"topon.s5s8.pgw-2.epc.mnc001.mcc001.3gppnetwork.org">>},

			     %% A/AAAA record alternatives
			     #{type => host,
			       name => <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.s5s8.pgw-2.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.sx.sgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.sx.pgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.pgw-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.upf-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED}
			    ]},
		  mydns =>
		      #{type   => dns,
			server => {127,0,0,1},
			port   => 53}
		  },

	    apns =>
		[{?'APN-PROXY',
		  [{vrf, example},
		   {ip_pools, [<<"pool-A">>]}]},
		 {?'APN-LB-1', [{vrf, example}, {ip_pools, [<<"pool-A">>]}]}
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
			 }}],
		  rulebase =>
		      [{<<"m2m0001">>, [<<"r-0001">>]}]
		 },

	    proxy_map =>
		[{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
		 {imsi, [{?'IMSI', [{imsi, ?'PROXY-IMSI'}, {msisdn, ?'PROXY-MSISDN'}]}]}],

	    upf_nodes =>
		#{default =>
		      [{vrfs,
			[{cp, [{features, ['CP-Function']}]},
			 {irx, [{features, ['Access']}]},
			 {'proxy-irx', [{features, ['Core']}]},
			 {'remote-irx', [{features, ['Access']}]},
			 {'remote-irx2', [{features, ['Access']}]},
			 {example, [{features, ['SGi-LAN']}]}]
		       },
		       {ue_ip_pools,
			[[{ip_pools, [<<"pool-A">>]},
			  {vrf, example},
			   {ip_versions, [v4, v6]}]]}
		      ],
		  nodes =>
		      [{<<"topon.sx.sgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]},
		       {<<"topon.sx.pgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]},
		       {<<"topon.upf-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]}]
		 },

	    path_management =>
		[{busy, [{echo, 60 * 1000}]},
		 {idle, [{timeout, 1800 * 1000},
			 {echo,     600 * 1000}]},
		 {suspect, [{timeout, 0}]},
		 {down, [{timeout, 3600 * 1000},
			 {echo,     600 * 1000}]}]
	   }
	 },

	 {ergw_aaa,
	  [
	   {handlers,
	    [{ergw_aaa_static,
	      #{defaults =>
		    [{'NAS-Identifier',          <<"NAS-Identifier">>},
		     {'Node-Id',                 <<"PGW-001">>},
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
		  'Update-Gx' => #{avps => #{'Result-Code' => 2001}},
		  'Final-Gx' => #{avps => #{'Result-Code' => 2001}}
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

-define(CONFIG_UPDATE_MULTIPLE_PROXY_SOCKETS,
	[{[sockets, cp, ip], localhost},
	 {[sockets, irx, ip], test_gsn},
	 {[sockets, 'proxy-irx', ip], proxy_gsn},
	 {[sockets, 'remote-irx', ip], final_gsn},
	 {[sockets, 'remote-irx2', ip], final_gsn_2},
	 {[sockets, sx, ip], localhost},
	 {[node_selection, default, entries, {name, <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, default, entries, {name, <<"topon.s5s8.pgw-2.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, final_gsn_2}},
	 {[node_selection, default, entries, {name, <<"topon.sx.sgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, sgw_u_sx}},
	 {[node_selection, default, entries, {name, <<"topon.sx.pgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, pgw_u01_sx}},
	 {[node_selection, default, entries, {name, <<"topon.pgw-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, default, entries, {name, <<"topon.upf-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, sgw_u_sx}}
	]).

-define(CONFIG_UPDATE_SINGLE_PROXY_SOCKET,
	[{[sockets, cp, ip], localhost},
	 {[sockets, irx, ip], test_gsn},
	 {[sockets, 'remote-irx', ip], final_gsn},
	 {[sockets, 'remote-irx2', ip], final_gsn_2},
	 {[sockets, sx, ip], localhost},
	 {[node_selection, default, entries, {name, <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, default, entries, {name, <<"topon.s5s8.pgw-2.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, final_gsn_2}},
	 {[node_selection, default, entries, {name, <<"topon.sx.sgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, sgw_u_sx}},
	 {[node_selection, default, entries, {name, <<"topon.sx.pgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, pgw_u01_sx}},
	 {[node_selection, default, entries, {name, <<"topon.pgw-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, default, entries, {name, <<"topon.upf-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, sgw_u_sx}}
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
    lib_init_per_group(Config);
init_per_group(no_proxy_map, Config0) ->
    Cf0 = proplists:get_value(ergw_core, ?TEST_CONFIG_SINGLE_PROXY_SOCKET),
    Cf1 = maps:remove(proxy_map, Cf0),
    Cf = lists:keystore(ergw_core, 1, ?TEST_CONFIG_SINGLE_PROXY_SOCKET, {ergw_core, Cf1}),
    Config1 = lists:keystore(app_cfg, 1, Config0, {app_cfg, Cf}),
    Config = update_app_config(proplists:get_value(ip_group, Config1),
			       ?CONFIG_UPDATE_SINGLE_PROXY_SOCKET, Config1),
    lib_init_per_group(Config);
init_per_group(_Group, Config0) ->
    Config1 = lists:keystore(app_cfg, 1, Config0,
			    {app_cfg, ?TEST_CONFIG_MULTIPLE_PROXY_SOCKETS}),
    Config = update_app_config(proplists:get_value(ip_group, Config1),
			       ?CONFIG_UPDATE_MULTIPLE_PROXY_SOCKETS, Config1),
    lib_init_per_group(Config).

end_per_group(Group, _Config)
  when Group == ipv4; Group == ipv6 ->
    ok;
end_per_group(_Group, Config) ->
    ok = lib_end_per_group(Config),
    ok.

common() ->
    [invalid_gtp_pdu,
     create_session_request_missing_ie,
     create_session_request_accept_new,
     %% path_maint,				% does not work (yet) with stateless
     path_restart, path_restart_recovery,
     path_failure_to_pgw,
     path_failure_to_pgw_silent,
     path_failure_to_pgw_and_restore,
     path_failure_to_sgw,
     simple_session,
     simple_session_cp_teid,
     simple_session_random_port,
     duplicate_session_request,
     create_session_overload_response,
     create_session_request_resend,
     create_session_proxy_request_resend,
     create_session_request_timeout,
     create_lb_multi_session,
     one_lb_node_down,
     delete_session_request_resend,
     delete_session_request_timeout,
     error_indication_sgw2pgw,
     error_indication_pgw2sgw,
     %% request_fast_resend, TODO, FIXME
     modify_bearer_request_ra_update,
     modify_bearer_request_tei_update,
     modify_bearer_command,
     modify_bearer_command_resend,
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
     proxy_api_v2,
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
     session_accounting,
     dns_node_selection,
     sx_upf_reconnect,
     sx_upf_removal,
     sx_timeout
     %% delete_bearer_requests_multi
    ].

common_groups() ->
    [{group, single_proxy_interface},
     {group, multiple_proxy_interface},
     {group, no_proxy_map}].

groups() ->
    [{single_proxy_interface, [], common()},
     {multiple_proxy_interface, [], common()},
     {no_proxy_map, [], [simple_session_no_proxy_map]},
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
    ergw_test_sx_up:reset('pgw-u01'),
    ergw_test_sx_up:reset('sgw-u'),
    meck_reset(Config),
    start_gtpc_server(Config),
    reconnect_all_sx_nodes(),
    ClearSxHist andalso
	begin
	    ergw_test_sx_up:history('pgw-u01', true),
	    ergw_test_sx_up:history('sgw-u', true)
	end,
    ok.

init_per_testcase(delete_session_request_resend, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(gtp_path, [passthrough, no_link]),
    Config;
init_per_testcase(create_session_proxy_request_resend, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    ok = meck:expect(gtp_context, send_response,
		     fun(ReqKey, _Request, {create_session_response, _, _}) ->
			     gtp_context:request_finished(ReqKey),
			     ok;
			(ReqKey, Request, Response) ->
			     meck:passthrough([ReqKey, Request, Response])
		     end),
    Config;
init_per_testcase(create_session_request_timeout, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    %% block answer to session in the PGW
    ok = meck:expect(gtp_context, send_response,
		     fun(ReqKey, _Request, {create_session_response, _, _}) ->
			     gtp_context:request_finished(ReqKey),
			     ok;
			(ReqKey, Request, Response) ->
			     meck:passthrough([ReqKey, Request, Response])
		     end),
    ok = meck:expect(ergw_gtp_c_socket, make_send_req,
		     fun(ReqId, Src, Address, Port, _T3, N3, #gtp{type = Type} = Msg, CbInfo)
			   when Type == create_session_request ->
			     %% reduce timeout to 500 ms speed up the test
			     meck:passthrough([ReqId, Src, Address, Port, 500, N3, Msg, CbInfo]);
			(ReqId, Src, Address, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([ReqId, Src, Address, Port, T3, N3, Msg, CbInfo])
		     end),
    ok = meck:expect(ergw_context_statem, handle_event,
		     fun(info = Ev, EvData, #{session := init} = State, Data) ->
			     case meck:passthrough([Ev, EvData, State, Data]) of
				 {next_state, #{session := connecting} = NextState, DataNew, [{state_timeout, _, ReqKey}]} ->
				     %% 1 second timeout for the test
				     Action = [{state_timeout, 1000, ReqKey}],
				     {next_state, NextState, DataNew, Action};
				 Other ->
				     Other
			     end;
			(Ev, EvData, State, Data) ->
			     meck:passthrough([Ev, EvData, State, Data])
		     end),
    Config;
init_per_testcase(delete_session_request_timeout, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    ok = meck:expect(pgw_s5s8, handle_request,
		     fun(ReqKey, #gtp{type = delete_session_request}, _, _, _) ->
			     gtp_context:request_finished(ReqKey),
			     keep_state_and_data;
			(ReqKey, Msg, Resent, State, Data) ->
			     meck:passthrough([ReqKey, Msg, Resent, State, Data])
		     end),
    Config;
init_per_testcase(modify_bearer_command, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == delete_bearer_request_resend;
       TestCase == delete_bearer_request_invalid_teid;
       TestCase == delete_bearer_request_late_response;
       TestCase == modify_bearer_command_timeout ->
    setup_per_testcase(Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun(Socket, Src, DstIP, DstPort, _T3, _N3,
			 #gtp{type = Type} = Msg, CbInfo)
			   when Type == delete_bearer_request;
				Type == update_bearer_request ->
			     %% reduce timeout to 1 second and 2 resends
			     %% to speed up the test
			     meck:passthrough([Socket, Src, DstIP, DstPort, 1000, 2, Msg, CbInfo]);
			(Socket, Src, DstIP, DstPort, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([Socket, Src, DstIP, DstPort, T3, N3, Msg, CbInfo])
		     end),
    Config;
init_per_testcase(path_maint, Config) ->
    ergw_test_lib:set_path_timers(#{busy => #{echo => 700}}),
    setup_per_testcase(Config),
    Config;
init_per_testcase(path_failure_to_pgw_silent, Config) ->
    ok = meck:new(gtp_path, [passthrough, no_link]),
    setup_per_testcase(Config),
    Config;
init_per_testcase(path_failure_to_pgw_and_restore, Config) ->
    ergw_test_lib:set_path_timers(#{down => #{echo => 1}}),
    setup_per_testcase(Config),
    Config;
init_per_testcase(simple_session, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == create_lb_multi_session;
       TestCase == one_lb_node_down ->
    setup_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    Config;
init_per_testcase(simple_session_cp_teid, Config) ->
    {ok, _} = ergw_test_sx_up:feature('sgw-u', ftup, 0),
    setup_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    Config;
init_per_testcase(request_fast_resend, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    ok = meck:expect(pgw_s5s8, handle_request,
		     fun(Request, Msg, Resent, State, Data) ->
			     if Resent -> ok;
				true   -> ct:sleep(1000)
			     end,
			     meck:passthrough([Request, Msg, Resent, State, Data])
		     end),
    Config;
init_per_testcase(create_session_overload_response, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    ok = meck:expect(pgw_s5s8, handle_request,
		     fun(ReqKey, Request, _Resent, _State, _Data) ->
			     Response = make_response(Request, overload, undefined),
			     gtp_context:send_response(ReqKey, Request, Response),
			     {stop, normal}
		     end),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == interop_sgsn_to_sgw;
       TestCase == interop_sgw_to_sgsn ->
    setup_per_testcase(Config),
    ok = meck:new(ggsn_gn_proxy, [passthrough, no_link]),
    reset_path_metrics(),
    Config;
init_per_testcase(update_bearer_request, Config) ->
    %% our PGW does not send update_bearer_request, so we have to fake them
    setup_per_testcase(Config),
    ok = meck:new(pgw_s5s8, [passthrough, no_link]),
    ok = meck:expect(pgw_s5s8, handle_event,
		     fun({call, From}, update_context, _State, #{left_tunnel := LeftTunnel}) ->
			     ergw_pgw_test_lib:pgw_update_context(From, LeftTunnel),
			     keep_state_and_data;
			(Type, Content, State, Data) ->
			     meck:passthrough([Type, Content, State, Data])
		     end),
    ok = meck:expect(pgw_s5s8, handle_response,
		     fun(From, #gtp{type = update_bearer_response}, _, _, _) ->
			     gen_statem:reply(From, ok),
			     keep_state_and_data;
			(From, Response, Request, State, Data) ->
			     meck:passthrough([From, Response, Request, State, Data])
		     end),
    Config;

init_per_testcase(create_session_overload, Config) ->
    setup_per_testcase(Config),
    jobs:modify_queue(create, [{max_size, 0}]),
    jobs:modify_regulator(rate, create, {rate,create,1}, [{limit,1}]),
    Config;
init_per_testcase(dns_node_selection, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(inet_res, [passthrough, no_link, unstick]),
    Config;
init_per_testcase(sx_upf_removal, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(ergw_sx_node, [passthrough, no_link]),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == proxy_context_selection;
     TestCase == proxy_context_invalid_selection;
     TestCase == proxy_context_invalid_mapping;
     TestCase == proxy_api_v2 ->
    setup_per_testcase(Config),
    ok = meck:new(gtp_proxy_ds, [passthrough, no_link]),
    Config;
init_per_testcase(_, Config) ->
    setup_per_testcase(Config),
    Config.

wait_nudsf_empty(Cnt, Status) ->
    case ergw_nudsf:all() of
	[_] ->
	    ok;
	_Other when Cnt =:= 0, Status =:= ok ->
	    ct:pal("Nudsf contexts left: ~p", [_Other]),
	    {fail, "udsf not empty"};
	_Other when Cnt =:= 0 ->
	    ok;
	_Other ->
	    ct:sleep(50),
	    wait_nudsf_empty(Cnt - 1, Status)
    end.

end_per_testcase(Config) ->
    %% stop all paths
    lists:foreach(fun({_, Pid, _}) -> gtp_path:stop(Pid) end, gtp_path_reg:all()),
    stop_gtpc_server(),
    wait_nudsf_empty(10, ?config(tc_status, Config)).

end_per_testcase(create_session_proxy_request_resend, Config) ->
    ok = meck:unload(pgw_s5s8),
    ok = meck:delete(gtp_context, send_response, 3),
    end_per_testcase(Config);
end_per_testcase(create_session_request_timeout, Config) ->
    ok = meck:unload(pgw_s5s8),
    ok = meck:delete(gtp_context, send_response, 3),
    ok = meck:delete(ergw_gtp_c_socket, make_send_req, 8),
    ok = meck:delete(ergw_context_statem, handle_event, 4),
    ok = meck_init_hut_handle_request(?HUT),
    end_per_testcase(Config);
end_per_testcase(delete_session_request_resend, Config) ->
    meck:unload(gtp_path),
    end_per_testcase(Config);
end_per_testcase(delete_session_request_timeout, Config) ->
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config);
end_per_testcase(modify_bearer_command, Config) ->
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config);
end_per_testcase(TestCase, Config)
  when TestCase == delete_bearer_request_resend;
       TestCase == delete_bearer_request_invalid_teid;
       TestCase == delete_bearer_request_late_response;
       TestCase == modify_bearer_command_timeout ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),
    end_per_testcase(Config);
end_per_testcase(path_maint, Config) ->
    ergw_test_lib:set_path_timers(#{busy => #{echo => 60 * 1000}}),
    end_per_testcase(Config);
end_per_testcase(path_failure_to_pgw, Config) ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),
    end_per_testcase(Config);
end_per_testcase(path_failure_to_pgw_silent, Config) ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),
    meck:unload(gtp_path),
    end_per_testcase(Config);
end_per_testcase(path_failure_to_pgw_and_restore, Config) ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),
    ergw_test_lib:set_path_timers(#{down => #{echo => 600 * 1000}}),
    end_per_testcase(Config);
end_per_testcase(path_failure_to_sgw, Config) ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),
    end_per_testcase(Config);
end_per_testcase(simple_session, Config) ->
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config);
end_per_testcase(create_lb_multi_session, Config) ->
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config);
end_per_testcase(one_lb_node_down, Config) ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config);
end_per_testcase(simple_session_cp_teid, Config) ->
    {ok, _} = ergw_test_sx_up:feature('sgw-u', ftup, 1),
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config);
end_per_testcase(request_fast_resend, Config) ->
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config);
end_per_testcase(create_session_overload_response, Config) ->
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config);
end_per_testcase(TestCase, Config)
  when TestCase == interop_sgsn_to_sgw;
       TestCase == interop_sgw_to_sgsn ->
    ok = meck:unload(ggsn_gn_proxy),
    end_per_testcase(Config);
end_per_testcase(update_bearer_request, Config) ->
    ok = meck:unload(pgw_s5s8),
    end_per_testcase(Config);
end_per_testcase(create_session_overload, Config) ->
    jobs:modify_queue(create, [{max_size, 10}]),
    jobs:modify_regulator(rate, create, {rate,create,1}, [{limit,100}]),
    end_per_testcase(Config);
end_per_testcase(dns_node_selection, Config) ->
    ok = meck:unload(inet_res),
    ok = meck:delete(?HUT, init, 2),
    end_per_testcase(Config),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == proxy_context_selection;
     TestCase == proxy_context_invalid_selection;
     TestCase == proxy_context_invalid_mapping;
     TestCase == proxy_api_v2 ->
    ok = meck:unload(gtp_proxy_ds),
    end_per_testcase(Config),
    Config;
end_per_testcase(sx_upf_removal, Config) ->
    ok = meck:unload(ergw_sx_node),
    ok = meck:delete(ergw_sx_socket, call, 5),
    end_per_testcase(Config),
    Config;
end_per_testcase(sx_timeout, Config) ->
    ok = meck:delete(ergw_sx_socket, call, 5),
    end_per_testcase(Config);
end_per_testcase(_, Config) ->
    end_per_testcase(Config).

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
    ?equal(ergw_core:system_info(accept_new, false), true),
    create_session(reject_new, Config),
    ?equal(ergw_core:system_info(accept_new, true), false),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_overload_response() ->
    [{doc, "Check that Create Session Response with Cause Overload works"}].
create_session_overload_response(Config) ->
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},

    %% proxy will set the TEID, so use no_resources_available instead of overload
    create_session(no_resources_available, Config),

    ct:sleep(10),
    ?equal(false, ergw_context:test_cmd(gtp, CtxKey, is_alive)),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_maint() ->
    [{doc, "Check that Echo requests are sent"}].
path_maint(Config) ->
    GSNs = lists:foldl(
	     fun(X, M) -> maps:put(proplists:get_value(X, Config), X, M) end,
	     #{}, [client_ip, test_gsn, proxy_gsn, final_gsn]),

    {GtpC0, _, _} = create_session(random, Config),
    ct:sleep(500),

    {GtpC1, _, _} = create_session(random, GtpC0),
    ct:sleep(500),

    {GtpC2, _, _} = create_session(random, GtpC1),
    ct:sleep(500),

    Pings = lists:foldl(
	      fun({_, {ergw_gtp_c_socket, send_request, [_, _, IP, _, _, _, #gtp{type = echo_request}, _]}, _}, M) ->
		      Key = maps:get(IP, GSNs),
		      maps:update_with(Key, fun(Cnt) -> Cnt + 1 end, 1, M);
		 (_, M) ->
		      M
	      end, #{}, meck:history(ergw_gtp_c_socket)),

    delete_session(GtpC0),
    delete_session(GtpC1),
    delete_session(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),

    meck_validate(Config),

    ?equal(3, map_size(Pings)),
    maps:map(fun(K, V) -> ?match({_, X} when X >= 2, {K, V}) end, Pings),

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
path_failure_to_pgw() ->
    [{doc, "Check that Create Session Request works and "
      "that a path failure (Echo timeout) terminates the session"}].
path_failure_to_pgw(Config) ->
    Cntl = whereis(gtpc_client_server),
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_session(Config),

    #{right_tunnel := #tunnel{socket = CSocket}} = ergw_context:test_cmd(gtp, CtxKey, info),

    FinalGSN = proplists:get_value(final_gsn, Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, _, IP, _, _, _, #gtp{type = echo_request}, CbInfo)
			   when IP =:= FinalGSN ->
			     %% simulate a Echo timeout
			     ergw_gtp_c_socket:send_reply(CbInfo, timeout);
			 (Socket, Src, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([Socket, Src, IP, Port, T3, N3, Msg, CbInfo])
		     end),

    ok = gtp_path:ping(CSocket, v2, FinalGSN),

    %% echo timeout should trigger a DBR to SGW...
    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    %% wait for session cleanup
    ct:sleep(200),
    delete_session(not_found, GtpC),

    %% killing the PGW context
    ?equal(true, ergw_context:test_cmd(gtp, RemoteCtxKey, is_alive)),
    ergw_context:test_cmd(gtp, RemoteCtxKey, kill),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),

    DownPeers = lists:filter(
		  fun({_, State}) -> State =:= down end, gtp_path_reg:all(FinalGSN)),
    ?equal(1, length(DownPeers)),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_failure_to_pgw_silent() ->
    [{doc, "Check that Create Session Request works and "
      "that a path failure (Echo timeout) terminates the session"}].
path_failure_to_pgw_silent(Config) ->
    Cntl = whereis(gtpc_client_server),
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    ok = meck:expect(gtp_path, init,
		     fun ([Parent, Socket, Version, RemoteIP, Trigger, Args0]) ->
			     %% overwrite down notify
			     Args =
				 ergw_test_lib:maps_recusive_merge(
				   Args0, #{down => #{notify => silent}}),
			     meck:passthrough([[Parent, Socket, Version, RemoteIP, Trigger, Args]])
		     end),

    %% kill all paths to ensure the meck override is used
    [gtp_path:stop(Pid) || {_, Pid, _} <- gtp_path_reg:all()],

    {GtpC, _, _} = create_session(Config),

    #{right_tunnel := #tunnel{socket = CSocket}} = ergw_context:test_cmd(gtp, CtxKey, info),

    FinalGSN = proplists:get_value(final_gsn, Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, _, IP, _, _, _, #gtp{type = echo_request}, CbInfo)
			   when IP =:= FinalGSN ->
			     %% simulate a Echo timeout
			     ergw_gtp_c_socket:send_reply(CbInfo, timeout);
			 (Socket, Src, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([Socket, Src, IP, Port, T3, N3, Msg, CbInfo])
		     end),

    ok = gtp_path:ping(CSocket, v2, FinalGSN),

    %% echo timeout should not trigger a context teardown, but no DBR
    ?equal(timeout, recv_pdu(Cntl, undefined, 500, fun(Why) -> Why end)),

    %% check that the session is gone
    delete_session(not_found, GtpC),

    %% killing the PGW context
    ?equal(true, ergw_context:test_cmd(gtp, RemoteCtxKey, is_alive)),
    ergw_context:test_cmd(gtp, RemoteCtxKey, kill),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),

    DownPeers = lists:filter(
		  fun({_, State}) -> State =:= down end, gtp_path_reg:all(FinalGSN)),
    ?equal(1, length(DownPeers)),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_failure_to_pgw_and_restore() ->
    [{doc, "Check that Create Session Request works and "
      "that a path failure (Echo timeout) terminates the session "
      "and is later restored with a valid echo"}].
path_failure_to_pgw_and_restore(Config) ->
    Cntl = whereis(gtpc_client_server),
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    lists:foreach(fun({_, Pid, _}) -> gtp_path:stop(Pid) end, gtp_path_reg:all()),

    {GtpC, _, _} = create_session(Config),

    #{right_tunnel := #tunnel{socket = CSocket}} = ergw_context:test_cmd(gtp, CtxKey, info),

    FinalGSN = proplists:get_value(final_gsn, Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, _, IP, _, _, _, #gtp{type = echo_request}, CbInfo)
			   when IP =:= FinalGSN ->
			     %% simulate a Echo timeout
			     ergw_gtp_c_socket:send_reply(CbInfo, timeout);
			 (Socket, Src, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([Socket, Src, IP, Port, T3, N3, Msg, CbInfo])
		     end),

    ok = gtp_path:ping(CSocket, v2, FinalGSN),

    %% echo timeout should trigger a DBR to SGW.
    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    %% wait for session cleanup
    ct:sleep(200),
    delete_session(not_found, GtpC),

    % Check that IP is marked down
    ?match([_], lists:filter(
		  fun({_, State}) -> State =:= down end, gtp_path_reg:all(FinalGSN))),

    % confirm that a new session will now fail as the PGW is marked as down
    create_session(no_resources_available, Config),
    ct:sleep(200),

    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),

    %% Successful echo, clears down marked IP.
    gtp_path:ping(CSocket, v2, FinalGSN),

    %% wait for 100ms
    ?equal(timeout, recv_pdu(GtpC, undefined, 100, fun(Why) -> Why end)),

    ?match([], lists:filter(
		 fun({_, _, State}) -> State =:= down end, gtp_path_reg:all())),

    %% Check that new session now successfully created
    {GtpC1, _, _} = create_session(Config),
    delete_session(GtpC1),

    %% TBD: killing the PGW context, normally the path down above would take care of
    %%      that. But the path registration for stateless is TBD.
    ?LOG(debug, "All: ~p", [gtp_context_reg:all()]),
    R0 = (catch ergw_context:test_cmd(gtp, RemoteCtxKey, kill)),
    ?LOG(debug, "Kill: ~p", [R0]),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_failure_to_sgw() ->
    [{doc, "Check that Create Session Request works and "
      "that a path failure (Echo timeout) terminates the session"}].
path_failure_to_sgw(Config) ->
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},

    {GtpC, _, _} = create_session(Config),

    #{left_tunnel := #tunnel{socket = CSocket}} = ergw_context:test_cmd(gtp, CtxKey, info),

    ClientIP = proplists:get_value(client_ip, Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, _, IP, _, _, _, #gtp{type = echo_request}, CbInfo)
			   when IP =:= ClientIP ->
			     %% simulate a Echo timeout
			     ergw_gtp_c_socket:send_reply(CbInfo, timeout);
			 (Socket, Src, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([Socket, Src, IP, Port, T3, N3, Msg, CbInfo])
		     end),

    ok = gtp_path:ping(CSocket, v2, ClientIP),

    %% wait for session cleanup
    ct:sleep(200),
    delete_session(not_found, GtpC),

    [?match(#{tunnels := 0}, X) || X <- ergw_api:peer(all)],

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
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
    P = meck:capture(first, ?HUT, handle_request, ['_', GtpRecMatch, '_', '_', '_'], 2),
    ?match(#gtp{seq_no = SeqNo} when SeqNo >= 16#80000, P),

    FirstHR = meck:capture(first, pgw_s5s8, handle_request, ['_', GtpRecMatch, '_', '_', '_'], 2),
    %% ct:pal("FirstHR: ~s", [ergw_test_lib:pretty_print(FirstHR)]),
    ProxyAPN = ?'APN-PROXY' ++ [<<"mnc022">>,<<"mcc222">>,<<"gprs">>],
    ?match(
       #gtp{ie = #{
	      {v2_access_point_name, 0} :=
		       #v2_access_point_name{apn = ProxyAPN},
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
			       reporting_triggers := #reporting_triggers{}
			      }}, Acc) ->
		Acc#{{urr, id} => Id};
	    SERFilter(_, Acc) ->
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
				     #f_teid{teid = choose},
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
				     #f_teid{teid = choose},
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
	    SMRFilter(#update_pdr{} = PDR, Acc) ->
		maps:update_with(pdr, fun(V) -> [PDR|V] end, [PDR], Acc);
	    SMRFilter(_, Acc) ->
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
    ?equal(false, is_map_key(pdr, SMRMap)),

    ok.

%%--------------------------------------------------------------------
simple_session_cp_teid() ->
    [{doc, "Check simple Create Session, Delete Session sequence"}].
simple_session_cp_teid(Config) ->
    init_seq_no(?MODULE, 16#80000),
    GtpC0 = gtp_context(?MODULE, Config),

    {GtpC1, _, _} = create_session(GtpC0),
    delete_session(GtpC1),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    GtpRecMatch = #gtp{type = create_session_request, _ = '_'},
    P = meck:capture(first, ?HUT, handle_request, ['_', GtpRecMatch, '_', '_', '_'], 2),
    ?match(#gtp{seq_no = SeqNo} when SeqNo >= 16#80000, P),

    FirstHR = meck:capture(first, pgw_s5s8, handle_request, ['_', GtpRecMatch, '_', '_', '_'], 2),
    ct:pal("FirstHR: ~s", [ergw_test_lib:pretty_print(FirstHR)]),
    ProxyAPN = ?'APN-PROXY' ++ [<<"mnc022">>,<<"mcc222">>,<<"gprs">>],
    ?match(
       #gtp{ie = #{
	      {v2_access_point_name, 0} :=
		       #v2_access_point_name{apn = ProxyAPN},
	      {v2_international_mobile_subscriber_identity, 0} :=
		   #v2_international_mobile_subscriber_identity{imsi = ?'PROXY-IMSI'},
	      {v2_msisdn, 0} := #v2_msisdn{msisdn = ?'PROXY-MSISDN'}
	     }}, FirstHR),
    ?match(#gtp{seq_no = SeqNo} when SeqNo < 16#80000, FirstHR),

    ?equal([], outstanding_requests()),

    PSeids = pfcp_seids(),
    History = ergw_test_sx_up:history('sgw-u'),
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
						  #source_interface{interface = Intf}}}}
			} = PDR,
		      Acc) ->
		Acc#{{pdr, Intf} => PDR};
	    SERFilter(_, Acc) ->
		Acc
	end(maps:values(SER#pfcp.ie), #{}),

    #{{pdr,'Access'} := PdrAccess,
      {pdr,'Core'} := PdrCore
     } = SERMap,

    ?match(#create_pdr{
	      group = #{pdi := #pdi{group = #{f_teid := #f_teid{choose_id = undefined}}}}},
	   PdrAccess),
    ?match(#create_pdr{
	      group = #{pdi := #pdi{group = #{f_teid := #f_teid{choose_id = undefined}}}}},
	   PdrCore),
    SMRList =
	fun SMRFilter(Value, Acc) when is_list(Value) ->
		lists:foldl(SMRFilter, Acc, Value);
	    SMRFilter(#update_pdr{} = PDR, Acc) ->
		[PDR | Acc];
	    SMRFilter(_, Acc) ->
		Acc
	end(maps:values(SMR#pfcp.ie), []),
    ?equal([], SMRList),

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
    P = meck:capture(first, ?HUT, handle_request, ['_', GtpRecMatch, '_', '_', '_'], 2),
    ?match(#gtp{seq_no = SeqNo} when SeqNo >= 16#80000, P),

    ?equal([], outstanding_requests()),
    ok.

%%--------------------------------------------------------------------
simple_session_no_proxy_map() ->
    [{doc, "Check simple Create Session, Delete Session sequence without proxy_map config"}].
simple_session_no_proxy_map(Config) ->
    init_seq_no(?MODULE, 16#80000),
    GtpC0 = gtp_context(?MODULE, Config),

    {GtpC1, _, _} = create_session(proxy_apn, GtpC0),
    delete_session(GtpC1),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    GtpRecMatch = #gtp{type = create_session_request, _ = '_'},
    P = meck:capture(first, ?HUT, handle_request, ['_', GtpRecMatch, '_', '_', '_'], 2),
    ?match(#gtp{seq_no = SeqNo} when SeqNo >= 16#80000, P),

    ?equal([], outstanding_requests()),
    ok.

%%--------------------------------------------------------------------
create_lb_multi_session() ->
    [{doc, "Create multi sessions across the 2 Load Balancers"}].
create_lb_multi_session(Config) ->
    init_seq_no(?MODULE, 16#80000),
    GtpC = gtp_context(?MODULE, Config),

    GSNs = [{proplists:get_value(K, Config), 0} || K <- [final_gsn, final_gsn_2]],
    CntSinit = maps:from_list(GSNs),

    %% for 6 clients cumulative nCr for at least 1 hit on both lb = 0.984
    %% for 10 clients it is = 0.999. 1 < No of clients =< 10
    %%
    %% however, for small number of tries the deviation from this expected number
    %% is far greater, run with a max. tries of 100 clients...

    fun TestFun(0, _, _) ->
	    ct:fail(max_tries);
	TestFun(Cnt, CntS0, GtpC0) ->
	    {GtpC1, _, _} = create_session(#{apn => ?'APN-LB-1'}, GtpC0),

	    CntS = lists:foldl(
		     fun({#socket_teid_key{
			     type = 'gtp-c', teid = #fq_teid{ip = PeerIP}}, _}, M)
			   when is_map_key(PeerIP, M) ->
			     maps:update_with(PeerIP, fun(C) -> C + 1 end, 1, M);
			(_, M) -> M
		     end, CntS0, gtp_context_reg:all()),

	    {GtpC2, _, _} = delete_session(GtpC1),

	    case maps:fold(fun(_K, V, Acc) -> Acc andalso V /= 0 end, true, CntS) of
		true ->
		    ct:pal("CntS: ~p~nSuccess with ~p tries left", [CntS, Cnt]),
		    ok;
		_ ->
		    TestFun(Cnt - 1, CntS, GtpC2)
	    end
    end(100, CntSinit, GtpC),

    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%----------------------------------------------------------------------
one_lb_node_down() ->
    [{doc, "One lb PGW peer node is down"}].
one_lb_node_down(Config) ->
    %% set one peer node as down gtp_path_req and ensure that it is not chosen
    init_seq_no(?MODULE, 16#80000),

    DownGSN = proplists:get_value(final_gsn_2, Config),
    CSocket = ergw_socket_reg:lookup('gtp-c', 'irx'),

    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, _, IP, _, _, _, #gtp{type = echo_request}, CbInfo)
			   when IP =:= DownGSN ->
			     %% simulate a Echo timeout
			     ergw_gtp_c_socket:send_reply(CbInfo, timeout);
			 (Socket, Src, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([Socket, Src, IP, Port, T3, N3, Msg, CbInfo])
		     end),

    %% create the path
    CPid = gtp_path:maybe_new_path(CSocket, v2, DownGSN, activity),

    %% down the path by forcing a echo
    ok = gtp_path:ping(CPid),
    ct:sleep(200),

    % make sure that worked
    DownPeers = lists:filter(
		  fun({_, State}) -> State =:= down end, gtp_path_reg:all(DownGSN)),
    ?equal(1, length(DownPeers)),

    GtpCs0 = make_gtp_contexts(?NUM_OF_CLIENTS, Config),
    GtpCs1 = lists:map(fun(GtpC0) -> create_session(random, GtpC0) end, GtpCs0),

    PgwFqTeids = [X || {#socket_teid_key{type = 'gtp-c', teid = #fq_teid{ip = PeerIP}}, _} =
			   X <- gtp_context_reg:all(), PeerIP == DownGSN],
    ?match(0, length(PgwFqTeids)), % Check no connection to down peer

    lists:foreach(fun({GtpC1,_,_}) -> delete_session(GtpC1) end, GtpCs1),

    ok = meck:wait(?NUM_OF_CLIENTS, ?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),

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
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_proxy_request_resend() ->
    [{doc, "Check that the proxy does not send the Create Session Request multiple times"}].
create_session_proxy_request_resend(Config) ->
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    GtpC = gtp_context(Config),
    Request = make_request(create_session_request, simple, GtpC),

    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, 2 * 1000, error)),

    %% killing the proxy PGW context
    ?equal(true, ergw_context:test_cmd(gtp, CtxKey, is_alive)),
    ergw_context:test_cmd(gtp, CtxKey, terminate_context),

    ?match(1, meck:num_calls(pgw_s5s8, handle_request,
			     ['_', #gtp{type = create_session_request, _ = '_'}, '_', '_', '_'])),

    %% the init timeout will eventually take down the remote context, make it exit quicker
    ergw_context:test_cmd(gtp, RemoteCtxKey, kill),

    wait4tunnels(?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_timeout() ->
    [{doc, "Check that the proxy does shutdown the context on timeout"}].
create_session_request_timeout(Config) ->
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    GtpC = gtp_context(Config),
    Request = make_request(create_session_request, simple, GtpC),

    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, 2 * 1000, error)),

    ?equal(false, ergw_context:test_cmd(gtp, CtxKey, is_alive)),
    ?match(1, meck:num_calls(pgw_s5s8, handle_request, '_')),

    %% the init timeout will eventually take down the remote context, make it exit quicker
    ergw_context:test_cmd(gtp, RemoteCtxKey, kill),

    wait4tunnels(?TIMEOUT),
    ?equal([], outstanding_requests()),
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
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
delete_session_request_timeout() ->
    [{doc, "Check that a Delete Session Request terminates the "
           "proxy session even when the final GSN fails"}].
delete_session_request_timeout(Config) ->
    ProxyCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_session(Config),
    ?equal(true, ergw_context:test_cmd(gtp, ProxyCtxKey, is_alive)),

    Request = make_request(delete_session_request, simple, GtpC),

    %% simulate retransmissions
    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, ?TIMEOUT, error)),
    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, ?TIMEOUT, error)),
    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, ?TIMEOUT, error)),

    %% killing the PGW context
    ?equal(true, ergw_context:test_cmd(gtp, ProxyCtxKey, is_alive)),
    ergw_context:test_cmd(gtp, ProxyCtxKey, kill),

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

    ct:sleep(200),
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
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    ProxyCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_session(Config),
    ?equal(true, ergw_context:test_cmd(gtp, CtxKey, is_alive)),
    #{bearer := #{right := RightBearer}} = ergw_context:test_cmd(gtp, CtxKey, info),

    ergw_test_sx_up:send('sgw-u', make_error_indication_report(RightBearer)),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_bearer_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    ct:sleep(200),
    delete_session(not_found, GtpC),

    %% killing the PGW context
    ?equal(true, ergw_context:test_cmd(gtp, ProxyCtxKey, is_alive)),
    ergw_context:test_cmd(gtp, ProxyCtxKey, kill),

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
    ?equal(timeout, recv_pdu(GtpC1, undefined, 100, fun(Why) -> Why end)),

    GtpC2 = Send(change_notification_request, simple, GtpC1),
    ?equal(timeout, recv_pdu(GtpC2, undefined, 100, fun(Why) -> Why end)),

    GtpC3 = Send(change_notification_request, without_tei, GtpC2),
    ?equal(timeout, recv_pdu(GtpC3, undefined, 100, fun(Why) -> Why end)),

    ?equal([], outstanding_requests()),

    delete_session(GtpC3),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(3, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),
    ?match(3, meck:num_calls(pgw_s5s8, handle_request, ['_', '_', true, '_', '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_request_ra_update() ->
    [{doc, "Check Modify Bearer Routing Area Update"}].
modify_bearer_request_ra_update(Config) ->
    ProxyCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC1, _, _} = create_session(Config),
    ?equal(true, ergw_context:test_cmd(gtp, ProxyCtxKey, is_alive)),
    #{left_tunnel := LeftTunnel1, bearer := #{left := LeftBearer1}} =
	ergw_context:test_cmd(gtp, ProxyCtxKey, info),

    {GtpC2, _, _} = modify_bearer(ra_update, GtpC1),
    #{left_tunnel := LeftTunnel2, bearer := #{left := LeftBearer2}} =
	ergw_context:test_cmd(gtp, ProxyCtxKey, info),

    ?equal([], outstanding_requests()),
    delete_session(GtpC2),

    %% make sure the SGW side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the PDN-GW side control TEID don't change
    ?equal(LeftTunnel1#tunnel.remote, LeftTunnel2#tunnel.remote),
    ?equal(LeftBearer1#bearer.remote, LeftBearer2#bearer.remote),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
modify_bearer_request_tei_update() ->
    [{doc, "Check Modify Bearer with TEID update (e.g. SGW change)"}].
modify_bearer_request_tei_update(Config) ->
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    ProxyCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC1, _, _} = create_session(Config),
    ?equal(true, ergw_context:test_cmd(gtp, ProxyCtxKey, is_alive)),
    #{left_tunnel := LeftTunnel1, bearer := #{left := LeftBearer1}} =
	ergw_context:test_cmd(gtp, ProxyCtxKey, info),

    ?equal(true, ergw_context:test_cmd(gtp, CtxKey, is_alive)),
    #{right_tunnel := RightTunnel1} = ergw_context:test_cmd(gtp, CtxKey, info),

    ProxyRegKey1 = gtp_context:tunnel_key(local, RightTunnel1),
    ?equal(true, ergw_context:test_cmd(gtp, ProxyRegKey1, is_alive)),

    {GtpC2, _, _} = modify_bearer(tei_update, GtpC1),
    #{left_tunnel := LeftTunnel2, bearer := #{left := LeftBearer2}} =
	ergw_context:test_cmd(gtp, ProxyCtxKey, info),

    #{right_tunnel := RightTunnel2} = ergw_context:test_cmd(gtp, CtxKey, info),
    ProxyRegKey2 = gtp_context:tunnel_key(local, RightTunnel2),
    ?equal(false, ergw_context:test_cmd(gtp, ProxyRegKey1, is_alive)),
    ?equal(true, ergw_context:test_cmd(gtp, ProxyRegKey2, is_alive)),

    ?equal([], outstanding_requests()),
    delete_session(GtpC2),

    %% make sure the SGW side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the PDN-GW side control TEID DOES change
    ?not_equal(LeftTunnel1#tunnel.remote, LeftTunnel2#tunnel.remote),
    ?equal(LeftBearer1#bearer.remote, LeftBearer2#bearer.remote),

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

    GtpRecMatch = #gtp{type = modify_bearer_command, _ = '_'},
    P = meck:capture(first, pgw_s5s8, handle_request, ['_', GtpRecMatch, '_', '_', '_'], 2),
    ?match(#gtp{seq_no = SeqNo} when SeqNo >= 16#800000, P),

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
    meck:expect(gtp_proxy_ds, map,
		fun(ProxyInfo) ->
			proxy_context_selection_map(ProxyInfo, <<"ams">>)
		end),

    {GtpC, _, _} = create_session(Config),
    ?equal([], outstanding_requests()),
    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
proxy_context_invalid_selection() ->
    [{doc, "Check that the proxy context selection works"}].
proxy_context_invalid_selection(Config) ->
    meck:expect(gtp_proxy_ds, map,
		fun(ProxyInfo) ->
			proxy_context_selection_map(ProxyInfo, <<"undefined">>)
		end),

    {GtpC, _, _} = create_session(Config),
    ?equal([], outstanding_requests()),
    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
proxy_context_invalid_mapping() ->
    [{doc, "Check rejection of a session when the proxy selects failes"}].
proxy_context_invalid_mapping(Config) ->
    meck:expect(gtp_proxy_ds, map,
		fun(_ProxyInfo) -> {error, user_authentication_failed} end),

    {_, _, _} = create_session(invalid_mapping, Config),
    ?equal([], outstanding_requests()),

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

    {GtpC, _, _} = create_session(Config),
    ?equal([], outstanding_requests()),
    delete_session(GtpC),

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
    ProxyCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_session(Config),
    ?equal(true, ergw_context:test_cmd(gtp, ProxyCtxKey, is_alive)),

    Self = self(),
    spawn(fun() -> Self ! {req, ergw_context:test_cmd(gtp, ProxyCtxKey, delete_context)} end),

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
    ProxyCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {_, _, _} = create_session(Config),
    ?equal(true, ergw_context:test_cmd(gtp, ProxyCtxKey, is_alive)),

    Self = self(),
    spawn(fun() -> Self ! {req, ergw_context:test_cmd(gtp, ProxyCtxKey, delete_context)} end),

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
    ProxyCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_session(Config),
    ?equal(true, ergw_context:test_cmd(gtp, ProxyCtxKey, is_alive)),

    Self = self(),
    spawn(fun() -> Self ! {req, ergw_context:test_cmd(gtp, ProxyCtxKey, delete_context)} end),

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
    ProxyCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_session(Config),
    ?equal(true, ergw_context:test_cmd(gtp, ProxyCtxKey, is_alive)),

    Self = self(),
    spawn(fun() -> Self ! {req, ergw_context:test_cmd(gtp, ProxyCtxKey, delete_context)} end),

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
    ProxyCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC1, _, _} = ergw_ggsn_test_lib:create_pdp_context(Config),
    ?equal(true, ergw_context:test_cmd(gtp, ProxyCtxKey, is_alive)),
    #{left_tunnel := LeftTunnel1, bearer := #{left := LeftBearer1}} =
	ergw_context:test_cmd(gtp, ProxyCtxKey, info),

    check_contexts_metric(v1, 3, 1),
    check_contexts_metric(v2, 0, 0),

    {GtpC2, _, _} = modify_bearer(tei_update, GtpC1),
    #{left_tunnel := LeftTunnel2, bearer := #{left := LeftBearer2}} =
	ergw_context:test_cmd(gtp, ProxyCtxKey, info),

    ?equal([], outstanding_requests()),
    check_contexts_metric(v1, 3, 0),
    check_contexts_metric(v2, 3, 1),
    delete_session(GtpC2),

    %% make sure the SGSN/SGW side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the GGSN/PDN-GW side control TEID DOES change
    ?not_equal(LeftTunnel1#tunnel.remote, LeftTunnel2#tunnel.remote),
    ?equal(LeftBearer1#bearer.remote, LeftBearer2#bearer.remote),

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

    ct:sleep(200),
    check_contexts_metric(v1, 3, 0),
    check_contexts_metric(v2, 3, 0),
    ok.

%%--------------------------------------------------------------------
interop_sgw_to_sgsn() ->
    [{doc, "Check 3GPP T 23.401, Annex D, SGW to SGSN handover"}].
interop_sgw_to_sgsn(Config) ->
    ProxyCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC1, _, _} = create_session(Config),
    ?equal(true, ergw_context:test_cmd(gtp, ProxyCtxKey, is_alive)),
    #{left_tunnel := LeftTunnel1, bearer := #{left := LeftBearer1}} =
      ergw_context:test_cmd(gtp, ProxyCtxKey, info),

    check_contexts_metric(v1, 0, 0),
    check_contexts_metric(v2, 3, 1),
    {GtpC2, _, _} = ergw_ggsn_test_lib:update_pdp_context(tei_update, GtpC1),
    #{left_tunnel := LeftTunnel2, bearer := #{left := LeftBearer2}} =
	ergw_context:test_cmd(gtp, ProxyCtxKey, info),

    check_contexts_metric(v1, 3, 1),
    check_contexts_metric(v2, 3, 0),
    ergw_ggsn_test_lib:delete_pdp_context(GtpC2),

    %% make sure the SGSN/SGW side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the GGSN/PDN-GW side control TEID DOES change
    ?not_equal(LeftTunnel1#tunnel.remote, LeftTunnel2#tunnel.remote),
    ?equal(LeftBearer1#bearer.remote, LeftBearer2#bearer.remote),

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

    ct:sleep(200),
    check_contexts_metric(v1, 3, 0),
    check_contexts_metric(v2, 3, 0),
    ok.

%%--------------------------------------------------------------------
update_bearer_request() ->
    [{doc, "Check PGW initiated Update Bearer"},
     {timetrap,{seconds,60}}].
update_bearer_request(Config) ->
    Cntl = whereis(gtpc_client_server),
    ProxyCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_session(Config),
    ?equal(true, ergw_context:test_cmd(gtp, ProxyCtxKey, is_alive)),

    Self = self(),
    spawn(fun() -> Self ! {req, ergw_context:test_cmd(gtp, ProxyCtxKey, update_context)} end),

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
    #{pfcp:= PCtx} = gtp_context:info(Pid),

    %% make sure we handle that the Sx node is not returning any accounting
    ergw_test_sx_up:accounting('sgw-u', off),

    SessionOpts1 = ergw_test_lib:query_usage_report(PCtx),
    ?equal(false, maps:is_key('InPackets', SessionOpts1)),
    ?equal(false, maps:is_key('InOctets', SessionOpts1)),

    %% enable accouting again....
    ergw_test_sx_up:accounting('sgw-u', on),

    SessionOpts2 = ergw_test_lib:query_usage_report(PCtx),
    ?match(#{'InPackets' := 3, 'OutPackets' := 1,
	     'InOctets' := 4, 'OutOctets' := 2}, SessionOpts2),

    SessionOpts3 = ergw_test_lib:query_usage_report(PCtx),
    ?match(#{'InPackets' := 3, 'OutPackets' := 1,
	     'InOctets' := 4, 'OutOctets' := 2}, SessionOpts3),

    delete_session(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
-define(ProxyV, "proxy.example.net.apn.epc.mnc022.mcc222.3gppnetwork.org").
-define(ProxyH, "proxy.example.net.apn.epc.mnc001.mcc001.3gppnetwork.org").
-define(PGW, "topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org").
-define(UPF, "topon.sx.pgw-u02.epc.mnc001.mcc001.3gppnetwork.org").

dns_node_selection() ->
    [{doc, "Check simple Create Session, Delete Session sequence"}].
dns_node_selection(Config) ->
    %% overwrite the node selection
    meck:expect(?HUT, init,
		fun (Opts, Data) ->
			meck:passthrough([Opts#{node_selection => [mydns]}, Data])
		end),

    DNSrr = fun (Name, a, IP) when tuple_size (IP) == 4 ->
		    {ok, {dns_rec, {dns_header, 1, true, query, false, false, true, true, false, 0},
			  [{dns_query, Name, a, in}],
			  [{dns_rr, Name, a, in, 0, 8595, IP, undefined, [], false}],
			  [], []}};
		(Name, aaaa, IP) when tuple_size (IP) == 8 ->
		    {ok, {dns_rec, {dns_header, 1, true, query, false, false, true, true, false, 0},
			  [{dns_query, Name, aaaa, in}],
			  [{dns_rr, Name, aaaa, in, 0, 8595, IP, undefined, [], false}],
			  [], []}};
		(_, _, _) ->
		    {error, nxdomain}
	    end,

    meck:expect(
      inet_res, resolve,
      fun (?ProxyV, in, naptr, _Opts) ->
	      {ok, {dns_rec, {dns_header, 7509, true, query, false, false, true, true, false, 0},
		    [{dns_query, ?ProxyV, naptr, in}],
		    [{dns_rr, ?ProxyV, naptr, in, 0, 593,
		      {100, 100, "a", "x-3gpp-pgw:x-s8-gtp:x-gn-gtp:x-gp", [], ?PGW},
		      undefined, [], false}],
		    [{dns_rr,"epc.mnc022.mcc222.3gppnetwork.org", soa, in, 0, 3600,
		      {"epc.mnc022.mcc222.3gppnetwork.org",
		       "administrator.example.com", 1, 3600, 15, 604800, 3600},
		      undefined,[],false},
		     {dns_rr, "epc.mnc022.mcc222.3gppnetwork.org", ns, in, 0, 593,
		      "dns1.mnc022.mcc222.3gppnetwork.org", undefined, [], false},
		     {dns_rr, "epc.mnc022.mcc222.3gppnetwork.org", ns, in, 0, 593,
		      "dns0.mnc022.mcc222.3gppnetwork.org", undefined, [], false}],
		    []}};
	  (?PGW, in, Type, _Opts) when Type =:= a; Type =:= aaaa ->
	      ct:pal("Resolve: ~0p", [{?PGW, in, Type, _Opts}]),
	      DNSrr(?PGW, Type, proplists:get_value(final_gsn, Config));
	  (?ProxyH, in, naptr, _Opts) ->
	      {ok, {dns_rec, {dns_header, 7509, true, query, false, false, true, true, false, 0},
		    [{dns_query, ?ProxyH, naptr, in}],
		    [{dns_rr, ?ProxyH, naptr, in, 0, 593,
		      {100, 100, "a", "x-3gpp-upf:x-sxa:x-sxb", [], ?UPF},
		      undefined, [], false}],
		    [{dns_rr,"epc.mnc001.mcc001.3gppnetwork.org", soa, in, 0, 3600,
		      {"epc.mnc001.mcc001.3gppnetwork.org",
		       "administrator.example.com", 1, 3600, 15, 604800, 3600},
		      undefined,[],false},
		     {dns_rr, "epc.mnc001.mcc001.3gppnetwork.org", ns, in, 0, 593,
		      "dns1.mnc001.mcc001.3gppnetwork.org", undefined, [], false},
		     {dns_rr, "epc.mnc001.mcc001.3gppnetwork.org", ns, in, 0, 593,
		      "dns0.mnc001.mcc001.3gppnetwork.org", undefined, [], false}],
		    []}};
	  (?UPF, in, Type, _Opts) when Type =:= a; Type =:= aaaa ->
	      DNSrr(?UPF, Type, proplists:get_value(pgw_u02_sx, Config));
	  (Name, Class, Type, Opts) ->
	      meck:passthrough([Name, Class, Type, Opts])
      end),

    lists:foreach(
	fun(_) ->
	    {GtpC, _, _} = create_session(Config),
	    delete_session(GtpC)
	end,
	lists:seq(1, 10 + rand:uniform(10))
    ),

    timer:sleep(1100),

    {GtpC3, _, _} = create_session(Config),
    delete_session(GtpC3),

    ?equal(6, meck:num_calls(inet_res, resolve, '_')),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),

    ?equal([], outstanding_requests()),

    ok.

%%--------------------------------------------------------------------
sx_upf_reconnect() ->
    [{doc, "Test UPF reconnect behavior"}].
sx_upf_reconnect(Config) ->
    {GtpCinit, _, _} = create_session(Config),
    delete_session(GtpCinit),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    ergw_test_sx_up:restart('sgw-u'),
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

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
sx_upf_removal() ->
    [{doc, "Test UPF removal mid session"}].
sx_upf_removal(Config) ->
    Cntl = whereis(gtpc_client_server),

    %% reduce Sx timeout to speed up test
    ok = meck:expect(ergw_sx_socket, call,
		     fun(Peer, _T1, _N1, Msg, CbInfo) ->
			     meck:passthrough([Peer, 100, 2, Msg, CbInfo])
		     end),

    {GtpC, _, _} = create_session(Config),

    ergw_test_sx_up:disable('sgw-u'),

    %% heart beats are send every 5000 ms, make sure we wait long enough
    Req = recv_pdu(Cntl, 6000),
    ?match(#gtp{type = delete_bearer_request}, Req),
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
    ergw_test_sx_up:disable('sgw-u'),

    create_session(system_failure, Config),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
%% The following test in inherently broken and disabled.
%%
%% For the test suite, proxy contexts and PGW server context all live
%% in the same registry. The delete_contexts/3 call will not distingiush
%% between them. This leads to all kind of interesting race conditions
%% that can not occure in live networks.
%%
%% It is unclear whether is any value in sorting the race condition out
%% to get this test to pass.
delete_bearer_requests_multi() ->
    [{doc, "Check ergw_api deletes multiple contexts"}].
delete_bearer_requests_multi(Config) ->
    Cntl = whereis(gtpc_client_server),

    {GtpC0, _, _} = create_session(Config),
    {GtpC1, _, _} = create_session(random, GtpC0),

    Ref = make_ref(),
    Self = self(),
    spawn(fun() -> Self ! {req, Ref, ergw_api:delete_contexts(3)} end),

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

reset_path_metrics() ->
    Name = gtp_path_contexts_total,
    Metrics = prometheus_gauge:values(default, Name),
    _ = [prometheus_gauge:remove(Name, [V || {_,V} <- LabelValues])
	 || {LabelValues, _} <- Metrics],
    ok.

check_contexts_metric(Version, Cnt, Expect) ->
    Metrics0 = prometheus_gauge:values(default, gtp_path_contexts_total),
    Metrics = lists:foldl(fun({K, V}, Acc) ->
				  Tags = [Tag || {_, Tag} <- K],
				  case lists:member(Version, Tags) of
				      true  -> [{Tags, V} | Acc];
				      false -> Acc
				  end
			  end, [], Metrics0),
    ?equal(Cnt, length(Metrics)),
    [?equal({Path, Expect}, M) || {Path, _} = M <- Metrics].

pfcp_seids() ->
    lists:flatten(ets:match(gtp_context_reg, {#seid_key{seid = '$1'},{ergw_sx_node, '_'}})).

make_gtp_contexts(Cnt, Config) ->
    BaseIP = proplists:get_value(client_ip, Config),
    make_gtp_contexts(Cnt, BaseIP, Config).

make_gtp_context_ip(Id, {A,B,C,D}) ->
    {A,B,C,D + Id};
make_gtp_context_ip(Id, {A,B,C,D,E,F,G,H}) ->
    {A,B,C,D,E,F,G,H + Id}.

make_gtp_contexts(0, _BaseIP, _Config) ->
    [];
make_gtp_contexts(Id, BaseIP, Config) ->
    IP = make_gtp_context_ip(Id, BaseIP),
    [gtp_context(?MODULE, IP, Config) | make_gtp_contexts(Id - 1, BaseIP, Config)].
