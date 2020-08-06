%% Copyright 2015-2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_ip_pool_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_local_pool_sup/0, start_dhcp_pool_sup/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_local_pool_sup() ->
    ChildSpecs =
	[#{id      => ergw_local_pool_reg,
	   start   => {ergw_local_pool_reg, start_link, []},
	   restart => permanent,
	   type    => worker,
	   modules => [ergw_local_pool_reg]},
	 #{id      => ergw_local_pool_sup,
	   start   => {ergw_local_pool_sup, start_link, []},
	   restart => permanent,
	   type    => supervisor,
	   modules => [ergw_local_pool_sup]}],
    [supervisor:start_child(?SERVER, Cs) || Cs <- ChildSpecs],
    ok.

start_dhcp_pool_sup() ->
    ChildSpecs =
	[#{id      => ergw_dhcp_socket,
	   start   => {ergw_dhcp_socket, start_link, []},
	   restart => permanent,
	   type    => worker,
	   modules => [ergw_dhcp_pool_reg]},
	 #{id      => ergw_dhcp_pool_reg,
	   start   => {ergw_dhcp_pool_reg, start_link, []},
	   restart => permanent,
	   type    => worker,
	   modules => [ergw_dhcp_pool_reg]},
	 #{id      => ergw_dhcp_pool_sup,
	   start   => {ergw_dhcp_pool_sup, start_link, []},
	   restart => permanent,
	   type    => supervisor,
	   modules => [ergw_dhcp_pool_sup]}],
    [supervisor:start_child(?SERVER, Cs) || Cs <- ChildSpecs],
    ok.

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, {{one_for_one, 5, 10}, []}}.
