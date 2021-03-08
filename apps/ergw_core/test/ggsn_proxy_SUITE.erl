%% Copyright 2017-2020, Travelping GmbH <info@travelping.com>

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
-define(NUM_OF_CLIENTS, 8). %% Num of IP clients for multi contexts

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

	 {ergw_core,
	  #{node =>
		[{node_id, <<"GGSN">>}],
	    sockets =>
		[{cp, [{type, 'gtp-u'},
		       {vrf, cp},
		       {ip, ?MUST_BE_UPDATED},
		       {reuseaddr, true}
		      ]},
		 {irx, [{type, 'gtp-c'},
			{vrf, irx},
			{ip,  ?MUST_BE_UPDATED},
			{reuseaddr, true}
		       ]},
		 {'proxy-irx', [{type, 'gtp-c'},
				{vrf, irx},
				{ip,  ?MUST_BE_UPDATED},
				{reuseaddr, true}
			       ]},
		 {'remote-irx', [{type, 'gtp-c'},
				 {vrf, irx},
				 {ip,  ?MUST_BE_UPDATED},
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
		       {node_selection, [default]},
		       {contexts,
			[{<<"ams">>,
			  [{proxy_sockets, ['proxy-irx']}]}]}
		      ],
		  %% remote GGSN handler
		  'gn-remote' =>
		      [{handler, ggsn_gn},
		       {protocol, gn},
		       {sockets, ['remote-irx', 'remote-irx2']},
		       {node_selection, [default]},
		       {aaa, [{'Username',
			       [{default, ['IMSI', <<"@">>, 'APN']}]}]}
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
			       service     => 'x-3gpp-ggsn',
			       protocols   => ['x-gn', 'x-gp'],
			       replacement => <<"topon.gtp.ggsn.epc.mnc001.mcc001.3gppnetwork.org">>},
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
			       service     => 'x-3gpp-ggsn',
			       protocols   => ['x-gn', 'x-gp'],
			       replacement => <<"topon.gtp.ggsn.epc.mnc001.mcc001.3gppnetwork.org">>},
			     #{type        => naptr,
			       name        => <<"lb-1.apn.epc.mnc000.mcc700.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-ggsn',
			       protocols   => ['x-gn', 'x-gp'],
			       replacement => <<"topon.gtp.ggsn-2.epc.mnc001.mcc001.3gppnetwork.org">>},

			     %% A/AAAA record alternatives
			     #{type => host,
			       name => <<"topon.gtp.ggsn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.gtp.ggsn-2.epc.mnc001.mcc001.3gppnetwork.org">>,
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
			    ]}
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
		       {ip_pools, [<<"pool-A">>]}],
		  nodes =>
		      [{<<"topon.sx.sgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]},
		       {<<"topon.sx.pgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]},
		       {<<"topon.upf-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]}]
		  },

	    path_management =>
		[{t3, 10 * 1000},
		 {n3,  5},
		 {echo, 60 * 1000},
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
		[{node_id, <<"GGSN">>}],
	    sockets =>
		[{cp, [{type, 'gtp-u'},
		       {vrf, cp},
		       {ip, ?MUST_BE_UPDATED},
		       {reuseaddr, true}
		      ]},
		 {irx, [{type, 'gtp-c'},
			{vrf, irx},
			{ip,  ?TEST_GSN_IPv4},
			{reuseaddr, true}
		       ]},
		 {'remote-irx', [{type, 'gtp-c'},
				 {vrf, irx},
				 {ip,  ?FINAL_GSN_IPv4},
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
		       {node_selection, [default]},
		       {contexts,
			[{<<"ams">>,
			  [{proxy_sockets, ['irx']}]}]}
		      ],
		  %% remote GGSN handler
		  'gn-remote' =>
		      [{handler, ggsn_gn},
		       {protocol, gn},
		       {sockets, ['remote-irx', 'remote-irx2']},
		       {node_selection, [default]},
		       {aaa, [{'Username',
			       [{default, ['IMSI', <<"@">>, 'APN']}]}]}
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
			       service     => 'x-3gpp-ggsn',
			       protocols   => ['x-gn', 'x-gp'],
			       replacement => <<"topon.gtp.ggsn.epc.mnc001.mcc001.3gppnetwork.org">>},
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
			       service     => 'x-3gpp-ggsn',
			       protocols   => ['x-gn', 'x-gp'],
			       replacement => <<"topon.gtp.ggsn.epc.mnc001.mcc001.3gppnetwork.org">>},
			     #{type        => naptr,
			       name        => <<"lb-1.apn.epc.mnc000.mcc700.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-ggsn',
			       protocols   => ['x-gn', 'x-gp'],
			       replacement => <<"topon.gtp.ggsn-2.epc.mnc001.mcc001.3gppnetwork.org">>},

			     %% A/AAAA record alternatives
			     #{type => host,
			       name => <<"topon.gtp.ggsn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.gtp.ggsn-2.epc.mnc001.mcc001.3gppnetwork.org">>,
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
			    ]}
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
			 {irx, [{features, ['Access', 'Core']}]},
			 {'remote-irx', [{features, ['Access']}]},
			 {'remote-irx2', [{features, ['Access']}]},
			 {example, [{features, ['SGi-LAN']}]}]
		       },
		       {ip_pools, [<<"pool-A">>]}],
		  nodes =>
		      [{<<"topon.sx.sgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]},
		       {<<"topon.sx.pgw-u01.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]},
		       {<<"topon.upf-1.nodes.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]}]
		 },

	    path_management =>
		[{t3, 10 * 1000},
		 {n3,  5},
		 {echo, 60 * 1000},
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
	 {[node_selection, default, entries, {name, <<"topon.gtp.ggsn.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, default, entries, {name, <<"topon.gtp.ggsn-2.epc.mnc001.mcc001.3gppnetwork.org">>}],
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
	 {[node_selection, default, entries, {name, <<"topon.gtp.ggsn.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, default, entries, {name, <<"topon.gtp.ggsn-2.epc.mnc001.mcc001.3gppnetwork.org">>}],
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
     create_pdp_context_request_missing_ie,
     create_pdp_context_request_accept_new,
     path_maint,
     path_restart, path_restart_recovery,
     ggsn_broken_recovery,
     path_failure_to_ggsn,
     path_failure_to_ggsn_and_restore,
     path_failure_to_sgsn,
     simple_pdp_context_request,
     simple_pdp_context_request_no_proxy_map,
     create_pdp_context_request_resend,
     create_pdp_context_proxy_request_resend,
     create_pdp_context_request_timeout,
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
     update_pdp_context_request_broken_recovery,
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
     %% delete_bearer_requests_multi
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
    ct:pal("Sockets: ~p", [ergw_socket_reg:all()]),
    ergw_test_sx_up:reset('pgw-u01'),
    ergw_test_sx_up:reset('sgw-u'),
    meck_reset(Config),
    start_gtpc_server(Config),
    reconnect_all_sx_nodes(),
    ClearSxHist andalso ergw_test_sx_up:history('pgw-u01', true),
    ok.

init_per_testcase(TestCase, Config)
  when TestCase == path_restart;
       TestCase == ggsn_broken_recovery ->
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
init_per_testcase(create_pdp_context_request_timeout, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    %% block session in the GGSN
    ok = meck:expect(ggsn_gn, handle_request,
		     fun(ReqKey, #gtp{type = create_pdp_context_request}, _, _, _) ->
			     gtp_context:request_finished(ReqKey),
			     keep_state_and_data;
			(ReqKey, Msg, Resent, State, Data) ->
			     meck:passthrough([ReqKey, Msg, Resent, State, Data])
		     end),
    ok = meck:expect(ergw_gtp_c_socket, make_send_req,
		     fun(ReqId, Src, Address, Port, _T3, N3, #gtp{type = Type} = Msg, CbInfo)
			   when Type == create_session_request ->
			     %% reduce timeout to 500 ms speed up the test
			     meck:passthrough([ReqId, Src, Address, Port, 500, N3, Msg, CbInfo]);
			(ReqId, Src, Address, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([ReqId, Src, Address, Port, T3, N3, Msg, CbInfo])
		     end),
    ok = meck:expect(?HUT, handle_request,
		     fun(ReqKey, Request, Resent, State, Data) ->
			     case meck:passthrough([ReqKey, Request, Resent, State, Data]) of
				 {next_state, connecting, DataNew, _} ->
				     %% 1 second timeout for the test
				     Action = [{state_timeout, 1000, connecting}],
				     {next_state, connecting, DataNew, Action};
				 Other ->
				     Other
			     end
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
		     fun(Socket, Src, DstIP, DstPort, _T3, _N3,
			 #gtp{type = delete_pdp_context_request} = Msg, CbInfo) ->
			     %% reduce timeout to 1 second and 2 resends
			     %% to speed up the test
			     meck:passthrough([Socket, Src, DstIP, DstPort, 1000, 2, Msg, CbInfo]);
			(Socket, Src, DstIP, DstPort, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([Socket, Src, DstIP, DstPort, T3, N3, Msg, CbInfo])
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
init_per_testcase(path_maint, Config) ->
    ergw_test_lib:set_path_timers(#{'echo' => 700}),
    setup_per_testcase(Config),
    Config;
init_per_testcase(path_failure_to_ggsn_and_restore, Config) ->
    ergw_test_lib:set_path_timers(#{down => #{echo => 1}}),
    setup_per_testcase(Config),
    Config;
init_per_testcase(simple_pdp_context_request, Config) ->
    setup_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    Config;
init_per_testcase(TestCase, Config)
  when TestCase == create_lb_multi_context;
       TestCase == one_lb_node_down ->
    setup_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    Config;
init_per_testcase(ggsn_update_pdp_context_request, Config) ->
    %% our GGSN does not send update_bearer_request, so we have to fake them
    setup_per_testcase(Config),
    ok = meck:new(ggsn_gn, [passthrough, no_link]),
    ok = meck:expect(ggsn_gn, handle_event,
		     fun({call, From}, update_context, _State, #{left_tunnel := LeftTunnel}) ->
			     ergw_ggsn_test_lib:ggsn_update_context(From, LeftTunnel),
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

end_per_testcase(_Config) ->
    stop_gtpc_server().

end_per_testcase(TestCase, Config)
  when TestCase == path_restart;
       TestCase == ggsn_broken_recovery ->
    meck:unload(gtp_path),
    end_per_testcase(Config),
    Config;
end_per_testcase(TestCase, Config)
  when TestCase == create_lb_multi_context;
       TestCase == one_lb_node_down->
    ok = meck:unload(ggsn_gn),
    end_per_testcase(Config),
    Config;
end_per_testcase(create_pdp_context_proxy_request_resend, Config) ->
    ok = meck:unload(ggsn_gn),
    end_per_testcase(Config),
    Config;
end_per_testcase(create_pdp_context_request_timeout, Config) ->
    ok = meck:unload(ggsn_gn),
    ok = meck:delete(ergw_gtp_c_socket, make_send_req, 8),
    ok = meck:delete(?HUT, handle_request, 5),
    ok = meck_init_hut_handle_request(?HUT),
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
    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),
    end_per_testcase(Config),
    Config;
end_per_testcase(request_fast_resend, Config) ->
    ok = meck:unload(ggsn_gn),
    end_per_testcase(Config),
    Config;
end_per_testcase(path_maint, Config) ->
    ergw_test_lib:set_path_timers(#{'echo' => 60 * 1000}),
    end_per_testcase(Config);
end_per_testcase(path_failure_to_ggsn, Config) ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),
    end_per_testcase(Config);
end_per_testcase(path_failure_to_ggsn_and_restore, Config) ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),
    ergw_test_lib:set_path_timers(#{down => #{echo => 600 * 1000}}),
    end_per_testcase(Config);
end_per_testcase(path_failure_to_sgsn, Config) ->
    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),
    end_per_testcase(Config);
end_per_testcase(simple_pdp_context_request, Config) ->
    meck:unload(ggsn_gn),
    end_per_testcase(Config),
    Config;
end_per_testcase(ggsn_update_pdp_context_request, Config) ->
    meck:unload(ggsn_gn),
    end_per_testcase(Config),
    Config;
end_per_testcase(update_pdp_context_request_broken_recovery, Config) ->
    meck:delete(gtp_context, send_response, 3),
    end_per_testcase(Config),
    Config;
end_per_testcase(create_pdp_context_overload, Config) ->
    jobs:modify_queue(create, [{max_size, 10}]),
    jobs:modify_regulator(rate, create, {rate,create,1}, [{limit,100}]),
    end_per_testcase(Config),
    Config;
end_per_testcase(sx_upf_removal, Config) ->
    ok = meck:unload(ergw_sx_node),
    ok = meck:delete(ergw_sx_socket, call, 5),
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
end_per_testcase(sx_timeout, Config) ->
    ok = meck:delete(ergw_sx_socket, call, 5),
    end_per_testcase(Config);
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
    ?equal(ergw_core:system_info(accept_new, false), true),
    create_pdp_context(reject_new, Config),
    ?equal(ergw_core:system_info(accept_new, true), false),

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

    {GtpC0, _, _} = create_pdp_context(random, Config),
    ct:sleep(500),

    {GtpC1, _, _} = create_pdp_context(random, GtpC0),
    ct:sleep(500),

    {GtpC2, _, _} = create_pdp_context(random, GtpC1),
    ct:sleep(500),

    Pings = lists:foldl(
	      fun({_, {ergw_gtp_c_socket, send_request, [_, _, IP, _, _, _, #gtp{type = echo_request}, _]}, _}, M) ->
		      Key = maps:get(IP, GSNs),
		      maps:update_with(Key, fun(Cnt) -> Cnt + 1 end, 1, M);
		 (_, M) ->
		      M
	      end, #{}, meck:history(ergw_gtp_c_socket)),

    delete_pdp_context(GtpC0),
    delete_pdp_context(GtpC1),
    delete_pdp_context(GtpC2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),

    meck_validate(Config),

    ?equal(3, map_size(Pings)),
    maps:map(fun(K, V) -> ?match({_, X} when X >= 2, {K, V}) end, Pings),

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
ggsn_broken_recovery() ->
    [{doc, "Check that Create PDP Context Request works and "
           "that a GGSN Restart terminates the session"}].
ggsn_broken_recovery(Config) ->
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    {GtpC, _, _} = create_pdp_context(Config),

    {_, CtxPid} = gtp_context_reg:lookup(CtxKey),
    #{right_tunnel := #tunnel{socket = CSocket}} = gtp_context:info(CtxPid),

    FinalGSN = proplists:get_value(final_gsn, Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, _, IP, _, _, _, #gtp{type = echo_request} = Req, CbInfo)
			   when IP =:= FinalGSN ->
			     IEs = #{{recovery,0} => #recovery{restart_counter = 0}},
			     Resp = Req#gtp{type = echo_response, ie = IEs},
			     ct:pal("Req: ~p~nResp: ~p~n", [Req, Resp]),
			     ergw_gtp_c_socket:send_reply(CbInfo, Resp);
			 (Socket, Src, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([Socket, Src, IP, Port, T3, N3, Msg, CbInfo])
		     end),

    %% send a ping from GGSN, should trigger a race warning
    ok = gtp_path:ping(CSocket, v1, FinalGSN),

    ct:sleep(1000),
    [?match(#{tunnels := 1}, X) || X <- ergw_api:peer(all)],

    delete_pdp_context(GtpC),

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
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_pdp_context(Config),

    {_, CtxPid} = gtp_context_reg:lookup(CtxKey),
    #{right_tunnel := #tunnel{socket = CSocket}} = gtp_context:info(CtxPid),

    FinalGSN = proplists:get_value(final_gsn, Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, _, IP, _, _, _, #gtp{type = echo_request}, CbInfo)
			   when IP =:= FinalGSN ->
			     %% simulate a Echo timeout
			     ergw_gtp_c_socket:send_reply(CbInfo, timeout);
			 (Socket, Src, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([Socket, Src, IP, Port, T3, N3, Msg, CbInfo])
		     end),

    gtp_path:ping(CSocket, v1, FinalGSN),

    %% echo timeout should trigger a Delete PDP Context Request to SGSN.
    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    %% wait for session cleanup
    ct:sleep(100),
    delete_pdp_context(not_found, GtpC),

    {_Handler, Server} = gtp_context_reg:lookup(RemoteCtxKey),
    true = is_pid(Server),
    %% killing the GGSN context
    exit(Server, kill),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),

    DownPeers = lists:filter(
		  fun({_, State}) -> State =:= down end, gtp_path_reg:all(FinalGSN)),
    ?equal(1, length(DownPeers)),
    [{PeerPid, _}] = DownPeers,
    gtp_path:stop(PeerPid),

    meck_validate(Config),

    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),
    ok.

%%--------------------------------------------------------------------
path_failure_to_ggsn_and_restore() ->
    [{doc, "Check that Create Session Request works and "
      "that a path failure (Echo timeout) terminates the session "
      "and is later restored with a valid echo"}].
path_failure_to_ggsn_and_restore(Config) ->
    Cntl = whereis(gtpc_client_server),
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},

    lists:foreach(fun({_, Pid, _}) -> gtp_path:stop(Pid) end, gtp_path_reg:all()),

    {GtpC, _, _} = create_pdp_context(Config),

    {_, CtxPid} = gtp_context_reg:lookup(CtxKey),
    #{right_tunnel := #tunnel{socket = CSocket}} = gtp_context:info(CtxPid),

    FinalGSN = proplists:get_value(final_gsn, Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, _, IP, _, _, _, #gtp{type = echo_request}, CbInfo)
			   when IP =:= FinalGSN ->
			     %% simulate a Echo timeout
			     ergw_gtp_c_socket:send_reply(CbInfo, timeout);
			 (Socket, Src, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([Socket, Src, IP, Port, T3, N3, Msg, CbInfo])
		     end),

    gtp_path:ping(CSocket, v1, FinalGSN),

    %% echo timeout should trigger a Delete PDP Context Request to SGSN.
    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    %% wait for session cleanup
    ct:sleep(100),
    delete_pdp_context(not_found, GtpC),

    % Check that IP is marked down
    ?match([_], lists:filter(
		  fun({_, State}) -> State =:= down end, gtp_path_reg:all(FinalGSN))),

    create_pdp_context(no_resources_available, Config),
    ct:sleep(100),

    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),

    %% Successful echo, clears down marked IP.
    gtp_path:ping(CSocket, v1, FinalGSN),

    %% wait for 100ms
    ?equal(timeout, recv_pdu(GtpC, undefined, 100, fun(Why) -> Why end)),

    ?match([], lists:filter(
		 fun({_, _, State}) -> State =:= down end, gtp_path_reg:all())),

    %% Check that new session now successfully created
    {GtpC1, _, _} = create_pdp_context(Config),
    delete_pdp_context(GtpC1),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    lists:foreach(fun({_, Pid, _}) -> gtp_path:stop(Pid) end, gtp_path_reg:all()),

    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
path_failure_to_sgsn() ->
    [{doc, "Check that Create PDP Context works and "
      "that a path failure (Echo timeout) terminates the session"}].
path_failure_to_sgsn(Config) ->
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    {GtpC, _, _} = create_pdp_context(Config),

    {_, CtxPid} = gtp_context_reg:lookup(CtxKey),
    #{left_tunnel := #tunnel{socket = CSocket}} = gtp_context:info(CtxPid),

    ClientIP = proplists:get_value(client_ip, Config),
    ok = meck:expect(ergw_gtp_c_socket, send_request,
		     fun (_, _, IP, _, _, _, #gtp{type = echo_request}, CbInfo)
			   when IP =:= ClientIP ->
			     %% simulate a Echo timeout
			     ergw_gtp_c_socket:send_reply(CbInfo, timeout);
			 (Socket, Src, IP, Port, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([Socket, Src, IP, Port, T3, N3, Msg, CbInfo])
		     end),

    gtp_path:ping(CSocket, v1, ClientIP),

    %% wait for session cleanup
    ct:sleep(100),
    delete_pdp_context(not_found, GtpC),

    [?match(#{tunnels := 0}, X) || X <- ergw_api:peer(all)],

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    meck_validate(Config),

    ok = meck:delete(ergw_gtp_c_socket, send_request, 8),
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
    ct:pal("V: ~s", [ergw_test_lib:pretty_print(V)]),
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
    init_seq_no(?MODULE, 16#8000),
    GtpC = gtp_context(?MODULE, Config),

    %% stop all existing paths
    lists:foreach(fun({_, Pid, _}) -> gtp_path:stop(Pid) end, gtp_path_reg:all()),

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
	    {GtpC1, _, _} = create_pdp_context(#{apn => ?'APN-LB-1'}, GtpC0),

	    CntS = lists:foldl(
		     fun({#socket_teid_key{
			     type = 'gtp-c', teid = #fq_teid{ip = PeerIP}}, _}, M)
			   when is_map_key(PeerIP, M) ->
			     maps:update_with(PeerIP, fun(C) -> C + 1 end, 1, M);
			(_, M) -> M
		     end, CntS0, gtp_context_reg:all()),

	    {GtpC2, _, _} = delete_pdp_context(GtpC1),

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
    init_seq_no(?MODULE, 16#8000),

    %% stop all existing paths
    lists:foreach(fun({_, Pid, _}) -> gtp_path:stop(Pid) end, gtp_path_reg:all()),

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
    CPid = gtp_path:maybe_new_path(CSocket, v1, DownGSN),

    %% down the path by forcing a echo
    ok = gtp_path:ping(CPid),
    ct:sleep(100),

    % make sure that worked
    DownPeers = lists:filter(
		  fun({_, State}) -> State =:= down end, gtp_path_reg:all(DownGSN)),
    ?equal(1, length(DownPeers)),

    GtpCs0 = make_gtp_contexts(?NUM_OF_CLIENTS, Config),
    GtpCs1 = lists:map(fun(GtpC0) -> create_pdp_context(random, GtpC0) end, GtpCs0),



    PgwFqTeids = [X || {#socket_teid_key{type = 'gtp-c', teid = #fq_teid{ip = PeerIP}}, _} =
			   X <- gtp_context_reg:all(), PeerIP == DownGSN],
    ?match(0, length(PgwFqTeids)), % Check no connection to down peer

    lists:foreach(fun({GtpC1,_,_}) -> delete_pdp_context(GtpC1) end, GtpCs1),

    ok = meck:wait(?NUM_OF_CLIENTS, ?HUT, terminate, '_', ?TIMEOUT),
    wait4tunnels(?TIMEOUT),
    lists:foreach(fun({_, Pid, _}) -> gtp_path:stop(Pid) end, gtp_path_reg:all()),

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
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    GtpC = gtp_context(Config),
    Request = make_request(create_pdp_context_request, simple, GtpC),

    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, 2 * 1000, error)),

    {_Handler, Server} = gtp_context_reg:lookup(CtxKey),
    true = is_pid(Server),

    %% killing the proxy PGW context
    gtp_context:terminate_context(Server),

    ?match(1, meck:num_calls(ggsn_gn, handle_request,
			     ['_', #gtp{type = create_pdp_context_request, _ = '_'}, '_', '_', '_'])),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_pdp_context_request_timeout() ->
    [{doc, "Check that the proxy does shutdown the context on timeout"}].
create_pdp_context_request_timeout(Config) ->
    %% logger:set_primary_config(level, debug),
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},

    GtpC = gtp_context(Config),
    Request = make_request(create_pdp_context_request, simple, GtpC),

    ?equal({error,timeout}, send_recv_pdu(GtpC, Request, 2 * 1000, error)),

    ?equal(undefined, gtp_context_reg:lookup(CtxKey)),
    ?match(1, meck:num_calls(ggsn_gn, handle_request, '_')),

    wait4tunnels(?TIMEOUT),
    ?equal([], outstanding_requests()),
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
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup(RemoteCtxKey),
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
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_pdp_context(Config),

    {_, CtxPid} = gtp_context_reg:lookup(CtxKey),
    true = is_pid(CtxPid),
    #{bearer := #{right := RightBearer}} = gtp_context:info(CtxPid),

    ergw_test_sx_up:send('sgw-u', make_error_indication_report(RightBearer)),

    Request = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),

    ct:sleep(100),
    delete_pdp_context(not_found, GtpC),

    {_Handler, Server} = gtp_context_reg:lookup(RemoteCtxKey),
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
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC1, _, _} = create_pdp_context(Config),
    {_, CtxPid} = gtp_context_reg:lookup(RemoteCtxKey),
    #{left_tunnel := LeftTunnel1, bearer := #{left := LeftBearer1}} = gtp_context:info(CtxPid),

    {GtpC2, _, _} = update_pdp_context(ra_update, GtpC1),
    #{left_tunnel := LeftTunnel2, bearer := #{left := LeftBearer2}} = gtp_context:info(CtxPid),

    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC2),

    %% make sure the SGSN side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the GGSN side control TEID don't change
    ?equal(LeftTunnel1#tunnel.remote, LeftTunnel2#tunnel.remote),
    ?equal(LeftBearer1#bearer.remote, LeftBearer2#bearer.remote),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
update_pdp_context_request_tei_update() ->
    [{doc, "Check Update PDP Context with TEID update (e.g. SGSN change)"}].
update_pdp_context_request_tei_update(Config) ->
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC1, _, _} = create_pdp_context(Config),
    {_, CtxPid} = gtp_context_reg:lookup(RemoteCtxKey),
    #{left_tunnel := LeftTunnel1, bearer := #{left := LeftBearer1}} = gtp_context:info(CtxPid),

    {_Handler, ProxyCtxPid} = gtp_context_reg:lookup(CtxKey),
    #{right_tunnel := RightTunnel1} = gtp_context:info(ProxyCtxPid),
    ProxyRegKey1 = gtp_context:tunnel_key(local, RightTunnel1),
    ?match({gtp_context, ProxyCtxPid}, gtp_context_reg:lookup(ProxyRegKey1)),

    {GtpC2, _, _} = update_pdp_context(tei_update, GtpC1),
    #{left_tunnel := LeftTunnel2, bearer := #{left := LeftBearer2}} = gtp_context:info(CtxPid),

    #{right_tunnel := RightTunnel2} = gtp_context:info(ProxyCtxPid),
    ProxyRegKey2 = gtp_context:tunnel_key(local, RightTunnel2),
    ?match(undefined, gtp_context_reg:lookup(ProxyRegKey1)),
    ?match({gtp_context, ProxyCtxPid}, gtp_context_reg:lookup(ProxyRegKey2)),

    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC2),

    %% make sure the SGSN side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the GGSN side control TEID DOES change
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
    ok.

%%--------------------------------------------------------------------
update_pdp_context_request_broken_recovery() ->
    [{doc, "Check Update PDP Context where the response includes an invalid recovery"}].
update_pdp_context_request_broken_recovery(Config) ->
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    ok = meck:expect(gtp_context, send_response,
		     fun(ReqKey, Request, {update_pdp_context_response, TEID, IEs0})->
			     IEs = [#recovery{restart_counter = 0},
				     #protocol_configuration_options{
					config = {0,
						  [{13,<<"\b\b\b\b">>},
						   {13,<<8,8,4,4>>},
						   {17,<<>>},
						   {16,<<5,80>>}]}},
				    #aggregate_maximum_bit_rate{
				       uplink = 8640, downlink = 8640}
				    | IEs0],
			     Response = {update_pdp_context_response, TEID, IEs},
			     meck:passthrough([ReqKey, Request, Response]);
			(ReqKey, Request, Response)->
			     meck:passthrough([ReqKey, Request, Response])
		     end),
    {GtpC1, _, _} = create_pdp_context(Config),
    {_, CtxPid} = gtp_context_reg:lookup(RemoteCtxKey),
    #{left_tunnel := LeftTunnel1, bearer := #{left := LeftBearer1}} = gtp_context:info(CtxPid),

    {GtpC2, _, _} = update_pdp_context(simple, GtpC1),
    #{left_tunnel := LeftTunnel2, bearer := #{left := LeftBearer2}} = gtp_context:info(CtxPid),

    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC2),

    %% make sure the SGSN side TEID don't change
    ?equal(GtpC1#gtpc.remote_control_tei, GtpC2#gtpc.remote_control_tei),
    ?equal(GtpC1#gtpc.remote_data_tei,    GtpC2#gtpc.remote_data_tei),

    %% make sure the GGSN side control TEID don't change
    ?equal(LeftTunnel1#tunnel.remote, LeftTunnel2#tunnel.remote),
    ?equal(LeftBearer1#bearer.remote, LeftBearer2#bearer.remote),

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
    meck:expect(gtp_proxy_ds, map,
		fun(ProxyInfo) ->
			proxy_context_selection_map(ProxyInfo, <<"ams">>)
		end),

    {GtpC, _, _} = create_pdp_context(Config),
    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC),

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

    {GtpC, _, _} = create_pdp_context(Config),
    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
proxy_context_invalid_mapping() ->
    [{doc, "Check rejection of a session when the proxy selects failes"}].
proxy_context_invalid_mapping(Config) ->
    meck:expect(gtp_proxy_ds, map,
		fun(_ProxyInfo) -> {error, user_authentication_failed} end),

    {_, _, _} = create_pdp_context(invalid_mapping, Config),
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

    {GtpC, _, _} = create_pdp_context(Config),
    ?equal([], outstanding_requests()),
    delete_pdp_context(GtpC),

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
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup(RemoteCtxKey),
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
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {_, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup(RemoteCtxKey),
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
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup(RemoteCtxKey),
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
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {_Handler, Server} = gtp_context_reg:lookup(RemoteCtxKey),
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
    RemoteCtxKey = #context_key{socket = 'remote-irx', id = {imsi, ?'PROXY-IMSI', 5}},

    {GtpC, _, _} = create_pdp_context(Config),

    {_Handler, Server} = gtp_context_reg:lookup(RemoteCtxKey),
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
    CtxKey = #context_key{socket = 'irx', id = {imsi, ?'IMSI', 5}},

    create_pdp_context(overload, Config),

    ct:sleep(10),
    ?equal(undefined, gtp_context_reg:lookup(CtxKey)),

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
    Socket =
	case ergw_socket_reg:lookup('gtp-c', 'proxy-irx') of
	    undefined ->
		ergw_socket_reg:lookup('gtp-c', 'irx');
	    Other ->
		Other
	end,
    {GtpC, _, _} = create_pdp_context(Config),
    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),

    {T0, Q0} = ergw_gtp_c_socket:get_request_q(Socket),
    ?match(X when X /= 0, length(T0)),
    ?match(X when X /= 0, length(Q0)),

    ct:sleep({seconds, 120}),

    {T1, Q1} = ergw_gtp_c_socket:get_request_q(Socket),
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

    delete_pdp_context(GtpC),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
sx_upf_reconnect() ->
    [{doc, "Test UPF reconnect behavior"}].
sx_upf_reconnect(Config) ->
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

    {GtpC, _, _} = create_pdp_context(Config),

    ergw_test_sx_up:disable('sgw-u'),

    %% heart beats are send every 5000 ms, make sure we wait long enough
    Req = recv_pdu(Cntl, 6000),
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
    ergw_test_sx_up:disable('sgw-u'),

    create_pdp_context(system_failure, Config),

    ?equal([], outstanding_requests()),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
%% The following test in inherently broken and disabled.
%%
%% For the test suite, proxy contexts and GGSN server context all live
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

    {GtpC0, _, _} = create_pdp_context(Config),
    {GtpC1, _, _} = create_pdp_context(random, GtpC0),

    Ref = make_ref(),
    Self = self(),
    spawn(fun() -> Self ! {req, Ref, ergw_api:delete_contexts(3)} end),

    Request0 = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request0),
    Response0 = make_response(Request0, simple, GtpC0),
    send_pdu(Cntl, GtpC0, Response0),

    Request1 = recv_pdu(Cntl, 5000),
    ?match(#gtp{type = delete_pdp_context_request}, Request1),
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
