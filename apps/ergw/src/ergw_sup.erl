%% Copyright 2021, Travelping GmbH <info@travelping.com>

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

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Config) ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, Config).

%% ===================================================================
%% Supervisor callbacks
%% ===================================================================

%% sup_flags() = #{strategy => strategy(),         % optional
%%                 intensity => non_neg_integer(), % optional
%%                 period => pos_integer()}        % optional
%% child_spec() = #{id => child_id(),       % mandatory
%%                  start => mfargs(),      % mandatory
%%                  restart => restart(),   % optional
%%                  shutdown => shutdown(), % optional
%%                  type => worker(),       % optional
%%                  modules => modules()}   % optional
init(Config) ->
    SupFlags = #{strategy => one_for_all,
		 intensity => 0,
		 period => 1},
    ChildSpecs =
	[#{id       => ergw,
	   start    => {ergw, start_link, [Config]},
	   restart  => permanent,
	   shutdown => 5000,
	   type     => worker,
	   modules  => [ergw]}],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
