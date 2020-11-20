%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(bench_SUITE).

-compile([export_all, nowarn_export_all]).
-compile([{parse_transform, cut}]).

-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_pgw_test_lib.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-define(TIMEOUT, 2000).

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

	 {jobs, [{samplers,
		  [{cpu_feedback, jobs_sampler_cpu, []}
		  ]},
		 {queues,
		  [{path_restart,
		    [{regulators, [{counter, [{limit, 10000}]}]},
		     %% 10 = % increment by which to modify the limit
		     {modifiers,  [{cpu_feedback, 10}]}
		    ]},
		   {create,
		    [{max_time, 5000}, %% max 5 seconds
		     {regulators, [{rate, [{limit, 10000}]}]},
		     %% 10 = % increment by which to modify the limit
		     {modifiers,  [{cpu_feedback, 10}]}
		    ]},
		   {delete,
		    [{regulators, [{counter, [{limit, 10000}]}]},
		     %% 10 = % increment by which to modify the limit
		     {modifiers,  [{cpu_feedback, 10}]}
		    ]},
		   {other,
		    [{max_time, 10000}, %% max 10 seconds
		     {regulators, [{rate, [{limit, 10000}]}]},
		     %% 10 = % increment by which to modify the limit
		     {modifiers,  [{cpu_feedback, 10}]}
		    ]}
		  ]}
		]},

	 {ergw, [{'$setup_vars',
		  [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
		 {node_id, <<"PGW">>},
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
			 {node, 'ergw'},
			 {name, 'ergw'},
			 {socket, cp},
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

		      %% A/AAAA record alternatives
		      {"topon.s5s8.pgw.$ORIGIN", ?MUST_BE_UPDATED, []},
		      {"topon.sx.prox01.$ORIGIN", ?MUST_BE_UPDATED, []}
		     ]
		    }
		   }
		  ]
		 },

		 {apns,
		  [{?'APN-EXAMPLE',
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]},
		   {[<<"exa">>, <<"mple">>, <<"net">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]},
		   {[<<"APN1">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]},
		   {[<<"APN2">>, <<"mnc001">>, <<"mcc001">>, <<"gprs">>],
		    [{vrf, sgi},
		     {ip_pools, ['pool-A']}]}
		   %% {'_', [{vrf, wildcard}]}
		  ]},

		 {charging,
		  [{default,
		    [{rulebase,
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
		       {<<"m2m0001">>, [<<"r-0001">>]}
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
		   {"topon.sx.prox01.$ORIGIN", [connect]}
		  ]
		 }
		]},

	 {ergw_aaa,
	  [
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
		      #{'Result-Code' => 2001,
			'Charging-Rule-Install' =>
			    [#{'Charging-Rule-Base-Name' => [<<"m2m0001">>]}]
		       },
		  'Initial-Gx-Redirect' =>
		      #{'Result-Code' => 2001,
			'Charging-Rule-Install' =>
			    [#{'Charging-Rule-Definition' =>
				   [#{
				      'Charging-Rule-Name' => <<"m2m">>,
				      'Rating-Group' => [3000],
				      'Flow-Information' =>
					  [#{'Flow-Description' => [<<"permit out ip from any to assigned">>],
					     'Flow-Direction'   => [1]    %% DownLink
					    },
					   #{'Flow-Description' => [<<"permit out ip from any to assigned">>],
					     'Flow-Direction'   => [2]    %% UpLink
					    }],
				      'Metering-Method'  => [1],
				      'Precedence' => [100],
				      'Offline'  => [1],
				      'Redirect-Information' =>
					  [#{'Redirect-Support' =>
						 [1],   %% ENABLED
					     'Redirect-Address-Type' =>
						 [2],   %% URL
					     'Redirect-Server-Address' =>
						 ["http://www.heise.de/"]
					    }]
				     }]
			      }]
		       },
		  'Update-Gx' => #{'Result-Code' => 2001},
		  'Final-Gx' => #{'Result-Code' => 2001},
		  'Initial-OCS' =>
		      #{'Result-Code' => 2001,
			'Multiple-Services-Credit-Control' =>
			    [#{'Envelope-Reporting' => [0],
			       'Granted-Service-Unit' =>
				   [#{'CC-Time' => [3600],
				      'CC-Total-Octets' => [102400]}],
			       'Rating-Group' => [3000],
			       'Validity-Time' => [3600],
			       'Result-Code' => [2001],
			       'Time-Quota-Threshold' => [60],
			       'Volume-Quota-Threshold' => [10240]
			      }]
		       },
		  'Update-OCS' =>
		      #{'Result-Code' => 2001,
			'Multiple-Services-Credit-Control' =>
			    [#{'Envelope-Reporting' => [0],
			       'Granted-Service-Unit' =>
				   [#{'CC-Time' => [3600],
				      'CC-Total-Octets' => [102400]}],
			       'Rating-Group' => [3000],
			       'Validity-Time' => [3600],
			       'Result-Code' => [2001],
			       'Time-Quota-Threshold' => [60],
			       'Volume-Quota-Threshold' => [10240]
			      }]
		       },
		  'Initial-OCS-VT' =>
		      #{'Result-Code' => 2001,
			'Multiple-Services-Credit-Control' =>
			    [#{'Envelope-Reporting' => [0],
			       'Granted-Service-Unit' =>
				   [#{'CC-Time' => [3600],
				      'CC-Total-Octets' => [102400]}],
			       'Rating-Group' => [3000],
			       'Validity-Time' => [2],
			       'Result-Code' => [2001],
			       'Time-Quota-Threshold' => [60],
			       'Volume-Quota-Threshold' => [10240]
			      }]
		       },
		  'Update-OCS-VT' =>
		      #{'Result-Code' => 2001,
			'Multiple-Services-Credit-Control' =>
			    [#{'Envelope-Reporting' => [0],
			       'Granted-Service-Unit' =>
				   [#{'CC-Time' => [3600],
				      'CC-Total-Octets' => [102400]}],
			       'Rating-Group' => [3000],
			       'Validity-Time' => [2],
			       'Result-Code' => [2001],
			       'Time-Quota-Threshold' => [60],
			       'Volume-Quota-Threshold' => [10240]
			      }]
		       },
		  'Final-OCS' => #{'Result-Code' => 2001}
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
	[{[sockets, 'cp-socket', ip], localhost},
	 {[sockets, 'irx-socket', ip], test_gsn},
	 {[sockets, sx, ip], localhost},
	 {[node_selection, {default, 2}, 2, "topon.s5s8.pgw.$ORIGIN"],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, {default, 2}, 2, "topon.sx.prox01.$ORIGIN"],
	  {fun node_sel_update/2, pgw_u01_sx}}
	]).

node_sel_update(Node, {_,_,_,_} = IP) ->
    {Node, [IP], []};
node_sel_update(Node, {_,_,_,_,_,_,_,_} = IP) ->
    {Node, [], [IP]}.

%%%===================================================================
%%% Setup
%%%===================================================================

suite() ->
    [{timetrap, {minutes, 10}}].

init_per_suite(Config0) ->
    case os:getenv("BENCHMARK") of
	"true" ->
	    [{app_cfg, ?TEST_CONFIG} | Config0];
	_ ->
	    {skip, "skipping benchmark tests"}
    end.

end_per_suite(_Config) ->
    ok.

bench_init_per_group(Config0) ->
    {_, AppCfg} = lists:keyfind(app_cfg, 1, Config0),   %% let it crash if undefined

    Config = ergw_test_lib:init_ets(Config0),
    [application:load(App) || App <- [cowboy, ergw, ergw_aaa]],
    load_config(AppCfg),
    {ok, _} = application:ensure_all_started(ergw),
    {ok, _} = ergw_test_sx_up:start('pgw-u01', proplists:get_value(pgw_u01_sx, Config)),
    {ok, _} = ergw_test_sx_up:start('sgw-u', proplists:get_value(sgw_u_sx, Config)),
    {ok, AppsCfg} = application:get_env(ergw_aaa, apps),
    [{aaa_cfg, AppsCfg} |Config].

init_per_group(ipv6, Config0) ->
    case ergw_test_lib:has_ipv6_test_config() of
	true ->
	    Config = update_app_config(ipv6, ?CONFIG_UPDATE, Config0),
	    bench_init_per_group(Config);
	_ ->
	    {skip, "IPv6 test IPs not configured"}
    end;
init_per_group(ipv4, Config0) ->
    Config = update_app_config(ipv4, ?CONFIG_UPDATE, Config0),
    bench_init_per_group(Config).

bench_end_per_group(Config) ->
    ok = ergw_test_sx_up:stop('pgw-u01'),
    ok = ergw_test_sx_up:stop('sgw-u'),
    ?config(table_owner, Config) ! stop,
    [application:stop(App) || App <- [ranch, cowboy, ergw, ergw_aaa]],
    ok.

end_per_group(Group, Config)
  when Group == ipv4; Group == ipv6 ->
    ok = bench_end_per_group(Config).

common() ->
    [contexts_at_scale].

groups() ->
    [{ipv4, [], common()},
     {ipv6, [], common()}].

all() ->
    [{group, ipv4},
     {group, ipv6}].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(Config) ->
    ergw_test_sx_up:reset('pgw-u01'),
    ergw_test_sx_up:history('pgw-u01', false),
    start_gtpc_server(Config),
    reconnect_all_sx_nodes(),
    ok.

init_per_testcase(contexts_at_scale, Config) ->
    init_per_testcase(Config),
    Config;
init_per_testcase(_, Config) ->
    init_per_testcase(Config),
    Config.

end_per_testcase(Config) ->
    stop_gtpc_server(),
    AppsCfg = proplists:get_value(aaa_cfg, Config),
    ok = application:set_env(ergw_aaa, apps, AppsCfg),
    ok.

end_per_testcase(_, Config) ->
    end_per_testcase(Config),
    Config.

%%--------------------------------------------------------------------

create_nsess(_Base, _GtpC, Ctxs, _Delay, 0) ->
    Ctxs;
create_nsess(Base, GtpC0, Ctxs, Delay, N) ->
    {Time, {GtpC1, _, _}} =
	timer:tc(ergw_pgw_test_lib, create_deterministic_session, [Base, N, GtpC0]),
    erlang:garbage_collect(),
    case floor((Delay - Time) / 1.0e3) of
	Sleep when Sleep > 0 ->
	    ct:sleep(Sleep);
	_ ->
	    ok
    end,
    create_nsess(Base, GtpC1, [GtpC1|Ctxs], Delay, N - 1).

contexts_at_scale() ->
    [{doc, "Check that a Path Restart terminates multiple session"}].
contexts_at_scale(Config) ->
    {GtpC0, _, _} = create_session(Config),

    TargetRate = 1000,
    NProcs = 10,
    NCtx = 15000,

    Delay = 1.0e6 * NProcs / TargetRate,
    Order = ceil(math:log2(NCtx)),
    Start = erlang:monotonic_time(),
    Procs =
	start_timed_nproc(
	  fun (N) ->
		  GtpC = GtpC0#gtpc{socket = make_gtp_socket(0, Config)},
		  create_nsess(1000 + (N bsl Order), GtpC, [], Delay, NCtx)
	  end, [], NProcs),

    T = collect_nproc(Procs),
    Stop = erlang:monotonic_time(),

    TotalExec = lists:foldl(fun({Ms, _}, Sum) -> Sum + Ms end, 0, T),
    Total = erlang:convert_time_unit(Stop - Start, native, microsecond),
    ct:pal("~8w (~w) x ~8w: ~w exec us, ~w us, ~f secs, ~f us/req, ~f req/s~n",
	   [NProcs, length(Procs), NCtx, TotalExec, Total,
	    Total / 1.0e6, Total / (NProcs * NCtx),
	    (NProcs * NCtx) / (Total / 1.0e6)]),

    Tunnels = NProcs * NCtx + 1,
    {Cnt, _} = ergw_nudsf:search(#{tag => type, value => 'gtp-c'}, #{count => true}),
    %%[?match(#{tunnels := Tunnels}, X) || X <- ergw_api:peer(all)],
    ?equal(Tunnels, Cnt),

    ct:log(fmt_memory_html("Memory", erlang:memory())),

    ProcInfo = process_info(),
    %% ct:pal("ProcessInfo:~n~s~n", [fmt_process_info(ProcInfo)]),
    %% ct:log("~s~n", [fmt_process_info_html(ProcInfo)]),
    Summary = process_summary(ProcInfo),
    %% ct:pal("ProcessSummary:~n~s~n", [fmt_process_summary(Summary)]),
    ct:log(fmt_process_summary_html("ProcessSummary", Summary, 10)),

    %% let it settle...
    ct:sleep({seconds, 10}),
    Summary1 = process_summary(process_info()),
    ct:log(fmt_process_summary_html("ProcessSummary after 10 seconds", Summary1, 10)),

    %% simulate patch restart to kill the PDP context
    Echo = make_request(echo_request, simple,
			gtp_context_inc_seq(
			  gtp_context_inc_restart_counter(GtpC0))),
    send_recv_pdu(GtpC0, Echo),

    wait4tunnels(?TIMEOUT),
    ct:sleep({seconds, 30}),

    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

maps_recusive_merge(Key, Value, Map) ->
    maps:update_with(Key, fun(V) -> maps_recusive_merge(V, Value) end, Value, Map).

maps_recusive_merge(M1, M2)
  when is_map(M1) andalso is_map(M1) ->
    maps:fold(fun maps_recusive_merge/3, M1, M2);
maps_recusive_merge(_, New) ->
    New.

cfg_get_value([], Cfg) ->
    Cfg;
cfg_get_value([H|T], Cfg) when is_map(Cfg) ->
    cfg_get_value(T, maps:get(H, Cfg));
cfg_get_value([H|T], Cfg) when is_list(Cfg) ->
    cfg_get_value(T, proplists:get_value(H, Cfg)).

load_aaa_answer_config(AnswerCfg) ->
    {ok, Cfg0} = application:get_env(ergw_aaa, apps),
    Session = cfg_get_value([default, session, 'Default'], Cfg0),
    Answers =
	[{Proc, [{'Default', Session#{answer => Answer}}]}
	 || {Proc, Answer} <- AnswerCfg],
    UpdCfg =
	#{default =>
	      #{procedures => maps:from_list(Answers)}},
    Cfg = maps_recusive_merge(Cfg0, UpdCfg),
    ok = application:set_env(ergw_aaa, apps, Cfg).

collect_nproc(Pids) ->
    lists:map(fun (Pid) -> receive {Pid, T} -> T end end, Pids).

start_nproc(_Fun, Pids, 0) ->
    Pids;
start_nproc(Fun, Pids, N) when is_function(Fun, 1) ->
    [proc_lib:spawn_link(fun () -> Fun(N) end) | start_nproc(Fun, Pids, N - 1)].

timed_proc(Owner, Fun) ->
    Owner ! {self(), timer:tc(Fun)}.

start_timed_nproc(Fun, Pids, N) when is_function(Fun, 1) ->
    Owner = self(),
    start_nproc(fun (Arg) -> timed_proc(Owner, fun () -> Fun(Arg) end) end, Pids, N).

units(X) when X > 1024 * 1024 * 1024 ->
    io_lib:format("~.4f GB", [X / math:pow(2, 30)]);
units(X) when X > 1024 * 1024 ->
    io_lib:format("~.4f MB", [X / math:pow(2, 20)]);
units(X) when X > 1024 ->
    io_lib:format("~.4f kB", [X / math:pow(2, 10)]);
units(X) ->
    io_lib:format("~.4w byte", [X]).

mfa({M, F, A}) when is_atom(M), is_atom(F), is_integer(A) ->
    io_lib:format("~s:~s/~w", [M, F, A]);
mfa(MFA) ->
    io_lib:format("~p", [MFA]).

process_info_2(Pid, Acc) ->
    case erlang:process_info(Pid, [current_function, memory, dictionary]) of
	[{current_function, C}, {memory, M}|_] = ProcInfo ->
	    I = proc_lib:translate_initial_call(ProcInfo),
	    [{Pid, C, I, M} | Acc];
	_ ->
	    Acc
    end.

process_info() ->
    lists:foldl(fun process_info_2/2, [], erlang:processes()).

fmt_process_info(ProcInfo) ->
    [[io_lib:format("~p:~p: I: ~p, ~p - ~s~n", [Pid, C, I, M, units(M)]) ||
	 {Pid, C, I, M} <- lists:keysort(4, ProcInfo)]].

fmt_process_info_html(ProcInfo) ->
    ["<emph>ProcessInfo:</emph>"] ++
	["<table><tr><th>Pid</th><th>Current</th><th>Initial</th><th colspan=\"2\">Memory</th></tr>"] ++
	[[io_lib:format("<tr><td>~1000p</td><td>~1000p</td><td>~s</td><td>~1000p</td><td>~s</td></tr>~n",
			[Pid, C, mfa(I), M, units(M)]) ||
	     {Pid, C, I, M} <- lists:reverse(lists:keysort(4, ProcInfo))]]
	++ ["</table>"].

upd_process_summary(Mem, {I, Cnt, Sum, Log, Min, Max}) ->
    {I, Cnt + 1, Sum + Mem, Log + math:log(Mem), min(Min, Mem), max(Max, Mem)}.

process_summary(ProcInfo) ->
    M = lists:foldl(
	  fun({_Pid, _C, I, M}, Acc) ->
		  maps:update_with(
		    I, upd_process_summary(M, _), {I, 1, M, math:log(M), M, M}, Acc)
	  end, #{}, ProcInfo),
    maps:values(M).

fmt_process_summary(ProcSummary) ->
    [[io_lib:format("~p: Cnt ~w, Total ~s, Max ~s, Min ~s~n",
		    [I, Cnt, units(Sum), units(Min), units(Max)]) ||
	 {I, Cnt, Sum, _Log, Min, Max} <- lists:reverse(lists:keysort(3, ProcSummary))]].

fmt_process_summary_html(Head, ProcSummary) ->
    fmt_process_summary_html(Head, ProcSummary, length(ProcSummary)).

fmt_process_summary_html(Head, ProcSummary, Limit) ->
    LProcS = lists:sublist(lists:reverse(lists:keysort(3, ProcSummary)), Limit),
    Total =
	lists:foldl(fun ({_I, _Cnt, Sum, _Log, _Min, _Max}, T) -> T + Sum end,
		    0, ProcSummary),
    DispTotal =
	lists:foldl(fun ({_I, _Cnt, Sum, _Log, _Min, _Max}, T) -> T + Sum end,
		    0, LProcS),
    io_lib:format("<emph>~s:</emph>", [Head]) ++
	["<table><tr><th>Initial</th><th>Count</th>"
	 "<th>Total</th><th>Min</th><th>Max</th><th>Arith. Avg</th><th>Geom. Avg</th></tr>"] ++
	[[io_lib:format("<tr align=\"right\"><td align=\"left\">~s</td><td>~w</td><td>~s</td><td>~s</td><td>~s</td>"
			"<td>~s</td><td>~s</td></tr>",
			[mfa(I), Cnt, units(Sum), units(Min), units(Max),
			 units(Sum/Cnt), units(math:exp(Log / Cnt))])
	  || {I, Cnt, Sum, Log, Min, Max} <- LProcS]]
	++ io_lib:format("<tfoot><tr align=\"right\"><td align=\"left\">Total of shown above</td>"
			 "<td /><td>~s</td><td>~.2f %</td><td /><td /><td /></tr>"
			 "<tr align=\"right\"><td align=\"left\">Total (incl. not shown processes)</td>"
			 "<td /><td>~s</td><td /><td /><td /><td /></tr></tfoot>~n",
			 [units(DispTotal), (DispTotal / Total) * 100, units(Total)])
	++ ["</table>"].

fmt_memory_html(Head, Memory) ->
    io_lib:format("<emph>~s:</emph>", [Head]) ++
	["<table><tr><th>Keyl</th><th colspan=\"2\">Value</th></tr>"] ++
	[[io_lib:format("<tr align=\"right\"><td align=\"left\">~1000p</td><td>~w</td><td>~s</td></tr>",
			[Key, Value, units(Value)])
	  || {Key, Value} <- Memory]]
	++ ["</table>"].
