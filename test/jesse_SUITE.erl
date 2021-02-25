%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(jesse_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_ggsn_test_lib.hrl").

-define(error_option(Config),
	?match({error,{options, _}}, (catch ergw_config_legacy:validate_config(Config)))).

-define(ok_legacy_option(Config),
	?match({ok, #{}}, (catch ergw_config_legacy:load(Config)))).

-define(ok_option(Config),
	?match(#{}, (catch begin
			       {ok, Cnf} = ergw_config_legacy:load(Config),
			       ok = ergw_config:validate_config(Cnf),
			       Mapped = ergw_config:serialize_config(Cnf),
			       JBin = jsx:encode(Mapped),
			       Dec = jsx:decode(JBin, [return_maps, {labels, binary}]),
			       NewCnf = ergw_config:coerce_config(Dec),
			       ?match(true, diff([], Cnf, NewCnf)),
			       Cnf
			   end))).

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
    ergw_config:load_schemas(),

    ?ok_option(set_cfg_value([path_management, echo], off, ?PGW_PROXY_CONFIG)),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

fk(Key) -> lists:join($., Key).

diff([<<"handlers">>, _, <<"aaa">>], _, _) ->
    %% the APN aaa key is passthrough, don't check it for now
    true;
diff(_, A, A) ->
    true;
diff(Key, A, B) when is_map(A), is_map(B) ->
    KeysA = lists:sort(maps:keys(A)),
    KeysB = lists:sort(maps:keys(B)),

    if KeysA /= KeysB ->
	    ct:pal("(~p) ~s: not equal~nA: ~p~nB: ~p~n",
		   [Key, fk(Key), KeysA -- KeysB, KeysB -- KeysA]);
       true ->
	    ok
    end,

    Keys = sets:to_list(sets:intersection(sets:from_list(KeysA), sets:from_list(KeysB))),
    CmpR =
	lists:dropwhile(
	  fun(K) ->
		  diff(Key ++ [ergw_config:to_binary(K)], maps:get(K, A), maps:get(K, B))
	  end, Keys),
    CmpR =:= [];
diff(Key, A, B) ->
    ct:pal("(~p) ~s: not equal~nA: ~p~nB: ~p~n", [Key, fk(Key), A, B]),
    false.
