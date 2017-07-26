%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_reg).

-behaviour(regine_server).

%% API
-export([start_link/0]).
-export([register/2, register/3, unregister/2, lookup/2]).
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

register(GtpPort, Ident) ->
    register(GtpPort, Ident, self()).

register(#gtp_port{name = PortName}, Ident, Pid) ->
    Key = {PortName, Ident},
    regine_server:register(?SERVER, Pid, Key, undefined).

unregister(#gtp_port{name = PortName}, Ident) ->
    Key = {PortName, Ident},
    regine_server:unregister(?SERVER, Key, undefined).

lookup(#gtp_port{name = PortName}, Ident) ->
    Key = {PortName, Ident},
    case ets:lookup(?SERVER, Key) of
	[{Key, Pid}] ->
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

handle_register(Pid, Key, _Value, State) ->
    case ets:insert_new(?SERVER, {Key, Pid}) of
	true ->  {ok, [Key], State};
	false -> {error, duplicate}
    end.

handle_unregister(Key, _Value, State) ->
    do_unregister(Key, State).

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

do_unregister(Key, State) ->
    Pids = [Pid || {_, Pid} <- ets:take(?SERVER, Key)],
    {Pids, State}.
