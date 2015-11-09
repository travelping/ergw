%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_v1_u).

-behaviour(gtp_protocol).

%% API
-export([gtp_msg_type/1,
	 build_response/1,
	 build_echo_request/0,
	 type/0, port/0]).

-include("include/epgw.hrl").

%%====================================================================
%% API
%%====================================================================

type() -> 'gtp-u'.
port() -> ?GTP1u_PORT.

build_echo_request() ->
    gtp_v1_c:build_echo_request().

build_response(Response) ->
    gtp_v1_c:build_response(Response).

gtp_msg_type(Type) ->
    gtp_v1_c:gtp_msg_type(Type).

%%%===================================================================
%%% Internal functions
%%%===================================================================
