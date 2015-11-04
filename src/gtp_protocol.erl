-module(gtp_protocol).

-include_lib("gtplib/include/gtp_packet.hrl").

-callback gtp_msg_type(Type :: atom()) -> MsgType :: 'request' | 'response' | 'other'.

-callback build_response(Response :: term()) -> GtpReply :: #gtp{}.
