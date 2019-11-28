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

-define(CONFIG_UPDATE,
	[{[sockets, cp, ip], localhost},
	 {[sockets, irx, ip], test_gsn},
	 {[sx_socket, ip], localhost},
	 {[node_selection, {default, 2}, 2, "topon.gn.ggsn.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox01.$ORIGIN"],
	  {fun node_sel_update/2, pgw_u_sx}}
	]).

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
		  %% proxy handler
		  [{gn, [{handler, ggsn_gn_proxy},
			 {sockets, [irx]},
			 {proxy_sockets, ['proxy-irx']},
			 {node_selection, [static]},
			 {contexts,
			  [{<<"ams">>,
			    [{proxy_sockets, ['proxy-irx']}]}]}
			]}
		  ]},

		 {sx_socket,
		  [{node, 'ergw'},
		   {name, 'ergw'},
		   {socket, cp},
		   {ip, {127,0,0,1}},
		   {reuseaddr, true}]},

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
		      {"_default.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
		       [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
			{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
		       "topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org"},

		      {"web.apn.epc.mnc001.mcc001.3gppnetwork.org", {300,64536},
		       [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
			{"x-3gpp-pgw","x-gn"},{"x-3gpp-pgw","x-gp"}],
		       "topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org"},

		      %% A/AAAA record alternatives
		      {"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org",  [{172, 20, 16, 89}], []}
		     ]
		    }
		   },
		   {mydns,
		    {dns, {{172,20,16,75}, 53}}}
		  ]
		 },

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
	 {ergw_aaa, [{ergw_aaa_provider, {ergw_aaa_mock, [{shared_secret, <<"MySecret">>}]}}]}
	]).

all() ->
    [http_api_version_req,
     http_api_status_req,
     http_api_status_accept_new_get_req,
     http_api_status_accept_new_post_req,
     http_api_prometheus_metrics_req
     %% http_api_delete_sessions
    ].

init_per_testcase(Config) ->
    meck_reset(Config).
init_per_testcase(http_api_delete_sessions, Config) ->
    ct:pal("Sockets: ~p", [ergw_gtp_socket_reg:all()]),
    ergw_test_sx_up:reset('pgw-u'),
    meck_reset(Config),
    start_gtpc_server(Config),
    Config;
init_per_testcase(_, Config) ->
    init_per_testcase(Config),
    Config.

end_per_testcase(http_api_session_delete, Config) ->
    stop_gtpc_server(),
    Config;
end_per_testcase(_, Config) ->
    Config.

init_per_suite(Config0) ->
    inets:start(),
    Config1 = [{app_cfg, ?TEST_CONFIG},
	       {handler_under_test, ggsn_gn_proxy}
	       | Config0],
    Config2 = update_app_config(ipv4, [], Config1),
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
	lists:filter(fun(<<"ergw_ip_pool_free", _/binary>>) ->
			     true;
			(_) -> false
		     end, Lines),
    ?equal(2, length(Result)),
    ok.

http_api_delete_sessions() ->
    [{doc, "Check DELETE /contexts/count API"}].
http_api_delete_sessions(Config) ->
    Res1 = json_http_request(delete, "/contexts/0"),
    ?match(#{<<"contexts">> := 0}, Res1),

    ok = meck:wait(ggsn_gn, terminate, '_', 2000),
    wait4tunnels(2000),
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
