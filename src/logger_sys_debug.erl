%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(logger_sys_debug).

-export([logger_gen_fsm_trace/3, logger_gen_statem_trace/3, logger_gen_server_trace/3]).

-ignore_xref([?MODULE]).

-include_lib("kernel/include/logger.hrl").

%%-----------------------------------------------------------------
%% Format debug messages. Print them as the call-back module sees
%% them, not as the real erlang messages.
%%
%% This a copy of gen_event:print_event/3 modified for logger debug
%%-----------------------------------------------------------------
logger_gen_fsm_trace(FuncState, {in, Msg}, {Name, StateName}) ->
    case Msg of
	{'$gen_fsm', Event} ->
	    ?LOG(debug, "~p:~p got event ~p in state ~w", [FuncState, Name, Event, StateName]);
	{'$gen_all_state_event', Event} ->
	    ?LOG(debug, "~p:~p got all_state_event ~p in state ~w", [FuncState, Name, Event, StateName]);
	{timeout, Ref, {'$gen_timer', Message}} ->
	    ?LOG(debug, "~p:~p got timer ~p in state ~w", [FuncState, Name, {timeout, Ref, Message}, StateName]);
	{timeout, _Ref, {'$gen_fsm', Event}} ->
	    ?LOG(debug, "~p:~p got timer ~p in state ~w", [FuncState, Name, Event, StateName]);
	_ ->
	    ?LOG(debug, "~p:~p got ~p in state ~w~n", [FuncState, Name, Msg, StateName])
    end,
    FuncState;
logger_gen_fsm_trace(FuncState, {out, Msg, To, StateName}, Name) ->
    ?LOG(debug, "~p:~p sent ~p to ~w and switched to state ~w", [FuncState, Name, Msg, To, StateName]),
    FuncState;
logger_gen_fsm_trace(FuncState, return, {Name, StateName}) ->
    ?LOG(debug, "~p:~p switched to state ~w", [FuncState, Name, StateName]),
    FuncState.

%%-----------------------------------------------------------------
%% Format debug messages. Print them as the call-back module sees
%% them, not as the real erlang messages.
%%
%% This a copy of gen_statem:print_event/3 modified for logger debug
%%-----------------------------------------------------------------
logger_gen_statem_trace(FuncState, {in, Event, State}, Name) ->
    ?LOG(debug, "~tp receive ~ts in state ~tp~n",
	 [Name,event_string(Event),State]),
    FuncState;
logger_gen_statem_trace(FuncState, {code_change,Event,State}, Name) ->
    ?LOG(debug, "~tp receive ~ts after code change in state ~tp~n",
	 [Name,event_string(Event),State]),
    FuncState;
logger_gen_statem_trace(FuncState, {out,Reply,{To,_Tag}}, Name) ->
    ?LOG(debug, "~tp send ~tp to ~tw~n",
	 [Name,Reply,To]),
    FuncState;
logger_gen_statem_trace(FuncState, {enter,State}, Name) ->
    ?LOG(debug, "~tp enter in state ~tp~n",
	 [Name,State]),
    FuncState;
logger_gen_statem_trace(FuncState, {start_timer,Action,State}, Name) ->
    ?LOG(debug, "~tp start_timer ~tp in state ~tp~n",
	 [Name,Action,State]),
    FuncState;
logger_gen_statem_trace(FuncState, {insert_timeout,Event,State}, Name) ->
    ?LOG(debug, "~tp insert_timeout ~tp in state ~tp~n",
	 [Name,Event,State]),
    FuncState;
logger_gen_statem_trace(FuncState, {terminate,Reason,State}, Name) ->
    ?LOG(debug, "~tp terminate ~tp in state ~tp~n",
	 [Name,Reason,State]),
    FuncState;
logger_gen_statem_trace(FuncState, {Tag,Event,State,NextState}, Name)
			when Tag =:= postpone; Tag =:= consume ->
    StateString =
	case NextState of
	    State ->
		io_lib:format("~tp", [State]);
	    _ ->
		io_lib:format("~tp => ~tp", [State,NextState])
	end,
    ?LOG(debug, "~tp ~tw ~ts in state ~ts~n",
	 [Name,Tag,event_string(Event),StateString]),
    FuncState.

event_string(Event) ->
    case Event of
	{{call,{Pid,_Tag}},Request} ->
	    io_lib:format("call ~tp from ~tw", [Request,Pid]);
	{EventType,EventContent} ->
	    io_lib:format("~tw ~tp", [EventType,EventContent])
    end.

%%-----------------------------------------------------------------
%% Format debug messages. Print them as the call-back module sees
%% them, not as the real erlang messages.
%%
%% This a copy of gen_server:print_event/3 modified for logger debug
%%-----------------------------------------------------------------
logger_gen_server_trace(FuncState, {in, Msg}, Name) ->
    case Msg of
	{'$gen_call', {From, _Tag}, Call} ->
	    ?LOG(debug, "~p:~p got call ~p from ~w", [FuncState, Name, Call, From]);
	{'$gen_cast', Cast} ->
	    ?LOG(debug, "~p:~p got cast ~p", [FuncState, Name, Cast]);
	_ ->
	    ?LOG(debug, "~p:~p got ~p", [FuncState, Name, Msg])
    end,
    FuncState;
logger_gen_server_trace(FuncState, {out, Msg, To, State}, Name) ->
    ?LOG(debug, "~p:~p sent ~p to ~w, new state ~w", [FuncState, Name, Msg, To, State]),
    FuncState;
logger_gen_server_trace(FuncState, {noreply, State}, Name) ->
    ?LOG(debug, "~p:~p new state ~w", [FuncState, Name, State]),
    FuncState;
logger_gen_server_trace(FuncState, Event, Name) ->
    ?LOG(debug, "~p:~p dbg ~p", [FuncState, Name, Event]),
    FuncState.
