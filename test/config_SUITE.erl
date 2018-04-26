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
	[accept_new,
	 {sockets,
	  [{irx, [{type, 'gtp-c'},
		  {ip,  ?TEST_GSN_IPv4},
		  {reuseaddr, true}
		 ]}
	  ]},

	 {vrfs,
	  [{upstream, [{pools,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
				 {?IPv6PoolStart, ?IPv6PoolEnd, 64}
				]},
		       {'MS-Primary-DNS-Server', {8,8,8,8}},
		       {'MS-Secondary-DNS-Server', {8,8,4,4}},
		       {'MS-Primary-NBNS-Server', {127,0,0,1}},
		       {'MS-Secondary-NBNS-Server', {127,0,0,1}}
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

	 {sx_socket,
	  [{node, 'ergw'},
	   {name, 'ergw'},
	   {ip, {127,0,0,1}}]},

	 {apns,
	  [{?'APN-EXAMPLE', [{vrf, upstream}]},
	   {[<<"APN1">>], [{vrf, upstream}]}
	  ]}
	]).

-define(GGSN_PROXY_CONFIG,
	[{sockets,
	  [{irx, [{type, 'gtp-c'},
		  {ip,  ?TEST_GSN_IPv4},
		  {reuseaddr, true}
		 ]},
	   {'remote-irx', [{type, 'gtp-c'},
			   {ip,  ?FINAL_GSN_IPv4},
			   {reuseaddr, true}
			  ]}
	  ]},

	 {vrfs,
	  [{example, [{pools,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
				{?IPv6PoolStart, ?IPv6PoolEnd, 64}
			       ]},
		      {'MS-Primary-DNS-Server', {8,8,8,8}},
		      {'MS-Secondary-DNS-Server', {8,8,4,4}},
		      {'MS-Primary-NBNS-Server', {127,0,0,1}},
		      {'MS-Secondary-NBNS-Server', {127,0,0,1}}
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
		 {sockets, ['remote-irx']},
		 {node_selection, [static]},
		 {aaa, [{'Username',
			 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
		]}
	  ]},

	 {sx_socket,
	  [{node, 'ergw'},
	   {name, 'ergw'},
	   {ip, {127,0,0,1}}]},

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
	 }
	]).

-define(PGW_CONFIG,
	[{sockets,
	  [{irx, [{type, 'gtp-c'},
		  {ip,  ?TEST_GSN_IPv4},
		  {reuseaddr, true}
		 ]}
	  ]},

	 {vrfs,
	  [{upstream, [{pools,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
				 {?IPv6PoolStart, ?IPv6PoolEnd, 64}
				]},
		       {'MS-Primary-DNS-Server', {8,8,8,8}},
		       {'MS-Secondary-DNS-Server', {8,8,4,4}},
		       {'MS-Primary-NBNS-Server', {127,0,0,1}},
		       {'MS-Secondary-NBNS-Server', {127,0,0,1}}
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

	 {sx_socket,
	  [{node, 'ergw'},
	   {name, 'ergw'},
	   {ip, {127,0,0,1}}]},

	 {apns,
	  [{?'APN-EXAMPLE', [{vrf, upstream}]},
	   {[<<"APN1">>], [{vrf, upstream}]}
	  ]}
	]).


-define(PGW_PROXY_CONFIG,
	[
	 {sockets,
	  [{irx, [{type, 'gtp-c'},
		  {ip,  ?TEST_GSN_IPv4},
		  {reuseaddr, true}
		 ]},
	   {'remote-irx', [{type, 'gtp-c'},
			   {ip,  ?FINAL_GSN_IPv4},
			   {reuseaddr, true}
			  ]}
	  ]},

	 {vrfs,
	  [{example, [{pools,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
				{?IPv6PoolStart, ?IPv6PoolEnd, 64}
			       ]},
		      {'MS-Primary-DNS-Server', {8,8,8,8}},
		      {'MS-Secondary-DNS-Server', {8,8,4,4}},
		      {'MS-Primary-NBNS-Server', {127,0,0,1}},
		      {'MS-Secondary-NBNS-Server', {127,0,0,1}}
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
		 {sockets, ['remote-irx']},
		 {node_selection, [static]},
		 {aaa, [{'Username',
			 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
		]},
	   {s5s8, [{handler, pgw_s5s8},
		   {sockets, ['remote-irx']},
		   {node_selection, [static]}
		  ]}
	  ]},

	 {sx_socket,
	  [{node, 'ergw'},
	   {name, 'ergw'},
	   {ip, {127,0,0,1}},
	   {reuseaddr, true}]},

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
    ?error_option(set_cfg_value([sockets], undefined, ?GGSN_CONFIG)),

    ?error_option(set_cfg_value([accept_new], invalid, ?GGSN_CONFIG)),
    Accept0 = (catch ergw_config:validate_config(?GGSN_CONFIG)),
    ?equal(true, proplists:get_value(accept_new, Accept0)),
    Accept1 = (catch ergw_config:validate_config(set_cfg_value([accept_new], true, ?GGSN_CONFIG))),
    ?equal(true, proplists:get_value(accept_new, Accept1)),
    Accept2 = (catch ergw_config:validate_config(set_cfg_value([accept_new], false, ?GGSN_CONFIG))),
    ?equal(false, proplists:get_value(accept_new, Accept2)),

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

    SockOpts = [{type, 'gtp-c'}, {ip,  ?TEST_GSN_IPv4}, reuseaddr, freebind],
    SockCfg = (catch ergw_config:validate_config(
		       add_cfg_value([sockets, 'irx-2'], SockOpts, ?GGSN_CONFIG))),
    ?match(#{type      := 'gtp-c',
	     ip        := _,
	     freebind  := true,
	     reuseaddr := true},
	   proplists:get_value('irx-2', proplists:get_value(sockets, SockCfg))),

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

    ?error_option(set_cfg_value([vrfs, upstream], invalid, ?GGSN_CONFIG)),
    ?error_option(add_cfg_value([vrfs, upstream], [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs], invalid, ?GGSN_CONFIG)),

    ?error_option(set_cfg_value([vrfs, upstream, pools], invalid, ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools], [], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{?IPv4PoolStart, ?IPv4PoolEnd, 0}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{?IPv4PoolStart, ?IPv4PoolEnd, 33}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{?IPv4PoolStart, ?IPv4PoolEnd, invalid}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{?IPv4PoolStart, invalid, 32}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{invalid, ?IPv4PoolEnd, 32}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{?IPv4PoolEnd, ?IPv4PoolStart, 32}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{?IPv6PoolStart, ?IPv6PoolEnd, 0}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{?IPv6PoolStart, ?IPv6PoolEnd, 129}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{?IPv6PoolStart, ?IPv6PoolEnd, 127}], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([vrfs, upstream, pools],
			     [{?IPv6PoolStart, ?IPv6PoolEnd, 128}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{?IPv6PoolStart, ?IPv6PoolEnd, invalid}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{?IPv6PoolStart, invalid, 64}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{invalid, ?IPv6PoolEnd, 64}], ?GGSN_CONFIG)),
    ?error_option(set_cfg_value([vrfs, upstream, pools],
				[{?IPv6PoolEnd, ?IPv6PoolStart, 64}], ?GGSN_CONFIG)),

    ?error_option(set_cfg_value([apns, '_'], [], ?GGSN_CONFIG)),
    ?ok_option(set_cfg_value([apns, '_', vrf], upstream, ?GGSN_CONFIG)),
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
    ?match(VRF when is_map(VRF), proplists:get_value([<<"apn1">>], APN0)),

    ?ok_option(?GGSN_PROXY_CONFIG),
    ?error_option(set_cfg_value([handlers, gn, contexts, invalid], [], ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, contexts, <<"ams">>], invalid, ?GGSN_PROXY_CONFIG)),
    ?error_option(set_cfg_value([handlers, gn, contexts, <<"ams">>, proxy_sockets], invalid, ?GGSN_PROXY_CONFIG)),
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
    ?ok_option(set_cfg_value([node_selection, default],
			     {static, [{"Host", [{1,1,1,1}], []}]},
			     ?GGSN_PROXY_CONFIG)),

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
    ok.
