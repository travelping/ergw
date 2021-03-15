%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_proxy_ds_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

-include("ergw_test_lib.hrl").

%%%===================================================================
%%% API
%%%===================================================================

init_per_suite(Config) ->
    ProxyMap = [
	{imsi, [{<<"111111111111111">>, {<<"111111111111111">>, <<"16477141111">>}},
		{<<"222222222222222">>, {<<"333333333333333">>, <<"16477141222">>}} ]},
	{apn, [{[<<"apn1">>], [<<"example1">>, <<"com">>]},
	       {[<<"apn2">>], [<<"example2">>, <<"com">>]}
	      ]}
    ],
    Cfg = [{plmn_id, {<<"001">>, <<"01">>}},
	   {node_id, <<"node">>},
	   {accept_new, true},
	   {proxy_map, ProxyMap},
	   {sockets, []},
	   {handlers, #{}},
	   {ip_pools, #{}},
	   {nodes, #{}}
	  ],
    application:load(ergw_core),
    [application:set_env(ergw_core, K, V) || {K, V} <- Cfg],
    {ok, _} = application:ensure_all_started(riak_core),
    {ok, Pid} = ergw_core:start(maps:from_list(Cfg)),
    gen_server:start({local, gtp_proxy_ds_test}, gtp_proxy_ds, [], []),
    ergw_core:wait_till_ready(),
    [{ergw_core, Pid}|Config].

end_per_suite(Config) ->
    ProxyMap = [],
    Pid = proplists:get_value(ergw_core, Config),
    application:set_env(ergw_core, proxy_map, ProxyMap),
    gen_server:stop(gtp_proxy_ds_test),
    gen_server:stop(Pid),
    application:stop(riak_core),
    ok.


all() ->
    [map].

%%%===================================================================
%%% Tests
%%%===================================================================

%%--------------------------------------------------------------------
map() ->
    [{doc, "Check that gtp_proxy_ds:map/1 works as expected"}].
map(_Config) ->
    ?match({error, {badarg, _}},
	   gen_server:call(gtp_proxy_ds_test, {map, #{}})),

    ProxyInfo0 = #{apn    => [<<"apn0">>],
		   imsi   => <<"000000000000000">>,
		   msisdn => <<"unknown">>,
		   gwSelectionAPN => [<<"apn0">>],
		   upfSelectionAPN => [<<"apn0">>]},
    ?match(#{apn    := [<<"apn0">>],
	     imsi   := <<"000000000000000">>,
	     msisdn := <<"unknown">>},
	   gen_server:call(gtp_proxy_ds_test, {map, ProxyInfo0})),

    ProxyInfo1 = #{apn    => [<<"apn1">>],
		   imsi   => <<"111111111111111">>,
		   msisdn => <<"unknown">>},
    ?match(#{apn    := [<<"example1">>, <<"com">>],
	     imsi   := <<"111111111111111">>,
	     msisdn := <<"16477141111">>},
	   gen_server:call(gtp_proxy_ds_test, {map, ProxyInfo1})),

    ProxyInfo2 = #{apn    => [<<"apn2">>],
		   imsi   => <<"222222222222222">>,
		   msisdn => <<"unknown">>},
    ?match(#{apn    := [<<"example2">>, <<"com">>],
	     imsi   := <<"333333333333333">>,
	     msisdn := <<"16477141222">>},
	   gen_server:call(gtp_proxy_ds_test, {map, ProxyInfo2})),
    ok.
