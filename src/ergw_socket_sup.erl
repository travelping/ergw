%% Copyright 2015-2020 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_socket_sup).

-behaviour(supervisor).

%% API
-export([start_link/0, new/2]).

-ignore_xref([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%% ===================================================================
%% API functions
%% ===================================================================

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

new(Type, Socket)->
    supervisor:start_child(?SERVER, [Type, Socket]).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

init([]) ->
    SubFlags =
	#{strategy  => simple_one_for_one,
	  intensity => 5,
	  period    => 10},
    ChildSpec =
	#{id       => ergw_socket,
	  start    => {ergw_socket, start_link, []},
	  restart  => transient,
	  shutdown => 1000,
	  type     => worker,
	  modules  => dynamic},

    {ok, {SubFlags, [ChildSpec]}}.
