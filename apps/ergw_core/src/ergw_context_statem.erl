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
-export([start_link/3]).

-if(?OTP_RELEASE =< 23).
-ignore_xref([behaviour_info/1]).
-endif.

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4, terminate/3, code_change/4]).

%% async FSM helpers
-export([next/5, send_request/1]).

-include_lib("kernel/include/logger.hrl").

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

%%% -----------------------------------------------------------------

start_link(Handler, Args, Opts) ->
    proc_lib:start_link(?MODULE, init, [{[Handler | Args], Opts}]).

%%====================================================================
%% gen_statem API
%%====================================================================

-define(HANDLER, ?MODULE).

callback_mode() -> [handle_event_function, state_enter].

init({[Handler | Args], LoopOpts}) ->
    process_flag(trap_exit, true),
    proc_lib:init_ack({ok, self()}),
    {ok, State, LoopData} = Handler:init(Args, #{?HANDLER => Handler}),
    gen_statem:enter_loop(?MODULE, LoopOpts, State, LoopData).

handle_event(enter, OldState, State, #{?HANDLER := Handler} = Data) ->
    Handler:handle_event(enter, OldState, State, Data);

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
