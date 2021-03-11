%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(sbi_nbsf_SUITE).

-compile([export_all, nowarn_export_all]).

-include("ergw_test_lib.hrl").
-include("ergw_pgw_test_lib.hrl").
-include_lib("common_test/include/ct.hrl").

-define(HUT, sbi_nbsf_handler).				%% Handler Under Test

%%%===================================================================
%%% Config
%%%===================================================================

-define(TEST_CONFIG,
	[
	 {kernel,
	  [{logger,
	    [%% force cth_log to async mode, never block the tests
	     {handler, cth_log_redirect, cth_log_redirect,
	      #{config =>
		    #{sync_mode_qlen => 10000,
		      drop_mode_qlen => 10000,
		      flush_qlen     => 10000}
	       }
	     }
	    ]}
	  ]},

	 {ergw_core, [{'$setup_vars',
		  [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},

		 {node_id, <<"PGW">>},
		 {http_api, [{port, 0}]},

		 {sockets,
		  [{'cp-socket',
			[{type, 'gtp-u'},
			 {vrf, cp},
			 {ip, ?MUST_BE_UPDATED},
			 {reuseaddr, true}
			]},
		   {'irx-socket',
			 [{type, 'gtp-c'},
			  {vrf, irx},
			  {ip, ?MUST_BE_UPDATED},
			  {reuseaddr, true}
			 ]},

		   {sx, [{type, 'pfcp'},
			 {socket, 'cp-socket'},
			 {ip, ?MUST_BE_UPDATED},
			 {reuseaddr, true}
			]}
		  ]},

		 {ip_pools,
		  [{'pool-A', [{ranges,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
					  {?IPv6PoolStart, ?IPv6PoolEnd, 64},
					  {?IPv6HostPoolStart, ?IPv6HostPoolEnd, 128}]},
			       {'MS-Primary-DNS-Server', {8,8,8,8}},
			       {'MS-Secondary-DNS-Server', {8,8,4,4}},
			       {'MS-Primary-NBNS-Server', {127,0,0,1}},
			       {'MS-Secondary-NBNS-Server', {127,0,0,1}},
			       {'DNS-Server-IPv6-Address',
				[{16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8888},
				 {16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8844}]}
			      ]},
		   {'pool-B', [{ranges,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
					  {?IPv6PoolStart, ?IPv6PoolEnd, 64},
					  {?IPv6HostPoolStart, ?IPv6HostPoolEnd, 128}]},
			       {'MS-Primary-DNS-Server', {8,8,8,8}},
			       {'MS-Secondary-DNS-Server', {8,8,4,4}},
			       {'MS-Primary-NBNS-Server', {127,0,0,1}},
			       {'MS-Secondary-NBNS-Server', {127,0,0,1}},
			       {'DNS-Server-IPv6-Address',
				[{16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8888},
				 {16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8844}]}
			      ]},
		   {'pool-C', [{ranges,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
					  {?IPv6PoolStart, ?IPv6PoolEnd, 64},
					  {?IPv6HostPoolStart, ?IPv6HostPoolEnd, 128}]},
			       {'MS-Primary-DNS-Server', {8,8,8,8}},
			       {'MS-Secondary-DNS-Server', {8,8,4,4}},
			       {'MS-Primary-NBNS-Server', {127,0,0,1}},
			       {'MS-Secondary-NBNS-Server', {127,0,0,1}},
			       {'DNS-Server-IPv6-Address',
				[{16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8888},
				 {16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8844}]}
			      ]}
		  ]},

		 {handlers,
		  [{gn, [{handler, pgw_s5s8},
			 {sockets, ['irx-socket']},
			 {node_selection, [default]},
			 {aaa, [{'Username',
				 [{default, ['IMSI',   <<"/">>,
					     'IMEI',   <<"/">>,
					     'MSISDN', <<"/">>,
					     'ATOM',   <<"/">>,
					     "TEXT",   <<"/">>,
					     12345,
					     <<"@">>, 'APN']}]}]}
			]},
		   {s5s8, [{handler, pgw_s5s8},
			   {sockets, ['irx-socket']},
			   {node_selection, [default]},
			   {aaa, [{'Username',
				   [{default, ['IMSI',   <<"/">>,
					       'IMEI',   <<"/">>,
					       'MSISDN', <<"/">>,
					       'ATOM',   <<"/">>,
					       "TEXT",   <<"/">>,
					       12345,
					       <<"@">>, 'APN']}]}]}
			  ]}
		  ]},

		 {node_selection,
		  [{default,
		    {static,
		     [
		      %% APN NAPTR alternative
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
			{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
		       "topon.s5s8.pgw.$ORIGIN"},
		      {"_default.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.prox01.$ORIGIN"},
		      {"_default.apn.$ORIGIN", {400,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.prox03.$ORIGIN"},
		      {"async-sx.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.prox01.$ORIGIN"},
		      {"async-sx.apn.$ORIGIN", {300,64536},
		       [{"x-3gpp-upf","x-sxb"}],
		       "topon.sx.prox02.$ORIGIN"},

		      %% A/AAAA record alternatives
		      {"topon.s5s8.pgw.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.prox01.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.prox02.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.prox03.$ORIGIN", ?MUST_BE_UPDATED, []}
		     ]
		    }
		   }
		  ]
		 },

		 {apns,
		  [{?'APN-EXAMPLE',
		    [{vrf, sgi},
		     {ip_pools, ['pool-A', 'pool-B']}]},
		   {[<<"exa">>, <<"mple">>, <<"net">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]},
		   {[<<"APN1">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]},
		   {[<<"APN2">>, <<"mnc001">>, <<"mcc001">>, <<"gprs">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]},
		   {[<<"async-sx">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]}
		   %% {'_', [{vrf, wildcard}]}
		  ]},

		 {charging,
		  [{default,
		    [{offline,
		      [{triggers,
			[{'cgi-sai-change',            'container'},
			 {'ecgi-change',               'container'},
			 {'max-cond-change',           'cdr'},
			 {'ms-time-zone-change',       'cdr'},
			 {'qos-change',                'container'},
			 {'rai-change',                'container'},
			 {'rat-change',                'cdr'},
			 {'sgsn-sgw-change',           'cdr'},
			 {'sgsn-sgw-plmn-id-change',   'cdr'},
			 {'tai-change',                'container'},
			 {'tariff-switch-change',      'container'},
			 {'user-location-info-change', 'container'}
			]}
		      ]},
		     {rulebase,
		      [{<<"r-0001">>,
			#{'Rating-Group' => [3000],
			  'Flow-Information' =>
			      [#{'Flow-Description' => [<<"permit out ip from any to assigned">>],
				 'Flow-Direction'   => [1]    %% DownLink
				},
			       #{'Flow-Description' => [<<"permit out ip from any to assigned">>],
				 'Flow-Direction'   => [2]    %% UpLink
				}],
			  'Metering-Method'  => [1],
			  'Precedence' => [100],
			  'Offline'  => [1]
			 }},
		       {<<"r-0002">>,
			#{'Rating-Group' => [4000],
			  'Flow-Information' =>
			      [#{'Flow-Description' => [<<"permit out ip from any to assigned">>],
				 'Flow-Direction'   => [1]    %% DownLink
				},
			       #{'Flow-Description' => [<<"permit out ip from any to assigned">>],
				 'Flow-Direction'   => [2]    %% UpLink
				}],
			  'Metering-Method'  => [1],
			  'Precedence' => [100],
			  'Offline'  => [1]
			 }},
		       {<<"m2m0001">>, [<<"r-0001">>]},
		       {<<"m2m0002">>, [<<"r-0002">>]}
		      ]}
		     ]}
		  ]},

		 {nodes,
		  [{default,
		    [{vrfs,
		      [{cp, [{features, ['CP-Function']}]},
		       {irx, [{features, ['Access']}]},
		       {sgi, [{features, ['SGi-LAN']}]}
		      ]},
		     {ip_pools, ['pool-A']}]
		   },
		   {"topon.sx.prox01.$ORIGIN", [connect]},
		   {"topon.sx.prox03.$ORIGIN", [connect, {ip_pools, ['pool-B', 'pool-C']}]}
		  ]
		 }
		]},

	 {ergw_aaa,
	  [
	   {handlers,
	    [{ergw_aaa_static,
	      [{'NAS-Identifier',          <<"NAS-Identifier">>},
	       {'Node-Id',                 <<"PGW-001">>},
	       {'Charging-Rule-Base-Name', <<"m2m0001">>},
	       {'Acct-Interim-Interval',  600}
	      ]}
	    ]},
	   {services,
	    [{'Default',
	      [{handler, 'ergw_aaa_static'},
	       {answers,
		#{'Initial-Gx' =>
		      #{'Result-Code' => 2001,
			'Charging-Rule-Install' =>
			    [#{'Charging-Rule-Base-Name' => [<<"m2m0001">>]}]
		       },
		  'Update-Gx' => #{'Result-Code' => 2001},
		  'Final-Gx' => #{'Result-Code' => 2001}
		 }
	       }
	      ]}
	    ]},
	   {apps,
	    [{default,
	      [{session, ['Default']},
	       {procedures, [{authenticate, []},
			     {authorize, []},
			     {start, []},
			     {interim, []},
			     {stop, []},
			     {{gx, 'CCR-Initial'},   [{'Default', [{answer, 'Initial-Gx'}]}]},
			     {{gx, 'CCR-Update'},    [{'Default', [{answer, 'Update-Gx'}]}]},
			     {{gx, 'CCR-Terminate'}, [{'Default', [{answer, 'Final-Gx'}]}]},
			     {{gy, 'CCR-Initial'},   []},
			     {{gy, 'CCR-Update'},    []},
			     %%{{gy, 'CCR-Update'},    [{'Default', [{answer, 'Update-If-Down'}]}]},
			     {{gy, 'CCR-Terminate'}, []}
			    ]}
	      ]}
	    ]}
	  ]}
	]).

-define(CONFIG_UPDATE,
	[{[http_api, ip], localhost},
	 {[sockets, 'cp-socket', ip], localhost},
	 {[sockets, 'irx-socket', ip], test_gsn},
	 {[sockets, sx, ip], localhost},
	 {[node_selection, {default, 2}, 2, "topon.s5s8.pgw.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox01.$ORIGIN"],
	  {fun node_sel_update/2, pgw_u01_sx}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox02.$ORIGIN"],
	  {fun node_sel_update/2, sgw_u_sx}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox03.$ORIGIN"],
	  {fun node_sel_update/2, pgw_u02_sx}}
	]).

node_sel_update(Node, {_,_,_,_} = IP) ->
    {Node, [IP], []};
node_sel_update(Node, {_,_,_,_,_,_,_,_} = IP) ->
    {Node, [], [IP]}.

%%%===================================================================
%%% Setup
%%%===================================================================

suite() ->
    [{timetrap,{seconds,30}}].

init_per_suite(Config0) ->
    [{handler_under_test, ?HUT},
     {app_cfg, ?TEST_CONFIG} | Config0].

end_per_suite(_Config) ->
    ok.

init_per_group(ipv6, Config0) ->
    case ergw_test_lib:has_ipv6_test_config() of
	true ->
	    Config1 = [{protocol, ipv6}|Config0],
	    Config = update_app_config(ipv6, ?CONFIG_UPDATE, Config1),
	    inets:start(),
	    application:ensure_all_started(gun),
	    lib_init_per_group(Config);
	_ ->
	    {skip, "IPv6 test IPs not configured"}
    end;
init_per_group(ipv4, Config0) ->
    Config1 = [{protocol, ipv4}|Config0],
    Config = update_app_config(ipv4, ?CONFIG_UPDATE, Config1),
    inets:start(),
    application:ensure_all_started(gun),
    lib_init_per_group(Config).

end_per_group(_Group, Config) ->
    inets:stop(),
    application:stop(gun),
    ok = lib_end_per_group(Config).

common() ->
    [nbsf_get].

groups() ->
    [{ipv4, [], common()},
     {ipv6, [], common()}
    ].

all() ->
    [{group, ipv4},
     {group, ipv6}].

%%%===================================================================
%%% Tests
%%%===================================================================

setup_per_testcase(Config, ClearSxHist) ->
    ct:pal("Sockets: ~p", [ergw_socket_reg:all()]),
    ergw_test_sx_up:reset('pgw-u01'),
    meck_reset(Config),
    start_gtpc_server(Config),
    reconnect_all_sx_nodes(),
    ClearSxHist andalso ergw_test_sx_up:history('pgw-u01', true),
    ok.

init_per_testcase(_, Config) ->
    setup_per_testcase(Config, true),
    Config.

end_per_testcase(_, Config) ->
    stop_gtpc_server(),
    Config.

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

    {GtpC1, _, _} = create_session(ipv4, Config),
    Qs1 = get_test_qs(ipv4, GtpC1),
    ?match({200, #{'ipv4Addr' := _}}, json_h2_request(H2C, get, URI, Qs1)),

    ?match({200, _}, json_h2_request(H2C, get, URI, [{"dnn", "eXaMpLe.net"}|Qs1])),
    ?match({404, empty}, json_h2_request(H2C, get, URI, [{"dnn", "example.net"}|Qs1])),

    ?match({200, _}, json_h2_request(H2C, get, URI, [{"ipDomain", "sgi"}|Qs1])),
    ?match({404, empty}, json_h2_request(H2C, get, URI, [{"ipDomain", "SGI"}|Qs1])),

    S1 = jsx:encode(#{sst => 1, sd => 16#ffffff}),
    ?match({200, _}, json_h2_request(H2C, get, URI, [{"snssai", S1}|Qs1])),
    S2 = jsx:encode(#{sst => 0, sd => 16#ffffff}),
    ?match({404, empty}, json_h2_request(H2C, get, URI, [{"snssai", S2}|Qs1])),
    S3 = jsx:encode(#{sst => <<"test">>, sd => 16#ffffff}),
    ?match({400, _}, json_h2_request(H2C, get, URI, [{"snssai", S3}|Qs1])),

    delete_session(GtpC1),

    {GtpC2, _, _} = create_session(ipv6, Config),
    ?match({200, #{'ipv6Prefix' := _}},
	    json_h2_request(H2C, get, URI, get_test_qs(ipv6, GtpC2))),
    delete_session(GtpC2),

    {GtpC3, _, _} = create_session(ipv4v6, Config),
    ?match({200, #{'ipv4Addr' := _, 'ipv6Prefix' := _}},
	   json_h2_request(H2C, get, URI, get_test_qs(ipv4, GtpC3))),
    ?match({200, #{'ipv4Addr' := _, 'ipv6Prefix' := _}},
	   json_h2_request(H2C, get, URI, get_test_qs(ipv6, GtpC3))),
    delete_session(GtpC3),

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
