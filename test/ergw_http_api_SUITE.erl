%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_http_api_SUITE).

-compile(export_all).

-include("ergw_test_lib.hrl").
-include("ergw_ggsn_test_lib.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("common_test/include/ct.hrl").

-define(TEST_CONFIG,
	[
	 {lager, [{colored, true},
		  {error_logger_redirect, false},
		  %% force lager into async logging, otherwise
		  %% the test will timeout randomly
		  {async_threshold, undefined},
		  {handlers, [{lager_console_backend, info}]}
		 ]},

	 {ergw, [{dp_handler, '$meck'},
		 {sockets,
		  [{irx, [{type, 'gtp-c'},
			  {ip,  ?TEST_GSN},
			  {reuseaddr, true}
			 ]},
		   {grx, [{type, 'gtp-u'},
			  {node, 'gtp-u-node@localhost'},
			  {name, 'grx'}]}
		  ]},

		 {vrfs,
		  [{example, [{pools,  [{{10, 180, 0, 1}, {10, 180, 255, 254}, 32},
                                        {{16#8001, 0, 0, 0, 0, 0, 0, 0},
					  {16#8001, 0, 0, 16#FFFF, 0, 0, 0, 0}, 64}
					]},
			       {'MS-Primary-DNS-Server', {8,8,8,8}},
			       {'MS-Secondary-DNS-Server', {8,8,4,4}},
			       {'MS-Primary-NBNS-Server', {127,0,0,1}},
			       {'MS-Secondary-NBNS-Server', {127,0,0,1}}
			      ]}
		  ]},

		 {handlers,
		  [{gn, [{handler, ggsn_gn},
			 {sockets, [irx]},
			 {data_paths, [grx]},
			 {aaa, [{'Username',
				 [{default, ['IMSI',   <<"/">>,
					     'IMEI',   <<"/">>,
					     'MSISDN', <<"/">>,
					     'ATOM',   <<"/">>,
					     "TEXT",   <<"/">>,
					     12345,
					     <<"@">>, 'APN']}]}]}
			]},
		   {gn, [{handler, ggsn_gn},
			 {sockets, ['remote-irx']},
			 {data_paths, ['remote-grx']},
			 {aaa, [{'Username',
				 [{default, ['IMSI', <<"@">>, 'APN']}]}]}
			]}
		  ]},

		 {apns,
		  [{?'APN-EXAMPLE', [{vrf, example}]},
		   {[<<"APN1">>], [{vrf, example}]}
		  ]},
                 {http_api, [{port, 0}]}
		]},
	 {ergw_aaa, [{ergw_aaa_provider, {ergw_aaa_mock, [{shared_secret, <<"MySecret">>}]}}]}
	]).

all() ->
    [http_api_version_req,
     http_api_status_req,
     http_api_status_accept_new_get_req,
     http_api_status_accept_new_post_req,
     http_api_prometheus_metrics_req,
     http_api_prometheus_metrics_sub_req,
     http_api_metrics_req,
     http_api_metrics_sub_req,
     http_api_session_stop,
     http_api_session_info,
     http_api_sessions_list].

init_per_testcase(Config) ->
    meck_reset(Config).
init_per_testcase(http_api_session_stop, Config) ->
    ok = meck:expect(gtp_socket, send_request,
		     fun(GtpPort, DstIP, DstPort, _T3, _N3,
			 #gtp{type = delete_pdp_context_request} = Msg, CbInfo) ->
			     %% reduce timeout to 1 second and 2 resends
			     %% to speed up the test
			     meck:passthrough([GtpPort, DstIP, DstPort, 1000, 2, Msg, CbInfo]);
			(GtpPort, DstIP, DstPort, T3, N3, Msg, CbInfo) ->
			     meck:passthrough([GtpPort, DstIP, DstPort, T3, N3, Msg, CbInfo])
		     end),
    Config;
init_per_testcase(_, Config) ->
    init_per_testcase(Config),
    Config.

end_per_testcase(http_api_session_stop, Config) ->
    ok = meck:delete(gtp_socket, send_request, 7),
    Config;
end_per_testcase(_, Config) ->
    Config.

init_per_suite(Config0) ->
    inets:start(),
    Config1 = [{app_cfg, ?TEST_CONFIG},
              {handler_under_test, ggsn_gn}
	      | Config0],
    Config = lib_init_per_suite(Config1),

    %% fake exometer entries
    DataPointG = [socket, 'gtp-c', irx, pt, v1, gauge_test],
    DataPointH = [socket, 'gtp-c', irx, pt, v1, histogram_test],
    DataPointS = [socket, 'gtp-c', irx, pt, v1, spiral_test],
    DataPointF = [socket, 'gtp-c', irx, pt, v1, function_test],
    DataPointIP4 = [path, irx, {127,0,0,1}, contexts],
    DataPointIP6 = [path, irx, {0,0,0,0,0,0,0,1}, contexts],
    exometer:new(DataPointG, gauge, []),
    exometer:new(DataPointH, histogram, [{time_span, 300 * 1000}]),
    exometer:new(DataPointS, spiral, [{time_span, 300 * 1000}]),
    exometer:new(DataPointF, {function, ?MODULE, exo_function}, []),
    exometer:new(DataPointIP4, gauge, []),
    exometer:new(DataPointIP6, gauge, []),
    lists:foreach(
      fun(_) ->
	      Value = rand:uniform(1000),
	      exometer:update(DataPointG, Value),
	      exometer:update(DataPointH, Value),
	      exometer:update(DataPointS, Value)
      end, lists:seq(1, 100)),

    Config.

end_per_suite(Config) ->
    inets:stop(),
    ok = lib_end_per_suite(Config),
    ok.

http_api_session_info() ->
    [{doc, "Check /session/id/bearer_id API"}].
http_api_session_info(Config) ->
    S = make_gtp_socket(Config),
    {GtpC1, _, _} = create_pdp_context(S),

    URL1 = get_test_url("/api/v1/sessions/111111111111111"),
    {ok, {_, _, Body1}} = httpc:request(get, {URL1, []},
                                        [], [{body_format, binary}]),
    Res1 = jsx:decode(Body1, [return_maps]),
    Session1 = maps:get(<<"Session">>, Res1),
    ?match(#{<<"MSISDN">> := ?MSISDN, <<"IMSI">> := ?IMSI}, Session1),

    URL2 = get_test_url("/api/v1/sessions/111111111111112"),
    {ok, {{_, StatusCode, _}, _, Body2}} = httpc:request(get, {URL2, []},
                                                         [], [{body_format, binary}]),
    ?equal(404, StatusCode),
    Res2 = jsx:decode(Body2, [return_maps]),
    ?match(#{<<"Session">> := []}, Res2),

    delete_pdp_context(S, GtpC1),
    ok = meck:wait(ggsn_gn, terminate, '_', 2000),
    meck_validate(Config),
    ok.

http_api_sessions_list() ->
    [{doc, "Check /session API"}].
http_api_sessions_list(Config) ->
    URL1 = get_test_url("/api/v1/sessions"),
    {ok, {_, _, Body1}} = httpc:request(get, {URL1, []},
                                        [], [{body_format, binary}]),
    Res1 = jsx:decode(Body1, [return_maps]),
    ?match(#{<<"TotalCount">> := 0, <<"Sessions">> := []}, Res1),

    S = make_gtp_socket(Config),
    {GtpC1, _, _} = create_pdp_context(S),
    {GtpC2, _, _} = create_pdp_context(random, S, GtpC1),

    URL2 = get_test_url("/api/v1/sessions"),
    {ok, {_, _, Body2}} = httpc:request(get, {URL2, []},
                                        [], [{body_format, binary}]),
    Res2 = jsx:decode(Body2, [return_maps]),
    ?match(#{<<"TotalCount">> := 2}, Res2),
    lists:foreach(fun (Session) ->
                          ?match(#{<<"MSISDN">> := ?MSISDN,
                                   <<"LocalGTPEntity">> :=
                                       #{<<"GTP-C">> :=
                                             #{<<"IP">> := <<"127.0.0.1">>, <<"Version">> := <<"v1">>},
                                         <<"GTP-U">> :=
                                             #{<<"IP">> := <<"127.0.0.1">>, <<"Version">> := <<"v1">>}},
                                   <<"RemoteGTPEntity">> :=
                                       #{<<"GTP-C">> :=
                                             #{<<"IP">> := <<"127.127.127.127">>, <<"Version">> := <<"v1">>},
                                         <<"GTP-U">> :=
                                             #{<<"IP">> := <<"127.127.127.127">>, <<"Version">> := <<"v1">>}}
                                  }, Session)
                  end, maps:get(<<"Sessions">>, Res1)),
    delete_pdp_context(S, GtpC1),
    delete_pdp_context(S, GtpC2),
    ok = meck:wait(ggsn_gn, terminate, '_', 2000),
    meck_validate(Config),
    ok.

http_api_session_stop() ->
    [{doc, "Check DELETE /session/id/bearer_id"}].
http_api_session_stop(Config) ->
    % Create session and request it
    S = make_gtp_socket(Config),
    {_GtpC1, _, _} = create_pdp_context(S),

    URL1 = get_test_url("/api/v1/sessions"),
    {ok, {_, _, Body1}} = httpc:request(get, {URL1, []},
                                        [], [{body_format, binary}]),
    Res1 = jsx:decode(Body1, [return_maps]),
    ?match(#{<<"TotalCount">> := 1}, Res1),

    % Stop session
    URL2 = get_test_url("/api/v1/sessions/111111111111111/5"),
    {ok, {_, _, Body2}} = httpc:request(delete, {URL2, [], "", []},
                                        [], [{body_format, binary}]),
    Res2 = jsx:decode(Body2, [return_maps]),
    ?match(#{<<"Result">> := <<"ok">>}, Res2),

    % Stop non-existent session
    URL3 = get_test_url("/api/v1/sessions/111111111111112/5"),
    {ok, {{_, StatusCode, _}, _, Body3}} = httpc:request(delete, {URL3, [], "", []},
                                                         [], [{body_format, binary}]),
    ?equal(404, StatusCode),
    Res3 = jsx:decode(Body3, [return_maps]),
    ?match(#{<<"Result">> := <<"Session not found">>}, Res3),

    % Check that session was destroyed after stop
    URL4 = get_test_url("/api/v1/sessions"),
    {ok, {_, _, Body4}} = httpc:request(get, {URL4, []},
                                        [], [{body_format, binary}]),
    Res4 = jsx:decode(Body4, [return_maps]),
    ?match(#{<<"TotalCount">> := 0}, Res4),

    ok = meck:wait(ggsn_gn, terminate, '_', 2000),
    wait4tunnels(2000),
    meck_validate(Config),
    ok.

http_api_version_req() ->
    [{doc, "Check /api/v1/version API"}].
http_api_version_req(_Config) ->
    URL = get_test_url("/api/v1/version"),
    {ok, {_, _, Body}} = httpc:request(get, {URL, []},
				       [], [{body_format, binary}]),
    {ok, Vsn} = application:get_key(ergw, vsn),
    Res = jsx:decode(Body, [return_maps]),
    ?equal(Res, #{<<"version">> => list_to_binary(Vsn)}),
    ok.

http_api_status_req() ->
    [{doc, "Check /api/v1/status API"}].
http_api_status_req(_Config) ->
    SysInfo = maps:from_list(ergw:system_info()),
    URL = get_test_url("/api/v1/status"),
    {ok, {_, _, Body}} = httpc:request(get, {URL, []},
				       [], [{body_format, binary}]),
    Response = jsx:decode(Body, [return_maps]),
    ?equal(maps:get(accept_new, SysInfo), maps:get(<<"acceptNewRequests">>, Response)),
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
    AcceptNew = ergw:system_info(accept_new),
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
    ?equal(ergw:system_info(accept_new), Result1),
    ?equal(false, Result1),

    {ok, {_, _, ReqBody2}} = httpc:request(post, {AcceptURL, [], "application/json", ""},
					   [], [{body_format, binary}]),
    Result2 = maps:get(<<"acceptNewRequests">>, jsx:decode(ReqBody2, [return_maps])),
    ?equal(ergw:system_info(accept_new), Result2),
    ?equal(true, Result2),

    ok.

http_api_prometheus_metrics_req() ->
    [{doc, "Check Prometheus API Endpoint"}].
http_api_prometheus_metrics_req(_Config) ->
    URL = get_test_url("/metrics"),
    Accept = "application/vnd.google.protobuf;proto=io.prometheus.client.MetricFamily;encoding=delimited;q=0.7,"
             ++ "text/plain;version=0.0.4;q=0.3,*/*;q=0.1",
    {ok, {_, _, Body}} = httpc:request(get, {URL, [{"Accept", Accept}]},
				       [], [{body_format, binary}]),
    Lines = binary:split(Body, <<"\n">>, [global]),
    Result =
        lists:filter(fun(<<"socket_gtp_c_irx_tx_v2_mbms_session_start_response_count", _/binary>>) ->
                             true;
                        (_) -> false
                     end, Lines),
    ?equal(1, length(Result)),
    ok.

http_api_prometheus_metrics_sub_req() ->
    [{doc, "Check /metrics/... Prometheus API endpoint"}].
http_api_prometheus_metrics_sub_req(_Config) ->
    Accept = "application/vnd.google.protobuf;proto=io.prometheus.client.MetricFamily;encoding=delimited;q=0.7,"
             ++ "text/plain;version=0.0.4;q=0.3,*/*;q=0.1",
    URL0 = get_test_url("/metrics/socket/gtp-c/irx/tx/v2/mbms_session_start_response"),
    {ok, {_, _, Body}} = httpc:request(get, {URL0, [{"Accept", Accept}]},
				       [], [{body_format, binary}]),
    Lines = binary:split(Body, <<"\n">>, [global]),
    Result =
        lists:filter(fun(<<"socket_gtp_c_irx_tx_v2_mbms_session_start_response_count", _/binary>>) ->
                             true;
                        (_) -> false
                     end, Lines),
    ?equal(1, length(Result)),

    URL1 = get_test_url("/metrics/path/irx/127.0.0.1/contexts"),
    ?match({ok, _}, httpc:request(get, {URL1, [{"Accept", Accept}]},
				  [], [{body_format, binary}])),

    URL2 = get_test_url("/metrics/path/irx/::1/contexts"),
    ?match({ok, _}, httpc:request(get, {URL2, [{"Accept", Accept}]},
				  [], [{body_format, binary}])),

    ok.

http_api_metrics_req() ->
    [{doc, "Check /metrics API"}].
http_api_metrics_req(_Config) ->
    URL = get_test_url("/metrics"),
    {ok, {_, _, Body}} = httpc:request(get, {URL, []},
				       [], [{body_format, binary}]),
    Res = jsx:decode(Body, [return_maps]),
    ?match(#{<<"socket">> := #{}}, Res),
    ok.

http_api_metrics_sub_req() ->
    [{doc, "Check /metrics/... API"}].
http_api_metrics_sub_req(_Config) ->
    URL0 = get_test_url("/metrics/socket/gtp-c/irx/rx"),
    {ok, {_, _, Body0}} = httpc:request(get, {URL0, []},
				       [], [{body_format, binary}]),
    Res0 = jsx:decode(Body0, [return_maps]),
    ?match(#{<<"v1">> := #{}}, Res0),

    URL1 = get_test_url("/metrics/path/irx/127.0.0.1/contexts"),
    {ok, {_, _, Body1}} = httpc:request(get, {URL1, []},
				       [], [{body_format, binary}]),
    Res1 = jsx:decode(Body1, [return_maps]),
    ?match(#{<<"value">> := _}, Res1),

    URL2 = get_test_url("/metrics/path/irx/::1/contexts"),
    {ok, {_, _, Body2}} = httpc:request(get, {URL2, []},
				       [], [{body_format, binary}]),
    Res2 = jsx:decode(Body2, [return_maps]),
    ?match(#{<<"value">> := _}, Res2),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_test_url(Path) ->
    Port = ranch:get_port(ergw_http_listener),
    lists:flatten(io_lib:format("http://localhost:~w~s", [Port, Path])).

exo_function(_) ->
    [{value, rand:uniform(1000)}].
