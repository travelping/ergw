%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, start_sx_socket/1]).

%% Supervisor callbacks
-export([init/1]).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type, Args), {I, {I, start_link, Args}, permanent, 5000, Type, [I]}).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

start_sx_socket(Opts) ->
    {ok, _} = supervisor:start_child(?MODULE, ?CHILD(ergw_sx_socket, worker, [Opts])).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, {{one_for_one, 5, 10}, [?CHILD(gtp_path_reg, worker, []),
				 ?CHILD(gtp_path_sup, supervisor, []),
				 ?CHILD(gtp_context_reg, worker, []),
				 ?CHILD(gtp_context_sup, supervisor, []),
				 ?CHILD(tdf_sup, supervisor, []),
				 ?CHILD(ergw_gtp_socket_reg, worker, []),
				 ?CHILD(ergw_gtp_socket_sup, supervisor, []),
				 ?CHILD(ergw_sx_node_reg, worker, []),
				 ?CHILD(ergw_sx_node_sup, supervisor, []),
				 ?CHILD(gtp_proxy_ds, worker, []),
				 ?CHILD(vrf_reg, worker, []),
				 ?CHILD(vrf_sup, supervisor, []),
				 ?CHILD(ergw, worker, [])
				]} }.
