%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(proxy_lib_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").

-define('CP-Node', "topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org").
-define('SX-Node', "topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org").
-define('CP-IP', {172,20,21,91}).
-define('SX-IP', {172,20,16,91}).

-define(SERVICES, [{"x-3gpp-pgw", "x-s8-gtp"},
		   {"x-3gpp-pgw", "x-s5-gtp"},
		   {"x-3gpp-pgw", "x-gp"},
		   {"x-3gpp-pgw", "x-gn"}]).


-define(ERGW_NODE_SELECTION,
	#{default =>
	      {static,
	       [
		%% APN NAPTR alternative
		{"web.apn.epc.mnc001.mcc001.3gppnetwork.org", {0,0},
		 [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
		  {"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
		 ?'CP-Node'},
		{"web.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
		 [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
		  {"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
		 ?'CP-Node'},
		{"web.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
		 [{"x-3gpp-upf","x-sxa"}],
		 ?'SX-Node'},

		%% A/AAAA record alternatives
		{"web.apn.epc.mnc123.mcc001.3gppnetwork.org", {300,64536},
		 [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
		  {"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
		 ?'CP-Node'},
		{"web.apn.epc.mnc123.mcc001.3gppnetwork.org", {300,64536},
		 [{"x-3gpp-upf","x-sxa"}],
		 ?'SX-Node'},

		%% A/AAAA record alternatives
		{"web.apn.epc.mnc123.mcc001.example.org", {300,64536},
		 [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
		  {"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
		 ?'CP-Node'},
		{"web.apn.epc.mnc123.mcc001.example.org", {300,64536},
		 [{"x-3gpp-upf","x-sxa"}],
		 ?'SX-Node'},

		{?'CP-Node',  [?'CP-IP'], []},
		{?'SX-Node', [?'SX-IP'], []}
	       ]
	      }
	 }
       ).

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [proxy_lookup].

suite() ->
    [{timetrap, {seconds, 30}}].

groups() ->
    [].

init_per_suite(Config) ->
    application:load(ergw),
    application:set_env(ergw, node_selection, ?ERGW_NODE_SELECTION),
    {ok, Pid} = ergw_inet_res:start(),
    ok = meck:new(ergw, [passthrough, no_link]),
    ok = meck:expect(ergw, get_plmn_id, fun() -> {<<"001">>, <<"01">>} end),
    [{cache_server, Pid} | Config].

end_per_suite(Config) ->
    meck:unload(ergw),
    Pid = proplists:get_value(cache_server, Config),
    exit(Pid, kill),
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

proxy_lookup() ->
    [{doc, "lookup from config"}].
proxy_lookup(_Config) ->
    NodeSelect = [default],
    Socket = #socket{name = <<"TEST">>},
    PI =
	#{imsi    => <<"001010000000002">>,
	  msisdn  => <<"444444400008502">>,
	  apn     => apn(<<"web">>),
	  context => <<"GRX2">>
	 },

	gtp_path_reg:start_link(),
    PI1 =
	PI#{gwSelectionAPN => apn(<<"web.apn.epc.mnc001.mcc001.3gppnetwork.org">>)},
    {ok, Proxy1} = ergw_proxy_lib:select_gw(PI1, v1, ?SERVICES, NodeSelect, Socket),
    ?match({?'CP-Node', ?'CP-IP'}, Proxy1),

    PI2 =
	PI#{gwSelectionAPN => apn(<<"web.apn.epc.mnc123.mcc001.3gppnetwork.org">>)},
    {ok, Proxy2} = ergw_proxy_lib:select_gw(PI2, v1, ?SERVICES, NodeSelect, Socket),
    ?match({?'CP-Node', ?'CP-IP'}, Proxy2),

    PI4 = PI#{gwSelectionAPN => apn(<<"web">>)},
    {ok, Proxy4} = ergw_proxy_lib:select_gw(PI4, v1, ?SERVICES, NodeSelect, Socket),
    ?match({?'CP-Node', ?'CP-IP'}, Proxy4),

    PI5 = PI#{gwSelectionAPN => apn(<<"web.mnc001.mcc001.gprs">>)},
    {ok, Proxy5} = ergw_proxy_lib:select_gw(PI5, v1, ?SERVICES, NodeSelect, Socket),
    ?match({?'CP-Node', ?'CP-IP'}, Proxy5),

    PI6 = PI#{gwSelectionAPN => apn(<<"web.mnc123.mcc001.gprs">>)},
    {ok, Proxy6} = ergw_proxy_lib:select_gw(PI6, v1, ?SERVICES, NodeSelect, Socket),
    ?match({?'CP-Node', ?'CP-IP'}, Proxy6),

    PI7 = PI#{gwSelectionAPN => apn(<<"web.mnc567.mcc001.gprs">>)},
    {error, Proxy7} = ergw_proxy_lib:select_gw(PI7, v1, ?SERVICES, NodeSelect, Socket),
    ?match(#ctx_err{level = ?FATAL, reply = system_failure}, Proxy7),

    PI8 = PI#{gwSelectionAPN => apn(<<"web.apn.epc.mnc001.mcc001.3gppnetwork.org">>)},
    ok = gtp_path_reg:register({<<"TEST">>, v1, ?'CP-IP'}, down),
    {error, Proxy8} = ergw_proxy_lib:select_gw(PI8, v1, ?SERVICES, NodeSelect, Socket),
    ?match(#ctx_err{level = ?FATAL, reply = no_resources_available}, Proxy8),
    ok.

apn(Bin) ->
    binary:split(Bin, <<".">>, [global, trim_all]).
