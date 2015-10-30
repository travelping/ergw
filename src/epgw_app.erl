%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(epgw_app).

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
	   Pid <- epgw_sup:start_link(),
           return(Pid)
       ]).

stop(_State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================
