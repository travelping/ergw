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
	?match(true, (catch ergw_config:validate_config(Config)))).

%%%===================================================================
%%% API
%%%===================================================================

all() ->
    [config].

config() ->
    [{doc, "Test the config validation"}].
config(Config)  ->
    DataDir  = ?config(data_dir, Config),
    GGSNcfg = read_json(DataDir, "ggsn.json"),
    GGSNproxyCfg = read_json(DataDir, "ggsn_proxy.json"),
    PGWcfg = read_json(DataDir, "pgw.json"),
    PGWproxyCfg = read_json(DataDir, "pgw_proxy.json"),
    SAEs11cfg = read_json(DataDir, "sae_s11.json"),
    TDFcfg = read_json(DataDir, "tdf.json"),

    ct:pal("GGSN: ~p", [GGSNcfg]),

    ?ok_option(GGSNcfg),
    ?ok_option(GGSNproxyCfg),
    ?ok_option(PGWcfg),
    ?ok_option(PGWproxyCfg),
    ?ok_option(SAEs11cfg),
    ?ok_option(TDFcfg),


    ?ok_option(set([node_id], undefined, GGSNcfg)),
    ?ok_option(set([node_id], <<"GGSN">>, GGSNcfg)),
    ?ok_option(set([node_id], "GGSN", GGSNcfg)),
    ?ok_option(set([node_id], ["GGSN", <<"-proxy">>], GGSNcfg)),

    ?ok_option(set([teid], #{prefix => 2, len => 4}, GGSNcfg)),

    ?ok_option(set([accept_new], true, GGSNcfg)),
    ?ok_option(set([accept_new], false, GGSNcfg)),

    ?ok_option(set([http_api, port], 1234, GGSNcfg)),
    ?ok_option(set([http_api, num_acceptors], 5, GGSNcfg)),
    ?ok_option(set([http_api, ip], ?LOCALHOST_IPv4, GGSNcfg)),
    ?ok_option(set([http_api, ip], ?LOCALHOST_IPv6, GGSNcfg)),
    ?ok_option(set([http_api, ipv6_v6only], true, GGSNcfg)),

    ?ok_option(set([sockets, irx, ip], ?LOCALHOST_IPv6, GGSNcfg)),
    ?ok_option(set([sockets, irx, netdev], <<"netdev">>, GGSNcfg)),
    ?ok_option(set([sockets, irx, netdev], "netdev", GGSNcfg)),
    ?ok_option(set([sockets, irx, netns], <<"netns">>, GGSNcfg)),
    ?ok_option(set([sockets, irx, netns], "netns", GGSNcfg)),
    ?ok_option(set([sockets, irx, freebind], true, GGSNcfg)),
    ?ok_option(set([sockets, irx, freebind], false, GGSNcfg)),
    ?ok_option(set([sockets, irx, rcvbuf], 1, GGSNcfg)),
    ?ok_option(set([sockets, irx, send_port], true, GGSNcfg)),
    ?ok_option(set([sockets, irx, send_port], false, GGSNcfg)),
    ?ok_option(set([sockets, irx, send_port], 0, GGSNcfg)),
    ?ok_option(set([sockets, irx, send_port], 12345, GGSNcfg)),

    ?ok_option(set([sockets, irx, vrf], {apn, <<"irx">>}, GGSNcfg)),
    ?ok_option(set([sockets, irx, vrf], #{type => apn, name => <<"irx">>}, GGSNcfg)),
    ?ok_option(set([sockets, irx, vrf], #{type => dnn, name => <<"irx">>}, GGSNcfg)),

    SockOpts = #{type => 'gtp-c', ip => ?TEST_GSN_IPv4, reuseaddr => true, freebind => true},
    SockCfg = set([sockets, 'irx-2'], SockOpts, GGSNcfg),
    ?match(#{type      := 'gtp-c',
	     ip        := _,
	     freebind  := true,
	     reuseaddr := true},
	   maps:get(<<"irx-2">>, maps:get(sockets, SockCfg))),

    ?ok_option(set([sockets, sx, ip], ?LOCALHOST_IPv6, GGSNcfg)),
    ?ok_option(set([sockets, sx, netdev], <<"netdev">>, GGSNcfg)),
    ?ok_option(set([sockets, sx, netdev], "netdev", GGSNcfg)),
    ?ok_option(set([sockets, sx, netns], <<"netns">>, GGSNcfg)),
    ?ok_option(set([sockets, sx, netns], "netns", GGSNcfg)),
    ?ok_option(set([sockets, sx, freebind], true, GGSNcfg)),
    ?ok_option(set([sockets, sx, freebind], false, GGSNcfg)),
    ?ok_option(set([sockets, sx, rcvbuf], 1, GGSNcfg)),

    ?ok_option(set([handlers, gn, aaa, '3GPP-GGSN-MCC-MNC'], <<"00101">>, GGSNcfg)),
    ?ok_option(set([handlers, gn], #{handler => ggsn_gn,
				     sockets => [irx],
				     node_selection => [static]}, GGSNcfg)),

    ?match(X when is_binary(X), (catch vrf:validate_name('aaa'))),
    ?match(X when is_binary(X), (catch vrf:validate_name('1st.2nd'))),
    ?match(X when is_binary(X), (catch vrf:validate_name("1st.2nd"))),
    ?match(X when is_binary(X), (catch vrf:validate_name(<<"1st.2nd">>))),
    ?match(X when is_binary(X), (catch vrf:validate_name([<<"1st">>, <<"2nd">>]))),

    ?ok_option(set([ip_pools, 'pool-A', ranges],
		   [#{start => ?IPv6PoolStart, 'end' => ?IPv6PoolEnd, prefixLen => 128}], GGSNcfg)),
    ?ok_option(set([ip_pools, 'pool-A', 'DNS-Server-IPv6-Address'],
				[?LOCALHOST_IPv6], GGSNcfg)),
    ?ok_option(set([ip_pools, 'pool-A', '3GPP-IPv6-DNS-Servers'],
			     [?LOCALHOST_IPv6], GGSNcfg)),
    ?ok_option(set([ip_pools, 'pool-A', '3GPP-IPv6-DNS-Servers'],
			     [?LOCALHOST_IPv6], GGSNcfg)),

    ?ok_option(set([apns, <<"*">>, vrf], {apn, <<"upstream">>}, GGSNcfg)),
    ?ok_option(set([apns, <<"*">>, vrf], {apn, <<"upstream.tld">>}, GGSNcfg)),

    ?ok_option(set([apns, ?'APN-PROXY'], #{vrf => {apn, <<"example">>}}, GGSNcfg)),
    ?ok_option(set([apns, [<<"a-b">>]], #{vrf => {dnn, <<"example">>}}, GGSNcfg)),

    ?ok_option(set([apns, ?'APN-EXAMPLE', ip_pools], [], GGSNcfg)),
    ?ok_option(set([apns, ?'APN-EXAMPLE', ip_pools], [a, b], GGSNcfg)),

    ?ok_option(set([apns, ?'APN-EXAMPLE', bearer_type], 'IPv4', GGSNcfg)),
    ?ok_option(set([apns, ?'APN-EXAMPLE', bearer_type], 'IPv6', GGSNcfg)),
    ?ok_option(set([apns, ?'APN-EXAMPLE', bearer_type], 'IPv4v6', GGSNcfg)),

    ?ok_option(set([apns, ?'APN-EXAMPLE', prefered_bearer_type], 'IPv4', GGSNcfg)),
    ?ok_option(set([apns, ?'APN-EXAMPLE', prefered_bearer_type], 'IPv6', GGSNcfg)),

    ?ok_option(set([apns, ?'APN-EXAMPLE', ipv6_ue_interface_id], default, GGSNcfg)),
    ?ok_option(set([apns, ?'APN-EXAMPLE', ipv6_ue_interface_id], random, GGSNcfg)),
    ?ok_option(set([apns, ?'APN-EXAMPLE', ipv6_ue_interface_id], {0,0,0,0,0,0,0,2}, GGSNcfg)),

    ?ok_option(set([apns, ?'APN-EXAMPLE', '3GPP-IPv6-DNS-Servers'],
			     [?LOCALHOST_IPv6], GGSNcfg)),
    ?ok_option(set([apns, ?'APN-EXAMPLE', '3GPP-IPv6-DNS-Servers'],
			     [?LOCALHOST_IPv6], GGSNcfg)),

    ct:pal("GGSN proxy: ~p", [GGSNproxyCfg]),

    ?ok_option(set([handlers, gn, proxy_data_source], gtp_proxy_ds, GGSNproxyCfg)),
    ?ok_option(set([handlers, gn, contexts, <<"ams">>], #{node_selection => [static]}, GGSNproxyCfg)),
    ?ok_option(set([handlers, gn, contexts, <<"ams">>, node_selection], [static], GGSNproxyCfg)),
    ?ok_option(set([handlers, gn, node_selection], [static], GGSNproxyCfg)),

    ?ok_option(set([node_selection, mydns], #{type => dns, server => undefined}, GGSNproxyCfg)),
    ?ok_option(set([node_selection, mydns], #{type => dns, server => {172,20,16,75}, port => 53},
			     GGSNproxyCfg)),

    ?ok_option(set([node_selection, default],
		   #{type => static,
		     entries =>
			 [#{type => naptr, name => "Label", order => 0, priority => 0,
			    service => "x-3gpp-pgw", protocols => ["x-gp"],
			    replacement => "Host"}]},
			     GGSNproxyCfg)),
    ?ok_option(set([node_selection, default],
		   #{type => static,
		     entries =>
			 [#{type => host, name => "Host", ip4 => [?LOCALHOST_IPv4]}]},
		   GGSNproxyCfg)),
    ?ok_option(set([node_selection, default],
		   #{type => static,
		     entries =>
			 [#{type => host, name => "Host", ip6 => [?LOCALHOST_IPv6]}]},
		   GGSNproxyCfg)),

    ?ok_option(set([nodes, default, ip_pools], [], GGSNcfg)),
    ?ok_option(set([nodes, default, ip_pools], [a, b], GGSNcfg)),

    ?ok_option(set([nodes, default, heartbeat],
		   #{interval => 5000, timeout => 500, retry => 5}, GGSNcfg)),
    ?ok_option(set([nodes, default, request], #{timeout => 30000, retry => 5}, GGSNcfg)),

    ?ok_option(set([metrics, gtp_path_rtt_millisecond_intervals], [10, 100], GGSNcfg)),

    ?ok_option(set([nodes, entries, "test"], #{}, GGSNproxyCfg)),
    %% ?ok_option(set([nodes, entries, "test", vrfs, cp, features], ['CP-Function'], GGSNproxyCfg)),
    %% ?ok_option(set([nodes, entries, "test", vrfs, 'cp2', features], ['CP-Function'], GGSNproxyCfg)),

    ?ok_option(set([nodes, entries, "test"], #{connect => true}, GGSNproxyCfg)),
    ?ok_option(set([nodes, entries, "test"], #{connect => false}, GGSNproxyCfg)),

    ?ok_option(set([nodes, entries, "test"], #{raddr => {1,1,1,1}}, GGSNproxyCfg)),
    ?ok_option(set([nodes, entries, "test"], #{raddr => {1,1,1,1,2,2,2,2}}, GGSNproxyCfg)),
    ?ok_option(set([nodes, entries, "test"], #{rport => 1234}, GGSNproxyCfg)),

    %% TBD:

    %% ?ok_option(set([handlers, gn, node_selection], [static], PGWproxyCfg)),

    %% ?ok_option(set([node_selection, mydns], {dns, undefined}, PGWproxyCfg)),
    %% ?ok_option(set([node_selection, mydns], {dns, {172,20,16,75}},
    %% 			     PGWproxyCfg)),
    %% ?ok_option(set([node_selection, mydns], {dns, {{172,20,16,75}, 53}},
    %% 			     PGWproxyCfg)),

    %% ?ok_option(set([node_selection, default],
    %% 			     {static, [{"Label", {0,0}, [{"x-3gpp-pgw","x-s8-gtp"}], "Host"}]},
    %% 			     PGWproxyCfg)),
    %% ?ok_option(set([node_selection, default],
    %% 			     {static, [{"Host", [{1,1,1,1}], []}]},
    %% 			     PGWproxyCfg)),

    %% %% Charging Config
    %% ?ok_option(set([charging, default], [], GGSNcfg)),
    %% ?ok_option(set([charging, default, online], [], GGSNcfg)),
    %% ?ok_option(set([charging, default, offline], [], GGSNcfg)),
    %% ?ok_option(set([charging, default, offline], [enable], GGSNcfg)),
    %% ?ok_option(set([charging, default, offline], [disable], GGSNcfg)),
    %% ?ok_option(set([charging, default, offline, enable], true, GGSNcfg)),
    %% ?ok_option(set([charging, default, offline, enable], false, GGSNcfg)),
    %% ?ok_option(set([charging, default, offline, triggers], [], GGSNcfg)),
    %% ?ok_option(set([charging, default, offline, triggers], [{'ecgi-change', off}], GGSNcfg)),

    %% %% Charging Policy Rulebase Config
    %% RB = [charging, default, rulebase],
    %% ?ok_option(set(RB, [], GGSNcfg)),
    %% ?ok_option(set(RB ++ [<<"rb-0001">>], [<<"r-0001">>], GGSNcfg)),
    %% ?ok_option(set(RB, [{<<"rb-0001">>, [<<"r-0001">>]}], GGSNcfg)),

    %% ?ok_option(set(RB ++ [<<"rb-0001">>],
    %% 			     [{'Rating-Group', [3000]}], GGSNcfg)),
    %% ?ok_option(set(RB ++ [<<"rb-0001">>],
    %% 			     [{'Rating-Group', [3000]},
    %% 			      {'Service-Identifier', [value]}], GGSNcfg)),

    %% ?ok_option(set(RB ++ [<<"rb-0001">>],
    %% 			     #{'Rating-Group' => [3000]}, GGSNcfg)),

    %% %% path management configuration
    %% ?ok_option(set([path_management, t3], 10 * 1000, PGWproxyCfg)),
    %% ?ok_option(set([path_management, n3], 5, PGWproxyCfg)),
    %% ?ok_option(set([path_management, echo], 60 * 1000, PGWproxyCfg)),
    %% ?ok_option(set([path_management, idle_echo], 60 * 1000, PGWproxyCfg)),
    %% ?ok_option(set([path_management, down_echo], 60 * 1000, PGWproxyCfg)),
    %% ?ok_option(set([path_management, echo], off, PGWproxyCfg)),
    %% ?ok_option(set([path_management, idle_echo], off, PGWproxyCfg)),
    %% ?ok_option(set([path_management, down_echo], off, PGWproxyCfg)),
    %% ?ok_option(set([path_management, idle_timeout], 300 * 1000, PGWproxyCfg)),
    %% ?ok_option(set([path_management, down_timeout], 7200 * 1000, PGWproxyCfg)),
    %% ?ok_option(set([path_management, idle_timeout], 0, PGWproxyCfg)),
    %% ?ok_option(set([path_management, down_timeout], 0, PGWproxyCfg)),
    %% ?ok_option(set([path_management, icmp_error_handling], ignore, PGWproxyCfg)),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

read_json(Dir, File) ->
    {ok, Bin} = file:read_file(filename:join(Dir, File)),
    Config = jsx:decode(Bin, [return_maps, {labels, binary}]),
    ergw_config:coerce_config(Config).

set(Keys, Value, Config) ->
    ergw_config:set(Keys, Value, Config).
