-module(gtp_protocol).

-if(?OTP_RELEASE =< 23).
-ignore_xref([behaviour_info/1]).
-endif.

-include_lib("gtplib/include/gtp_packet.hrl").

-callback gtp_msg_type(Type :: atom()) -> MsgType :: 'request' | 'response' | 'other'.

-callback build_response(Response :: term()) -> GtpReply :: #gtp{}.

-callback type() -> Type :: 'gtp-c' | 'gtp-u'.
-callback port() -> Port :: non_neg_integer().

-callback build_echo_request() -> EchoRequest :: #gtp{}.

-callback get_cause(IEs :: map()) -> Cause :: atom().
