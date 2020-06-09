%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, new/5, run/1]).

-ignore_xref([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

new(Socket, Info, Version, Interface, IfOpts) ->
    Opts = [{hibernate_after, 500},
	    {spawn_opt,[{fullsweep_after, 0}]}],
    new(Socket, Info, Version, Interface, IfOpts, Opts).

new(Socket, Info, Version, Interface, IfOpts, Opts) ->
    ?LOG(debug, "new(~p)", [[Socket, Info, Version, Interface, IfOpts, Opts]]),
    supervisor:start_child(?SERVER, [Socket, Info, Version, Interface, IfOpts, Opts]).

run(RecordId) ->
    Opts = [{hibernate_after, 500},
	    {spawn_opt,[{fullsweep_after, 0}]},
	    {debug, [log]}
	   ],
    run(RecordId, Opts).

run(RecordId, Opts) ->
    ?LOG(debug, "run(~p)", [[RecordId, Opts]]),
    supervisor:start_child(?SERVER, [RecordId, Opts]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, {{simple_one_for_one, 5, 10},
	  [{gtp_context, {gtp_context, start_link, []}, temporary, 1000, worker, [gtp_context]}]}}.
