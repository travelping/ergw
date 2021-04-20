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

	 {ergw_core,
	  #{node =>
		[{node_id, <<"PGW.epc.mnc001.mcc001.3gppnetwork.org">>}],
	    sockets =>
		[{'cp-socket',
		  [{type, 'gtp-u'},
		   {vrf, cp},
		   {ip, ?MUST_BE_UPDATED},
		   {reuseaddr, true}
		  ]},
		 {'irx-socket',
		  [{type, 'gtp-c'},
		   {vrf, irx},
		   {rcvbuf, 134217728},
		   {ip, ?MUST_BE_UPDATED},
		   {reuseaddr, true}
		  ]},

		 {sx, [{type, 'pfcp'},
		       {rcvbuf, 134217728},
		       {socket, 'cp-socket'},
		       {ip, ?MUST_BE_UPDATED},
		       {reuseaddr, true}
		      ]}
		],

	    ip_pools =>
		[{<<"pool-A">>, [{ranges, [#{start => ?IPv4PoolStart, 'end' => ?IPv4PoolEnd, prefix_len => 32},
					   #{start => ?IPv6PoolStart, 'end' => ?IPv6PoolEnd, prefix_len => 64},
					   #{start => ?IPv6HostPoolStart, 'end' => ?IPv6HostPoolEnd, prefix_len => 128}]},
				 {'MS-Primary-DNS-Server', {8,8,8,8}},
				 {'MS-Secondary-DNS-Server', {8,8,4,4}},
				 {'MS-Primary-NBNS-Server', {127,0,0,1}},
				 {'MS-Secondary-NBNS-Server', {127,0,0,1}},
				 {'DNS-Server-IPv6-Address',
				  [{16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8888},
				   {16#2001, 16#4860, 16#4860, 0, 0, 0, 0, 16#8844}]}
				]}
		],

	    handlers =>
		#{gn =>
		      [{handler, pgw_s5s8},
		       {protocol, gn},
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
		      ],
		  s5s8 =>
		      [{handler, pgw_s5s8},
		       {protocol, s5s8},
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

	    node_selection =>
		#{default =>
		      #{type => static,
			entries =>
			    [
			     %% APN NAPTR alternative
			     #{type        => naptr,
			       name        => <<"_default.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-pgw',
			       protocols   => ['x-s5-gtp', 'x-s8-gtp', 'x-gn', 'x-gp'],
			       replacement => <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>},

			     #{type        => naptr,
			       name        => <<"_default.apn.epc.mnc001.mcc001.3gppnetwork.org">>,
			       order       => 300,
			       preference  => 64536,
			       service     => 'x-3gpp-upf',
			       protocols   => ['x-sxb'],
			       replacement => <<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>},

			     %% A/AAAA record alternatives
			     #{type => host,
			       name => <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED},
			     #{type => host,
			       name => <<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>,
			       ip4  => ?MUST_BE_UPDATED,
			       ip6  => ?MUST_BE_UPDATED}
			    ]}
		 },

	    apns =>
		[{?'APN-EXAMPLE',
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]}]},
		 {[<<"exa">>, <<"mple">>, <<"net">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]}]},
		 {[<<"APN1">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]}]},
		 {[<<"APN2">>, <<"mnc001">>, <<"mcc001">>, <<"gprs">>],
		  [{vrf, sgi},
		   {ip_pools, [<<"pool-A">>]}]}
		 %% {'_', [{vrf, wildcard}]}
		],

	    charging =>
		#{rules =>
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
		       }}],
		  rulebase =>
		      [{<<"m2m0001">>, [<<"r-0001">>]}]
		 },

	    upf_nodes =>
		#{default =>
		      [{vrfs,
			[{cp, [{features, ['CP-Function']}]},
			 {irx, [{features, ['Access']}]},
			 {sgi, [{features, ['SGi-LAN']}]}
			]},
		       {ue_ip_pools,
			[[{ip_pools, [<<"pool-A">>]},
			  {vrf, sgi},
			   {ip_versions, [v4, v6]}]]}
		      ],
		  nodes =>
		      [{<<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>, [connect]}]
		 }
	   }
	 },

	 {ergw_aaa,
	  [
	   {handlers,
	    [{ergw_aaa_static,
	      #{defaults =>
		    [{'NAS-Identifier',          <<"NAS-Identifier">>},
		     {'Node-Id',                 <<"PGW-001">>},
		     {'Charging-Rule-Base-Name', <<"m2m0001">>}]
	       }}
	    ]},
	   {services,
	    [{'Default',
	      [{handler, 'ergw_aaa_static'},
	       {answers,
		#{'Initial-Gx' =>
		      #{avps =>
			    #{'Result-Code' => 2001,
			      'Charging-Rule-Install' =>
				  [#{'Charging-Rule-Base-Name' => [<<"m2m0001">>]}]
			     }
		       },
		  'Update-Gx' => #{avps => #{'Result-Code' => 2001}},
		  'Final-Gx' => #{avps => #{'Result-Code' => 2001}}
		 }
	       }
	      ]}
	    ]},
	   {apps,
	    [{default,
	      [{init, [#{service => 'Default'}]},
	       {authenticate, []},
	       {authorize, []},
	       {start, []},
	       {interim, []},
	       {stop, []},
	       {{gx,'CCR-Initial'},   [#{service => 'Default', answer => 'Initial-Gx'}]},
	       {{gx,'CCR-Terminate'}, [#{service => 'Default', answer => 'Final-Gx'}]},
	       {{gx,'CCR-Update'},    [#{service => 'Default', answer => 'Update-Gx'}]},
	       {{gy, 'CCR-Initial'},   []},
	       {{gy, 'CCR-Update'},    []},
	       {{gy, 'CCR-Terminate'}, []}
	      ]}
	    ]}
	  ]}
	]).

-define(CONFIG_UPDATE,
	[{[sockets, 'cp-socket', ip], localhost},
	 {[sockets, 'irx-socket', ip], test_gsn},
	 {[sockets, sx, ip], localhost},
	 {[node_selection, default, entries, {name, <<"topon.s5s8.pgw.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, final_gsn}},
	 {[node_selection, default, entries, {name, <<"topon.sx.prox01.epc.mnc001.mcc001.3gppnetwork.org">>}],
	  {fun node_sel_update/2, pgw_u01_sx}}
	]).

node_sel_update(Node, {_,_,_,_} = IP) ->
    Node#{ip4 => [IP], ip6 => []};
node_sel_update(Node, {_,_,_,_,_,_,_,_} = IP) ->
    Node#{ip4 => [], ip6 => [IP]}.

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

%% copy of lib_{init,end}_per_group without the meck overhead
bench_init_per_group(Config0) ->
    {_, AppCfg} = lists:keyfind(app_cfg, 1, Config0),   %% let it crash if undefined

    Config = ergw_test_lib:init_ets(Config0),
    [application:load(App) || App <- [cowboy, jobs, ergw_core, ergw_aaa]],
    load_config(AppCfg),
    {ok, _} = application:ensure_all_started(ergw_core),
    ergw_cluster:wait_till_ready(),
    ok = ergw_cluster:start([{enabled, false}]),
    ergw_cluster:wait_till_running(),

    ergw_test_lib:init_apps(AppCfg),

    {ok, _} = ergw_test_sx_up:start('pgw-u01', proplists:get_value(pgw_u01_sx, Config)),
    {ok, _} = ergw_test_sx_up:start('sgw-u', proplists:get_value(sgw_u_sx, Config)),

    {ok, AppsCfg} = application:get_env(ergw_aaa, apps),
    [{aaa_cfg, AppsCfg} |Config].

bench_end_per_group(Config) ->
    %% ok = ergw_test_sx_up:stop('pgw-u01'),
    %% ok = ergw_test_sx_up:stop('sgw-u'),
    ?config(table_owner, Config) ! stop,
    [application:stop(App) || App <- [ranch, cowboy, ergw_core, ergw_aaa, ergw_cluster]],
    ok.

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
    logger:set_primary_config(level, critical),
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

create_nsess(_Base, _GtpC, _Delay, 0) ->
    [];
create_nsess(Base, GtpC0, Delay, N) ->
    {Time, {GtpC1, _, _}} =
	timer:tc(ergw_pgw_test_lib, create_deterministic_session, [Base, N, GtpC0]),
    %%erlang:garbage_collect(),
    %%erlang:yield(),
    %% case floor((Delay - Time) / 1.0e3) of
    %% 	Sleep when Sleep > 0 ->
    %% 	    timer:sleep(Sleep);
    %% 	_ ->
    %% 	    ok
    %% end,
    [Time | create_nsess(Base, GtpC1, Delay, N - 1)].

contexts_at_scale() ->
    [{doc, "Check that a Path Restart terminates multiple session"}].
contexts_at_scale(Config) ->
    process_flag(trap_exit, true),
    %% process_flag(scheduler, 1),
    %% process_flag(priority, high),

    {GtpC0, _, _} = create_session({ipv4, false, default}, Config),
    Echo0 = make_request(echo_request, simple, GtpC0),
    send_recv_pdu(GtpC0, Echo0),

    TargetRate = 5000,
    NProcs = 32,
    NCtx = 1500,
    %NCtx = 150000,

    Delay = 1.0e6 * NProcs / TargetRate,
    Order = ceil(math:log2(NCtx)),
    Start = erlang:monotonic_time(),
    Procs =
	start_timed_nproc(
	  fun (N) ->
		  %% process_flag(scheduler, 1),
		  %% process_flag(priority, high),

		  GtpC = GtpC0#gtpc{socket = make_gtp_socket(0, Config)},
		  create_nsess(1000 + (N bsl Order), GtpC, Delay, NCtx)
	  end, [], NProcs),

    T = collect_nproc(Procs),
    Stop = erlang:monotonic_time(),

    TotalExec = lists:foldl(fun({Ms, _}, Sum) -> Sum + Ms end, 0, T),
    Total = erlang:convert_time_unit(Stop - Start, native, microsecond),
    ct:pal("~8w (~w) x ~8w: ~w exec µs, ~w µs, ~f secs, ~f µs/req, ~f req/s (wallTime: ~f req/s~n)",
	   [NProcs, length(Procs), NCtx, TotalExec, Total,
	    Total / 1.0e6, Total / (NProcs * NCtx),
	    (NProcs * NCtx) / (TotalExec / 1.0e6),
	    (NProcs * NCtx) / (Total / 1.0e6)]),

    ct:log(fmt_proc_times(Total, T)),

    Tunnels = NProcs * NCtx + 1,
    [?match(#{tunnels := Tunnels}, X) || X <- ergw_api:peer(all)],

    fun DrainF() ->
	    receive
		_ -> DrainF()
	    after
		0 -> ok
	    end
    end(),

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

    wait_4_tunnels_stop(),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_tunnel_cnt() ->
    lists:foldl(
      fun(#{tunnels := N}, Sum) -> N + Sum end, 0, ergw_api:peer(all)).

wait_4_tunnels_stop() ->
    wait_4_tunnels_stop(get_tunnel_cnt()).

wait_4_tunnels_stop(0) ->
    ok;
wait_4_tunnels_stop(N) ->
    ct:sleep(100),
    case get_tunnel_cnt() of
	N ->
	    ct:fail("timeout, waiting for tunnels to terminate, left over ~p", [N]);
	Total ->
	    wait_4_tunnels_stop(Total)
    end.

collect_nproc(Pids) ->
    lists:map(fun (Pid) -> receive {Pid, T} -> T end end, Pids).

start_nproc(_Fun, Pids, 0) ->
    Pids;
start_nproc(Fun, Pids, N) when is_function(Fun, 1) ->
    [spawn_link(fun () -> Fun(N) end) | start_nproc(Fun, Pids, N - 1)].

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

process_info() ->
    lists:foldl(
      fun(Pid, Acc) ->
	      try
		  {_, C} = erlang:process_info(Pid, current_function),
		  {_, M} = erlang:process_info(Pid, memory),
		  I = proc_lib:translate_initial_call(Pid),
		  [{Pid, C, I, M}|Acc]
	      catch
		  _:_ -> Acc
	      end
      end, [], erlang:processes()).

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

times_avg(Times) ->
    Len = length(Times),
    {Sum, Log} =
	lists:foldl(
	  fun(V, {Sum0, Log0}) -> {Sum0 + V, Log0 + math:log(V)} end, {0, 0}, Times),
    {Sum / Len, math:exp(Log / Len)}.

fmt_avg(Values) ->
    {Avg, Log} = times_avg(Values),
    io_lib:format("<td align=\"right\">~w</td><td align=\"right\">~w</td>",
		  [round(Avg), round(Log)]).

fmt_times(Key, Wall, Times) ->
    Len = length(Times),
    SortT = lists:sort(Times),
    Perc1 = lists:sublist(SortT, erlang:ceil(Len * 0.01)),
    Perc5 = lists:sublist(SortT, erlang:ceil(Len * 0.05)),
    Perc95 = lists:nthtail(erlang:floor(Len * 0.95), SortT),
    Perc99 = lists:nthtail(erlang:floor(Len * 0.99), SortT),

    ["<tr align=\"right\">",
     "<td align=\"left\">", Key, "</td>",
     [fmt_avg(P) || P <- [Times, Perc1, Perc5, Perc95, Perc99]],
     io_lib:format("<td align=\"right\">~w</td><td align=\"right\">~w</td>"
		   "<td align=\"right\">~f</td>",
		   [hd(SortT), lists:nth(Len, SortT), Len / (Wall / 1.0e6)]),
     "</tr>"].

fmt_proc_times(TotalExec, Times) ->
    AllTimes = lists:foldl(fun({_, T}, Acc) -> Acc ++ T end, [], Times),
    file:write_file("times.csv",
		    [[integer_to_list(X), "\n"] || X <- AllTimes]),
    ["<table>"
     "  <caption>Times</caption>"
     "  <colgroup>"
     "      <col>"
     "      <col span=\"2\">"
     "      <col span=\"2\">"
     "      <col span=\"2\">"
     "      <col span=\"2\">"
     "      <col span=\"3\">"
     "  </colgroup>"
     "  <tr>"
     "    <th rowspan=\"2\" scope=\"colgroup\" />"
     "    <th colspan=\"2\" scope=\"colgroup\">Overall</th>"
     "    <th colspan=\"2\" scope=\"colgroup\">1st percentil</th>"
     "    <th colspan=\"2\" scope=\"colgroup\">5th percentil</th>"
     "    <th colspan=\"2\" scope=\"colgroup\">95th percentil</th>"
     "    <th colspan=\"2\" scope=\"colgroup\">99th percentil</th>"
     "    <th colspan=\"3\" scope=\"colgroup\" />"
     "  </tr>"
     "  <tr>"
     "      <th scope=\"col\">Arith. Avg</th>"
     "      <th scope=\"col\">Geom. Avg</th>"
     "      <th scope=\"col\">Arith. Avg</th>"
     "      <th scope=\"col\">Geom. Avg</th>"
     "      <th scope=\"col\">Arith. Avg</th>"
     "      <th scope=\"col\">Geom. Avg</th>"
     "      <th scope=\"col\">Arith. Avg</th>"
     "      <th scope=\"col\">Geom. Avg</th>"
     "      <th scope=\"col\">Arith. Avg</th>"
     "      <th scope=\"col\">Geom. Avg</th>"
     "      <th scope=\"col\">Fastest</th>"
     "      <th scope=\"col\">Slowest</th>"
     "      <th scope=\"col\">Req/s</th>"
     "  </tr>",
     [fmt_times("", Wall, T) || {Wall, T} <- Times],
     fmt_times("Total", TotalExec, AllTimes),
     "</table>"].
