%% Copyright 2016-2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_local_pool_reg).

-behaviour(regine_server).

%% API
-export([start_link/0]).
-export([register/1, lookup/1]).
-export([all/0]).

-ignore_xref([start_link/0, all/0]).

%% regine_server callbacks
-export([init/1, handle_register/4, handle_unregister/3, handle_pid_remove/3,
	 handle_death/3, terminate/2]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include("include/ergw.hrl").

-define(SERVER, ?MODULE).
-define(TAB, ?MODULE).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    regine_server:start_link({local, ?SERVER}, ?MODULE, []).

register(Pool) ->
    regine_server:register(?SERVER, self(), Pool, undefined).

lookup(Pool) when is_binary(Pool) ->
    case ets:lookup(?TAB, Pool) of
	[{_, Pid}] -> Pid;
	_ -> undefined
    end.

all() ->
    ets:tab2list(?TAB).

%%%===================================================================
%%% regine callbacks
%%%===================================================================

init([]) ->
    ets:new(?TAB, [named_table, set, protected, {keypos, 1}, {read_concurrency, true}]),
    {ok, state}.

handle_register(Pid, Pool, _Value, State) ->
    case ets:insert_new(?TAB, {Pool, Pid}) of
	false -> {error, duplicate};
	true  -> {ok, [Pool], State}
    end.

handle_unregister(Pool, _Value, State) ->
    Objs = ets:take(?TAB, Pool),
    {[Pid || {_, Pid} <- Objs], State}.

handle_pid_remove(_Pid, Pools, State) ->
    [ets:delete(?TAB, Pool) || Pool <- Pools],
    State.

handle_death(_Pid, _Reason, State) ->
    State.

terminate(_Reason, _State) ->
	ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
