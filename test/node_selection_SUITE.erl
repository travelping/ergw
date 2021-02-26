%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.
-module(node_selection_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").

-include("ergw_test_lib.hrl").

% copy from kernel/src/inet_dns.hrl
-record(dns_rec, {header, qdlist = [], anlist = [], nslist = [], arlist = []}).
-record(dns_rr, {domain = "", type = any, class = in, cnt = 0, ttl = 0, data = [],
		 tm, bm = [], func = false}).

-define(ERGW1, {100, 255, 4, 133}).
-define(ERGW2, {100, 255, 4, 125}).
-define(HUB1,  {100, 255, 5, 46}).
-define(HUB2,  {100, 255, 5, 45}).
-define(UP1,   {172,20,16,91}).

-define(SERVICES, [{"x-3gpp-pgw", "x-s8-gtp"},
		   {"x-3gpp-pgw", "x-s5-gtp"},
		   {"x-3gpp-pgw", "x-gp"},
		   {"x-3gpp-pgw", "x-gn"}]).

-define(SRV_q,
	#dns_rec{
	   anlist = [#dns_rr{domain = "example.apn.epc.mnc001.mcc001.3gppnetwork.org",
			     type = naptr,
			     data = % order pref flags service                regexp
				    { 100,  100, "s",  "x-3gpp-pgw:x-s8-gtp", [],
				    % replacement
				      "pgw-list-2.node.epc.mnc001.mcc001.3gppnetwork.org"}}],
	   arlist = [#dns_rr{domain = "ergw.ovh.node.epc.mnc001.mcc001.3gppnetwork.org",
			     type = a,
			     data = ?ERGW1},
		     #dns_rr{domain = "ergw.ovh.node.epc.mnc001.mcc001.3gppnetwork.org",
			     type = a,
			     data = ?ERGW2},
		     #dns_rr{domain = "ns0.mnc001.mcc001.3gppnetwork.org",
			     type = a,
			     data = {10, 10, 4, 2}},
		     #dns_rr{domain = "ns1.mnc001.mcc001.3gppnetwork.org",
			     type = a,
			     data = {10, 10, 4, 3}},
		     #dns_rr{domain = "pgw-list-2.node.epc.mnc001.mcc001.3gppnetwork.org",
			     type = srv,
			     data = % priority weight port
				    { 100,     100,   2123,
				    % target
				     "ergw.ovh.node.epc.mnc001.mcc001.3gppnetwork.org"}}]
	  }).

-define(SRV_q_no_ar,
	#dns_rec{
	   anlist = [#dns_rr{domain = "example.apn.epc.mnc002.mcc001.3gppnetwork.org",
			     type = naptr,
			     data = % order pref flags service                regexp
				    { 100,  100, "s",  "x-3gpp-pgw:x-s8-gtp", [],
				    % replacement
				      "pgw-list-2.node.epc.mnc002.mcc001.3gppnetwork.org"}}]
	  }).

-define(A_q,
	#dns_rec{
	   anlist = [#dns_rr{domain = "example.apn.epc.mnc003.mcc001.3gppnetwork.org",
			     type = naptr,
			     data = % order pref flags service
				    { 20,   20, "a",   "x-3gpp-pgw:x-s5-gtp:x-s8-gtp:x-gn",
				    % regexp replacement
				      [],     "hub.node.epc.mnc003.mcc001.3gppnetwork.org"}}],
	   arlist = [#dns_rr{domain = "hub.node.epc.mnc003.mcc001.3gppnetwork.org",
			     type = a,
			     data = ?HUB1},
		     #dns_rr{domain = "hub.node.epc.mnc003.mcc001.3gppnetwork.org",
			     type = a,
			     data = ?HUB2}]
	  }).

-define(A_q_no_ar,
	#dns_rec{
	   anlist = [#dns_rr{domain = "example.apn.epc.mnc004.mcc001.3gppnetwork.org",
			     type = naptr,
			     data = % order pref flags service
				    { 20,   20, "a",   "x-3gpp-pgw:x-s5-gtp:x-s8-gtp:x-gn",
				    % regexp replacement
				      [],     "hub.node.epc.mnc004.mcc001.3gppnetwork.org"}}]
	  }).

-define(L1, [{"topon.gngp.pgw.north.epc.mnc005.mcc001.3gppnetwork.org",
	      {500,64536},
	      [{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
	      [{1,0,0,2}],
	      []},
	     {"topon.s5s8.pgw.north.epc.mnc005.mcc001.3gppnetwork.org",
	      {200,64536},
	      [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"}],
	      [{1,0,0,1}],
	      []}]).

-define(L2, [{"topon.s5s8.pgw.south.epc.mnc005.mcc001.3gppnetwork.org",
	      {200,64536},
	      [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"}],
	      [{2,0,0,1}],
	      []},
	     {"topon.gngp.pgw.south.epc.mnc005.mcc001.3gppnetwork.org",
	      {500,64536},
	      [{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
	      [{2,0,0,2}],
	      []}]).

-define(L3, [{"topon.gngp.saegw.south.epc.mnc005.mcc001.3gppnetwork.org",
	      {500,64536},
	      [{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
	      [{5,0,0,2},{5,0,0,5}],
	      []},
	     {"topon.s5s8.saegw.south.epc.mnc005.mcc001.3gppnetwork.org",
	      {200,64536},
	      [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"}],
	      [{5,0,0,4},{5,0,0,1}],
	      []}]).

-define(S1, [{"topon.s5s8.sgw.south.epc.mnc005.mcc001.3gppnetwork.org",
	      {300,64536},
	      [{"x-3gpp-sgw","x-s5-gtp"},{"x-3gpp-sgw","x-s8-gtp"}],
	      [{4,0,0,2}],
	      []},
	     {"topon.gngp.sgw.south.epc.mnc005.mcc001.3gppnetwork.org",
	      {800,64536},
	      [{"x-3gpp-sgw","x-gn"},{"x-3gpp-sgw","x-gp"}],
	      [{4,0,0,3}],
	      []}]).

-define(S2, [{"topon.gngp.saegw.south.epc.mnc005.mcc001.3gppnetwork.org",
	      {800,64536},
	      [{"x-3gpp-sgw","x-gn"},{"x-3gpp-sgw","x-gp"}],
	      [{5,0,0,5},{5,0,0,2}],
	      []},
	     {"topon.s5s8.saegw.south.epc.mnc005.mcc001.3gppnetwork.org",
	      {300,64536},
	      [{"x-3gpp-sgw","x-s5-gtp"},{"x-3gpp-sgw","x-s8-gtp"}],
	      [{5,0,0,1},{5,0,0,4}],
	      []}]).

-define(ERGW_NODE_SELECTION,
	#{default =>
	      {static,
	       [
		%% APN NAPTR alternative
		{"_default.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
		 [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
		  {"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
		 "topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org"},
		{"_default.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
		 [{"x-3gpp-upf","x-sxa"}],
		 "topon.sx.prox01.node.epc.mnc001.mcc001.3gppnetwork.org"},

		{"web.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
		 [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
		  {"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
		 "topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org"},
		{"web.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
		 [{"x-3gpp-upf","x-sxa"}],
		 "topon.sx.prox01.node.epc.mnc001.mcc001.3gppnetwork.org"},

		{"lb.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
		 [{"x-3gpp-upf","x-sxa"}],
		 "topon.sx.prox01.node.epc.mnc001.mcc001.3gppnetwork.org"},
		{"lb.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
		 [{"x-3gpp-upf","x-sxa"}],
		 "topon.sx.prox02.node.epc.mnc001.mcc001.3gppnetwork.org"},
		{"lb.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,10},
		 [{"x-3gpp-upf","x-sxa"}],
		 "topon.sx.prox03.node.epc.mnc001.mcc001.3gppnetwork.org"},

		%% A/AAAA record alternatives
		{"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org",  [?ERGW1], []},
		{"topon.sx.prox01.node.epc.mnc001.mcc001.3gppnetwork.org", [?UP1], []},
		{"topon.sx.prox02.node.epc.mnc001.mcc001.3gppnetwork.org", [?UP1], []},
		{"topon.sx.prox03.node.epc.mnc001.mcc001.3gppnetwork.org", [?UP1], []}
	       ]
	      }
	 }
       ).

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

lookup_suites() ->
    [srv_lookup, srv_lookup_no_ar, a_lookup, a_lookup_no_ar,
     default_lookup, lb_entry_lookup].

api_suites() ->
    [topology_match, colocation_match,
     apn_to_fqdn, lb_entry_stats].

groups() ->
    [{api, [], api_suites()},
     {static, [], lookup_suites()},
     {dns, [], lookup_suites()}].

all() ->
    [{group, api},
     {group, static},
     {group, dns}].

suite() ->
    [{timetrap, {seconds, 30}}].

init_per_suite(Config) ->
    ok = meck:new(ergw, [passthrough, no_link]),
    ok = meck:expect(ergw, get_plmn_id, fun() -> {<<"001">>, <<"01">>} end),
    Config.

end_per_suite(_Config) ->
    ok = meck:unload(ergw),
    ok.

init_per_group(static, Config) ->
    application:set_env(ergw, node_selection, ?ERGW_NODE_SELECTION),
    ok = meck:new(ergw_node_selection, [passthrough, no_link]),
    ok = meck:expect(ergw_node_selection, naptr,
		     fun("example.apn.epc.mnc001.mcc001.3gppnetwork.org.", _) ->
			     {ok, ?SRV_q};
			("example.apn.epc.mnc002.mcc001.3gppnetwork.org.", _) ->
			     {ok, ?SRV_q_no_ar};
			("example.apn.epc.mnc003.mcc001.3gppnetwork.org.", _) ->
			     {ok, ?A_q};
			("example.apn.epc.mnc004.mcc001.3gppnetwork.org.", _) ->
			     {ok, ?A_q_no_ar}
		     end),
    Config;
init_per_group(dns, Config) ->
    case os:getenv("CI_DNS_SERVER") of
	Server when is_list(Server) ->
	    {ok, ServerIP} = inet:parse_address(Server),
	    NodeSelection = #{default => {dns, {ServerIP, 53}}},
	    application:set_env(ergw, node_selection, NodeSelection),
	    Pid = spawn(fun cache_server/0),
	    [{cache_server, Pid}, {dns_servers, {ServerIP, 53}} | Config];
	false ->
	    {skip, "DNS test server not configured"}
    end;
init_per_group(_, Config) ->
    Config.

end_per_group(static, _Config) ->
    ok = meck:unload(ergw_node_selection),
    ok;
end_per_group(dns, Config) ->
    Pid = proplists:get_value(cache_server, Config),
    Pid ! stop,
    ok;
end_per_group(_, _Config) ->
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

srv_lookup() ->
    [{doc, "NAPTR lookup with following SRV"}].
srv_lookup(Config) ->
    NameServers = proplists:get_value(dns_servers, Config),
    R = ergw_node_selection:lookup_dns("example.apn.epc.mnc001.mcc001.3gppnetwork.org.",
				       ?SERVICES, NameServers),
    ?match([{"pgw-list-2.node.epc.mnc001.mcc001.3gppnetwork.org", _, _, [_|_], _}], R),
    [{_, _, _, IP4, _}] = R,
    ?equal(lists:sort([?ERGW1, ?ERGW2]), lists:sort(IP4)),

    ok.

srv_lookup_no_ar() ->
    [{doc, "NPTR lookup with following SRV (no AR section in DNS response)"}].
srv_lookup_no_ar(Config) ->
    NameServers = proplists:get_value(dns_servers, Config),
    R = ergw_node_selection:lookup_dns("example.apn.epc.mnc002.mcc001.3gppnetwork.org.",
				       ?SERVICES, NameServers),
    ?match([{"pgw-list-2.node.epc.mnc002.mcc001.3gppnetwork.org", _, _, [], []}], R),
    ok.

a_lookup() ->
    [{doc, "NAPTR lookup with following A"}].
a_lookup(Config) ->
    NameServers = proplists:get_value(dns_servers, Config),
    R = ergw_node_selection:lookup_dns("example.apn.epc.mnc003.mcc001.3gppnetwork.org.",
				       ?SERVICES, NameServers),
    ?match([{"hub.node.epc.mnc003.mcc001.3gppnetwork.org", _, _, [_|_], _}], R),
    [{_, _, _, IP4, _}] = R,
    ?equal(lists:sort([?HUB1, ?HUB2]), lists:sort(IP4)),
    ok.

a_lookup_no_ar() ->
    [{doc, "NPTR lookup with following A"}].
a_lookup_no_ar(Config) ->
    NameServers = proplists:get_value(dns_servers, Config),
    R = ergw_node_selection:lookup_dns("example.apn.epc.mnc004.mcc001.3gppnetwork.org.",
				       ?SERVICES, NameServers),
    ?match([{"hub.node.epc.mnc004.mcc001.3gppnetwork.org", _, _, [], []}], R),
    ok.

default_lookup() ->
    [{doc, "lookup from config"}].
default_lookup(_Config) ->
    R = ergw_node_selection:candidates("example.apn.epc", [{"x-3gpp-upf","x-sxa"}], [default]),
    ?match([{"topon.sx.prox01.node.epc.mnc001.mcc001.3gppnetwork.org", _, _, [_|_], _}], R),
    [{_, _, _, IP4, _}] = R,
    ?equal(lists:sort([?UP1]), lists:sort(IP4)),
    ok.

topology_match() ->
    [{doc, "Check that topon node matching find the best combination"}].
topology_match(_Config) ->
    ?match([{{"topon.gngp.pgw.south.epc.mnc005.mcc001.3gppnetwork.org", _, _, _, _},
	     {"topon.gngp.sgw.south.epc.mnc005.mcc001.3gppnetwork.org", _, _, _, _}} | _],
	   ergw_node_selection:topology_match(?L1 ++ ?L2, ?S1)).

colocation_match() ->
    [{doc, "Check that topon node matching find the best combination"}].
colocation_match(_Config) ->
    ?match([{{"topon.gngp.saegw.south.epc.mnc005.mcc001.3gppnetwork.org", _, _, _, _},
	     {"topon.gngp.saegw.south.epc.mnc005.mcc001.3gppnetwork.org", _, _, _, _}} | _],
	   ergw_node_selection:colocation_match(?L1 ++ ?L2 ++ ?L3, ?S1 ++ ?S2)).

apn_to_fqdn() ->
    [{doc, "Translater APN-NI and APN-OI into a proper DNS FQDN for lookup"}].
apn_to_fqdn(_Config) ->
    TestsOk =
	[["example","com"],
	 [<<"example">>, <<"com">>],
	 ["example","com","mnc001","mcc001","gprs"],
	 ["example","com","apn","epc","mnc001","mcc001","3gppnetwork","org"]],
    lists:foreach(
      fun(X) ->
	      ?equal({fqdn,["example","com","apn","epc","mnc001","mcc001","3gppnetwork","org"]},
		     ergw_node_selection:apn_to_fqdn(X)) end, TestsOk),

    %%
    %% malformed APNs will result in broken FQDNs, but should not crash
    %% see 3GPP TS 23.003, Sect. 9.1 Structure of APN
    %%

    %% APN-NI ends with GRPS
    ?equal({fqdn,["example","gprs","apn","epc","mnc001","mcc001","3gppnetwork","org"]},
	   ergw_node_selection:apn_to_fqdn(["example","gprs"])),
    ?equal({fqdn,["apn","epc","example","com","3gppnetwork","org"]},
	   ergw_node_selection:apn_to_fqdn(["example","com","gprs"])),

    %% MCC/MNC swapped
    ?equal({fqdn,["example","com","apn","epc","mcc001","mnc001","3gppnetwork","org"]},
	   ergw_node_selection:apn_to_fqdn(["example","com","mcc001","mnc001","gprs"])),

    %% end with .3gppnetwork.org
    ?equal({fqdn,["example","com","3gppnetwork","org"]},
	   ergw_node_selection:apn_to_fqdn(["example","com","3gppnetwork","org"])),

    %% .3gppnetwork.org with incomplete content
    ?equal({fqdn,["example","com","mcc001","mnc001","3gppnetwork","org"]},
	   ergw_node_selection:apn_to_fqdn(["example","com","mcc001","mnc001","3gppnetwork","org"])),

    ?equal({fqdn,["example",<<"com">>,"apn","epc","mnc001","mcc001","3gppnetwork","org"]},
	   ergw_node_selection:apn_to_fqdn(["example",<<"com">>])),

    %% expected to crash
    ?match({'EXIT', {badarg, _}},
	   (catch ergw_node_selection:apn_to_fqdn([<<"example">>,"com"]))),

    ok.

lb_entry_lookup() ->
    [{doc, "Load balancing entry from config"}].
lb_entry_lookup(_Config) ->
    R = ergw_node_selection:candidates("lb.apn.epc", [{"x-3gpp-upf","x-sxa"}], [default]),
    ?match([{"topon.sx.prox01.node.epc.mnc001.mcc001.3gppnetwork.org", _, _, [_|_], _},
	    {"topon.sx.prox02.node.epc.mnc001.mcc001.3gppnetwork.org", _, _, [_|_], _},
	    {"topon.sx.prox03.node.epc.mnc001.mcc001.3gppnetwork.org", _, _, [_|_], _}],
	   lists:sort(R)),

    {N1, R1} = ergw_node_selection:snaptr_candidate(R),
    ?match({_, _, _}, N1),
    ?equal(lists:keydelete(element(1, N1), 1, R), R1),

    ok.

lb_entry_stats() ->
    [{doc, "Check that load balancing if indeed fair"}].
lb_entry_stats(_Config) ->
    NEntries = 20,
    NTries = 50000,
    Expected = NTries / NEntries,
    Entries =
	[{I, {1,100}, 'N', ['IP4'], ['IP6']} || I <- lists:seq(1, NEntries)],
    Stats =
	fun SFun(0,   S) -> S;
	    SFun(Cnt, S) ->
		{{E, _, _}, _} = ergw_node_selection:snaptr_candidate(Entries),
		SFun(Cnt - 1, maps:update_with(E, fun(X) -> X + 1 end, 1, S))
	end(NTries, #{}),
    Max = hd(lists:sort(fun(A,B) -> B > A end,
			[abs(Expected - V)/Expected ||
			    {_, V} <- maps:to_list(Stats)])),
    %% lets be gratious and accept a 10% deviantion from the expected mean
    Max > 0.1 andalso ct:fail("SNAPTR selection unbalanced"),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

cache_server() ->
    ok = ergw_node_selection_cache:init(),
    receive stop -> ok end,
    ok.
