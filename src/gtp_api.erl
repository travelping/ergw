-module(gtp_api).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("ergw/include/ergw.hrl").

-optional_callbacks([handle_response/5]).

-callback validate_options(Opts :: [{Key :: atom(), Value :: term()}]) ->
    Return :: #{Key :: atom() => Value :: term()}.

-callback init(Opts :: term(),
	       Data :: map()) ->
    Return :: {ok, Data :: map()} |
	      {stop, Reason :: term()}.

-callback request_spec(Version :: 'v1' | 'v2', MsgType :: atom(), Cause :: atom()) ->
    Return :: [{ { IE :: atom(), Instance :: 0..255 }, 'optional' | 'mandatory' }].

-callback handle_event(
	    'enter',
	    OldState :: gen_statem:state(),
	    State, % Current state
	    Data :: map()) ->
    gen_statem:state_enter_result(State);
	   (gen_statem:event_type(),
	    EventContent :: term(),
	    State :: gen_statem:state(), % Current state
	    Data :: map()) ->
    gen_statem:event_handler_result(gen_statem:state()).

-callback handle_pdu(ReqKey :: #request{},
		     Msg :: #gtp{},
		     State :: gen_statem:state(), % Current state
		     Data :: map()) ->
    gen_statem:event_handler_result(gen_statem:state()).

-callback handle_request(ReqKey :: #request{},
			 Msg :: #gtp{},
			 Resent :: boolean(),
			 State :: gen_statem:state(), % Current state
			 Data :: map()) ->
    Return :: {reply, Reply :: term(), Data :: map()} |
	      {stop, Reply :: term(), Data :: map()} |
	      {error, Reply :: term()} |
	      {noreply, Data :: map()}.

-callback handle_response(RequestInfo :: term(),
			  Response :: #gtp{},
			  Request  :: #gtp{},
			  State :: gen_statem:state(), % Current state
			  Data :: map()) ->
    Result :: {noreply, NewData :: map()} |
	      {noreply, NewData :: map(), Timeout :: integer() | 'infinity'} |
	      {noreply, NewData :: map(), 'hibernate'} |
	      {stop, Reason :: term(), NewData :: map()}.

-callback handle_sx_report(Msg :: #pfcp{},
			   State :: gen_statem:state(), % Current state
			   Data :: map()) ->
    Return :: {reply, Reply :: term(), NewData :: map()} |
	      {ok, NewData :: map()} |
	      {stop, NewData :: map()} |
	      {error, Reply :: term(), NewData :: map()} |
	      {noreply, NewData :: map()}.

-callback session_events(Session :: list() | map(),
			 Events :: list(),
			 State :: gen_statem:state(), % Current state
			 Data :: map()) ->
    Data :: map().

%% Clean up before the server terminates.
-callback terminate(
	    Reason :: 'normal' | 'shutdown' | {'shutdown', term()}
		    | term(),
	    State :: gen_statem:state(),
	    Data :: gen_statem:data()) ->
    any().
