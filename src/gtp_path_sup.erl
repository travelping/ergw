%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU Lesser General Public License
%% as published by the Free Software Foundation; either version
%% 3 of the License, or (at your option) any later version.

-module(gtp_path_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, new_path/4]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

new_path(GtpPort, Version, RemoteIP, Args) ->
    supervisor:start_child(?SERVER, [GtpPort, Version, RemoteIP, Args]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    {ok, {{simple_one_for_one, 5, 10},
	  [{gtp_path, {gtp_path, start_link, []}, temporary, 1000, worker, [gtp_path]}]}}.
