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

-define(TIMEOUT, 2000).
-define(HUT, ggsn_gn).

-define(TEST_CONFIG,
	[
	 {kernel,
	  [{logger,
	    [{handler, default, logger_std_h,
	      #{level => info,
		config =>
		    #{sync_mode_qlen => 10000,
		      drop_mode_qlen => 10000,
		      flush_qlen     => 10000}
	       }
	     }
	    ]}
	  ]},

	 {ergw, [{'$setup_vars',
		  [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
		 {node_id, <<"GGSN">>},
		 {sockets,
		  [{cp, [{type, 'gtp-u'},
			 {ip, ?LOCALHOST_IPv4},
			 {reuseaddr, true}
			]},
		   {irx, [{type, 'gtp-c'},
			  {ip,  ?TEST_GSN_IPv4},
			  {reuseaddr, true}
			 ]},
		   {'proxy-irx', [{type, 'gtp-c'},
				  {ip,  ?PROXY_GSN_IPv4},
				  {reuseaddr, true}
				 ]},

		   {sx, [{type, 'pfcp'},
			 {node, 'ergw'},
			 {name, 'ergw'},
			 {socket, cp},
			 {ip, ?LOCALHOST_IPv4},
			 {reuseaddr, true}
			]}
		  ]},

		 {ip_pools,
		  [{'pool-A', [{ranges,  [{?IPv4PoolStart, ?IPv4PoolEnd, 32},
					  {?IPv6PoolStart, ?IPv6PoolEnd, 64}]},
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
		  [{gn, [{handler, ggsn_gn},
			 {sockets, [irx]},
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

		 {apns,
		  [{?'APN-EXAMPLE',
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]}
		  ]},

		 {proxy_map,
		  [{apn,  [{?'APN-EXAMPLE', ?'APN-PROXY'}]},
		   {imsi, [{?'IMSI', {?'PROXY-IMSI', ?'PROXY-MSISDN'}}
			  ]}
		  ]},

		  {node_selection,
 		  [{default,
 		    {static,
 		     [
 		      %% APN NAPTR alternative
 		      {"_default.apn.$ORIGIN", {300,64536},
 		       [{"x-3gpp-ggsn","x-gn"},{"x-3gpp-ggsn","x-gp"}],
 		       "topon.gn.ggsn.$ORIGIN"},
 		      {"_default.apn.$ORIGIN", {300,64536},
 		       [{"x-3gpp-upf","x-sxb"}],
 		       "topon.sx.prox01.$ORIGIN"},
 		      {"async-sx.apn.$ORIGIN", {300,64536},
 		       [{"x-3gpp-upf","x-sxb"}],
 		       "topon.sx.prox01.$ORIGIN"},
 		      {"async-sx.apn.$ORIGIN", {300,64536},
 		       [{"x-3gpp-upf","x-sxb"}],
 		       "topon.sx.prox02.$ORIGIN"},

 		      %% A/AAAA record alternatives
 		      {"topon.gn.ggsn.$ORIGIN", ?MUST_BE_UPDATED, []},
 		      {"topon.sx.prox01.$ORIGIN", ?MUST_BE_UPDATED, []},
 		      {"topon.sx.prox02.$ORIGIN", ?MUST_BE_UPDATED, []}
 		     ]
 		    }
 		   }
 		  ]
 		 },

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
		   }]
		 },

		 {http_api, [{port, 0}]}
		]},

		{ergw_aaa, [
	   	   {handlers,
	   	    [{ergw_aaa_static,
	   	      [{'NAS-Identifier',          <<"NAS-Identifier">>},
	   	       {'Node-Id',                 <<"PGW-001">>},
	   	       {'Charging-Rule-Base-Name', <<"m2m0001">>}
	   	      ]}
	   	    ]},
	   	   {services,
	   	    [{'Default',
	   	      [{handler, 'ergw_aaa_static'},
	   	       {answers,
				#{'Initial-Gx' =>
					#{
						'Result-Code' => 2001,
						'Charging-Rule-Install' => [#{'Charging-Rule-Base-Name' => [<<"m2m0001">>]}]
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
	   			     {{gy, 'CCR-Terminate'}, []}
	   			    ]}
	   	      ]}
	   	    ]}
   	  ]}
	]).

-define(CONFIG_UPDATE,
	[{[sockets, cp, ip], localhost},
	 {[sockets, irx, ip], test_gsn},
	 {[sockets, sx, ip], localhost},
	 {[node_selection, {default, 2}, 2, "topon.gn.ggsn.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox01.$ORIGIN"],
	  {fun node_sel_update/2, pgw_u01_sx}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox02.$ORIGIN"],
	  {fun node_sel_update/2, sgw_u_sx}}
	]).

node_sel_update(Node, {_,_,_,_} = IP) ->
    {Node, [IP], []};
node_sel_update(Node, {_,_,_,_,_,_,_,_} = IP) ->
    {Node, [], [IP]}.

all() ->
    [http_api_version_req,
     http_api_status_req,
     http_api_status_accept_new_get_req,
     http_api_status_accept_new_post_req,
     http_api_prometheus_metrics_req,
     http_api_delete_sessions,
     http_api_delete_all_sessions
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

end_per_testcase(_Config) ->
    stop_gtpc_server(),
    ok.

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
    inets:start(),
    Config1 = [{app_cfg, ?TEST_CONFIG}, {handler_under_test, ?HUT} | Config0],
    Config2 = update_app_config(ipv4, ?CONFIG_UPDATE, Config1),
    lib_init_per_suite(Config2).

end_per_suite(Config) ->
    inets:stop(),
    ok = lib_end_per_suite(Config),
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
