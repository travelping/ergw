%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% Cluster wide, redundanten timer service -- NOT YET
%%  for the moment, just a thin shim over the stdlib timer module

-module(ergw_timer_service).

-compile({no_auto_import,[apply/3]}).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([apply/4, cancel/1]).

-ignore_xref([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {tid, ids}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

apply(Id, MF, OldTimesAndEvs, NewTimesAndEvs) ->
    gen_server:call(?SERVER, {apply, Id, MF, OldTimesAndEvs, NewTimesAndEvs}).

cancel(Id) ->
    gen_server:call(?SERVER, {cancel, Id}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    TID = ets:new(?MODULE, [ordered_set, private, {keypos, 1}]),
    {ok, #state{tid = TID, ids = #{}}, infinity}.

handle_call({apply, Id, MF, OldTimesAndEvs, NewTimesAndEvs}, _From,
	    #state{tid = TID, ids = Ids} = State0) ->
    maps:fold(
      fun(Time, _Evs, _) -> ets:delete(TID, {Time, Id}) end, ok, OldTimesAndEvs),
    maps:fold(
      fun(Time, Evs, _) -> ets:insert(TID, {{Time, Id}, Evs}) end, ok, NewTimesAndEvs),
    State = State0#state{ids = Ids#{Id => {MF, NewTimesAndEvs}}},
    {reply, ok, State, next_timeout(State)};

handle_call({cancel, Id}, _From, #state{tid = TID, ids = Ids} = State0) ->
    case Ids of
	#{Id := {_, TimesAndEvs}} ->
	    maps:fold(
	      fun(Time, _Evs, _) -> ets:delete(TID, {Time, Id}) end, ok, TimesAndEvs),
	    State = State0#state{ids = maps:remove(Id, Ids)},
	    {reply, ok, State, next_timeout(State)};
	_ ->
	    {reply, ok, State0, next_timeout(State0)}
    end.

handle_cast(_Request, State) ->
    {noreply, State, next_timeout(State)}.

handle_info(timeout, State0) ->
    Now = erlang:monotonic_time(millisecond),
    State = handle_timeout(Now, State0),
    {noreply, State, next_timeout(State)};
handle_info(_Info, State) ->
    {noreply, State, next_timeout(State)}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_timeout(Now, #state{tid = TID} = State) ->
    case ets:first(TID) of
	'$end_of_table' ->
	    State;
	{Time, _} = Key when Time =< Now ->
	    handle_timeout(Now, exec_timeout(Key, State));
	_ ->
	    State
    end.

exec_timeout({Time, Id} = Key, #state{tid = TID, ids = Ids} = State) ->
    [{_, Evs}] = ets:take(TID, Key),
    {MF, TimesAndEvs0} = maps:get(Id, Ids),
    {Evs, TimesAndEvs} = maps:take(Time, TimesAndEvs0),
    apply_timeout(MF, Id, Time, Evs),
    case maps:size(TimesAndEvs) of
	0 ->
	    State#state{ids = maps:remove(Id, Ids)};

	_ ->
	    State#state{ids = maps:put(Id, {MF, TimesAndEvs}, Ids)}
    end.

apply_timeout(Fun, Id, Time, Evs) when is_function(Fun) ->
    (catch Fun(Id, Time, Evs));
apply_timeout({M, F}, Id, Time, Evs) ->
    (catch erlang:apply(M, F, [Id, Time, Evs])).

next_timeout(#state{tid = TID}) ->
    case ets:first(TID) of
	'$end_of_table' ->
	    infinity;
	{Time, _Ref} ->
	    max(1, Time - erlang:monotonic_time(millisecond))
    end.
