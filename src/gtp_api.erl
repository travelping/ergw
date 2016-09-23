-module(gtp_api).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("ergw/include/ergw.hrl").

-optional_callbacks([handle_response/5]).

-callback init(Opts :: term(),
	       State :: map()) ->
    Return :: {ok, State ::map()} |
	      {stop, Reason :: term()}.

-callback handle_cast(Request:: term(), State :: map()) ->
    Result :: {noreply, NewState :: map()} |
	      {noreply, NewState :: map(), Timeout :: integer() | 'infinity'} |
	      {noreply, NewState :: map(), 'hibernate'} |
	      {stop, Reason :: term(), NewState :: map()}.

-callback handle_request(From :: {#gtp_port{}, IP :: inet:ip_address(), Port :: 0 .. 65535},
			 Msg :: #gtp{},
			 RequestRecord :: term(),
			 Resent :: boolean(),
			 State :: map()) ->
    Return :: {reply, Reply :: term(), State :: map()} |
	      {stop, Reply :: term(), State :: map()} |
	      {error, Reply :: term()} |
	      {noreply, State :: map()}.

-callback handle_response(RequestInfo :: term(),
			  Response :: #gtp{},
			  ResponseRecord :: term(),
			  Request  :: #gtp{},
			  State :: map()) ->
    Result :: {noreply, NewState :: map()} |
	      {noreply, NewState :: map(), Timeout :: integer() | 'infinity'} |
	      {noreply, NewState :: map(), 'hibernate'} |
	      {stop, Reason :: term(), NewState :: map()}.
