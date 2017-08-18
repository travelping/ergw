%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_proxy_ds_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

-include("../include/gtp_proxy_ds.hrl").
-include("ergw_test_lib.hrl").

%%%===================================================================
%%% API
%%%===================================================================

init_per_suite(Config) ->
    ProxyMap = [
        {imsi, [{<<"111111111111111">>, {<<"111111111111111">>, <<"16477141111">>}}, 
                {<<"222222222222222">>, {<<"333333333333333">>, <<"16477141222">>}} ]}, 
        {apn, [{[<<"apn1">>], [<<"example1">>, <<"com">>]},
               {[<<"apn2">>], [<<"example2">>, <<"com">>]} ]}
    ],
    application:set_env(ergw, proxy_map, ProxyMap),
    gen_server:start({local, gtp_proxy_ds_test}, gtp_proxy_ds, [], []),
    Config.

end_per_suite(_Config) ->
    ProxyMap = [],
    application:set_env(ergw, proxy_map, ProxyMap),
    gen_server:stop(gtp_proxy_ds_test),
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
    ?equal({ok, #proxy_info{}}, 
           gen_server:call(gtp_proxy_ds_test, {map, #proxy_info{}})),

    ProxyInfo0 = #proxy_info{apn = [<<"apn0">>], 
                             imsi = <<"000000000000000">>, 
                             msisdn = <<"unknown">>},
    ?match({ok, ProxyInfo0}, gen_server:call(gtp_proxy_ds_test, {map, ProxyInfo0})),

    ProxyInfo1 = #proxy_info{apn = [<<"apn1">>], 
                             imsi = <<"111111111111111">>, 
                             msisdn = <<"unknown">>},
    ?match({ok, #proxy_info{apn = [<<"example1">>, <<"com">>], 
                            imsi = <<"111111111111111">>, 
                            msisdn = <<"16477141111">>}}, 
           gen_server:call(gtp_proxy_ds_test, {map, ProxyInfo1})),

    ProxyInfo2 = #proxy_info{apn = [<<"apn2">>], 
                             imsi = <<"222222222222222">>, 
                             msisdn = <<"unknown">>},
    ?match({ok, #proxy_info{apn = [<<"example2">>, <<"com">>], 
                            imsi = <<"333333333333333">>, 
                            msisdn = <<"16477141222">>}}, 
           gen_server:call(gtp_proxy_ds_test, {map, ProxyInfo2})),

    ok.
