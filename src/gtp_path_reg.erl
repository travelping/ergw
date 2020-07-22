%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_path_reg).

-behaviour(regine_server).

%% API
-export([start_link/0]).
-export([register/1, unregister/1, lookup/1]).
-export([all/0, all/1]).
-export([add_down_peer/1, remove_down_peer/1, get_down_peers/0]).

%% regine_server callbacks
-export([init/1, handle_register/4, handle_unregister/3, handle_pid_remove/3, 
	 handle_death/3, terminate/2, handle_call/3]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include_lib("stdlib/include/ms_transform.hrl").

-define(SERVER, ?MODULE).

-record(state,{peer_data :: map()}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    regine_server:start_link({local, ?SERVER}, ?MODULE, []).

register(Key) ->
    regine_server:register(?SERVER, self(), Key, undefined).
unregister(Key) ->
    regine_server:unregister(?SERVER, Key, undefined).

lookup(Key) ->
    case ets:lookup(?SERVER, Key) of
	[{Key, Pid}] ->
	    Pid;
	_ ->
	    undefined
    end.

% add down peer in State
add_down_peer(IP) ->
    regine_server:call(?SERVER, [{down_peer, {add, IP}}]).

% remove down peer in State
remove_down_peer(IP) ->
    regine_server:call(?SERVER, [{down_peer, {remove,IP}}]).

% get down peers
get_down_peers() ->
    regine_server:call(?SERVER, [{down_peer, list}]).

all() ->
    ets:tab2list(?SERVER).

all({_,_,_,_} = IP) ->
    all_ip(IP);
all({_,_,_,_,_,_,_,_} = IP) ->
    all_ip(IP);
all(Port) when is_atom(Port) ->
    Ms = ets:fun2ms(fun({{Name, _, _}, Pid}) when Name =:= Port -> Pid end),
    ets:select(?SERVER, Ms).

all_ip(IP) ->
    %%ets:select(Tab,[{{'$1','$2','$3'},[],['$$']}])
    Ms = ets:fun2ms(fun({{_, _, PeerIP}, Pid}) when PeerIP =:= IP -> Pid end),
    ets:select(?SERVER, Ms).

%%%===================================================================
%%% regine callbacks
%%%===================================================================

init([]) ->
    ets:new(?SERVER, [ordered_set, named_table, public, {keypos, 1}]),
    {ok, #state{peer_data = #{}}}.

handle_register(Pid, Key, _Value, State) ->
    ets:insert(?SERVER, {Key, Pid}),
    {ok, [Key], State}.

handle_unregister(Key, _Value, State) ->
    unregister(Key, State).

handle_pid_remove(_Pid, Keys, State) ->
    lists:foreach(fun(Key) -> ets:delete(?SERVER, Key) end, Keys),
    State.

handle_call([{down_peer, {add, IP}}], _Pid, #state{peer_data = Data0} = State0) ->
    DownPeers = maps:get(down_peers, Data0, []),
    State = case lists:member(IP, DownPeers) of
                false ->
                    Data = maps:put(down_peers, [IP | DownPeers], Data0),
                    State0#state{peer_data = Data};
                _ ->
                    State0
            end,
    {reply, ok, State};
handle_call([{down_peer, {remove, IP}}], _Pid, #state{peer_data = Data0} = State) ->
    DownPeers0 = maps:get(down_peers, Data0, []),
    DownPeers = lists:delete(IP, DownPeers0),
    Data = maps:put(down_peers, DownPeers, Data0),
    {reply, ok, State#state{peer_data = Data}};
handle_call([{down_peer, list}], _Pid, #state{peer_data = Data} = State) ->
    DownPeers = maps:get(down_peers, Data,[]),
    {reply, {ok, DownPeers}, State}.

handle_death(_Pid, _Reason, State) ->
    State.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

unregister(Key, State) ->
    Pids = [Pid || {_, Pid} <- ets:take(?SERVER, Key)],
    {Pids, State}.
