%% Copyright 2016,2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU Lesser General Public License
%% as published by the Free Software Foundation; either version
%% 3 of the License, or (at your option) any later version.

-module(gtp_api).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("ergw/include/ergw.hrl").

-optional_callbacks([handle_response/4]).

-callback validate_options(Opts :: [{Key :: atom(), Value :: term()}]) ->
    Return :: #{Key :: atom() => Value :: term()}.

-callback init(Opts :: term(),
	       State :: map()) ->
    Return :: {ok, State ::map()} |
	      {stop, Reason :: term()}.

-callback request_spec(Version :: 'v1' | 'v2', MsgType :: atom(), Cause :: atom()) ->
    Return :: [{ { IE :: atom(), Instance :: 0..255 }, 'optional' | 'mandatory' }].

-callback handle_call(Request:: term(), From :: {pid(), reference()},
		      State :: map()) ->
    Result :: {reply, Reply :: term(), NewState :: map()} |
	      {reply, Reply :: term(), NewState :: map(),
	       Timeout :: integer() | 'infinity'} |
	      {reply, Reply :: term(), NewState :: map(), 'hibernate'} |
	      {noreply, NewState :: map()} |
	      {noreply, NewState :: map(), Timeout :: integer() | 'infinity'} |
	      {noreply, NewState :: map(), 'hibernate'} |
	      {stop, Reason :: term(), Reply :: term(), NewState :: map()} |
	      {stop, Reason :: term(), NewState :: map()}.

-callback handle_cast(Request:: term(), State :: map()) ->
    Result :: {noreply, NewState :: map()} |
	      {noreply, NewState :: map(), Timeout :: integer() | 'infinity'} |
	      {noreply, NewState :: map(), 'hibernate'} |
	      {stop, Reason :: term(), NewState :: map()}.

-callback handle_info(Info:: term(), State :: map()) ->
    Result :: {noreply, NewState :: map()} |
	      {noreply, NewState :: map(), Timeout :: integer() | 'infinity'} |
	      {noreply, NewState :: map(), 'hibernate'} |
	      {stop, Reason :: term(), NewState :: map()}.

-callback handle_request(ReqKey :: #request{},
			 Msg :: #gtp{},
			 Resent :: boolean(),
			 State :: map()) ->
    Return :: {reply, Reply :: term(), State :: map()} |
	      {stop, Reply :: term(), State :: map()} |
	      {error, Reply :: term()} |
	      {noreply, State :: map()}.

-callback handle_response(RequestInfo :: term(),
			  Response :: #gtp{},
			  Request  :: #gtp{},
			  State :: map()) ->
    Result :: {noreply, NewState :: map()} |
	      {noreply, NewState :: map(), Timeout :: integer() | 'infinity'} |
	      {noreply, NewState :: map(), 'hibernate'} |
	      {stop, Reason :: term(), NewState :: map()}.
