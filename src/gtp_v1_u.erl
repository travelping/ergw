%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_v1_u).

-export([handle_request/4]).

-include_lib("gtplib/include/gtp_packet.hrl").

%%====================================================================
%% API
%%====================================================================

handle_request(_Type, _TEI, _IEs, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
