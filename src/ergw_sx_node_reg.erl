%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sx_node_reg).

-behaviour(regine_server).

%% API
-export([start_link/0]).
-export([register/2, lookup/1, up/2, down/1, available/0]).
-export([all/0]).
-export([count_available/0, count_monitors/1]).

-ignore_xref([start_link/0, all/0]).

%% regine_server callbacks
-export([init/1, handle_register/4, handle_unregister/3, handle_pid_remove/3,
	 handle_death/3, handle_call/3, terminate/2]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    regine_server:start_link({local, ?SERVER}, ?MODULE, []).

register(Key, Pid) when is_pid(Pid) ->
    regine_server:register(?SERVER, Pid, Key, undefined).

%% unregister(Key) ->
%%     regine_server:unregister(?SERVER, Key, undefined).

lookup(Key) ->
    case ets:lookup(?SERVER, Key) of
	[{Key, Pid}] ->
	    {ok, Pid};
	_ ->
	    {error, not_found}
    end.

up(Key, Caps) ->
    regine_server:call(?SERVER, {up, Key, Caps}).

down(Key) ->
    regine_server:call(?SERVER, {down, Key}).

available() ->
    regine_server:call(?SERVER, available).

all() ->
    ets:tab2list(?SERVER).

count_available() ->
    maps:size(available()).

count_monitors(Pid) ->
    case process_info(Pid, monitored_by) of
        {monitored_by, Monitors} ->
            length(Monitors);
        _ ->
            0
    end.

%%%===================================================================
%%% regine callbacks
%%%===================================================================

init([]) ->
    ets:new(?SERVER, [ordered_set, named_table, public, {keypos, 1}]),
    {ok, #{}}.

handle_register(Pid, Id, _Value, State) ->
    case ets:insert_new(?SERVER, {Id, Pid}) of
	true ->  {ok, [Id], State};
	false -> {error, duplicate}
    end.

handle_unregister(Key, _Value, State) ->
    unregister(Key, State).

handle_pid_remove(_Pid, Keys, State) ->
    lists:foreach(fun(Key) -> ets:delete(?SERVER, Key) end, Keys),
    maps:without(Keys, State).

handle_death(_Pid, _Reason, State) ->
    State.

handle_call({up, Key, Caps}, _From, State) ->
    case lookup(Key) of
	{ok, Pid} ->
	    {reply, ok, maps:put(Key, {Pid, Caps}, State)};
	Other ->
	    {reply, Other, State}
    end;

handle_call({down, Key}, _From, State) ->
    {reply, ok, maps:remove(Key, State)};

handle_call(available, _From, State) ->
    State.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

unregister(Key, State) ->
    Pids = [Pid || {_, Pid} <- ets:take(?SERVER, Key)],
    {Pids, maps:remove(Key, State)}.
