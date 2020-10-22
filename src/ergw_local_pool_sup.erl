%% Copyright 2015-2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_local_pool_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_ip_pool/2]).

-ignore_xref([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_ip_pool(Pool, Opts) ->
    supervisor:start_child(?SERVER, [Pool, Opts, []]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    ChildSpec =
	#{id       => local_pool,
	  start    => {ergw_local_pool, start_link, []},
	  restart  => temporary,
	  shutdown => 1000,
	  type     => worker,
	  modules  => [ergw_local_pool]},
    {ok, {{simple_one_for_one, 5, 10}, [ChildSpec]}}.
