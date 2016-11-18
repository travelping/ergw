-module(gtp_protocol).

-include_lib("gtplib/include/gtp_packet.hrl").

-callback gtp_msg_type(Type :: atom()) -> MsgType :: 'request' | 'response' | 'other'.

-callback build_response(Response :: term()) -> GtpReply :: #gtp{}.

-callback type() -> Type :: 'gtp-c' | 'gtp-u'.
-callback port() -> Port :: non_neg_integer().

-callback build_echo_request(GtpPort :: term()) -> EchoRequest :: #gtp{}.
