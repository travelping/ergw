%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_app).

-compile({parse_transform, cut}).
-compile({parse_transform, do}).

-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%%===================================================================
%%% Application callbacks
%%%===================================================================

start(_StartType, _StartArgs) ->
    do([error_m ||
	   gtp_config:init(),
	   ensure_jobs_queues(),
	   Pid <- ergw_sup:start_link(),
	   ergw_config:load_config(setup:get_all_env(ergw)),
	   return(Pid)
       ]).

stop(_State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

ensure_jobs_queues() ->
    ensure_jobs_queue(path_restart, [{standard_counter, 100}]),
    ensure_jobs_queue(create, [{standard_rate, 100}, {max_size, 10}]),
    ensure_jobs_queue(delete, [{standard_counter, 100}]),
    ensure_jobs_queue(other, [{standard_rate, 100}, {max_size, 10}]),
    ok.

ensure_jobs_queue(Name, Options) ->
    case jobs:queue_info(Name) of
        undefined -> jobs:add_queue(Name, Options);
        {queue, _Props} -> ok
    end.
