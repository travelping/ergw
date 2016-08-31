-module(gtp_api).

-include_lib("gtplib/include/gtp_packet.hrl").

-callback handle_request(GtpPort :: term(),
			 Msg :: #gtp{},
			 RequestRecord :: term(),
			 State :: map()) ->
    Return :: {reply, Reply :: term(), State ::map()} |
	      {stop, Reply :: term(), State ::map()} |
	      {error, Reply :: term()} |
	      {noreply, State ::map()}.
