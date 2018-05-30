-module(dns_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

-include("ergw_test_lib.hrl").

-define(ERGW1, {100, 255, 4, 133}).
-define(ERGW2, {100, 255, 4, 125}).
-define(HUB1,  {100, 255, 5, 46}).
-define(HUB2,  {100, 255, 5, 45}).

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
                     fun("example.apn.epc.mnc001.mcc456.3gppnetwork.org.") -> 
                             % order pref flags service                              regexp
                             [{20,   20,  "a",  "x-3gpp-pgw:x-s5-gtp:x-s8-gtp:x-gn", [], 
                             % replacement
                              "hub.node.epc.mnc001.mcc456.3gppnetwork.org"}];
                        ("example.apn.epc.mnc123.mcc310.3gppnetwork.org.") -> 
                             % order pref flags service                regexp
                             [{100,  100, "s",  "x-3gpp-pgw:x-s8-gtp", [], 
                             % replacement
                              "pgw-list-2.node.epc.mnc123.mcc310.3gppnetwork.org"}];
                        (_) -> []
                     end),
    ok = meck:expect(ergw_dns, srv, 
                     fun("pgw-list-2.node.epc.mnc123.mcc310.3gppnetwork.org") -> 
                             % priority weight port 
                             [{100,     100,   2123, 
                             % target
                              "ergw.ovh.node.epc.mnc123.mcc310.3gppnetwork.org"}];
                        (_) -> []
                     end),
    ok = meck:expect(ergw_dns, a, 
                     fun("hub.node.epc.mnc001.mcc456.3gppnetwork.org" ) -> 
                             [?HUB1, ?HUB2];
                        ("ergw.ovh.node.epc.mnc123.mcc310.3gppnetwork.org") ->
                             [?ERGW1, ?ERGW2];
                        (_) -> []
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
