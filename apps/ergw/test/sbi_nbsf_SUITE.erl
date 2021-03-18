%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(sbi_nbsf_SUITE).

-compile([export_all, nowarn_export_all]).

-include("smc_test_lib.hrl").
-include("smc_ggsn_test_lib.hrl").
-include_lib("common_test/include/ct.hrl").

-define(HUT, sbi_nbsf_handler).				%% Handler Under Test


%%%===================================================================
%%% API
%%%===================================================================

common() ->
    [nbsf_get].

groups() ->
    [{ipv4, [], common()},
     {ipv6, [], common()}
    ].

all() ->
    [{group, ipv4},
     {group, ipv6}].

suite() ->
    [{timetrap,{seconds,30}}].

init_per_suite(Config0) ->
    inets:start(),
    application:ensure_all_started(gun),
    [{handler_under_test, ?HUT} | Config0].

end_per_suite(_Config) ->
    inets:stop(),
    application:stop(gun),
    ok.

init_per_group(ipv6, Config0) ->
    case smc_test_lib:has_ipv6_test_config() of
	true ->
	    Config1 = [{protocol, ipv6}, {config_file, "ipv6.json"} |Config0],
	    Config = smc_test_lib:group_config(ipv6, Config1),
	    lib_init_per_group(Config);
	_ ->
	    {skip, "IPv6 test IPs not configured"}
    end;
init_per_group(ipv4, Config0) ->
    Config1 = [{protocol, ipv4}, {config_file, "ipv4.json"} |Config0],
    Config = smc_test_lib:group_config(ipv4, Config1),
    lib_init_per_group(Config).

end_per_group(_Group, Config) ->
    lib_end_per_group(Config).

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(_, Config) ->
    ergw_test_sx_up:reset('pgw-u01'),
    meck_reset(Config),
    start_gtpc_server(Config),
    reconnect_all_sx_nodes(),
    ergw_test_sx_up:history('pgw-u01', true),
    Config.

end_per_testcase(_, _Config) ->
    stop_gtpc_server(),
    ok.

nbsf_get() ->
    [{doc, "Check /sbi/nbsf-management/v1/pcfBindings GET API"}].
nbsf_get(Config) ->
    URI = get_test_uri("/sbi/nbsf-management/v1/pcfBindings"),
    Protocol = protocol(Config),
    H2C = h2_connect(Protocol),

    ?match({400, #{cause := <<"UNSUPPORTED_HTTP_VERSION">>}},
	   json_http_request(Protocol, get, URI, [{"ipv4Addr", "127.0.0.1"}])),

    ?match({404, empty}, json_h2_request(H2C, get, URI, [{"ipv4Addr", "127.0.0.1"}])),
    ?match({404, empty}, json_h2_request(H2C, get, URI, [{"ipv6Prefix", "::1/128"}])),

    ?match({400, _}, json_h2_request(H2C, get, URI, [{"dnn", "test"}])),
    ?match({400, _}, json_h2_request(H2C, get, URI, [{"ipv4Addr", "256.0.0.1"}])),
    ?match({400, _}, json_h2_request(H2C, get, URI, [{"ipv4Addr", "::1/128"}])),
    ?match({400, _}, json_h2_request(H2C, get, URI, [{"ipv6Prefix", "127.0.0.1"}])),
    ?match({400, _}, json_h2_request(H2C, get, URI, [{"ipv6Prefix", "::1"}])),

    {GtpC1, _, _} = create_pdp_context(ipv4, Config),
    Qs1 = get_test_qs(ipv4, GtpC1),
    ?match({200, #{'ipv4Addr' := _}}, json_h2_request(H2C, get, URI, Qs1)),

    ?match({200, _}, json_h2_request(H2C, get, URI, [{"dnn", "example.net"}|Qs1])),
    ?match({404, empty}, json_h2_request(H2C, get, URI, [{"dnn", "eXample.net"}|Qs1])),

    ?match({200, _}, json_h2_request(H2C, get, URI, [{"ipDomain", "sgi"}|Qs1])),
    ?match({404, empty}, json_h2_request(H2C, get, URI, [{"ipDomain", "SGI"}|Qs1])),

    S1 = jsx:encode(#{sst => 1, sd => 16#ffffff}),
    ?match({200, _}, json_h2_request(H2C, get, URI, [{"snssai", S1}|Qs1])),
    S2 = jsx:encode(#{sst => 0, sd => 16#ffffff}),
    ?match({404, empty}, json_h2_request(H2C, get, URI, [{"snssai", S2}|Qs1])),
    S3 = jsx:encode(#{sst => <<"test">>, sd => 16#ffffff}),
    ?match({400, _}, json_h2_request(H2C, get, URI, [{"snssai", S3}|Qs1])),

    delete_pdp_context(GtpC1),

    {GtpC2, _, _} = create_pdp_context(ipv6, Config),
    ?match({200, #{'ipv6Prefix' := _}},
	    json_h2_request(H2C, get, URI, get_test_qs(ipv6, GtpC2))),
    delete_pdp_context(GtpC2),

    {GtpC3, _, _} = create_pdp_context(ipv4v6, Config),
    ?match({200, #{'ipv4Addr' := _, 'ipv6Prefix' := _}},
	   json_h2_request(H2C, get, URI, get_test_qs(ipv4, GtpC3))),
    ?match({200, #{'ipv4Addr' := _, 'ipv6Prefix' := _}},
	   json_h2_request(H2C, get, URI, get_test_qs(ipv6, GtpC3))),
    delete_pdp_context(GtpC3),

    gun:close(H2C),

    ?equal([], outstanding_requests()),
    meck_validate(Config),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

protocol(Config) ->
    case ?config(protocol, Config) of
	ipv6 -> inet6;
	_    -> inet
    end.

get_test_qs(ipv6, #gtpc{ue_ip = {_, {IP, _}}}) ->
    [{"ipv6Prefix", inet:ntoa(ergw_inet:bin2ip(IP)) ++ "/128"}];
get_test_qs(ipv4, #gtpc{ue_ip = {{IP, _}, _}}) ->
    [{"ipv4Addr", inet:ntoa(ergw_inet:bin2ip(IP))}].

get_test_uri(Path) ->
    Port = ranch:get_port(ergw_http_listener),
    #{scheme => "http",
      host   => "localhost",
      port   => Port,
      path   => Path}.

json_http_request(Protocol, Method, URI, Query) ->
    URL = uri_string:recompose(URI#{query => uri_string:compose_query(Query)}),
    Headers = [{"accept", "application/json, application/problem+json"}],
    Request = {URL, Headers},
    httpc:set_options([{ipfamily, Protocol}]),
    {ok, {{_, Code, _}, _, Body}} =
	httpc:request(Method, Request, [],  [{body_format, binary}]),
    JSON = case Body of
	       <<>> -> empty;
	       _    -> jsx:decode(Body, [return_maps, {labels, attempt_atom}])
	   end,
    {Code, JSON}.

h2_connect(Protocol) ->
    Port = ranch:get_port(ergw_http_listener),
    Opts = #{protocols => [http2], transport => tcp, tcp_opts => [Protocol]},
    {ok, Pid} = gun:open("localhost", Port, Opts),
    {ok, _Protocol} = gun:await_up(Pid),
    Pid.

json_h2_request(H2C, Method, #{path := Path}, Query) ->
    URL = uri_string:recompose(#{path => Path, query => uri_string:compose_query(Query)}),
    ct:pal("URL: ~p", [URL]),
    Headers = [{<<"accept">>, <<"application/json, application/problem+json">>}],
    StreamRef = gun:Method(H2C, URL, Headers),
    case gun:await(H2C, StreamRef) of
	{response, fin, Code, _Headers} ->
	    {Code, empty};
	{response, nofin, Code, _Headers} ->
	    {data, fin, Body} = gun:await(H2C, StreamRef),
	    JSON = case Body of
		       <<>> -> empty;
		       _    -> jsx:decode(Body, [return_maps, {labels, attempt_atom}])
		   end,
	    {Code, JSON}
    end.
