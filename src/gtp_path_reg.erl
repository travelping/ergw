%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_path_reg).

-behaviour(regine_server).

%% API
-export([start_link/0]).
-export([register/2, unregister/1, lookup/1]).
-export([all/0, all/1]).
-export([state/1, state/2]).

%% regine_server callbacks
-export([init/1, handle_register/4, handle_unregister/3, handle_pid_remove/3,
	 handle_death/3, terminate/2, handle_call/3]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include_lib("stdlib/include/ms_transform.hrl").

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    regine_server:start_link({local, ?SERVER}, ?MODULE, []).

register(Key, State) ->
    regine_server:register(?SERVER, self(), Key, State).
unregister(Key) ->
    regine_server:unregister(?SERVER, Key, undefined).

lookup(Key) ->
    case ets:lookup(?SERVER, Key) of
	[{Key, Pid, _}] ->
	    Pid;
	_ ->
	    undefined
    end.

state(Key, State) ->
    regine_server:call(?SERVER, {state, Key, State}).

state(Key) ->
    case ets:lookup(?SERVER, Key) of
	[{Key, _, State}] ->
	    State;
	_ ->
	    undefined
    end.

all() ->
    ets:tab2list(?SERVER).

all({_,_,_,_} = IP) ->
    all_ip(IP);
all({_,_,_,_,_,_,_,_} = IP) ->
    all_ip(IP);
all(Port) when is_atom(Port) ->
    Ms = ets:fun2ms(fun({{Name, _, _}, Pid, State}) when Name =:= Port -> {Pid, State} end),
    ets:select(?SERVER, Ms).

all_ip(IP) ->
    %%ets:select(Tab,[{{'$1','$2','$3'},[],['$$']}])
    Ms = ets:fun2ms(fun({{_, _, PeerIP}, Pid, State}) when PeerIP =:= IP -> {Pid, State} end),
    ets:select(?SERVER, Ms).

%%%===================================================================
%%% regine callbacks
%%%===================================================================

init([]) ->
    ets:new(?SERVER, [ordered_set, named_table, public, {keypos, 1}]),
    {ok, #state{}}.

handle_register(Pid, Key, Value, State) ->
    ets:insert(?SERVER, {Key, Pid, Value}),
    {ok, [Key], State}.

handle_unregister(Key, _Value, State) ->
    unregister(Key, State).

handle_pid_remove(_Pid, Keys, State) ->
    lists:foreach(fun(Key) -> ets:delete(?SERVER, Key) end, Keys),
    State.

handle_call({state, Key, PeerState}, _From, State) ->
    Result = ets:update_element(?SERVER, Key, {3, PeerState}),
    {reply, Result, State}.

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
