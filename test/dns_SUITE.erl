-module(dns_SUITE).

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

-define(SRV_q,
	#dns_rec{
	   anlist = [#dns_rr{domain = "example.apn.epc.mnc123.mcc310.3gppnetwork.org",
			     type = naptr,
			     data = % order pref flags service		      regexp
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

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [srv_lookup, a_lookup].

suite() ->
    [{timetrap, {seconds, 30}}].

groups() ->
    [].

init_per_suite(Config) ->
    ok = meck:new(ergw_dns, [passthrough, no_link]),
    ok = meck:expect(ergw_dns, naptr, 
		     fun("example.apn.epc.mnc123.mcc310.3gppnetwork.org.") -> 
			     {ok, ?SRV_q};
			("example.apn.epc.mnc001.mcc456.3gppnetwork.org.") -> 
			     {ok, ?A_q}
		     end),
    Config.

end_per_suite(_Config) ->
    ok = meck:unload(ergw_dns),
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

srv_lookup() ->
    [{doc, "NPTR lookup with following SRV"}].
srv_lookup(_Config) ->
    ?equal([], [?ERGW1, ?ERGW2] -- ergw_dns:lookup("example.apn.epc.mnc123.mcc310.3gppnetwork.org.")),
    ok.

a_lookup() ->
    [{doc, "NPTR lookup with following A"}].
a_lookup(_Config) ->
    ?equal([], [?HUB1, ?HUB2] -- ergw_dns:lookup("example.apn.epc.mnc001.mcc456.3gppnetwork.org.")),
    ok.
