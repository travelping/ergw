%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sx_node_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, new/3]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

new(Node, IP4, IP6)->
    supervisor:start_child(?SERVER, [Node, IP4, IP6]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, {{simple_one_for_one, 5, 10},
	  [{ergw_sx_node, {ergw_sx_node, start_link, []},
	    transient, 1000, worker, [ergw_sx_node]}]}}.
