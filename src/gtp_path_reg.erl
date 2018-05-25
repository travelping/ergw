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
-export([all/0, all/1, status/1, status/2, available/2]).

%% regine_server callbacks
-export([init/1, handle_register/4, handle_unregister/3, handle_pid_remove/3, handle_death/3, terminate/2]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include_lib("stdlib/include/ms_transform.hrl").
-include("include/ergw.hrl").

-define(SERVER, ?MODULE).

-record(state, {}).

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
	[#path{key = Key, pid = Pid}] ->
	    Pid;
	_ ->
	    undefined
    end.

status(Key) ->
    case ets:lookup(?SERVER, Key) of
	[#path{key = Key, status = Status}] ->
	    Status;
	_ ->
	    undefined
    end.

status(Key, State) ->
    ets:update_element(?SERVER, Key, {#path.status, State}).

available(Port, Version) ->
    Ms = ets:fun2ms(fun(#path{key = {PortName, PeerVersion, IP}, status = 'UP'})
			  when PortName =:= Port, PeerVersion =:= Version -> IP end),
    ets:select(?SERVER, Ms).

all() ->
    ets:tab2list(?SERVER).

all({_,_,_,_} = IP) ->
    all_ip(IP);
all({_,_,_,_,_,_,_,_} = IP) ->
    all_ip(IP);
all(Port) when is_atom(Port) ->
    Ms = ets:fun2ms(fun(#path{key = {Name, _, _}, pid = Pid}) when Name =:= Port -> Pid end),
    ets:select(?SERVER, Ms).

all_ip(IP) ->
    Ms = ets:fun2ms(fun(#path{key = {_, _, PeerIP}, pid = Pid}) when PeerIP =:= IP -> Pid end),
    ets:select(?SERVER, Ms).

%%%===================================================================
%%% regine callbacks
%%%===================================================================

init([]) ->
    ets:new(?SERVER, [ordered_set, named_table, public, {keypos, #path.key}]),
    {ok, #state{}}.

handle_register(Pid, Key, _Value, State) ->
    ets:insert(?SERVER, #path{key = Key, pid = Pid}),
    {ok, [Key], State}.

handle_unregister(Key, _Value, State) ->
    unregister(Key, State).

handle_pid_remove(_Pid, Keys, State) ->
    lists:foreach(fun(Key) -> ets:delete(?SERVER, Key) end, Keys),
    State.

handle_death(_Pid, _Reason, State) ->
    State.

terminate(_Reason, _State) ->
	ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

unregister(Key, State) ->
    Pids = [Pid || #path{pid = Pid} <- ets:take(?SERVER, Key)],
    {Pids, State}.
