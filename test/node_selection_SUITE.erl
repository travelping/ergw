-module(node_selection_SUITE).

-compile(export_all).

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

-define(SERVICES, [{"x-3gpp-pgw", "x-s8-gtp"},
		   {"x-3gpp-pgw", "x-s5-gtp"},
		   {"x-3gpp-pgw", "x-s8-gtp"},
		   {"x-3gpp-pgw", "x-gn"}]).

-define(SRV_q,
	#dns_rec{
	   anlist = [#dns_rr{domain = "example.apn.epc.mnc123.mcc310.3gppnetwork.org",
			     type = naptr,
			     data = % order pref flags service                regexp
				    { 100,  100, "s",  "x-3gpp-pgw:x-s8-gtp", [],
				    % replacement
				      "pgw-list-2.node.epc.mnc123.mcc310.3gppnetwork.org"}}],
	   arlist = [#dns_rr{domain = "ergw.ovh.node.epc.mnc123.mcc310.3gppnetwork.org",
			     type = a,
			     data = ?ERGW1},
		     #dns_rr{domain = "ergw.ovh.node.epc.mnc123.mcc310.3gppnetwork.org",
			     type = a,
			     data = ?ERGW2},
		     #dns_rr{domain = "ns0.mnc123.mcc310.3gppnetwork.org",
			     type = a,
			     data = {10, 10, 4, 2}},
		     #dns_rr{domain = "ns1.mnc123.mcc310.3gppnetwork.org",
			     type = a,
			     data = {10, 10, 4, 3}},
		     #dns_rr{domain = "pgw-list-2.node.epc.mnc123.mcc310.3gppnetwork.org",
			     type = srv,
			     data = % priority weight port
				    { 100,     100,   2123,
				    % target
				     "ergw.ovh.node.epc.mnc123.mcc310.3gppnetwork.org"}}]
	  }).

-define(A_q,
	#dns_rec{
	   anlist = [#dns_rr{domain = "example.apn.epc.mnc001.mcc456.3gppnetwork.org",
			     type = naptr,
			     data = % order pref flags service
				    { 20,   20, "a",   "x-3gpp-pgw:x-s5-gtp:x-s8-gtp:x-gn",
				    % regexp replacement
				      [],     "hub.node.epc.mnc001.mcc456.3gppnetwork.org"}}],
	   arlist = [#dns_rr{domain = "hub.node.epc.mnc001.mcc456.3gppnetwork.org",
			     type = a,
			     data = ?HUB1},
		     #dns_rr{domain = "hub.node.epc.mnc001.mcc456.3gppnetwork.org",
			     type = a,
			     data = ?HUB2}]
	  }).

-define(L1, [{"topon.gngp.pgw.north.epc.mnc990.mcc311.3gppnetwork.org",
	      {500,64536},
	      [{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
	      [{1,0,0,2}],
	      []},
	     {"topon.s5s8.pgw.north.epc.mnc990.mcc311.3gppnetwork.org",
	      {200,64536},
	      [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"}],
	      [{1,0,0,1}],
	      []}]).

-define(L2, [{"topon.s5s8.pgw.south.epc.mnc990.mcc311.3gppnetwork.org",
	      {200,64536},
	      [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"}],
	      [{2,0,0,1}],
	      []},
	     {"topon.gngp.pgw.south.epc.mnc990.mcc311.3gppnetwork.org",
	      {500,64536},
	      [{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
	      [{2,0,0,2}],
	      []}]).

-define(L3, [{"topon.gngp.saegw.south.epc.mnc990.mcc311.3gppnetwork.org",
	      {500,64536},
	      [{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
	      [{5,0,0,2},{5,0,0,5}],
	      []},
	     {"topon.s5s8.saegw.south.epc.mnc990.mcc311.3gppnetwork.org",
	      {200,64536},
	      [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"}],
	      [{5,0,0,4},{5,0,0,1}],
	      []}]).

-define(S1, [{"topon.s5s8.sgw.south.epc.mnc990.mcc311.3gppnetwork.org",
	      {300,64536},
	      [{"x-3gpp-sgw","x-s5-gtp"},{"x-3gpp-sgw","x-s8-gtp"}],
	      [{4,0,0,2}],
	      []},
	     {"topon.gngp.sgw.south.epc.mnc990.mcc311.3gppnetwork.org",
	      {800,64536},
	      [{"x-3gpp-sgw","x-gn"},{"x-3gpp-sgw","x-gp"}],
	      [{4,0,0,3}],
	      []}]).

-define(S2, [{"topon.gngp.saegw.south.epc.mnc990.mcc311.3gppnetwork.org",
	      {800,64536},
	      [{"x-3gpp-sgw","x-gn"},{"x-3gpp-sgw","x-gp"}],
	      [{5,0,0,5},{5,0,0,2}],
	      []},
	     {"topon.s5s8.saegw.south.epc.mnc990.mcc311.3gppnetwork.org",
	      {300,64536},
	      [{"x-3gpp-sgw","x-s5-gtp"},{"x-3gpp-sgw","x-s8-gtp"}],
	      [{5,0,0,1},{5,0,0,4}],
	      []}]).


%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [srv_lookup, a_lookup, topology_match, colocation_match].

suite() ->
    [{timetrap, {seconds, 30}}].

groups() ->
    [].

init_per_suite(Config) ->
    ok = meck:new(ergw_node_selection, [passthrough, no_link]),
    ok = meck:expect(ergw_node_selection, naptr,
		     fun("example.apn.epc.mnc123.mcc310.3gppnetwork.org.") ->
			     {ok, ?SRV_q};
			("example.apn.epc.mnc001.mcc456.3gppnetwork.org.") ->
			     {ok, ?A_q}
		     end),
    Config.

end_per_suite(_Config) ->
    ok = meck:unload(ergw_node_selection),
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

srv_lookup() ->
    [{doc, "NPTR lookup with following SRV"}].
srv_lookup(_Config) ->
    R = ergw_node_selection:lookup("example.apn.epc.mnc123.mcc310.3gppnetwork.org.", ?SERVICES),
    ?match([{"pgw-list-2.node.epc.mnc123.mcc310.3gppnetwork.org", _, _, [_|_], []}], R),
    [{_, _, _, IP4, _}] = R,
    ?equal(lists:sort([?ERGW1, ?ERGW2]), lists:sort(IP4)),

    ok.

a_lookup() ->
    [{doc, "NPTR lookup with following A"}].
a_lookup(_Config) ->
    R = ergw_node_selection:lookup("example.apn.epc.mnc001.mcc456.3gppnetwork.org.", ?SERVICES),
    ?match([{"hub.node.epc.mnc001.mcc456.3gppnetwork.org", _, _, [_|_], []}], R),
    [{_, _, _, IP4, _}] = R,
    ?equal(lists:sort([?HUB1, ?HUB2]), lists:sort(IP4)),
    ok.

topology_match() ->
    [{doc, "Check that topon node matching find the best combination"}].
topology_match(_Config) ->
    ?match([{{"topon.gngp.pgw.south.epc.mnc990.mcc311.3gppnetwork.org", _, _, _, _},
	     {"topon.gngp.sgw.south.epc.mnc990.mcc311.3gppnetwork.org", _, _, _, _}} | _],
	   ergw_node_selection:topology_match(?L1 ++ ?L2, ?S1)).

colocation_match() ->
    [{doc, "Check that topon node matching find the best combination"}].
colocation_match(_Config) ->
    ?match([{{"topon.gngp.saegw.south.epc.mnc990.mcc311.3gppnetwork.org", _, _, _, _},
	     {"topon.gngp.saegw.south.epc.mnc990.mcc311.3gppnetwork.org", _, _, _, _}} | _],
	   ergw_node_selection:colocation_match(?L1 ++ ?L2 ++ ?L3, ?S1 ++ ?S2)).
