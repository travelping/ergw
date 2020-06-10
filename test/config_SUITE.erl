%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(config_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_ggsn_test_lib.hrl").

-define(error_option(Config),
	?match({error,{options, _}}, (catch ergw_config:validate_config(Config)))).

-define(ok_option(Config),
	?match([_|_], (catch ergw_config:validate_config(Config)))).

-define(GGSN_CONFIG,
	[{node_id, <<"GGSN">>},
	 accept_new,
	 {http_api, [{port, 0}]},
	 {sockets,
	  [{cp, [{type, 'gtp-u'},
		 {ip,  ?LOCALHOST_IPv4},
		 {reuseaddr, true},
		 freebind
		]},
	   {irx, [{type, 'gtp-c'},
		  {ip,  ?TEST_GSN_IPv4},
		  {reuseaddr, true}
		 ]},

	   {sx, [{type, 'pfcp'},
		 {node, 'ergw'},
		 {name, 'ergw'},
		 {socket, cp},
		 {ip, ?LOCALHOST_IPv4},
		 {reuseaddr, true}
		]}
	  ]},

	 {ip_pools,
	  [{'pool-A', [{ranges,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
				  {?IPv6PoolStart, ?IPv6PoolEnd, 64}]},
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
		 {node_selection, [static]},
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

	 {apns,
	  [{?'APN-EXAMPLE',
	    [{vrf, upstream},
	     {ip_pools, ['pool-A', 'pool-B']}
	    ]},
	   {[<<"APN1">>],
	    [{vrfs, [upstream]},
	     {ip_pools, ['pool-A', 'pool-B']}
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
	   {"node-A", [connect]}]
	 },

	 {path_management,
	  [{t3, 10 * 1000},
	   {n3, 5},
	   {echo, 60 * 1000}]
	 }
	]).

-define(GGSN_PROXY_CONFIG,
	[{node_id, <<"GGSN-PROXY">>},
	 {sockets,
	  [{cp, [{type, 'gtp-u'},
		 {ip,  ?LOCALHOST_IPv4},
		 {reuseaddr, true},
		 freebind
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
			    {ip,  ?FINAL_GSN2_IPv4},
			    {reuseaddr, true}
			   ]},

	   {sx, [{type, 'pfcp'},
		 {node, 'ergw'},
		 {name, 'ergw'},
		 {socket, cp},
		 {ip, ?LOCALHOST_IPv4},
		 {reuseaddr, true}
		]}
	  ]},

	 {handlers,
	  %% proxy handler
	  [{gn, [{handler, ggsn_gn_proxy},
		 {sockets, [irx]},
		 {proxy_sockets, ['irx']},
		 {node_selection, [static]},
		 {contexts,
		  [{<<"ams">>,
		    [{proxy_sockets, ['irx']}]}]}
		]},
	   %% remote GGSN handler
	   {gn, [{handler, ggsn_gn},
		 {sockets, ['remote-irx', 'remote-irx2']},
		 {node_selection, [static]},
		 {aaa, [{'Username',
			 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
		]}
	  ]},

	 {apns,
	  [{?'APN-PROXY', [{vrf, example}]}
	  ]},

	 {proxy_map,
	  [{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
	   {imsi, [{?'IMSI', {?'PROXY-IMSI', ?'PROXY-MSISDN'}}
		  ]}
	  ]},

	 {node_selection,
	  [{default,
	    {static,
	     [
	      %% APN NAPTR alternative
	      {"_default.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
	       [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
		{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
	       "topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org"},
	      {"_default.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
	       [{"x-3gpp-upf","x-sxa"}],
	       "topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org"},

	      {"web.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
	       [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
		{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
	       "topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org"},
	      {"web.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
	       [{"x-3gpp-upf","x-sxa"}],
	       "topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org"},

	      %% A/AAAA record alternatives
	      {"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org",  [{172, 20, 16, 89}], []},
	      {"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org", [{172,20,16,91}], []}
	     ]
	    }
	   },
	   {mydns,
	    {dns, {{172,20,16,75}, 53}}}
	  ]
	 },

	 {nodes,
	  [{default,
	    [{vrfs,
	      [{cp, [{features, ['CP-Function']}]},
	       {irx, [{features, ['Access']}]},
	       {sgi, [{features, ['SGi-LAN']}]}]
	     }]
	   }]
	 },

	 {path_management,
	  [{t3, 10 * 1000},
	   {n3, 5},
	   {echo, 60 * 1000},
	   {idle_timeout, 1800 * 1000},
	   {idle_echo,     600 * 1000},
	   {down_timeout, 3600 * 1000},
	   {down_echo,     600 * 1000}]
	 }
	]).

-define(PGW_CONFIG,
	[{node_id, <<"PGW">>},
	 {sockets,
	  [{cp, [{type, 'gtp-u'},
		 {ip,  ?LOCALHOST_IPv4},
		 {reuseaddr, true},
		 freebind
		]},
	   {irx, [{type, 'gtp-c'},
		  {ip,  ?TEST_GSN_IPv4},
		  {reuseaddr, true}
		 ]},

	   {sx, [{type, 'pfcp'},
		 {node, 'ergw'},
		 {name, 'ergw'},
		 {socket, cp},
		 {ip, ?LOCALHOST_IPv4},
		 {reuseaddr, true}
		]}
	  ]},

	 {ip_pools,
	  [{'pool-A', [{ranges,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
				  {?IPv6PoolStart, ?IPv6PoolEnd, 64}]},
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
	  [{'h1', [{handler, pgw_s5s8},
		   {protocol, gn},
		   {sockets, [irx]},
		   {node_selection, [static]},
		   {aaa, [{'Username',
			   [{default, ['IMSI',   <<"/">>,
				       'IMEI',   <<"/">>,
				       'MSISDN', <<"/">>,
				       'ATOM',   <<"/">>,
				       "TEXT",   <<"/">>,
				       12345,
				       <<"@">>, 'APN']}]}]}
		  ]},
	   {'h2', [{handler, pgw_s5s8},
		   {protocol, s5s8},
		   {sockets, [irx]},
		   {node_selection, [static]},
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

	 {apns,
	  [{?'APN-EXAMPLE',
	    [{vrf, upstream},
	     {ip_pools, ['pool-A', 'pool-B']}
	    ]},
	   {[<<"APN1">>],
	    [{vrfs, [upstream]},
	     {ip_pools, ['pool-A', 'pool-B']}
	    ]}
	  ]},

	 {nodes,
	  [{default,
	    [{vrfs,
	      [{cp, [{features, ['CP-Function']}]},
	       {irx, [{features, ['Access']}]},
	       {sgi, [{features, ['SGi-LAN']}]}]
	     }]
	   }]
	 }
	]).

-define(PGW_PROXY_CONFIG,
	[{node_id, <<"PGW-PROXY">>},
	 {sockets,
	  [{cp, [{type, 'gtp-u'},
		 {ip,  ?LOCALHOST_IPv4},
		 {reuseaddr, true},
		 freebind
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
			    {ip, ?FINAL_GSN2_IPv4},
			    {reuseaddr, true}
			   ]},

	   {sx, [{type, 'pfcp'},
		 {node, 'ergw'},
		 {name, 'ergw'},
		 {socket, cp},
		 {ip, ?LOCALHOST_IPv4},
		 {reuseaddr, true}
		]}
	  ]},

	 {handlers,
	  %% proxy handler
	  [{gn, [{handler, pgw_s5s8_proxy},
		 {sockets, [irx]},
		 {proxy_sockets, ['irx']},
		 {node_selection, [static]}
		]},
	   {s5s8, [{handler, pgw_s5s8_proxy},
		   {sockets, [irx]},
		   {proxy_sockets, ['irx']},
		   {node_selection, [static]},
		   {contexts,
		    [{<<"ams">>,
		      [{proxy_sockets, ['irx']}]}]}
		  ]},
	   %% remote PGW handler
	   {gn, [{handler, pgw_s5s8},
		 {sockets, ['remote-irx', 'remote-irx2']},
		 {node_selection, [static]},
		 {aaa, [{'Username',
			 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
		]},
	   {s5s8, [{handler, pgw_s5s8},
		   {sockets, ['remote-irx', 'remote-irx2']},
		   {node_selection, [static]}
		  ]}
	  ]},

	 {apns,
	  [{?'APN-PROXY', [{vrf, example}]}
	  ]},

	 {proxy_map,
	  [{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
	   {imsi, [{?'IMSI', {?'PROXY-IMSI', ?'PROXY-MSISDN'}}
		  ]}
	  ]},

	 {node_selection,
	  [{default,
	    {static,
	     [
	      %% APN NAPTR alternative
	      {"_default.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
	       [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
		{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
	       "topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org"},
	      {"_default.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
	       [{"x-3gpp-upf","x-sxa"}],
	       "topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org"},

	      {"web.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
	       [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
		{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
	       "topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org"},
	      {"web.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
	       [{"x-3gpp-upf","x-sxa"}],
	       "topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org"},

	      %% A/AAAA record alternatives
	      {"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org",  [{172, 20, 16, 89}], []},
	      {"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org", [{172,20,16,91}], []}
	     ]
	    }
	   },
	   {mydns,
	    {dns, {{172,20,16,75}, 53}}}
	  ]
	 },

	 {nodes,
	  [{default,
	    [{vrfs,
	      [{cp, [{features, ['CP-Function']}]},
	       {irx, [{features, ['Access']}]},
	       {sgi, [{features, ['SGi-LAN']}]}]
	     }]
	   }]
	 }
	]).

-define(SAE_S11_CONFIG,
	[{node_id, <<"SAE-GW">>},
	 {sockets,
	  [{cp, [{type, 'gtp-u'},
		 {ip,  ?LOCALHOST_IPv4},
		 {reuseaddr, true},
		 freebind
		]},
	   {irx, [{type, 'gtp-c'},
		  {ip,  ?TEST_GSN_IPv4},
		  {reuseaddr, true}
		 ]},

	   {sx, [{type, 'pfcp'},
		 {node, 'ergw'},
		 {name, 'ergw'},
		 {socket, cp},
		 {ip, ?LOCALHOST_IPv4},
		 {reuseaddr, true}
		]}
	  ]},

	 {ip_pools,
	  [{'pool-A', [{ranges,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
				  {?IPv6PoolStart, ?IPv6PoolEnd, 64}]},
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
	  [{'h1', [{handler, saegw_s11},
		   {protocol, s11},
		   {sockets, [irx]},
		   {node_selection, [static]},
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

	 {apns,
	  [{?'APN-EXAMPLE',
	    [{vrf, upstream},
	     {ip_pools, ['pool-A', 'pool-B']}
	    ]},
	   {[<<"APN1">>],
	    [{vrfs, [upstream]},
	     {ip_pools, ['pool-A', 'pool-B']}
	    ]}
	  ]},

	 {nodes,
	  [{default,
	    [{vrfs,
	      [{cp, [{features, ['CP-Function']}]},
	       {irx, [{features, ['Access']}]},
	       {sgi, [{features, ['SGi-LAN']}]}]
	     }]
	   }]
	 }
	]).

-define(TDF_CONFIG,
	[{node_id, <<"TDF">>},
	 {sockets,
	  [{'cp-socket', [{type, 'gtp-u'},
			  {vrf, cp},
			  {ip,  ?LOCALHOST_IPv4},
			  freebind,
			  {reuseaddr, true}
			 ]},

	   {sx, [{type, 'pfcp'},
		 {node, 'ergw'},
		 {name, 'ergw'},
		 {socket, 'cp-socket'},
		 {ip, ?LOCALHOST_IPv4},
		 {reuseaddr, true}
		]}
	  ]},

	 {handlers,
	  [{'h1', [{handler, tdf},
		   {protocol, ip},
		   {apn, ?'APN-EXAMPLE'},
		   {nodes, ["topon.sx.prox01.mnc001.mcc001.3gppnetwork.org"]},
		   {node_selection, [default]}
		  ]}
	  ]},

	 {apns,
	  [{?'APN-EXAMPLE', [{vrf, sgi}]},
	   {'_', [{vrf, sgi}]}
	  ]},

	 {node_selection,
	  [{default,
	    {static,
	     [
	      %% APN NAPTR alternative
	      {"_default.apn.mnc001.mcc001.3gppnetwork.org", {300,64536},
	       [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
		{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
	       "topon.s5s8.pgw.mnc001.mcc001.3gppnetwork.org"},
	      {"_default.apn.mnc001.mcc001.3gppnetwork.org", {300,64536},
	       [{"x-3gpp-upf","x-sxb"}],
	       "topon.sx.prox01.mnc001.mcc001.3gppnetwork.org"},

	      {"web.apn.mnc001.mcc001.3gppnetwork.org", {300,64536},
	       [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
		{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
	       "topon.s5s8.pgw.mnc001.mcc001.3gppnetwork.org"},
	      {"web.apn.mnc001.mcc001.3gppnetwork.org", {300,64536},
	       [{"x-3gpp-upf","x-sxb"}],
	       "topon.sx.prox01.mnc001.mcc001.3gppnetwork.org"},

	      %% A/AAAA record alternatives
	      {"topon.s5s8.pgw.mnc001.mcc001.3gppnetwork.org",  [{172, 20, 16, 28}], []},
	      {"topon.sx.prox01.mnc001.mcc001.3gppnetwork.org", [{172,21,16,1}], []}
	     ]
	    }
	   },
	   {dns, {dns, {{8,8,8,8}, 53}}}
	  ]
	 },

	 {nodes,
	  [{default,
	    [{vrfs,
	      [{cp, [{features, ['CP-Function']}]},
	       {epc, [{features, ['TDF-Source', 'Access']}]},
	       {sgi, [{features, ['SGi-LAN']}]}]
	     }]
	   }]
	 }
	]).

%%%===================================================================
%%% API
%%%===================================================================

all() ->
    [config].

config() ->
    [{doc, "Test the config validation"}].
config(_Config)  ->
    ?ok_option(?GGSN_CONFIG),
    ?ok_option(ergw_config:validate_config(?GGSN_CONFIG)),
    ?error_option(set_cfg_value([plmn_id], {undefined, undefined}, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([plmn_id], {<<"abc">>, <<"ab">>}, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([node_id], undefined, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([node_id], "GGSN", ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([node_id], ["GGSN", <<"-proxy">>], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets], undefined, ?GGSN_CONFIG)),

    ?ok_option(set_cfg_value([teid], {2, 4}, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([teid], 1, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([teid], {8, 2}, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([teid], {atom, 8}, ?GGSN_CONFIG)),

    %% pass-through of unexpected options
    ?ok_option(set_cfg_value([invalid], [], ?GGSN_CONFIG)),

    ?error_option(set_cfg_value([accept_new], invalid, ?GGSN_CONFIG)),
    Accept0 = (catch ergw_config:validate_config(?GGSN_CONFIG)),
    ?equal(true, proplists:get_value(accept_new, Accept0)),
    Accept1 = (catch ergw_config:validate_config(set_cfg_value([accept_new], true, ?GGSN_CONFIG))),
    ?equal(true, proplists:get_value(accept_new, Accept1)),
    Accept2 = (catch ergw_config:validate_config(set_cfg_value([accept_new], false, ?GGSN_CONFIG))),
    ?equal(false, proplists:get_value(accept_new, Accept2)),

    ?ok_option(set_cfg_value([http_api, port], 1234, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([http_api, num_acceptors], 5, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([http_api, ip], ?LOCALHOST_IPv4, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([http_api, ip], ?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([http_api, ipv6_v6only], true, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([http_api], [ipv6_v6only], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([http_api, invalid], [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([http_api, port], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([http_api, acceptors_num], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([http_api, num_acceptors], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([http_api, ip], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([http_api, ipv6_v6only], invalid, ?GGSN_CONFIG)),

    ?error_option(set_cfg_value([sockets, irx, type], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, irx, ip], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, irx, ip], {1,1,1,1,1}, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, irx, ip], ?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, irx, netdev], <<"netdev">>, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, irx, netdev], "netdev", ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, irx, netdev], invalid, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, irx, netns], <<"netns">>, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, irx, netns], "netns", ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, irx, netns], invalid, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, irx, freebind], true, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, irx, freebind], false, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, irx, freebind], invalid, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, irx, rcvbuf], 1, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, irx, rcvbuf], -1, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, irx, rcvbuf], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, irx, invalid], true, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, irx], invalid, ?GGSN_CONFIG)),
    ?error_option(add_cfg_value([sockets, irx], [], ?GGSN_CONFIG)),

    ?ok_option(add_cfg_value([sockets, irx, vrf], 'irx', ?GGSN_CONFIG)),
    ?ok_option(add_cfg_value([sockets, irx, vrf], "irx", ?GGSN_CONFIG)),
    ?ok_option(add_cfg_value([sockets, irx, vrf], <<"irx">>, ?GGSN_CONFIG)),
    ?ok_option(add_cfg_value([sockets, irx, vrf], [<<"irx">>], ?GGSN_CONFIG)),
    ?error_option(add_cfg_value([sockets, irx, vrf], ["irx", invalid], ?GGSN_CONFIG)),
    ?error_option(add_cfg_value([sockets, irx, vrf], [<<"irx">>, invalid], ?GGSN_CONFIG)),
    ?error_option(add_cfg_value([sockets, irx, vrf], [<<"irx">>, "invalid"], ?GGSN_CONFIG)),

    SockOpts = [{type, 'gtp-c'}, {ip,  ?TEST_GSN_IPv4}, reuseaddr, freebind],
    SockCfg = (catch ergw_config:validate_config(
		       add_cfg_value([sockets, 'irx-2'], SockOpts, ?GGSN_CONFIG))),
    ?match(#{type      := 'gtp-c',
	     ip        := _,
	     freebind  := true,
	     reuseaddr := true},
	   proplists:get_value('irx-2', proplists:get_value(sockets, SockCfg))),

    ?error_option(set_cfg_value([sockets, sx, ip], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, sx, ip], {1,1,1,1,1}, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, sx, ip], ?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, sx, netdev], <<"netdev">>, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, sx, netdev], "netdev", ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, sx, netdev], invalid, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, sx, netns], <<"netns">>, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, sx, netns], "netns", ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, sx, netns], invalid, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, sx, freebind], true, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, sx, freebind], false, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, sx, freebind], invalid, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([sockets, sx, rcvbuf], 1, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, sx, rcvbuf], -1, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, sx, rcvbuf], invalid, ?GGSN_CONFIG)),
    ?error_option(add_cfg_value([sockets, sx, socket], [], ?GGSN_CONFIG)),
    ?error_option(add_cfg_value([sockets, sx, socket], "dp", ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, sx, invalid], true, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([sockets, sx], invalid, ?GGSN_CONFIG)),
    ?error_option(add_cfg_value([sockets, sx], [], ?GGSN_CONFIG)),

    ?error_option(set_cfg_value([handlers, gn], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, handler], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, protocol], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, sockets], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, datapaths], invalid, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([handlers, gn, aaa, '3GPP-GGSN-MCC-MNC'], <<"00101">>, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, aaa, 'Username', invalid], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, aaa, invalid], invalid, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([handlers, gn], [{handler, ggsn_gn},
					      {sockets, [irx]},
					      {node_selection, [static]}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn], [{sockets, [irx]},
						 {node_selection, [static]}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn], [{handler, ggsn_gn},
						 {sockets, [irx]}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn], [{handler, ggsn_gn},
						 {sockets, [irx]},
						 {node_selection, []}], ?GGSN_CONFIG)),

    ?match({error,{options, {vrf, _}}}, (catch vrf:validate_name([<<"1st">>, "2nd"]))),
    ?match(X when is_binary(X), (catch vrf:validate_name('aaa'))),
    ?match(X when is_binary(X), (catch vrf:validate_name('1st.2nd'))),
    ?match(X when is_binary(X), (catch vrf:validate_name("1st.2nd"))),
    ?match(X when is_binary(X), (catch vrf:validate_name(<<"1st.2nd">>))),
    ?match(X when is_binary(X), (catch vrf:validate_name([<<"1st">>, <<"2nd">>]))),

    ?error_option(set_cfg_value([ip_pools, 'pool-A'], invalid, ?GGSN_CONFIG)),
    ?error_option(add_cfg_value([ip_pools, 'pool-A'], [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools], invalid, ?GGSN_CONFIG)),

    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges], [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{?IPv4PoolStart, ?IPv4PoolEnd, 0}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{?IPv4PoolStart, ?IPv4PoolEnd, 33}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{?IPv4PoolStart, ?IPv4PoolEnd, invalid}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{?IPv4PoolStart, invalid, 32}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{invalid, ?IPv4PoolEnd, 32}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{?IPv4PoolEnd, ?IPv4PoolStart, 32}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{?IPv6PoolStart, ?IPv6PoolEnd, 0}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{?IPv6PoolStart, ?IPv6PoolEnd, 129}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{?IPv6PoolStart, ?IPv6PoolEnd, 127}], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			    [{?IPv6PoolStart, ?IPv6PoolEnd, 128}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{?IPv6PoolStart, ?IPv6PoolEnd, invalid}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{?IPv6PoolStart, invalid, 64}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{invalid, ?IPv6PoolEnd, 64}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', ranges],
			       [{?IPv6PoolEnd, ?IPv6PoolStart, 64}], ?GGSN_CONFIG)),

    ?error_option(set_cfg_value([ip_pools, 'pool-A', 'MS-Primary-DNS-Server'],
				invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', 'MS-Primary-DNS-Server'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', 'MS-Secondary-DNS-Server'],
				invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', 'MS-Secondary-DNS-Server'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', 'MS-Primary-NBNS-Server'],
				invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', 'MS-Primary-NBNS-Server'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', 'MS-Secondary-NBNS-Server'],
				invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', 'MS-Secondary-NBNS-Server'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', 'DNS-Server-IPv6-Address'],
				invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', 'DNS-Server-IPv6-Address'],
				?LOCALHOST_IPv4, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', 'DNS-Server-IPv6-Address'],
				[?LOCALHOST_IPv4], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', 'DNS-Server-IPv6-Address'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([ip_pools, 'pool-A', 'DNS-Server-IPv6-Address'],
				[?LOCALHOST_IPv6], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', '3GPP-IPv6-DNS-Servers'],
				invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', '3GPP-IPv6-DNS-Servers'],
				[invalid], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', '3GPP-IPv6-DNS-Servers'],
				?LOCALHOST_IPv4, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', '3GPP-IPv6-DNS-Servers'],
				[?LOCALHOST_IPv4], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([ip_pools, 'pool-A', '3GPP-IPv6-DNS-Servers'],
			     [?LOCALHOST_IPv6], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', '3GPP-IPv6-DNS-Servers'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([ip_pools, 'pool-A', '3GPP-IPv6-DNS-Servers'],
			     [?LOCALHOST_IPv6], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([ip_pools, 'pool-A', '3GPP-IPv6-DNS-Servers'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),

    ?error_option(set_cfg_value([apns, '_'], [], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([apns, '_', vrf], upstream, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([apns, '_', vrfs], [upstream], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, '_', vrfs], upstream, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([apns, '_', vrfs], [a, b], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, '_', vrfs], [a | b], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, '_', vrfs], [a, a], ?GGSN_CONFIG)),
    ?match({error, {apn, _}},
	   (catch ergw_config:validate_config(
		    set_cfg_value([apns, invalid], [], ?GGSN_CONFIG)))),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE'], [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE'], invalid, ?GGSN_CONFIG)),
    ?ok_option(add_cfg_value([apns, ?'APN-PROXY'], [{vrf, example}], ?GGSN_CONFIG)),
    ?error_option(add_cfg_value([apns, ?'APN-EXAMPLE'], [{vrf, example}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns], invalid, ?GGSN_CONFIG)),
    ?ok_option(add_cfg_value([apns, [<<"a-b">>]], [{vrf, example}], ?GGSN_CONFIG)),
    ?match({error, {apn, _}},
	   (catch ergw_config:validate_config(
		    add_cfg_value([apns, [<<"$">>]], [{vrf, example}], ?GGSN_CONFIG)))),
    ?match({error, {apn, _}},
	   (catch ergw_config:validate_config(
		    add_cfg_value([apns, [<<"_">>]], [{vrf, example}], ?GGSN_CONFIG)))),
    APN0 = proplists:get_value(apns, (catch ergw_config:validate_config(?GGSN_CONFIG))),
    %% check that APN's are lower cased after validation
    ?match(VRF when is_map(VRF), maps:get([<<"apn1">>], APN0)),

    ?ok_option(set_cfg_value([apns, ?'APN-EXAMPLE', ip_pools], [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', ip_pools], a, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([apns, ?'APN-EXAMPLE', ip_pools], [a, b], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', ip_pools], [a, a], ?GGSN_CONFIG)),

    ?ok_option(set_cfg_value([apns, ?'APN-EXAMPLE', bearer_type], 'IPv4', ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([apns, ?'APN-EXAMPLE', bearer_type], 'IPv6', ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([apns, ?'APN-EXAMPLE', bearer_type], 'IPv4v6', ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', bearer_type], 'Non-IP', ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', bearer_type], undefined, ?GGSN_CONFIG)),

    ?ok_option(set_cfg_value([apns, ?'APN-EXAMPLE', prefered_bearer_type], 'IPv4', ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([apns, ?'APN-EXAMPLE', prefered_bearer_type], 'IPv6', ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', prefered_bearer_type], 'IPv4v6', ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', prefered_bearer_type], 'Non-IP', ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', prefered_bearer_type], undefined, ?GGSN_CONFIG)),

    ?ok_option(set_cfg_value([apns, ?'APN-EXAMPLE', ipv6_ue_interface_id], default, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([apns, ?'APN-EXAMPLE', ipv6_ue_interface_id], random, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([apns, ?'APN-EXAMPLE', ipv6_ue_interface_id], {0,0,0,0,0,0,0,2}, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', ipv6_ue_interface_id], undefined, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', ipv6_ue_interface_id], {0,0,0,0,0,0,0,0}, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', ipv6_ue_interface_id], {1,0,0,0,0,0,0,0}, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', ipv6_ue_interface_id], {0,0,0,0,0,0,0,65536}, ?GGSN_CONFIG)),

    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', 'MS-Primary-DNS-Server'],
				invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', 'MS-Primary-DNS-Server'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', 'MS-Secondary-DNS-Server'],
				invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', 'MS-Secondary-DNS-Server'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', 'MS-Primary-NBNS-Server'],
				invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', 'MS-Primary-NBNS-Server'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', 'MS-Secondary-NBNS-Server'],
				invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', 'MS-Secondary-NBNS-Server'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', 'DNS-Server-IPv6-Address'],
				invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', 'DNS-Server-IPv6-Address'],
				?LOCALHOST_IPv4, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', '3GPP-IPv6-DNS-Servers'],
				invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', '3GPP-IPv6-DNS-Servers'],
				?LOCALHOST_IPv4, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([apns, ?'APN-EXAMPLE', '3GPP-IPv6-DNS-Servers'],
			     [?LOCALHOST_IPv6], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', '3GPP-IPv6-DNS-Servers'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([apns, ?'APN-EXAMPLE', '3GPP-IPv6-DNS-Servers'],
			     [?LOCALHOST_IPv6], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([apns, ?'APN-EXAMPLE', '3GPP-IPv6-DNS-Servers'],
				?LOCALHOST_IPv6, ?GGSN_CONFIG)),

    ?ok_option(?GGSN_PROXY_CONFIG),
    ?error_option(set_cfg_value([handlers, gn, contexts, invalid], [], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, contexts, <<"ams">>], invalid, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, contexts, <<"ams">>, proxy_sockets], invalid, ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([handlers, gn, proxy_data_source], gtp_proxy_ds, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, proxy_data_source], invalid, ?GGSN_PROXY_CONFIG)),

    ?error_option(set_cfg_value([handlers, gn, contexts, <<"ams">>, node_selection],
				invalid, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, contexts, <<"ams">>, node_selection],
				[], ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([handlers, gn, contexts, <<"ams">>, node_selection],
			     [static], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, node_selection], [], ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([handlers, gn, node_selection], [static], ?GGSN_PROXY_CONFIG)),

    ?error_option(set_cfg_value([node_selection], {1,2,3,4,5,6,7,8}, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([node_selection, mydns], {1,2,3,4,5,6,7,8}, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([node_selection, mydns], {dns, 1}, ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([node_selection, mydns], {dns, undefined}, ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([node_selection, mydns], {dns, {172,20,16,75}},
			     ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([node_selection, mydns], {dns, {{172,20,16,75}, 53}},
			     ?GGSN_PROXY_CONFIG)),

    ?error_option(set_cfg_value([node_selection, default], {static, 1}, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([node_selection, default], {static, []}, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([node_selection, default],
				{static, [{"Label", {0,0}, [], "Host"}]},
				?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([node_selection, default],
			     {static, [{"Label", {0,0}, [{"x-3gpp-pgw","x-gp"}], "Host"}]},
			     ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([node_selection, default],
			     {static, [{"Host", [], []}]},
			     ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([node_selection, default],
			     {static, [{"Host", [invalid], []}]},
			     ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([node_selection, default],
			     {static, [{"Host", [], [invalid]}]},
			     ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([node_selection, default],
			     {static, [{"Host", [?LOCALHOST_IPv4], []}]},
			     ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([node_selection, default],
			     {static, [{"Host", [], [?LOCALHOST_IPv6]}]},
			     ?GGSN_PROXY_CONFIG)),

    ?error_option(set_cfg_value([nodes], invalid, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes], [], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes, default], invalid, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes, default], [], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes, default], [{invalid, invalid}], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes, default, vrfs], invalid, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes, default, vrfs], [], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes, default, vrfs, cp], invalid, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes, default, vrfs, cp], [], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes, default, vrfs, cp, features], [], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes, default, vrfs, cp, features], invalid, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes, default, vrfs, cp, features], [invalid], ?GGSN_PROXY_CONFIG)),

    ?ok_option(set_cfg_value([nodes, default, ip_pools], [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([nodes, default, ip_pools], a, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([nodes, default, ip_pools], [a, b], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([nodes, default, ip_pools], [a, a], ?GGSN_CONFIG)),

    ?error_option(set_cfg_value([nodes, test], [], ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([nodes, "test"], [], ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([nodes, "test", vrfs, cp, features], ['CP-Function'], ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([nodes, "test", vrfs, 'cp2', features], ['CP-Function'], ?GGSN_PROXY_CONFIG)),

    ?ok_option(set_cfg_value([nodes, "test"], [connect], ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([nodes, "test"], [{connect, true}], ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([nodes, "test"], [{connect, false}], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes, "test"], [{raddr, invalid}], ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([nodes, "test"], [{raddr, {1,1,1,1}}], ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([nodes, "test"], [{raddr, {1,1,1,1,2,2,2,2}}], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([nodes, "test"], [{port, invalid}], ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([nodes, "test"], [{rport, 1234}], ?GGSN_PROXY_CONFIG)),

    ?error_option(set_cfg_value([proxy_map, invalid], [], ?GGSN_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([proxy_map, imsi],
			     [{<<"222222222222222">>, <<"333333333333333">>}], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([proxy_map, imsi],
				[{invalid, <<"333333333333333">>}], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([proxy_map, imsi],
				[{<<"222222222222222">>, invalid}], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([proxy_map, apn],
			     [{[invalid, <<"label">>], [<<"test">>]}], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([proxy_map, apn],
			     [{[<<"label">>], [invalid, <<"test">>]}], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([proxy_map, apn],
			     [{invalid, [<<"test">>]}], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([proxy_map, apn],
			     [{[<<"test">>], invalid}], ?GGSN_PROXY_CONFIG)),

    ?ok_option(?PGW_CONFIG),
    ?error_option(set_cfg_value([handlers, 'h1'], [{handler, pgw_s5s8},
						   {sockets, [irx]}], ?PGW_CONFIG)),

    ?ok_option(?PGW_PROXY_CONFIG),
    ?error_option(set_cfg_value([handlers, gn, node_selection], [], ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([handlers, gn, node_selection], [static], ?PGW_PROXY_CONFIG)),

    ?error_option(set_cfg_value([node_selection], {1,2,3,4,5,6,7,8}, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([node_selection, mydns], {1,2,3,4,5,6,7,8}, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([node_selection, mydns], {dns, 1}, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([node_selection, mydns], {dns, undefined}, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([node_selection, mydns], {dns, {172,20,16,75}},
			     ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([node_selection, mydns], {dns, {{172,20,16,75}, 53}},
			     ?PGW_PROXY_CONFIG)),

    ?error_option(set_cfg_value([node_selection, default], {static, 1}, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([node_selection, default], {static, []}, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([node_selection, default],
				{static, [{"Label", {0,0}, [], "Host"}]},
				?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([node_selection, default],
			     {static, [{"Label", {0,0}, [{"x-3gpp-pgw","x-s8-gtp"}], "Host"}]},
			     ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([node_selection, default],
			     {static, [{"Host", [], []}]},
			     ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([node_selection, default],
			     {static, [{"Host", [{1,1,1,1}], []}]},
			     ?PGW_PROXY_CONFIG)),

    ?ok_option(?SAE_S11_CONFIG),
    ?error_option(set_cfg_value([handlers, 'h1'], [{handler, saegw_s11},
						   {sockets, [irx]}], ?SAE_S11_CONFIG)),
    %% Charging Config
    ?error_option(set_cfg_value([charging], [], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([charging, default], [], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([charging, default, online], [], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([charging, default, offline], [], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([charging, default, offline], [enable], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([charging, default, offline], [disable], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([charging, default, offline, enable], true, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([charging, default, offline, enable], false, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([charging, default, offline, enable], invalid, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([charging, default, offline, triggers], [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([charging, default, offline, triggers, invalid], cdr, ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([charging, default, offline, triggers], [{'ecgi-change', off}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([charging, default, invalid], [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([charging, default, online, invalid], [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([charging, default, offline, invalid], [], ?GGSN_CONFIG)),

    ?ok_option(?TDF_CONFIG),
    ?error_option(set_cfg_value([handlers, tdf], invalid, ?TDF_CONFIG)),
    ?error_option(set_cfg_value([handlers, tdf, handler], invalid, ?TDF_CONFIG)),
    ?error_option(set_cfg_value([handlers, tdf, protocol], invalid, ?TDF_CONFIG)),
    ?error_option(set_cfg_value([handlers, tdf, protocol], ipv6, ?TDF_CONFIG)),
    ?error_option(set_cfg_value([handlers, tdf, sockets], invalid, ?TDF_CONFIG)),
    ?error_option(set_cfg_value([handlers, tdf, nodes], [], ?TDF_CONFIG)),
    ?error_option(set_cfg_value([handlers, tdf, node_selection], [], ?TDF_CONFIG)),
    ?error_option(set_cfg_value([handlers, tdf, node_selection], ["default"], ?TDF_CONFIG)),
    ?error_option(set_cfg_value([handlers, tdf, node_selection], [<<"default">>], ?TDF_CONFIG)),
    %% missing mandatory options
    ?error_option(set_cfg_value([handlers, tdf],
				[{handler, tdf},
				 {protocol, ip},
				 {nodes, ["topon.sx.prox01.mnc001.mcc001.3gppnetwork.org"]},
				 {node_selection, [default]}], ?TDF_CONFIG)),
    ?error_option(set_cfg_value([handlers, tdf],
				[{handler, tdf},
				 {protocol, ip},
				 {apn, ?'APN-EXAMPLE'},
				 {node_selection, [default]}], ?TDF_CONFIG)),
    ?error_option(set_cfg_value([handlers, tdf],
				[{handler, tdf},
				 {protocol, ip},
				 {apn, ?'APN-EXAMPLE'},
				 {nodes, ["topon.sx.prox01.mnc001.mcc001.3gppnetwork.org"]}],
				?TDF_CONFIG)),

    %% Charging Policy Rulebase Config
    RB = [charging, default, rulebase],
    ?ok_option(set_cfg_value(RB, [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value(RB ++ [<<"r-0001">>], [], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value(RB ++ [<<"rb-0001">>], [<<"r-0001">>], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value(RB, [{<<"rb-0001">>, [<<"r-0001">>]}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value(RB, [{<<"rb-0001">>, [<<"r-0001">>, <<"r-0001">>]}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value(RB, [{<<"rb-0001">>, [<<"r-0001">>]},
				  {<<"rb-0001">>, [<<"r-0001">>]}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value(RB ++ [<<"rb-0001">>], [<<"r-0001">>, undefined], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value(RB ++ [<<"rb-0001">>], [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value(RB ++ [<<"rb-0001">>], #{}, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value(RB ++ [<<"rb-0001">>], [undefined], ?GGSN_CONFIG)),

    ?ok_option(set_cfg_value(RB ++ [<<"rb-0001">>],
			     [{'Rating-Group', [3000]}], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value(RB ++ [<<"rb-0001">>],
			     [{'Rating-Group', [3000]},
			      {'Service-Identifier', [value]}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value(RB ++ [<<"rb-0001">>],
			     [{'Rating-Group', 3000}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value(RB ++ [<<"rb-0001">>],
				[{'Rating-Group', [3000]}, {'Rating-Group', [3000]}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value(RB ++ [<<"rb-0001">>],
				[{'Rating-Group', []}], ?GGSN_CONFIG)),

    ?ok_option(set_cfg_value(RB ++ [<<"rb-0001">>],
			     #{'Rating-Group' => [3000]}, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value(RB ++ [<<"rb-0001">>],
				#{'Rating-Group' => 3000}, ?GGSN_CONFIG)),

    ?error_option(set_cfg_value(RB ++ [<<"rb-0001">>],
				[{'Rating-Group', 3000}], ?GGSN_CONFIG)),

    %% path management configuration
    ?ok_option(set_cfg_value([path_management, t3], 10 * 1000, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([path_management, n3], 5, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([path_management, echo], 60 * 1000, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([path_management, idle_echo], 60 * 1000, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([path_management, down_echo], 60 * 1000, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([path_management, echo], off, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([path_management, idle_echo], off, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([path_management, down_echo], off, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([path_management, idle_timeout], 300 * 1000, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([path_management, down_timeout], 7200 * 1000, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([path_management, idle_timeout], 0, ?PGW_PROXY_CONFIG)),
    ?ok_option(set_cfg_value([path_management, down_timeout], 0, ?PGW_PROXY_CONFIG)),

    ?error_option(set_cfg_value([path_management, t3], -1, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([path_management, n3], -1, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([path_management, t3], invalid, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([path_management, n3], invalid, ?PGW_PROXY_CONFIG)),

    ?error_option(set_cfg_value([path_management, echo], 59 * 1000, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([path_management, echo], invalid, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([path_management, idle_echo], 59 * 1000, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([path_management, down_echo], 59 * 1000, ?PGW_PROXY_CONFIG)),

    ?error_option(set_cfg_value([path_management, idle_timeout], -1, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([path_management, down_timeout], -1, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([path_management, idle_timeout], invalid, ?PGW_PROXY_CONFIG)),
    ?error_option(set_cfg_value([path_management, down_timeout], invalid, ?PGW_PROXY_CONFIG)),
    ok.
