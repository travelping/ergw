%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(vrf_reg).

-behaviour(regine_server).

%% API
-export([start_link/0]).
-export([register/1, lookup/1]).
-export([all/0]).

%% regine_server callbacks
-export([init/1, handle_register/4, handle_unregister/3, handle_pid_remove/3, handle_death/3, terminate/2]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include("include/ergw.hrl").

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    regine_server:start_link({local, ?SERVER}, ?MODULE, []).

register(APN) ->
    regine_server:register(?SERVER, self(), APN, undefined).

lookup(APN) ->
    case ets:lookup(?SERVER, APN) of
	[{_, Pid}] ->
	    Pid;
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

handle_register(Pid, APN, _Value, State) ->
    case ets:insert_new(?SERVER, {APN, Pid}) of
	true ->  {ok, [APN], State};
	false -> {error, duplicate}
    end.

handle_unregister(APN, _Value, State) ->
    do_unregister(APN, State).

handle_pid_remove(_Pid, APNs, State) ->
    lists:foreach(fun(APN) -> ets:delete(?SERVER, APN) end, APNs),
    State.

handle_death(_Pid, _Reason, State) ->
    State.

terminate(_Reason, _State) ->
	ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

do_unregister(APN, State) ->
    Pids = case ets:lookup(?SERVER, APN) of
	       [{APN, Pid}] ->
		   ets:delete(?SERVER, APN),
		   [Pid];
	       _ -> []
	   end,
    {Pids, State}.
