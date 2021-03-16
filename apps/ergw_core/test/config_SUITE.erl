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

-define(bad(Fun), ?match({'EXIT', {badarg, _}}, (catch Fun))).
-define(ok(Fun), ?match(#{}, (catch Fun))).
-define(ok2(Fun), ?match({_, #{}}, (catch Fun))).

%%%===================================================================
%%% API
%%%===================================================================

all() ->
    [node,
     gtp_c_socket,
     gtp_u_socket,
     pfcp_socket,
     ggsn_handler,
     ggsn_proxy_handler,
     pgw_handler,
     pgw_proxy_handler,
     saegw_handler,
     tdf_handler,
     ip_pool,
     vrf,
     apn,
     node_sel,
     nodes,
     %% metrics,				% TBD: does not work yet
     proxy_map,
     charging,
     rule_base,
     path_management
    ].


node() ->
    [{doc, "Test tvalidation of the node global configuration"}].
node(_Config)  ->
    Node = [{node_id, <<"GGSN">>},
	    accept_new],
    ValF = fun ergw_core:validate_options/1,

    ?ok(ValF(Node)),
    ?ok(ValF(ValF(Node))),

    ?bad(ValF(set_cfg_value([plmn_id], {undefined, undefined}, Node))),
    ?bad(ValF(set_cfg_value([plmn_id], {<<"abc">>, <<"ab">>}, Node))),
    ?bad(ValF(set_cfg_value([node_id], undefined, Node))),
    ?ok(ValF(set_cfg_value([node_id], "GGSN", Node))),
    ?ok(ValF(set_cfg_value([node_id], ["GGSN", <<"-proxy">>], Node))),
    ?bad(ValF(set_cfg_value([sockets], undefined, Node))),

    ?ok(ValF(set_cfg_value([teid], {2, 4}, Node))),
    ?bad(ValF(set_cfg_value([teid], 1, Node))),
    ?bad(ValF(set_cfg_value([teid], {8, 2}, Node))),
    ?bad(ValF(set_cfg_value([teid], {atom, 8}, Node))),

    %% unexpected options
    ?bad(ValF(set_cfg_value([invalid], [], Node))),

    ct:pal("Cfg: ~p", [set_cfg_value([accept_new], invalid, Node)]),
    ?bad(ValF(set_cfg_value([accept_new], invalid, Node))),
    Accept0 = (catch ValF(Node)),
    ?equal(true, maps:get(accept_new, Accept0)),
    Accept1 = (catch ValF(set_cfg_value([accept_new], true, Node))),
    ?equal(true, maps:get(accept_new, Accept1)),
    Accept2 = (catch ValF(set_cfg_value([accept_new], false, Node))),
    ?equal(false, maps:get(accept_new, Accept2)),
    ok.

gtp_socket(ValF, Socket) ->
    ?ok(ValF(Socket)),
    ?bad(ValF(set_cfg_value([type], invalid, Socket))),
    ?bad(ValF(set_cfg_value([ip], invalid, Socket))),
    ?bad(ValF(set_cfg_value([ip], {1,1,1,1,1}, Socket))),
    ?ok(ValF(set_cfg_value([ip], ?LOCALHOST_IPv6, Socket))),
    ?ok(ValF(set_cfg_value([netdev], <<"netdev">>, Socket))),
    ?ok(ValF(set_cfg_value([netdev], "netdev", Socket))),
    ?bad(ValF(set_cfg_value([netdev], invalid, Socket))),
    ?ok(ValF(set_cfg_value([netns], <<"netns">>, Socket))),
    ?ok(ValF(set_cfg_value([netns], "netns", Socket))),
    ?bad(ValF(set_cfg_value([netns], invalid, Socket))),
    ?ok(ValF(set_cfg_value([freebind], true, Socket))),
    ?ok(ValF(set_cfg_value([freebind], false, Socket))),
    ?bad(ValF(set_cfg_value([freebind], invalid, Socket))),
    ?ok(ValF(set_cfg_value([rcvbuf], 1, Socket))),
    ?bad(ValF(set_cfg_value([rcvbuf], -1, Socket))),
    ?bad(ValF(set_cfg_value([rcvbuf], invalid, Socket))),
    ?bad(ValF(set_cfg_value([invalid], true, Socket))),
    ?bad(ValF(set_cfg_value([sockets, irx], invalid, Socket))),
    ?bad(ValF(add_cfg_value([sockets, irx], [], Socket))),
    ?ok(ValF(set_cfg_value([send_port], true, Socket))),
    ?ok(ValF(set_cfg_value([send_port], false, Socket))),
    ?ok(ValF(set_cfg_value([send_port], 0, Socket))),
    ?ok(ValF(set_cfg_value([send_port], 12345, Socket))),
    ?bad(ValF(set_cfg_value([send_port], -1, Socket))),
    ?bad(ValF(set_cfg_value([send_port], 22, Socket))),
    ?bad(ValF(set_cfg_value([send_port], invalid, Socket))),

    ?ok(ValF(add_cfg_value([vrf], 'irx', Socket))),
    ?ok(ValF(add_cfg_value([vrf], "irx", Socket))),
    ?ok(ValF(add_cfg_value([vrf], <<"irx">>, Socket))),
    ?ok(ValF(add_cfg_value([vrf], [<<"irx">>], Socket))),
    ?bad(ValF(add_cfg_value([vrf], ["irx", invalid], Socket))),
    ?bad(ValF(add_cfg_value([vrf], [<<"irx">>, invalid], Socket))),
    ?bad(ValF(add_cfg_value([vrf], [<<"irx">>, "invalid"], Socket))),
    ok.

gtp_c_socket() ->
    [{doc, "Test validation of the GTP-U socket configuration"}].
gtp_c_socket(_Config)  ->
    Socket = [{type, 'gtp-c'}, {ip,  ?TEST_GSN_IPv4}, {reuseaddr, true}],
    ValF = fun(Values) -> ergw_socket:validate_options(name, Values) end,

    gtp_socket(ValF, Socket),
    ?match(#{type      := 'gtp-c',
	     ip        := _,
	     reuseaddr := true},
	   ValF(Socket)),
    ok.

gtp_u_socket() ->
    [{doc, "Test validation of the GTP-U socket configuration"}].
gtp_u_socket(_Config)  ->
    Socket = [{type, 'gtp-u'}, {ip,  ?TEST_GSN_IPv4}, {reuseaddr, true}],
    ValF = fun(Values) -> ergw_socket:validate_options(name, Values) end,

    gtp_socket(ValF, Socket),
    ?match(#{type      := 'gtp-u',
	     ip        := _,
	     reuseaddr := true},
	   ValF(Socket)),
    ok.

pfcp_socket() ->
    [{doc, "Test validation of the PFCP socket configuration"}].
pfcp_socket(_Config)  ->
    Socket = [{type, 'pfcp'},
	      {socket, cp},
	      {ip, ?LOCALHOST_IPv4},
	      {reuseaddr, true}],
    ValF = fun(Values) -> ergw_socket:validate_options(name, Values) end,

    ?bad(ValF(set_cfg_value([ip], invalid, Socket))),
    ?bad(ValF(set_cfg_value([ip], {1,1,1,1,1}, Socket))),
    ?ok(ValF(set_cfg_value([ip], ?LOCALHOST_IPv6, Socket))),
    ?ok(ValF(set_cfg_value([netdev], <<"netdev">>, Socket))),
    ?ok(ValF(set_cfg_value([netdev], "netdev", Socket))),
    ?bad(ValF(set_cfg_value([netdev], invalid, Socket))),
    ?ok(ValF(set_cfg_value([netns], <<"netns">>, Socket))),
    ?ok(ValF(set_cfg_value([netns], "netns", Socket))),
    ?bad(ValF(set_cfg_value([netns], invalid, Socket))),
    ?ok(ValF(set_cfg_value([freebind], true, Socket))),
    ?ok(ValF(set_cfg_value([freebind], false, Socket))),
    ?bad(ValF(set_cfg_value([freebind], invalid, Socket))),
    ?ok(ValF(set_cfg_value([rcvbuf], 1, Socket))),
    ?bad(ValF(set_cfg_value([rcvbuf], -1, Socket))),
    ?bad(ValF(set_cfg_value([rcvbuf], invalid, Socket))),
    ?bad(ValF(add_cfg_value([socket], [], Socket))),
    ?bad(ValF(add_cfg_value([socket], "dp", Socket))),
    ?bad(ValF(set_cfg_value([invalid], true, Socket))),
    ?bad(ValF(set_cfg_value([sockets, sx], invalid, Socket))),
    ?bad(ValF(add_cfg_value([sockets, sx], [], Socket))),
    ok.

gen_handler(ValF, Handler) ->
    ?ok(ValF(Handler)),
    ?bad(ValF([])),
    ?bad(ValF(invalid)),

    ?bad(ValF(lists:keydelete(handler, 1, Handler))),
    ?bad(ValF(lists:keydelete(protocol, 1, Handler))),
    ?bad(ValF(lists:keydelete(sockets, 1, Handler))),

    ?bad(ValF(set_cfg_value([handler], invalid, Handler))),
    ?bad(ValF(set_cfg_value([protocol], invalid, Handler))),
    ?bad(ValF(set_cfg_value([sockets], invalid, Handler))),

    %% TBD: remove?
    ?bad(ValF(set_cfg_value([datapaths], invalid, Handler))),
    ok.

handler(ValF, Handler) ->
    gen_handler(ValF, Handler),

    ?ok(ValF(set_cfg_value([aaa, '3GPP-GGSN-MCC-MNC'], <<"00101">>, Handler))),
    ?bad(ValF(set_cfg_value([aaa, 'Username', invalid], invalid, Handler))),
    ?bad(ValF(set_cfg_value([aaa, invalid], invalid, Handler))),

    ?bad(ValF(set_cfg_value([node_selection], [], Handler))),
    ?ok(ValF(set_cfg_value([node_selection], [static], Handler))),
    ok.

proxy_handler(ValF, Handler) ->
    gen_handler(ValF, Handler),

    ?bad(ValF(set_cfg_value([contexts, invalid], [], Handler))),
    ?bad(ValF(set_cfg_value([contexts, <<"ams">>], invalid, Handler))),
    ?bad(ValF(set_cfg_value([contexts, <<"ams">>, proxy_sockets], invalid, Handler))),
    ?ok(ValF(set_cfg_value([proxy_data_source], gtp_proxy_ds, Handler))),
    ?bad(ValF(set_cfg_value([proxy_data_source], invalid, Handler))),

    ?bad(ValF(set_cfg_value([contexts, <<"ams">>, node_selection], invalid, Handler))),
    ?bad(ValF(set_cfg_value([contexts, <<"ams">>, node_selection], [], Handler))),
    ?ok(ValF(set_cfg_value([contexts, <<"ams">>, node_selection], [static], Handler))),
    ok.

ggsn_handler() ->
    [{doc, "Test validation of the GGSN handler configuration"}].
ggsn_handler(_Config)  ->
    Handler = [{handler, ggsn_gn},
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
				   <<"@">>, 'APN']}]}]}],
    ValF = fun(Values) -> ergw_context:validate_options(name, Values) end,

    handler(ValF, Handler),
    ok.

ggsn_proxy_handler() ->
    [{doc, "Test validation of the GGSN handler configuration"}].
ggsn_proxy_handler(_Config)  ->
    Handler = [{handler, ggsn_gn_proxy},
	       {protocol, gn},
	       {sockets, [irx]},
	       {proxy_sockets, ['irx']},
	       {node_selection, [static]},
	       {contexts,
		[{<<"ams">>,
		  [{proxy_sockets, ['irx']}]}]}
	      ],

    ValF = fun(Values) -> ergw_context:validate_options(name, Values) end,

    proxy_handler(ValF, Handler),
    ok.

pgw_handler() ->
    [{doc, "Test validation of the PGW handler configuration"}].
pgw_handler(_Config)  ->
    Handler = [{handler, pgw_s5s8},
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
				   <<"@">>, 'APN']}]}]}],
    ValF = fun(Values) -> ergw_context:validate_options(name, Values) end,

    handler(ValF, Handler),
    ok.

pgw_proxy_handler() ->
    [{doc, "Test validation of the PGW handler configuration"}].
pgw_proxy_handler(_Config)  ->
    Handler = [{handler, pgw_s5s8_proxy},
	       {protocol, s5s8},
	       {sockets, [irx]},
	       {proxy_sockets, ['irx']},
	       {node_selection, [static]},
	       {contexts,
		[{<<"ams">>,
		  [{proxy_sockets, ['irx']}]}]}
	      ],

    ValF = fun(Values) -> ergw_context:validate_options(name, Values) end,

    proxy_handler(ValF, Handler),
    ok.

saegw_handler() ->
    [{doc, "Test validation of the SAEGW handler configuration"}].
saegw_handler(_Config)  ->
    Handler = [{handler, saegw_s11},
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
				   <<"@">>, 'APN']}]}]}],
    ValF = fun(Values) -> ergw_context:validate_options(name, Values) end,

    handler(ValF, Handler),
    ok.

tdf_handler() ->
    [{doc, "Test validation of the TDF handler configuration"}].
tdf_handler(_Config)  ->
    Handler = [{handler, tdf},
	       {protocol, ip},
	       {apn, ?'APN-EXAMPLE'},
	       {nodes, [<<"topon.sx.prox01.mnc001.mcc001.3gppnetwork.org">>]},
	       {node_selection, [default]}
	      ],

    ValF = fun(Values) -> ergw_context:validate_options(name, Values) end,

    ?ok(ValF(Handler)),
    ?bad(ValF([])),
    ?bad(ValF(invalid)),

    %% missing mandatory options
    ?bad(ValF(lists:keydelete(handler, 1, Handler))),
    ?bad(ValF(lists:keydelete(protocol, 1, Handler))),
    ?bad(ValF(lists:keydelete(apn, 1, Handler))),
    ?bad(ValF(lists:keydelete(nodes, 1, Handler))),
    ?bad(ValF(lists:keydelete(node_selection, 1, Handler))),

    ?bad(ValF(set_cfg_value([handler], invalid, Handler))),
    ?bad(ValF(set_cfg_value([protocol], invalid, Handler))),
    ?bad(ValF(set_cfg_value([protocol], ipv6, Handler))),

    ?bad(ValF(set_cfg_value([nodes], [], Handler))),
    ?bad(ValF(set_cfg_value([node_selection], [], Handler))),
    ?bad(ValF(set_cfg_value([node_selection], ["default"], Handler))),
    ?bad(ValF(set_cfg_value([node_selection], [<<"default">>], Handler))),
    ok.

ip_pool() ->
    [{doc, "Test validation of the IP pool configuration"}].
ip_pool(_Config)  ->
    Pool = [{ranges, [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
		      {?IPv6PoolStart, ?IPv6PoolEnd, 64}]},
	    {'MS-Primary-DNS-Server', {8,8,8,8}},
	    {'MS-Secondary-DNS-Server', {8,8,4,4}},
	    {'MS-Primary-NBNS-Server', {127,0,0,1}},
	    {'MS-Secondary-NBNS-Server', {127,0,0,1}},
	    {'DNS-Server-IPv6-Address',
	     [{16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8888},
	      {16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8844}]}
	   ],
    ValF = fun(Values) -> ergw_ip_pool:validate_options(name, Values) end,

    ?ok(ValF(Pool)),
    ?bad(ValF([])),
    ?bad(ValF(invalid)),

    ?bad(ValF(set_cfg_value([ranges], invalid, Pool))),
    ?bad(ValF(set_cfg_value([ranges], [], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{?IPv4PoolStart, ?IPv4PoolEnd, 0}], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{?IPv4PoolStart, ?IPv4PoolEnd, 33}], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{?IPv4PoolStart, ?IPv4PoolEnd, invalid}], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{?IPv4PoolStart, invalid, 32}], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{invalid, ?IPv4PoolEnd, 32}], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{?IPv4PoolEnd, ?IPv4PoolStart, 32}], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{?IPv6PoolStart, ?IPv6PoolEnd, 0}], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{?IPv6PoolStart, ?IPv6PoolEnd, 129}], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{?IPv6PoolStart, ?IPv6PoolEnd, 127}], Pool))),
    ?ok(ValF(set_cfg_value([ranges], [{?IPv6PoolStart, ?IPv6PoolEnd, 128}], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{?IPv6PoolStart, ?IPv6PoolEnd, invalid}], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{?IPv6PoolStart, invalid, 64}], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{invalid, ?IPv6PoolEnd, 64}], Pool))),
    ?bad(ValF(set_cfg_value([ranges], [{?IPv6PoolEnd, ?IPv6PoolStart, 64}], Pool))),

    ?bad(ValF(set_cfg_value(['MS-Primary-DNS-Server'], invalid, Pool))),
    ?bad(ValF(set_cfg_value(['MS-Primary-DNS-Server'], ?LOCALHOST_IPv6, Pool))),
    ?bad(ValF(set_cfg_value(['MS-Secondary-DNS-Server'], invalid, Pool))),
    ?bad(ValF(set_cfg_value(['MS-Secondary-DNS-Server'], ?LOCALHOST_IPv6, Pool))),
    ?bad(ValF(set_cfg_value(['MS-Primary-NBNS-Server'], invalid, Pool))),
    ?bad(ValF(set_cfg_value(['MS-Primary-NBNS-Server'], ?LOCALHOST_IPv6, Pool))),
    ?bad(ValF(set_cfg_value(['MS-Secondary-NBNS-Server'], invalid, Pool))),
    ?bad(ValF(set_cfg_value(['MS-Secondary-NBNS-Server'], ?LOCALHOST_IPv6, Pool))),
    ?bad(ValF(set_cfg_value(['DNS-Server-IPv6-Address'], invalid, Pool))),
    ?bad(ValF(set_cfg_value(['DNS-Server-IPv6-Address'], ?LOCALHOST_IPv4, Pool))),
    ?bad(ValF(set_cfg_value(['DNS-Server-IPv6-Address'], [?LOCALHOST_IPv4], Pool))),
    ?bad(ValF(set_cfg_value(['DNS-Server-IPv6-Address'], ?LOCALHOST_IPv6, Pool))),
    ?ok(ValF(set_cfg_value(['DNS-Server-IPv6-Address'], [?LOCALHOST_IPv6], Pool))),
    ?bad(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], invalid, Pool))),
    ?bad(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], [invalid], Pool))),
    ?bad(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], ?LOCALHOST_IPv4, Pool))),
    ?bad(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], [?LOCALHOST_IPv4], Pool))),
    ?ok(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], [?LOCALHOST_IPv6], Pool))),
    ?bad(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], ?LOCALHOST_IPv6, Pool))),
    ?ok(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], [?LOCALHOST_IPv6], Pool))),
    ?bad(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], ?LOCALHOST_IPv6, Pool))),
    ok.

vrf() ->
    [{doc, "Test validation of the VRF configuration"}].
vrf(_Config)  ->
    ?match({'EXIT',{badarg, _}}, (catch vrf:validate_name([<<"1st">>, "2nd"]))),
    ?match(X when is_binary(X), (catch vrf:validate_name('aaa'))),
    ?match(X when is_binary(X), (catch vrf:validate_name('1st.2nd'))),
    ?match(X when is_binary(X), (catch vrf:validate_name("1st.2nd"))),
    ?match(X when is_binary(X), (catch vrf:validate_name(<<"1st.2nd">>))),
    ?match(X when is_binary(X), (catch vrf:validate_name([<<"1st">>, <<"2nd">>]))),
    ok.

apn() ->
    [{doc, "Test validation of the APN configuration"}].
apn(_Config)  ->
    APN = [{vrf, upstream},
	   {ip_pools, [<<"pool-A">>, <<"pool-B">>]}],
    ValF = fun(Values) -> ergw_apn:validate_options({?'APN-EXAMPLE', Values}) end,
    ValF2 = fun(Name, Values) -> ergw_apn:validate_options({Name, Values}) end,

    ?ok2(ValF(APN)),
    ?ok2(ValF2('_', APN)),
    ?bad(ValF([])),
    ?bad(ValF(invalid)),

    ?bad(ValF2(invalid, APN)),
    ?bad(ValF2([<<"$">>], APN)),

    ?ok2(ValF(set_cfg_value([vrf], upstream, APN))),
    ?ok2(ValF(set_cfg_value([vrfs], [upstream], APN))),
    ?bad(ValF(set_cfg_value([vrfs], upstream, APN))),
    ?ok2(ValF(set_cfg_value([vrfs], [a, b], APN))),
    ?bad(ValF(set_cfg_value([vrfs], [a | b], APN))),
    ?bad(ValF(set_cfg_value([vrfs], [a, a], APN))),

    %% check that APN's are lower cased after validation
    ?match({[<<"apn1">>], _}, ValF2([<<"APN1">>], APN)),

    ?ok2(ValF(set_cfg_value([ip_pools], [], APN))),
    ?bad(ValF(set_cfg_value([ip_pools], a, APN))),
    ?ok2(ValF(set_cfg_value([ip_pools], [a, b], APN))),
    ?bad(ValF(set_cfg_value([ip_pools], [a, a], APN))),

    ?ok2(ValF(set_cfg_value([bearer_type], 'IPv4', APN))),
    ?ok2(ValF(set_cfg_value([bearer_type], 'IPv6', APN))),
    ?ok2(ValF(set_cfg_value([bearer_type], 'IPv4v6', APN))),
    ?bad(ValF(set_cfg_value([bearer_type], 'Non-IP', APN))),
    ?bad(ValF(set_cfg_value([bearer_type], undefined, APN))),

    ?ok2(ValF(set_cfg_value([prefered_bearer_type], 'IPv4', APN))),
    ?ok2(ValF(set_cfg_value([prefered_bearer_type], 'IPv6', APN))),
    ?bad(ValF(set_cfg_value([prefered_bearer_type], 'IPv4v6', APN))),
    ?bad(ValF(set_cfg_value([prefered_bearer_type], 'Non-IP', APN))),
    ?bad(ValF(set_cfg_value([prefered_bearer_type], undefined, APN))),

    ?ok2(ValF(set_cfg_value([ipv6_ue_interface_id], default, APN))),
    ?ok2(ValF(set_cfg_value([ipv6_ue_interface_id], random, APN))),
    ?ok2(ValF(set_cfg_value([ipv6_ue_interface_id], {0,0,0,0,0,0,0,2}, APN))),
    ?bad(ValF(set_cfg_value([ipv6_ue_interface_id], undefined, APN))),
    ?bad(ValF(set_cfg_value([ipv6_ue_interface_id], {0,0,0,0,0,0,0,0}, APN))),
    ?bad(ValF(set_cfg_value([ipv6_ue_interface_id], {1,0,0,0,0,0,0,0}, APN))),
    ?bad(ValF(set_cfg_value([ipv6_ue_interface_id], {0,0,0,0,0,0,0,65536}, APN))),

    ?bad(ValF(set_cfg_value(['MS-Primary-DNS-Server'], invalid, APN))),
    ?bad(ValF(set_cfg_value(['MS-Primary-DNS-Server'], ?LOCALHOST_IPv6, APN))),
    ?bad(ValF(set_cfg_value(['MS-Secondary-DNS-Server'], invalid, APN))),
    ?bad(ValF(set_cfg_value(['MS-Secondary-DNS-Server'], ?LOCALHOST_IPv6, APN))),
    ?bad(ValF(set_cfg_value(['MS-Primary-NBNS-Server'], invalid, APN))),
    ?bad(ValF(set_cfg_value(['MS-Primary-NBNS-Server'], ?LOCALHOST_IPv6, APN))),
    ?bad(ValF(set_cfg_value(['MS-Secondary-NBNS-Server'], invalid, APN))),
    ?bad(ValF(set_cfg_value(['MS-Secondary-NBNS-Server'], ?LOCALHOST_IPv6, APN))),
    ?bad(ValF(set_cfg_value(['DNS-Server-IPv6-Address'], invalid, APN))),
    ?bad(ValF(set_cfg_value(['DNS-Server-IPv6-Address'], ?LOCALHOST_IPv4, APN))),
    ?bad(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], invalid, APN))),
    ?bad(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], ?LOCALHOST_IPv4, APN))),
    ?ok2(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], [?LOCALHOST_IPv6], APN))),
    ?bad(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], ?LOCALHOST_IPv6, APN))),
    ?ok2(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], [?LOCALHOST_IPv6], APN))),
    ?bad(ValF(set_cfg_value(['3GPP-IPv6-DNS-Servers'], ?LOCALHOST_IPv6, APN))),
    ok2.

node_sel() ->
    [{doc, "Test validation of the node selection configuration"}].
node_sel(_Config)  ->
    NodeSel = [{default,
		{static,
		 [
		  %% APN NAPTR alternative
		  {<<"_default.apn.epc.mnc001.mcc001.3gppnetwork.org">>, {300,64536},
		   [{'x-3gpp-pgw','x-s5-gtp'},{'x-3gpp-pgw','x-s8-gtp'},
		    {'x-3gpp-pgw','x-gn'},{'x-3gpp-pgw','x-gp'}],
		   <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>},
		  {<<"_default.apn.epc.mnc001.mcc001.3gppnetwork.org">>, {300,64536},
		   [{'x-3gpp-upf','x-sxa'}],
		   <<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>},

		  {<<"web.apn.epc.mnc001.mcc001.3gppnetwork.org">>, {300,64536},
		   [{'x-3gpp-pgw','x-s5-gtp'},{'x-3gpp-pgw','x-s8-gtp'},
		    {'x-3gpp-pgw','x-gn'},{'x-3gpp-pgw','x-gp'}],
		   <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>},
		  {<<"web.apn.epc.mnc001.mcc001.3gppnetwork.org">>, {300,64536},
		   [{'x-3gpp-upf','x-sxa'}],
		   <<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>},
		  {<<"web.apn.mnc001.mcc001.3gppnetwork.org">>, {300,64536},
		   [{'x-3gpp-upf','x-sxb'}],
		   <<"topon.sx.prox02.mnc001.mcc001.3gppnetwork.org">>},

		  %% A/AAAA record alternatives
		  {<<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>,  [{172, 20, 16, 89}], []},
		  {<<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>, [{172,20,16,91}], []},
		  {<<"topon.sx.prox02.epc.mnc001.mcc001.3gppnetwork.org">>, [{172,20,16,91}], []}
		 ]
		}
	       },
	       {mydns,
		{dns, {{172,20,16,75}, 53}}}
	      ],
    ValF = fun ergw_node_selection:validate_options/1,
    ?ok(ValF(NodeSel)),

    ?bad(ValF(set_cfg_value([mydns], {1,2,3,4,5,6,7,8}, NodeSel))),
    ?bad(ValF(set_cfg_value([mydns], {dns, 1}, NodeSel))),
    ?ok(ValF(set_cfg_value([mydns], {dns, undefined}, NodeSel))),
    ?ok(ValF(set_cfg_value([mydns], {dns, {172,20,16,75}}, NodeSel))),
    ?ok(ValF(set_cfg_value([mydns], {dns, {{172,20,16,75}, 53}}, NodeSel))),

    ?bad(ValF(set_cfg_value([default], {static, 1}, NodeSel))),
    ?bad(ValF(set_cfg_value([default], {static, []}, NodeSel))),
    ?bad(ValF(set_cfg_value([default], {static, [{"Label", {0,0}, [], "Host"}]}, NodeSel))),
    ?bad(ValF(set_cfg_value([default], {static, [{"Label", {0,0}, [{'x-3gpp-pgw','x-gp'}], "Host"}]}, NodeSel))),
    ?ok(ValF(set_cfg_value([default],  {static, [{<<"Label">>, {0,0}, [{'x-3gpp-pgw','x-gp'}], <<"Host">>}]}, NodeSel))),
    ?bad(ValF(set_cfg_value([default], {static, [{<<"Host">>, [], []}]}, NodeSel))),
    ?bad(ValF(set_cfg_value([default], {static, [{<<"Host">>, [invalid], []}]}, NodeSel))),
    ?bad(ValF(set_cfg_value([default], {static, [{<<"Host">>, [], [invalid]}]}, NodeSel))),
    ?ok(ValF(set_cfg_value([default],  {static, [{<<"Host">>, [?LOCALHOST_IPv4], []}]}, NodeSel))),
    ?ok(ValF(set_cfg_value([default],  {static, [{<<"Host">>, [], [?LOCALHOST_IPv6]}]}, NodeSel))),

    ok.

nodes() ->
    [{doc, "Test validation of the nodes configuration"}].
nodes(_Config)  ->
    Nodes = [{default,
	      [{vrfs,
		[{cp, [{features, ['CP-Function']}]},
		 {irx, [{features, ['Access']}]},
		 {sgi, [{features, ['SGi-LAN']}]}
		]},
	       {ip_pools, [<<"pool-A">>]}]
	     },
	     {<<"node-A">>, [connect]}],
    ValF = fun(Values) -> ergw_sx_node:validate_options(Values) end,

    ?ok(ValF(Nodes)),
    ?bad(ValF([])),

    ?bad(ValF(set_cfg_value([default], invalid, Nodes))),
    ?bad(ValF(set_cfg_value([default], [], Nodes))),
    ?bad(ValF(set_cfg_value([default], [{invalid, invalid}], Nodes))),
    ?bad(ValF(set_cfg_value([default, vrfs], invalid, Nodes))),
    ?bad(ValF(set_cfg_value([default, vrfs], [], Nodes))),
    ?bad(ValF(set_cfg_value([default, vrfs, cp], invalid, Nodes))),
    ?bad(ValF(set_cfg_value([default, vrfs, cp], [], Nodes))),
    ?bad(ValF(set_cfg_value([default, vrfs, cp, features], [], Nodes))),
    ?bad(ValF(set_cfg_value([default, vrfs, cp, features], invalid, Nodes))),
    ?bad(ValF(set_cfg_value([default, vrfs, cp, features], [invalid], Nodes))),

    ?ok(ValF(set_cfg_value([default, ip_pools], [], Nodes))),
    ?bad(ValF(set_cfg_value([default, ip_pools], a, Nodes))),
    ?ok(ValF(set_cfg_value([default, ip_pools], [a, b], Nodes))),
    ?bad(ValF(set_cfg_value([default, ip_pools], [a, a], Nodes))),

    ?bad(ValF(set_cfg_value([default, heartbeat], [{interval, invalid}], Nodes))),
    ?ok(ValF(set_cfg_value([default, heartbeat], [{interval, 5000}, {timeout, 500}, {retry, 5}], Nodes))),
    ?bad(ValF(set_cfg_value([default, request], [{timeout, invalid}], Nodes))),
    ?ok(ValF(set_cfg_value([default, request], [{timeout, 30000}, {retry, 5}], Nodes))),

    ?bad(ValF(set_cfg_value([test], [], Nodes))),
    ?bad(ValF(set_cfg_value(["test"], [], Nodes))),
    ?ok(ValF(set_cfg_value([<<"test">>], [], Nodes))),
    ?ok(ValF(set_cfg_value([<<"test">>, vrfs, cp, features], ['CP-Function'], Nodes))),
    ?ok(ValF(set_cfg_value([<<"test">>, vrfs, 'cp2', features], ['CP-Function'], Nodes))),

    ?ok(ValF(set_cfg_value([<<"test">>], [connect], Nodes))),
    ?ok(ValF(set_cfg_value([<<"test">>], [{connect, true}], Nodes))),
    ?ok(ValF(set_cfg_value([<<"test">>], [{connect, false}], Nodes))),
    ?bad(ValF(set_cfg_value([<<"test">>], [{raddr, invalid}], Nodes))),
    ?ok(ValF(set_cfg_value([<<"test">>], [{raddr, {1,1,1,1}}], Nodes))),
    ?ok(ValF(set_cfg_value([<<"test">>], [{raddr, {1,1,1,1,2,2,2,2}}], Nodes))),
    ?bad(ValF(set_cfg_value([<<"test">>], [{port, invalid}], Nodes))),
    ?ok(ValF(set_cfg_value([<<"test">>], [{rport, 1234}], Nodes))),
    ok.

metrics() ->
    [{doc, "Test validation of the metrics configuration"}].
metrics(_Config)  ->
    Metrics = [{gtp_path_rtt_millisecond_intervals, [10,30,50,75,100,1000,2000]}],
    ValF = fun(Values) -> ergw_prometheus:validate_options(Values) end,

    ?ok(ValF(Metrics)),
    ?bad(ValF([])),

    ?bad(ValF(set_cfg_value([gtp_path_rtt_millisecond_intervals], [invalid], Metrics))),
    ?bad(ValF(set_cfg_value([gtp_path_rtt_millisecond_intervals], [-100], Metrics))),
    ?ok(ValF(set_cfg_value([gtp_path_rtt_millisecond_intervals], [10, 100], Metrics))),
    ok.

proxy_map() ->
    [{doc, "Test validation of the proxy map configuration"}].
proxy_map(_Config)  ->
    Map = [{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
	   {imsi, [{?'IMSI', {?'PROXY-IMSI', ?'PROXY-MSISDN'}}]}],
    ValF = fun(Values) ->  gtp_proxy_ds:validate_options(Values) end,

    ?ok(ValF(Map)),

    ?bad(ValF(set_cfg_value([invalid], [], Map))),
    ?ok(ValF(set_cfg_value([imsi], [{<<"222222222222222">>, <<"333333333333333">>}], Map))),
    ?bad(ValF(set_cfg_value([imsi], [{invalid, <<"333333333333333">>}], Map))),
    ?bad(ValF(set_cfg_value([imsi], [{<<"222222222222222">>, invalid}], Map))),
    ?bad(ValF(set_cfg_value([apn], [{[invalid, <<"label">>], [<<"test">>]}], Map))),
    ?bad(ValF(set_cfg_value([apn], [{[<<"label">>], [invalid, <<"test">>]}], Map))),
    ?bad(ValF(set_cfg_value([apn], [{invalid, [<<"test">>]}], Map))),
    ?bad(ValF(set_cfg_value([apn], [{[<<"test">>], invalid}], Map))),
    ok.

charging() ->
    [{doc, "Test validation of the charging configuration"}].
charging(_Config)  ->
    Charging = [{default, []}],
    ValF = fun(Values) -> ergw_charging:validate_options(Values) end,

    ?ok(ValF(Charging)),

    ?ok(ValF(set_cfg_value([default, online], [], Charging))),
    ?ok(ValF(set_cfg_value([default, offline], [], Charging))),
    ?ok(ValF(set_cfg_value([default, offline], [enable], Charging))),
    ?ok(ValF(set_cfg_value([default, offline], [disable], Charging))),
    ?ok(ValF(set_cfg_value([default, offline, enable], true, Charging))),
    ?ok(ValF(set_cfg_value([default, offline, enable], false, Charging))),
    ?bad(ValF(set_cfg_value([default, offline, enable], invalid, Charging))),
    ?ok(ValF(set_cfg_value([default, offline, triggers], [], Charging))),
    ?bad(ValF(set_cfg_value([default, offline, triggers, invalid], cdr, Charging))),
    ?ok(ValF(set_cfg_value([default, offline, triggers], [{'ecgi-change', off}], Charging))),
    ?bad(ValF(set_cfg_value([default, invalid], [], Charging))),
    ?bad(ValF(set_cfg_value([default, online, invalid], [], Charging))),
    ?bad(ValF(set_cfg_value([default, offline, invalid], [], Charging))),
    ok.

rule_base() ->
    [{doc, "Test validation of the rule base configuration"}].
rule_base(_Config)  ->
    ValF = fun(Values) -> ergw_charging:validate_options(Values) end,
    RB = [default, rulebase],

    %% Charging Policy Rulebase Config
    ?ok(ValF(set_cfg_value(RB, [], []))),
    ?bad(ValF(set_cfg_value(RB ++ [<<"r-0001">>], [], []))),
    ?ok(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], [<<"r-0001">>], []))),
    ?ok(ValF(set_cfg_value(RB, [{<<"rb-0001">>, [<<"r-0001">>]}], []))),
    ?bad(ValF(set_cfg_value(RB, [{<<"rb-0001">>, [<<"r-0001">>, <<"r-0001">>]}], []))),
    ?bad(ValF(set_cfg_value(RB, [{<<"rb-0001">>, [<<"r-0001">>]}, {<<"rb-0001">>, [<<"r-0001">>]}], []))),
    ?bad(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], [<<"r-0001">>, undefined], []))),
    ?bad(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], [], []))),
    ?bad(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], #{}, []))),
    ?bad(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], [undefined], []))),

    ?ok(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], [{'Rating-Group', [3000]}], []))),
    ?ok(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], [{'Rating-Group', [3000]}, {'Service-Identifier', [value]}], []))),
    ?bad(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], [{'Rating-Group', 3000}], []))),
    ?bad(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], [{'Rating-Group', [3000]}, {'Rating-Group', [3000]}], []))),
    ?bad(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], [{'Rating-Group', []}], []))),

    ?ok(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], #{'Rating-Group' => [3000]}, []))),
    ?bad(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], #{'Rating-Group' => 3000}, []))),

    ?bad(ValF(set_cfg_value(RB ++ [<<"rb-0001">>], [{'Rating-Group', 3000}], []))),
    ok.

path_management() ->
    [{doc, "Test validation of the path management configuration"}].
path_management(_Config)  ->
    Path = [{t3, 10 * 1000},
	    {n3, 5},
	    {echo, 60 * 1000}],
    ValF = fun gtp_path:validate_options/1,

    ?ok(ValF(Path)),
    ?ok(ValF([])),

    ?ok(ValF(set_cfg_value([t3], 10 * 1000, Path))),
    ?ok(ValF(set_cfg_value([n3], 5, Path))),
    ?ok(ValF(set_cfg_value([echo], 60 * 1000, Path))),
    ?ok(ValF(set_cfg_value([idle_echo], 60 * 1000, Path))),
    ?ok(ValF(set_cfg_value([down_echo], 60 * 1000, Path))),
    ?ok(ValF(set_cfg_value([echo], off, Path))),
    ?ok(ValF(set_cfg_value([idle_echo], off, Path))),
    ?ok(ValF(set_cfg_value([down_echo], off, Path))),
    ?ok(ValF(set_cfg_value([idle_timeout], 300 * 1000, Path))),
    ?ok(ValF(set_cfg_value([down_timeout], 7200 * 1000, Path))),
    ?ok(ValF(set_cfg_value([idle_timeout], 0, Path))),
    ?ok(ValF(set_cfg_value([down_timeout], 0, Path))),
    ?ok(ValF(set_cfg_value([icmp_error_handling], ignore, Path))),

    ?bad(ValF(set_cfg_value([t3], -1, Path))),
    ?bad(ValF(set_cfg_value([n3], -1, Path))),
    ?bad(ValF(set_cfg_value([t3], invalid, Path))),
    ?bad(ValF(set_cfg_value([n3], invalid, Path))),

    ?bad(ValF(set_cfg_value([echo], 59 * 1000, Path))),
    ?bad(ValF(set_cfg_value([echo], invalid, Path))),
    ?bad(ValF(set_cfg_value([idle_echo], 59 * 1000, Path))),
    ?bad(ValF(set_cfg_value([down_echo], 59 * 1000, Path))),

    ?bad(ValF(set_cfg_value([idle_timeout], -1, Path))),
    ?bad(ValF(set_cfg_value([down_timeout], -1, Path))),
    ?bad(ValF(set_cfg_value([idle_timeout], invalid, Path))),
    ?bad(ValF(set_cfg_value([down_timeout], invalid, Path))),

    ?bad(ValF(set_cfg_value([icmp_error_handling], invalid, Path))),
    ?bad(ValF(set_cfg_value([icmp_error_handling], <<>>, Path))),
    ok.
