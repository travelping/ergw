%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_dhcp_pool_reg).

-behaviour(regine_server).

%% API
-export([start_link/0]).
-export([register/1, lookup/1, match/1]).
-export([all/0]).

%% regine_server callbacks
-export([init/1, handle_register/4, handle_unregister/3, handle_pid_remove/3,
	 handle_death/3, handle_call/3, terminate/2]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include("include/ergw.hrl").

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    regine_server:start_link({local, ?SERVER}, ?MODULE, []).

register(Pool) ->
    regine_server:register(?SERVER, self(), Pool, undefined).

lookup(Pool) when is_binary(Pool) ->
    regine_server:call(?SERVER, {lookup, Pool}).

match(Pools) when is_list(Pools) ->
    regine_server:call(?SERVER, {match, Pools}).

all() ->
    regine_server:call(?SERVER, all).

%%%===================================================================
%%% regine callbacks
%%%===================================================================

init([]) ->
    {ok, #{}}.

handle_register(_Pid, Pool, _Value, State)
  when is_map_key(Pool, State) ->
    {error, duplicate};
handle_register(Pid, Pool, _Value, State) ->
    {ok, [Pool], maps:put(Pool, Pid, State)}.

handle_unregister(Pool, _Value, State)
  when is_map_key(Pool, State) ->
    [[maps:get(Pool, State)], maps:remove(Pool, State)];
handle_unregister(_Pool, _Value, State) ->
    {[], State}.

handle_pid_remove(_Pid, Pools, State) ->
    maps:without(Pools, State).

handle_death(_Pid, _Reason, State) ->
    State.

handle_call({lookup, Pool}, _From, State) ->
    maps:get(Pool, State, undefined);

handle_call({match, Pools}, _From, State) ->
    maps:to_list(maps:with(Pools, State));

handle_call(all, _From, State) ->
    maps:to_list(State).

terminate(_Reason, _State) ->
	ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
