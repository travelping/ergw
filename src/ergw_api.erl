%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_api).

%% API
-export([peer/1, tunnel/1, contexts/1, delete_contexts/1]).

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
