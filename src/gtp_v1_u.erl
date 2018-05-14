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
	 build_echo_request/1,
	 type/0, port/0,
	 get_cause/1,
	 gtp_msg_types/0]).

-include("include/ergw.hrl").

%%====================================================================
%% API
%%====================================================================

type() -> 'gtp-u'.
port() -> ?GTP1u_PORT.

build_echo_request(GtpPort) ->
    gtp_v1_c:build_echo_request(GtpPort).

build_response(Response) ->
    gtp_v1_c:build_response(Response).

gtp_msg_type(Type) ->
    gtp_v1_c:gtp_msg_type(Type).

get_cause(_) ->
    undefined.

gtp_msg_types() ->
    [echo_request,
     echo_response,
     version_not_supported,
     g_pdu].

%%%===================================================================
%%% Internal functions
%%%===================================================================
