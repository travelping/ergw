%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_api).

-compile([{parse_transform, cut}]).

%% API
-export([peer/1, tunnel/1, contexts/1, delete_contexts/1, memory/1]).

%%%===================================================================
%%% API
%%%===================================================================

peer(all) ->
    Peers = gtp_path_reg:all(),
    lists:map(fun({_, Pid}) -> gtp_path:info(Pid) end, Peers);
peer({_,_,_,_} = IP) ->
    collect_peer_info(gtp_path_reg:all(IP));
peer({_,_,_,_,_,_,_,_} = IP) ->
    collect_peer_info(gtp_path_reg:all(IP));
peer(Port) when is_atom(Port) ->
    collect_peer_info(gtp_path_reg:all(Port)).

tunnel(all) ->
    lists:foldl(fun collect_contexts/2, [], contexts(all));
tunnel({_,_,_,_} = IP) ->
    lists:foldl(fun collext_path_contexts/2, [], gtp_path_reg:all(IP));
tunnel({_,_,_,_,_,_,_,_} = IP) ->
    lists:foldl(fun collext_path_contexts/2, [], gtp_path_reg:all(IP));
tunnel(Port) when is_atom(Port) ->
    lists:foldl(fun collext_path_contexts/2, [], gtp_path_reg:all(Port)).

contexts(all) ->
    lists:usort([Pid || {{_Socket, {teid, 'gtp-c', _TEID}}, {_, Pid}}
				       <- gtp_context_reg:all(), is_pid(Pid)]).

delete_contexts(Count) ->
    Contexts = lists:sublist(contexts(all), Count),
    lists:foreach(fun(Pid) -> gtp_context:delete_context(Pid) end, Contexts).

memory(Limit0) ->
    Limit = min(Limit0, 100),
    ProcInfo = process_info(),
    Summary = process_summary(ProcInfo),
    LProcS = lists:sublist(lists:reverse(lists:keysort(3, Summary)), Limit),
    io:format("~s~n", [fmt_process_summary("ProcessSummary", LProcS)]),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

collect_peer_info(Peers) ->
    lists:map(fun gtp_path:info/1, Peers).

collext_path_contexts(Path, Tunnels) ->
    lists:foldl(fun({Pid}, TunIn) ->
			collect_contexts(Pid, TunIn)
		end, Tunnels, gtp_path:all(Path)).

collect_contexts(Context, Tunnels) ->
    io:format("Context: ~p~n", [Context]),
    Info = gtp_context:info(Context),
    [Info#{'Process' => Context} | Tunnels].

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
    [begin
	 {_, C} = erlang:process_info(Pid, current_function),
	 {_, M} = erlang:process_info(Pid, memory),
	 I = proc_lib:translate_initial_call(Pid),
	 {Pid, C, I, M}
     end
     || Pid <- erlang:processes()].

upd_process_summary(Mem, {I, Cnt, Sum, Log, Min, Max}) ->
    {I, Cnt + 1, Sum + Mem, Log + math:log(Mem), min(Min, Mem), max(Max, Mem)}.

process_summary(ProcInfo) ->
    M = lists:foldl(
	  fun({_Pid, _C, I, M}, Acc) ->
		  maps:update_with(
		    I, upd_process_summary(M, _), {I, 1, M, math:log(M), M, M}, Acc)
	  end, #{}, ProcInfo),
    maps:values(M).

fmt_process_summary(Head, Summary) ->
    io_lib:format("~s~n~-40.s ~10.s ~15.s ~15.s ~15.s ~15.s ~15.s~n",
		  [Head, "Initial", "Count", "Total",
		   "Min", "Max", "Arith. Avg", "Geom. Avg"]) ++
    [[io_lib:format("~-40s ~10.w ~15.s ~15.s ~15.s ~15.s ~15.s~n",
		    [mfa(I), Cnt, units(Sum), units(Min), units(Max),
		     units(Sum/Cnt), units(math:exp(Log / Cnt))])
      || {I, Cnt, Sum, Log, Min, Max} <- Summary]].
