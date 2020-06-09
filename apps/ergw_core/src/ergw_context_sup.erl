%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_context_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, new/2, new/3, run/1, run/2]).

-ignore_xref([start_link/0, new/3, run/2]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-define(DEBUG_OPTS, []).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

new(Handler, Args) ->
    Opts = [{hibernate_after, 500},
	    {spawn_opt,[{fullsweep_after, 0}]}],
    new(Handler, Args, Opts).

new(Handler, Args, Opts) ->
    ?LOG(debug, "new(~p)", [[Handler, Args, Opts]]),
    SpawnOpts = proplists:get_value(spawn_opt, Opts, []),
    supervisor:start_child(?SERVER, [Handler, Args, SpawnOpts, Opts]).

run(RecordId) ->
    Opts = [{hibernate_after, 500},
	    {spawn_opt,[{fullsweep_after, 0}]},
	    {debug, ?DEBUG_OPTS}],
    run(RecordId, Opts).

run(RecordId, Opts) ->
    ?LOG(debug, "run(~p)", [[RecordId, Opts]]),
    SpawnOpts = proplists:get_value(spawn_opt, Opts, []),
    supervisor:start_child(?SERVER, [RecordId, SpawnOpts, Opts]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    SubFlags =
	#{strategy  => simple_one_for_one,
	  intensity => 5,
	  period    => 10},
    ChildSpec =
	  #{id       => ergw_context_statem,
	     start    => {ergw_context_statem, start_link, []},
	     restart  => temporary,
	     shutdown => 1000,
	     type     => worker,
	     modules  => [ergw_context_statem]},
    {ok, {SubFlags, [ChildSpec]}}.
