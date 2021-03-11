%% Copyright 2015-2020 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_socket_reg).

-behaviour(regine_server).

%% API
-export([start_link/0]).
-export([register/3, lookup/2, waitfor/2]).
-export([all/0]).

-ignore_xref([start_link/0]).

%% regine_server callbacks
-export([init/1, handle_register/4, handle_unregister/3, handle_pid_remove/3,
	 handle_death/3, handle_call/3, terminate/2]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------

-define(SERVER, ?MODULE).

-record(state, {waitfor = #{}}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    regine_server:start_link({local, ?SERVER}, ?MODULE, []).

register(Type, Name, Value) ->
    regine_server:register(?SERVER, self(), {Type, Name}, Value).

%% unregister(Type, Name) ->
%%     regine_server:unregister(?SERVER, {Type, Name}, undefined).

lookup(Type, Name) ->
    Key = {Type, Name},
    case ets:lookup(?SERVER, Key) of
	[{Key, _Pid, Value}] ->
	    Value;
	_ ->
	    undefined
    end.

waitfor(Type, Name) ->
    regine_server:call(?SERVER, {waitfor, {Type, Name}}, infinity).

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
	true ->  {ok, [Id], notify(Id, Value, State)};
	false -> {error, duplicate}
    end.

handle_unregister(Key, _Value, State) ->
    Pids = [Pid || {_, Pid, _} <- ets:take(?SERVER, Key)],
    {Pids, State}.

handle_pid_remove(_Pid, Keys, State) ->
    lists:foreach(fun(Key) -> ets:delete(?SERVER, Key) end, Keys),
    State.

handle_death(_Pid, _Reason, State) ->
    State.

handle_call({waitfor, Key}, From, #state{waitfor = WF} = State) ->
    case ets:lookup(?SERVER, Key) of
	[{Key, _Pid, Value}] ->
	    {reply, Value, State};
	_ ->
	    {noreply, State#state{waitfor = WF#{Key => From}}}
    end.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

notify(Key, Value, #state{waitfor = WF0} = State) ->
    case maps:take(Key, WF0) of
	{From, WF} ->
	    gen_server:reply(From, Value),
	    State#state{waitfor = WF};
	_ ->
	    State
    end.
