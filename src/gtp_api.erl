-module(gtp_api).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("ergw/include/ergw.hrl").

-callback init(Opts :: term(),
	       State :: map()) ->
    Return :: {ok, State ::map()} |
	      {stop, Reason :: term()}.

-callback handle_request(From :: {#gtp_port{}, IP :: inet:ip_address(), Port :: 0 .. 65535},
			 Msg :: #gtp{},
			 RequestRecord :: term(),
			 Resent :: boolean(),
			 State :: map()) ->
    Return :: {reply, Reply :: term(), State ::map()} |
	      {stop, Reply :: term(), State ::map()} |
	      {error, Reply :: term()} |
	      {noreply, State :: map()}.
