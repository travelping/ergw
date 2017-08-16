%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU Lesser General Public License
%% as published by the Free Software Foundation; either version
%% 3 of the License, or (at your option) any later version.

-module(gtp_socket_reg).

-behaviour(regine_server).

%% API
-export([start_link/0]).
-export([register/2, unregister/1, lookup/1]).
-export([all/0]).

%% regine_server callbacks
-export([init/1, handle_register/4, handle_unregister/3, handle_pid_remove/3, handle_death/3, terminate/2]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    regine_server:start_link({local, ?SERVER}, ?MODULE, []).

register(Key, Value) ->
    regine_server:register(?SERVER, self(), Key, Value).
unregister(Key) ->
    regine_server:unregister(?SERVER, Key, undefined).

lookup(Key) ->
    case ets:lookup(?SERVER, Key) of
	[{Key, _Pid, Value}] ->
	    Value;
	_ ->
	    undefined
    end.

all() ->
    ets:tab2list(?SERVER).

%%%===================================================================
%%% regine callbacks
%%%===================================================================

init([]) ->
    ets:new(?SERVER, [ordered_set, named_table, public, {keypos, 1}]),
    {ok, #state{}}.

handle_register(Pid, Id, Value, State) ->
    case ets:insert_new(?SERVER, {Id, Pid, Value}) of
	true ->  {ok, [Id], State};
	false -> {error, duplicate}
    end.

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
    Pids = [Pid || {_, Pid, _} <- ets:take(?SERVER, Key)],
    {Pids, State}.
