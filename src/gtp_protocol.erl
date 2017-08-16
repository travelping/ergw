%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU Lesser General Public License
%% as published by the Free Software Foundation; either version
%% 3 of the License, or (at your option) any later version.

-module(gtp_protocol).

-include_lib("gtplib/include/gtp_packet.hrl").

-callback gtp_msg_type(Type :: atom()) -> MsgType :: 'request' | 'response' | 'other'.

-callback build_response(Response :: term()) -> GtpReply :: #gtp{}.

-callback type() -> Type :: 'gtp-c' | 'gtp-u'.
-callback port() -> Port :: non_neg_integer().

-callback build_echo_request(GtpPort :: term()) -> EchoRequest :: #gtp{}.

-callback get_cause(IEs :: map()) -> Cause :: atom().
