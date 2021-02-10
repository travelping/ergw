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
    ProxyMap =
	#{imsi => #{<<"111111111111111">> =>
			#{imsi => <<"111111111111111">>, msisdn => <<"16477141111">>},
		    <<"222222222222222">> =>
			#{imsi => <<"333333333333333">>, msisdn => <<"16477141222">>}},
	  apn => #{[<<"apn1">>] => [<<"example1">>, <<"com">>],
		   [<<"apn2">>] => [<<"example2">>, <<"com">>]}},
    Cfg = #{node_id => <<"PROXY">>,
	    plmn_id => #{mcc => <<"001">>, mnc => <<"01">>},
	    accept_new => true,
	    cluster =>
		#{enabled => false,
		  initial_timeout => 60000,
		  release_cursor_every => 0,
		  seed_nodes => {erlang,nodes,[known]}},
	    proxy_map => ProxyMap,
	    sockets => #{},
	    handlers => #{},
	    ip_pools => #{},
	    nodes => #{entries => #{}},
	    http_api => #{enabled => false}},
    application:load(ergw),
    ergw_test_lib:clear_app_env(ergw),
    maps:foreach(fun(K, V) -> application:set_env(ergw, K, V) end, Cfg),
    {ok, _} = application:ensure_all_started(riak_core),
    {ok, _} = application:ensure_all_started(ra),
    ergw_config:config_meta(),
    {ok, Pid} = ergw:start(Cfg),
    gen_server:start({local, gtp_proxy_ds_test}, gtp_proxy_ds, [], []),
    ergw:wait_till_ready(),
    [{ergw, Pid}|Config].

end_per_suite(Config) ->
    ProxyMap = [],
    Pid = proplists:get_value(ergw, Config),
    application:set_env(ergw, proxy_map, ProxyMap),
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
