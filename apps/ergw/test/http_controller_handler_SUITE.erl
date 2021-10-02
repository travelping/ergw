%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(http_controller_handler_SUITE).

-compile(export_all).

-include("smc_test_lib.hrl").
-include("smc_ggsn_test_lib.hrl").
-include_lib("ergw_core/include/ergw.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("common_test/include/ct.hrl").

-define(HUT, ggsn_gn).

all() ->
    [http_controller_handler_post_ip_pools,
     http_controller_handler_post_ip_pools_invalid,
     http_controller_handler_post_apns,
     http_controller_handler_post_apns_invalid,
     http_controller_handler_post_upf_nodes,
     http_controller_handler_post_upf_nodes_invalid,
     http_controller_handler_post_invalid_json,
     http_controller_handler_check_http2_support].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_suite(Config0) ->
    Config1 = smc_test_lib:init_ets(Config0),
    Config2 = [{handler_under_test, ?HUT}|Config1],
    Config = smc_test_lib:group_config(ipv4, Config2),

    [application:load(App) || App <- [cowboy, ergw_core, ergw_aaa]],
    smc_test_lib:meck_init(Config),

    Dir  = ?config(data_dir, Config),
    application:load(ergw),
    CfgSet = #{type => json, file => filename:join(Dir, "ggsn.json")},
    application:set_env(ergw, config, CfgSet),
    {ok, Started} = application:ensure_all_started(ergw),
    ct:pal("Started: ~p", [Started]),

    %ergw:wait_till_running(), %% @TODO ...
    inets:start(),

    {ok, JsonBin} = file:read_file(filename:join(Dir, "post_test_data.json")),
    TestsPostData = {test_post_data, jsx:decode(JsonBin)},

    [TestsPostData|Config].

end_per_suite(Config) ->
    smc_test_lib:meck_unload(Config),
    ?config(table_owner, Config) ! stop,
    [application:stop(App) || App <- [ergw_core, ergw_aaa, ergw_cluster, ergw]],
    inets:stop(),
    ok.

http_controller_handler_post_ip_pools() ->
    [{doc, "Check /api/v1/controller success POST API ip_pools"}].
http_controller_handler_post_ip_pools(Config) ->
    Body = prepare_json_body(<<"ip_pools">>, Config),
    Resp = gun_post(Body),
    ct:pal("Request~p~nResponse ~p~n", [Body, Resp]),
    ?match(#{status := 200}, Resp).

http_controller_handler_post_ip_pools_invalid() ->
    [{doc, "Check /api/v1/controller invalid POST API ip_pools"}].
http_controller_handler_post_ip_pools_invalid(_Config) ->
    Body = <<"{\"ip_pools\": \"test\"}">>,
    Resp = gun_post(Body),
    ct:pal("Request~p~nResponse ~p~n", [Body, Resp]),
    #{headers := Headers} = Resp,
    ?match(<<"application/problem+json">>, proplists:get_value(<<"content-type">>, Headers)),
    ?match(#{status := 400}, Resp).

http_controller_handler_post_apns() ->
    [{doc, "Check /api/v1/controller success POST API apns"}].
http_controller_handler_post_apns(Config) ->
    Body = prepare_json_body(<<"apns">>, Config),
    Resp = gun_post(Body),
    ct:pal("Request~p~nResponse ~p~n", [Body, Resp]),
    ?match(#{status := 200}, Resp).

http_controller_handler_post_apns_invalid() ->
    [{doc, "Check /api/v1/controller invalid POST API apns"}].
http_controller_handler_post_apns_invalid(_Config) ->
    Body = <<"{\"apns\": \"test\"}">>,
    Resp = gun_post(Body),
    #{headers := Headers} = Resp,
    ?match(<<"application/problem+json">>, proplists:get_value(<<"content-type">>, Headers)),
    ct:pal("Request~p~nResponse ~p~n", [Body, Resp]),
    ?match(#{status := 400}, Resp).

http_controller_handler_post_upf_nodes() ->
    [{doc, "Check /api/v1/controller success POST API UPF nodes"}].
http_controller_handler_post_upf_nodes(Config) ->
    Body = prepare_json_body(<<"upf_nodes">>, Config),
    Resp = gun_post(Body),
    ct:pal("Request~p~nResponse ~p~n", [Body, Resp]),
    ?match(#{status := 200}, Resp).

http_controller_handler_post_upf_nodes_invalid() ->
    [{doc, "Check /api/v1/controller invalid POST API UPF nodes"}].
http_controller_handler_post_upf_nodes_invalid(_Config) ->
    Body = <<"{\"upf_nodes\": \"test\"}">>,
    Resp = gun_post(Body),
    #{headers := Headers} = Resp,
    ?match(<<"application/problem+json">>, proplists:get_value(<<"content-type">>, Headers)),
    ct:pal("Request~p~nResponse ~p~n", [Body, Resp]),
    ?match(#{status := 400}, Resp).

http_controller_handler_post_invalid_json() ->
    [{doc, "Check /api/v1/controller invalid POST API"}].
http_controller_handler_post_invalid_json(_Config) ->
    Body = <<"text">>,
    Resp = gun_post(Body),
    #{headers := Headers} = Resp,
    ?match(<<"application/problem+json">>, proplists:get_value(<<"content-type">>, Headers)),
    ct:pal("Request~p~nResponse ~p~n", [Body, Resp]),
    ?match(#{status := 400}, Resp).

http_controller_handler_check_http2_support() ->
    [{doc, "Check /api/v1/controller that the POST API is supported HTTP/2 only"}].
http_controller_handler_check_http2_support(Config) ->
    URL = get_test_url(),
    ContentType = "application/json",
    Body = prepare_json_body(<<"ip_pools">>, Config),
    Resp = httpc:request(post, {URL, [], ContentType, Body}, [], []),
    ct:pal("Request~p~nResponse ~p~n", [Body, Resp]),
    ?match({ok, {{_, 505, _}, _, _}}, Resp).

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_test_url() ->
    Port = ranch:get_port(ergw_http_listener),
    Path = "/api/v1/controller",
    lists:flatten(io_lib:format("http://localhost:~w~s", [Port, Path])).

prepare_json_body(Name, Config) ->
    #{Name := Data} = proplists:get_value(test_post_data, Config),
    jsx:encode(#{Name => Data}).

gun_post(Body) ->
    Pid = gun_http2(),
    Headers = [{<<"content-type">>, <<"application/json">>}],
    StreamRef = gun:post(Pid, <<"/api/v1/controller">>, Headers, Body),
    Resp = gun_reponse(#{pid => Pid, stream_ref => StreamRef, acc => <<>>}),
    ok = gun:close(Pid),
    maps:without([pid, stream_ref], Resp).

gun_http2() ->
    Port = ranch:get_port(ergw_http_listener),
    Opts = #{http2_opts => #{keepalive => infinity}, protocols => [http2]},
    {ok, Pid} = gun:open("localhost", Port, Opts),
    {ok, http2} = gun:await_up(Pid),
    Pid.

gun_reponse(#{pid := Pid, stream_ref := StreamRef, acc := Acc} = Opts) ->
    case gun:await(Pid, StreamRef) of
        {response, fin, Status, Headers} ->
            Opts#{status => Status, headers => Headers};
        {response, nofin, Status, Headers} ->
            gun_reponse(Opts#{status => Status, headers => Headers});
        {data, nofin, Data} ->
            gun_reponse(Opts#{acc => <<Acc/binary, Data/binary>>});
        {data, fin, Data} ->
            Opts#{acc => <<Acc/binary, Data/binary>>};
        {error, timeout} = Response ->
            Response;
        {error, _Reason} = Response ->
            Response
    end.
