%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(tdf_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, new/5, new/6]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

new(Node, VRF, IP4, IP6, SxOpts) ->
    Opts = [{hibernate_after, 500},
	    {spawn_opt,[{fullsweep_after, 0}]}],
    new(Node, VRF, IP4, IP6, SxOpts, Opts).

new(Node, VRF, IP4, IP6, SxOpts, Opts) ->
    lager:debug("new(~p)", [[Node, VRF, IP4, IP6, SxOpts, Opts]]),
    supervisor:start_child(?SERVER, [Node, VRF, IP4, IP6, SxOpts, Opts]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, {{simple_one_for_one, 5, 10},
	  [{tdf, {tdf, start_link, []}, temporary, 1000, worker, [tdf]}]}}.
