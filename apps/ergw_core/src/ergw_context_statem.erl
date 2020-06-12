%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_context_statem).

-behavior(gen_statem).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

%% API
-export([start_link/3, start_link/4, call/2, call/3, cast/2, send/2, with_context/2]).

-if(?OTP_RELEASE =< 23).
-ignore_xref([behaviour_info/1]).
-endif.

-ignore_xref([start_link/3, start_link/4, call/2, call/3, cast/2, send/2, with_context/2]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4, terminate/3, code_change/4]).

%% async FSM helpers
-export([next/5, send_request/1]).

-include_lib("kernel/include/logger.hrl").

-define(DEBUG_OPTS, [{install, {fun logger_sys_debug:logger_gen_statem_trace/3, ?MODULE}}]).

%%%=========================================================================
%%%  API
%%%=========================================================================

%% copied from gen_statem, simplyfied

-callback init(Args :: term(), Data :: map()) -> Result :: term().

-callback handle_event(
	    EvType :: term(), EvContent :: term(),
	    State :: map(),
	    Data :: map()) ->
    Result :: term().

-callback terminate(
	    Reason :: 'normal' | 'shutdown' | {'shutdown', term()}
		    | term(),
	    State :: map(),
	    Data :: map()) ->
    any().

-callback code_change(
	    OldVsn :: term() | {'down', term()},
	    OldState :: map(),
	    OldData :: map(),
	    Extra :: term()) ->
    {ok, NewState :: map(), NewData :: map()} |
    (Reason :: term()).

-callback get_record_meta(
	    Data :: map()) ->
    map().

-callback restore_session_state(
	    Data :: map()) ->
    map().

%%% -----------------------------------------------------------------

start_link(Handler, Args, SpawnOpts) when is_atom(Handler) ->
    LoopOpts = [{debug, ?DEBUG_OPTS}],
    start_link(Handler, Args, SpawnOpts, LoopOpts);

start_link(RecordId, SpawnOpts, LoopOpts) when is_binary(RecordId) ->
    proc_lib:start_link(?MODULE, init, [[self(), RecordId, LoopOpts]], infinity, SpawnOpts).

start_link(Handler, Args, SpawnOpts, LoopOpts) when is_atom(Handler) ->
    proc_lib:start_link(?MODULE, init, [[self(), Handler, Args, LoopOpts]], infinity, SpawnOpts).

call(Server, Request) ->
    call(Server, Request, infinity).

call(Server, Request, Timeout) ->
    with_context(Server,
		 fun(Pid) ->
			 try gen_statem:call(Pid, Request, Timeout)
			 catch exit:{Reason, _} -> {'EXIT', Reason}
			 end
		 end).

cast(Server, Msg) ->
    with_context(Server, gen_statem:cast(_, Msg)).

send(Server, Msg) ->
    with_context(Server, erlang:send(_, Msg)).

with_context_run(RecordId, Fun) ->
    case ergw_context_sup:run(RecordId) of
	{ok, Pid2} ->
	    Fun(Pid2);
	{already_started, Pid3} ->
	    Fun(Pid3);
	Other ->
	    Other
    end.

with_context(Pid, Fun) when is_pid(Pid), is_function(Fun, 1) ->
    Fun(Pid);
with_context(RecordId, Fun) when is_binary(RecordId), is_function(Fun, 1) ->
    case gtp_context_reg:whereis_name(RecordId) of
	Pid when is_pid(Pid) ->
	    case Fun(Pid) of
		{'EXIT', normal} ->
		    with_context_run(RecordId, Fun);
		Other ->
		    Other
	    end;
	_ ->
	    with_context_run(RecordId, Fun)
    end.

%%====================================================================
%% gen_statem API
%%====================================================================

-define(HANDLER, ?MODULE).

callback_mode() -> [handle_event_function, state_enter].

init([Parent, RecordId, LoopOpts]) ->
    case gtp_context_reg:register_name(RecordId, undefined, self()) of
	ok ->
	    proc_lib:init_ack(Parent, {ok, self()}),
	    case ergw_context:get_context_record(RecordId) of
		{ok, SState, Data} ->
		    State = ergw_context:init_state(SState),
		    enter_loop(LoopOpts, State#{fsm := idle}, Data, []);
		Other ->
		    erlang:exit(Other)
	    end;
	{error, duplicate} ->
	    Pid = gtp_context_reg:whereis_name(RecordId),
	    proc_lib:init_ack(Parent, {error, {already_started, Pid}})
    end;

init([Parent, Handler, Args, LoopOpts]) ->
    process_flag(trap_exit, true),
    proc_lib:init_ack(Parent, {ok, self()}),

    case Handler:init(Args, #{?HANDLER => Handler}) of
	{ok, State, Data} ->
	    init_new(LoopOpts, State, Data, []);
	{ok, State, Data, Actions} ->
	    init_new(LoopOpts, State, Data, Actions);
	InitR ->
	    case InitR of
		{stop, Reason} ->
		    exit(Reason);
		ignore ->
		    proc_lib:init_ack(Parent, ignore),
		    exit(normal);
		Else ->
		    Error = {bad_return_from_init, Else},
		    exit(Error)
	    end
    end.

init_new(LoopOpts, #{session := SState} = State, #{?HANDLER := Handler} = Data, Actions) ->
    Meta = Handler:get_record_meta(Data),
    ergw_context:create_context_record(SState, Meta, Data),
    enter_loop(LoopOpts, State, Data, Actions).

enter_loop(LoopOpts, State, #{?HANDLER := Handler} = Data0, Actions) ->
    Data = Handler:restore_session_state(Data0),
    gen_statem:enter_loop(?MODULE, LoopOpts, State, Data, Actions).

handle_event(enter, OldState, State, #{?HANDLER := Handler} = Data) ->
    Handler:handle_event(enter, OldState, State, Data);

handle_event({call, From}, handler, _State, #{?HANDLER := Handler}) ->
    {keep_state_and_data, [{reply, From, {ok, {Handler, self()}}}]};

handle_event(info, {{'DOWN', ReqId}, _, _, _, Info}, #{async := Async} = State, Data)
  when is_map_key(ReqId, Async) ->
    statem_m_continue(ReqId, {error, Info}, false, State, Data);
handle_event(info, {{'DOWN', _}, _, _, _, _}, _, _) ->
    keep_state_and_data;

handle_event(info, {'DOWN', _, process, ReqId, Info}, #{async := Async} = State, Data)
  when is_map_key(ReqId, Async) ->
    statem_m_continue(ReqId, {error, Info}, false, State, Data);

handle_event(info, {ReqId, Result}, #{async := Async} = State, Data)
  when is_map_key(ReqId, Async) ->
    statem_m_continue(ReqId, Result, false, State, Data);

%% OTP-24 style send_request responses.... WE REALLY SHOULD NOT BE DOING THIS
handle_event(info, {'DOWN', ReqId, _, _, Info}, #{async := Async} = State, Data)
  when is_map_key(ReqId, Async) ->
    statem_m_continue(ReqId, {error, Info}, false, State, Data);
handle_event(info, {[alias|ReqId], Result}, #{async := Async} = State, Data)
  when is_map_key(ReqId, Async) ->
    statem_m_continue(ReqId, Result, true, State, Data);

%% OTP-23 style send_request responses.... WE REALLY SHOULD NOT BE DOING THIS
handle_event(info, {{'$gen_request_id', ReqId}, Result}, #{async := Async} = State, Data)
  when is_map_key(ReqId, Async) ->
    statem_m_continue(ReqId, Result, true, State, Data);

handle_event(EventType, EventContent, State, #{?HANDLER := Handler} = Data) ->
    ?LOG(debug, "~p:handle_event:~nEventType: ~p~nEventContent: ~p~nState: ~p~nData: ~p~n",
	   [Handler, EventType, EventContent, State, Data]),
    R = (catch Handler:handle_event(EventType, EventContent, State, Data)),
    ?LOG(debug, "~p:handle_event: ->~nR: ~p~n", [Handler, R]),
    R.

terminate(Reason, State, #{?HANDLER := Handler} = Data) ->
    Handler:terminate(Reason, State, Data).

code_change(OldVsn, State, #{?HANDLER := Handler} = Data, Extra) ->
    Handler:code_change(OldVsn, State, Data, Extra).

%%====================================================================
%% async FSM helpers
%%====================================================================

next(StateFun, OkF, FailF, State0, Data0)
  when is_function(StateFun, 2),
       is_function(OkF, 3),
       is_function(FailF, 3) ->
    {Result, State, Data} = StateFun(State0, Data0),
    next(Result, OkF, FailF, State, Data);

next(ok, Fun, _, State, Data)
  when is_function(Fun, 3) ->
    Fun(ok, State, Data);
next({ok, Result}, Fun, _, State, Data)
  when is_function(Fun, 3) ->
    Fun(Result, State, Data);
next({error, Result}, _, Fun, State, Data)
  when is_function(Fun, 3) ->
    Fun(Result, State, Data);
next({wait, ReqId, Q}, OkF, FailF, #{async := Async} = State, Data)
  when (is_reference(ReqId) orelse is_pid(ReqId)),
       is_list(Q),
       is_function(OkF, 3),
       is_function(FailF, 3) ->
    Req = {ReqId, Q, OkF, FailF},
    {next_state, State#{async := maps:put(ReqId, Req, Async)}, Data}.

statem_m_continue(ReqId, Result, DeMonitor, #{async := Async0} = State, Data) ->
    {{Mref, Q, OkF, FailF}, Async} = maps:take(ReqId, Async0),
    case DeMonitor of
	true -> demonitor(Mref, [flush]);
	_ -> ok
    end,
    ?LOG(debug, "Result: ~p~n", [Result]),
    next(statem_m:response(Q, Result, _, _), OkF, FailF, State#{async := Async}, Data).

-if(?OTP_RELEASE =< 23).

send_request(Fun) when is_function(Fun, 0) ->
    Owner = self(),
    {Pid, _} = spawn_opt(fun() -> Owner ! {self(), Fun()} end, [monitor]),
    Pid.

-else.

send_request(Fun) when is_function(Fun, 0) ->
    Owner = self(),
    ReqId = make_ref(),
    Opts = [{monitor, [{tag, {'DOWN', ReqId}}]}],
    spawn_opt(fun() -> Owner ! {ReqId, Fun()} end, Opts),
    ReqId.

-endif.
