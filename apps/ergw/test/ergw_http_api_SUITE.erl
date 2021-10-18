%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_http_api_SUITE).

-compile(export_all).

-include("smc_test_lib.hrl").
-include("smc_ggsn_test_lib.hrl").
-include_lib("ergw_core/include/ergw.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("common_test/include/ct.hrl").

-define(TIMEOUT, 2000).
-define(HUT, ggsn_gn).

all() ->
    [http_api_version_req,
     http_api_status_req,
     http_api_status_accept_new_get_req,
     http_api_status_accept_new_post_req,
     http_api_prometheus_metrics_req,
     http_api_delete_sessions,
     http_api_delete_all_sessions,
     http_status_k8s
    ].

%%%===================================================================
%%% Tests
%%%===================================================================

setup_per_testcase(Config) ->
    setup_per_testcase(Config, true).

setup_per_testcase(Config, ClearSxHist) ->
    ct:pal("Sockets: ~p", [ergw_socket_reg:all()]),
    ergw_test_sx_up:reset('pgw-u01'),
    meck_reset(Config),
    start_gtpc_server(Config),
    reconnect_all_sx_nodes(),
    ClearSxHist andalso ergw_test_sx_up:history('pgw-u01', true),
    ok.

maybe_end_fail(ok, Fail) ->
    {fail, Fail};
maybe_end_fail(Other, _) ->
    Other.

end_per_testcase(Config) ->
    Result0 = proplists:get_value(tc_status, Config),
    Result1 = case active_contexts() of
		  0 -> Result0;
		  Ctx ->
		      Key = gtp_context:socket_teid_key(#socket{type = 'gtp-c', _ = '_'}, '_'),
		      Contexts = gtp_context_reg:global_select(Key),
		      ct:pal("ContextLeft: ~p", [Contexts]),
		      [ergw_context:test_cmd(gtp, C, kill) || C <- Contexts],
		      wait4contexts(1000),
		      maybe_end_fail(Result0, {contexts_left, Ctx})
	      end,
    stop_gtpc_server(),
    Result1.

init_per_testcase(Config) ->
    meck_reset(Config).

init_per_testcase(TestCase, Config) when TestCase =:= http_api_delete_sessions; TestCase =:= http_api_delete_all_sessions ->
    ct:pal("Sockets: ~p", [ergw_socket_reg:all()]),
    setup_per_testcase(Config),
    ok = meck:expect(?HUT, handle_request,
	fun(Request, Msg, Resent, State, Data) ->
	    if Resent -> ok;
	    true      -> ct:sleep(1000)
	end,
	meck:passthrough([Request, Msg, Resent, State, Data])
    end),
    Config;
init_per_testcase(_, Config) ->
    init_per_testcase(Config),
    Config.

end_per_testcase(TestCase, Config) when TestCase =:= http_api_delete_sessions; TestCase =:= http_api_delete_all_sessions ->
    end_per_testcase(Config),
    Config;
end_per_testcase(_, Config) ->
    Config.

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

    ergw:wait_till_running(),
    inets:start(),

    {ok, _} = ergw_test_sx_up:start('pgw-u01', proplists:get_value(pgw_u01_sx, Config)),
    {ok, _} = ergw_test_sx_up:start('pgw-u02', proplists:get_value(pgw_u02_sx, Config)),
    {ok, _} = ergw_test_sx_up:start('sgw-u', proplists:get_value(sgw_u_sx, Config)),
    {ok, _} = ergw_test_sx_up:start('tdf-u', proplists:get_value(tdf_u_sx, Config)),

    Config.

end_per_suite(Config) ->
    smc_test_lib:meck_unload(Config),
    ok = ergw_test_sx_up:stop('pgw-u01'),
    ok = ergw_test_sx_up:stop('pgw-u02'),
    ok = ergw_test_sx_up:stop('sgw-u'),
    ok = ergw_test_sx_up:stop('tdf-u'),
    ?config(table_owner, Config) ! stop,
    [application:stop(App) || App <- [ergw_core, ergw_aaa, ergw_cluster, ergw]],
    inets:stop(),
    ok.

http_api_version_req() ->
    [{doc, "Check /api/v1/version API"}].
http_api_version_req(_Config) ->
    URL = get_test_url("/api/v1/version"),
    {ok, {_, _, Body}} = httpc:request(get, {URL, []},
				       [], [{body_format, binary}]),
    {ok, Vsn} = application:get_key(ergw_core, vsn),
    Res = jsx:decode(Body, [return_maps]),
    ?equal(Res, #{<<"version">> => list_to_binary(Vsn)}),
    ok.

http_api_status_req() ->
    [{doc, "Check /api/v1/status API"}].
http_api_status_req(_Config) ->
    SysInfo = maps:from_list(ergw_core:system_info()),
    URL = get_test_url("/api/v1/status"),
    {ok, {_, _, Body}} = httpc:request(get, {URL, []},
				       [], [{body_format, binary}]),
    Response = jsx:decode(Body, [return_maps]),
    ?equal(maps:get(accept_new, SysInfo), maps:get(<<"acceptNewRequests">>, Response)),
    ?equal(maps:get(node_id, SysInfo), maps:get(<<"nodeId">>, Response)),
    {Mcc, Mnc} = maps:get(plmn_id, SysInfo),
    PlmnIdFromResponse = maps:get(<<"plmnId">>, Response),
    MccFromResponse = maps:get(<<"mcc">>, PlmnIdFromResponse),
    MncFromResponse = maps:get(<<"mnc">>, PlmnIdFromResponse),
    ?equal(Mcc, MccFromResponse),
    ?equal(Mnc, MncFromResponse),
    ok.

http_api_status_accept_new_get_req() ->
    [{doc, "Check /api/v1/status/accept-new API"}].
http_api_status_accept_new_get_req(_Config) ->
    URL = get_test_url("/api/v1/status/accept-new"),
    {ok, {_, _, Body}} = httpc:request(get, {URL, []},
				       [], [{body_format, binary}]),
    Response = jsx:decode(Body, [return_maps]),
    AcceptNew = ergw_core:system_info(accept_new),
    AcceptNewFromResponse = maps:get(<<"acceptNewRequests">>, Response),
    ?equal(AcceptNew, AcceptNewFromResponse),
    ok.

http_api_status_accept_new_post_req() ->
    [{doc, "Check GGSN /api/v1/status/accept-new/{true,false} API"}].
http_api_status_accept_new_post_req(_Config) ->
    StopURL = get_test_url("/api/v1/status/accept-new/false"),
    AcceptURL = get_test_url("/api/v1/status/accept-new/true"),

    {ok, {_, _, ReqBody1}} = httpc:request(post, {StopURL, [], "application/json", ""},
					   [], [{body_format, binary}]),
    Result1 = maps:get(<<"acceptNewRequests">>, jsx:decode(ReqBody1, [return_maps])),
    ?equal(ergw_core:system_info(accept_new), Result1),
    ?equal(false, Result1),

    {ok, {_, _, ReqBody2}} = httpc:request(post, {AcceptURL, [], "application/json", ""},
					   [], [{body_format, binary}]),
    Result2 = maps:get(<<"acceptNewRequests">>, jsx:decode(ReqBody2, [return_maps])),
    ?equal(ergw_core:system_info(accept_new), Result2),
    ?equal(true, Result2),

    ok.

http_api_prometheus_metrics_req() ->
    [{doc, "Check Prometheus API Endpoint"}].
http_api_prometheus_metrics_req(_Config) ->
    URL = get_test_url("/metrics"),
    Accept = "text/plain;version=0.0.4;q=0.3,*/*;q=0.1",
    {ok, {_, _, Body}} = httpc:request(get, {URL, [{"Accept", Accept}]},
				       [], [{body_format, binary}]),
    Lines = binary:split(Body, <<"\n">>, [global]),
    ct:pal("Lines: ~p", [Lines]),
    Result =
	lists:filter(fun(<<"ergw_local_pool_free", _/binary>>) ->
			     true;
			(_) -> false
		     end, Lines),
    ?equal(2, length(Result)),
    ok.

http_api_delete_sessions() ->
    [{doc, "Check DELETE /contexts/count API"}].
http_api_delete_sessions(Config) ->
    {GtpC0, _, _} = create_pdp_context(Config),
    {GtpC1, _, _} = create_pdp_context(random, GtpC0),
    ContextsCount = length(ergw_api:contexts(all)),
    Res = json_http_request(delete, "/api/v1/contexts/2"),
    ?match(#{<<"contexts">> := ContextsCount}, Res),
    ok = respond_delete_pdp_context_request([GtpC0, GtpC1], whereis(gtpc_client_server)),
    wait4tunnels(?TIMEOUT),
    ?match(0, length(ergw_api:contexts(all))),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),
    meck_validate(Config),
    ok.

http_api_delete_all_sessions() ->
    [{doc, "Check DELETE /contexts API"}].
http_api_delete_all_sessions(Config) ->
    {GtpC0, _, _} = create_pdp_context(Config),
    {GtpC1, _, _} = create_pdp_context(random, GtpC0),
    ContextsCount = length(ergw_api:contexts(all)),
    Res = json_http_request(delete, "/api/v1/contexts"),
    ?match(#{<<"contexts">> := ContextsCount}, Res),
    ok = respond_delete_pdp_context_request([GtpC0, GtpC1], whereis(gtpc_client_server)),
    wait4tunnels(?TIMEOUT),
    ?match(0, length(ergw_api:contexts(all))),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    ?match(0, meck:num_calls(?HUT, handle_request, ['_', '_', true, '_', '_'])),
    meck_validate(Config),
    ok.

http_status_k8s() ->
    [{doc, "Check that /status/ready works"}].
http_status_k8s(_Config) ->
    URL = get_test_url("/status/ready"),
    Accept = "text/plain",
    Response = httpc:request(get, {URL, [{"Accept", Accept}]},
			     [], [{body_format, binary}]),

    ?match({ok, {{_, 200, _}, _, _}}, Response),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_test_url(Path) ->
    Port = ranch:get_port(ergw_http_listener),
    lists:flatten(io_lib:format("http://localhost:~w~s", [Port, Path])).

json_http_request(Method, Path) ->
    URL = get_test_url(Path),
    {ok, {_, _, Body}} = httpc:request(Method, {URL, []},
				       [], [{body_format, binary}]),
    jsx:decode(Body, [return_maps]).

respond_delete_pdp_context_request([], _) ->
    ok;
respond_delete_pdp_context_request([GtpC|T], Cntl) ->
    Request = recv_pdu(Cntl, ?TIMEOUT),
    ?match(#gtp{type = delete_pdp_context_request}, Request),
    Response = make_response(Request, simple, GtpC),
    send_pdu(Cntl, GtpC, Response),
    respond_delete_pdp_context_request(T, Cntl).
