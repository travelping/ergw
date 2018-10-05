%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(proxy_lib_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include("../include/ergw.hrl").
-include("../include/gtp_proxy_ds.hrl").
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
    ok = meck:new(ergw, [passthrough, no_link]),
    ok = meck:expect(ergw, get_plmn_id, fun() -> {<<"001">>, <<"01">>} end),
    Config.

end_per_suite(_Config) ->
    meck:unload(ergw),
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

proxy_lookup() ->
    [{doc, "lookup from config"}].
proxy_lookup(_Config) ->
    State = #{node_selection => [default], context => "TEST"},
    ProxyInfo =
	#proxy_info{
	   imsi = <<"001010000000002">>,
	   msisdn = <<"444444400008502">>,
	   ggsns = undefined
	  },

    ProxyGGSN1 =
	#proxy_ggsn{
	   address =
	       {fqdn, ["web", "apn", "epc", "mnc001", "mcc001", "3gppnetwork", "org"]},
	   context = <<"GRX2">>,
	   dst_apn = [<<"web">>],
	   restrictions = [{v1,false},{v2,true}]},
    Proxy1 = ergw_proxy_lib:select_proxy_gsn(ProxyInfo, ProxyGGSN1, ?SERVICES, State),
    ?match(#proxy_ggsn{node = ?'CP-Node', address = ?'CP-IP'}, Proxy1),

    ProxyGGSN2 =
	#proxy_ggsn{
	   address =
	       {fqdn, ["web", "apn", "epc", "mnc123", "mcc001", "3gppnetwork", "org"]},
	   context = <<"GRX2">>,
	   dst_apn = [<<"web">>],
	   restrictions = [{v1,false},{v2,true}]},
    Proxy2 = ergw_proxy_lib:select_proxy_gsn(ProxyInfo, ProxyGGSN2, ?SERVICES, State),
    ?match(#proxy_ggsn{node = ?'CP-Node', address = ?'CP-IP'}, Proxy2),

    ProxyGGSN3 =
	#proxy_ggsn{
	   address =
	       {fqdn, ["web", "apn", "epc", "mnc123", "mcc001", "example", "org"]},
	   context = <<"GRX2">>,
	   dst_apn = [<<"web">>],
	   restrictions = [{v1,false},{v2,true}]},
    Proxy3 = ergw_proxy_lib:select_proxy_gsn(ProxyInfo, ProxyGGSN3, ?SERVICES, State),
    ?match(#proxy_ggsn{node = ?'CP-Node', address = ?'CP-IP'}, Proxy3),

    ProxyGGSN4 =
	#proxy_ggsn{
	   context = <<"GRX2">>,
	   dst_apn = [<<"web">>],
	   restrictions = [{v1,false},{v2,true}]},
    Proxy4 = ergw_proxy_lib:select_proxy_gsn(ProxyInfo, ProxyGGSN4, ?SERVICES, State),
    ?match(#proxy_ggsn{node = ?'CP-Node', address = ?'CP-IP'}, Proxy4),

    ProxyGGSN5 =
	#proxy_ggsn{
	   context = <<"GRX2">>,
	   dst_apn = [<<"web">>, <<"mnc001">>, <<"mcc001">>, <<"gprs">>],
	   restrictions = [{v1,false},{v2,true}]},
    Proxy5 = ergw_proxy_lib:select_proxy_gsn(ProxyInfo, ProxyGGSN5, ?SERVICES, State),
    ?match(#proxy_ggsn{node = ?'CP-Node', address = ?'CP-IP'}, Proxy5),

    ProxyGGSN6 =
	#proxy_ggsn{
	   context = <<"GRX2">>,
	   dst_apn = [<<"web">>, <<"mnc123">>, <<"mcc001">>, <<"gprs">>],
	   restrictions = [{v1,false},{v2,true}]},
    Proxy6 = ergw_proxy_lib:select_proxy_gsn(ProxyInfo, ProxyGGSN6, ?SERVICES, State),
    ?match(#proxy_ggsn{node = ?'CP-Node', address = ?'CP-IP'}, Proxy6),

    ProxyGGSN7 =
	#proxy_ggsn{
	   context = <<"GRX2">>,
	   dst_apn = [<<"web">>, <<"mnc567">>, <<"mcc001">>, <<"gprs">>],
	   restrictions = [{v1,false},{v2,true}]},
    Proxy7 = (catch ergw_proxy_lib:select_proxy_gsn(ProxyInfo, ProxyGGSN7, ?SERVICES, State)),
    ?match(#ctx_err{level = ?FATAL, reply = system_failure, context = "TEST"}, Proxy7),
    ok.
