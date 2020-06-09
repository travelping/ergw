%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sup).

-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type, Args), {I, {I, start_link, Args}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link(Config) ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, [Config]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([Config]) ->
    ok = ergw_node_selection_cache:init(),
    {ok, {{one_for_one, 5, 10},
	  ergw_nudsf:get_childspecs(Config) ++
	      [?CHILD(gtp_path_reg, worker, []),
	       ?CHILD(ergw_tei_mngr, worker, [Config]),
	       ?CHILD(ergw_timer_service, worker, []),
	       ?CHILD(gtp_path_sup, supervisor, []),
	       ?CHILD(gtp_context_reg, worker, []),
	       ?CHILD(gtp_context_sup, supervisor, []),
	       ?CHILD(tdf_sup, supervisor, []),
	       ?CHILD(ergw_socket_reg, worker, []),
	       ?CHILD(ergw_socket_sup, supervisor, []),
	       ?CHILD(ergw_sx_node_reg, worker, []),
	       ?CHILD(ergw_sx_node_sup, supervisor, []),
	       ?CHILD(ergw_sx_node_mngr, worker, []),
	       ?CHILD(gtp_proxy_ds, worker, []),
	       ?CHILD(ergw_ip_pool_sup, supervisor, []),
	       ?CHILD(ergw, worker, [])
	      ]} }.
