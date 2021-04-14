%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_global).
-behaviour(ra_machine).

-compile({parse_transform, cut}).
-compile({no_auto_import,[apply/3]}).

%% API
-export([ping/0, get/1, put/2, find/1]).
%-export([ping/1, get/2, put/3, delete/2, delete/3, all/1]).

% ra_machine callbacks
-export([init/1, apply/3]).

-ignore_xref([ping/0]).

-include_lib("kernel/include/logger.hrl").

ping() ->
    ServerRef = {ergw_cluster:get_ra_node_id(), node()},
    Ref = make_ref(),
    ra:process_command(ServerRef, {ping, Ref}).

put(Key, Value) ->
    Cmd = {put, Key, Value},
    ServerRef = {ergw_cluster:get_ra_node_id(), node()},
    case ra:process_command(ServerRef, Cmd) of
	{ok, {Index, Term}, LeaderRaNodeId} ->
	    {ok, {{index, Index}, {term, Term}, {leader, LeaderRaNodeId}}};
	{timeout, _} -> timeout
    end.

get(Key) ->
    ServerRef = {ergw_cluster:get_ra_node_id(), node()},
    case ra:consistent_query(ServerRef,
			     fun(State) ->
				     maps:get(Key, State, undefined)
			     end) of
	{ok, Value, _} ->
	    Value;
	{timeout, _} ->
	    timeout;
	{error, nodedown} ->
	    error
    end.

find(Query) ->
    ServerRef = {ergw_cluster:get_ra_node_id(), node()},
    case ra:consistent_query(ServerRef, find_query(Query, _)) of
	{ok, Value, _} ->
	    Value;
	{timeout, _} ->
	    timeout;
	{error, nodedown} ->
	    error
    end.

-if(0).
cas(ServerReference, Key, ExpectedValue, NewValue) ->
    Cmd = {cas, Key, ExpectedValue, NewValue},
    case ra:process_command(ServerReference, Cmd) of
	{ok, {{read, ReadValue}, {index, Index}, {term, Term}}, LeaderRaNodeId} ->
	    {ok, {{read, ReadValue},
		  {index, Index},
		  {term, Term},
		  {leader, LeaderRaNodeId}}};
	{timeout, _} -> timeout
    end.
-endif.

init(_Config) -> #{}.

apply(#{index := Index} = _Metadata, {ping, Ref} = Cmd, State) ->
    ?LOG(info, _Metadata#{cmd => Cmd}),
    SideEffects = [{release_cursor, Index, State}],
    {State, {ok, Ref}, SideEffects};

apply(#{index := Index} = _Metadata, {timeout, _} = Cmd, State) ->
    ?LOG(info, _Metadata#{cmd => Cmd}),
    SideEffects = [{release_cursor, Index, State}],
    {State, ok, SideEffects};

apply(#{index := Index, term := Term} = _Metadata, {put, Key, Value}, State) ->
    NewState = maps:put(Key, Value, State),
    SideEffects = side_effects(Index, NewState),
    %% return the index and term here as a result
    {NewState, {Index, Term}, SideEffects};

apply(#{index := Index, term := Term} = _Metadata,
      {cas, Key, ExpectedValue, NewValue}, State) ->
    {NewState, ReadValue} =
	case maps:get(Key, State, undefined) of
	    ExpectedValue ->
		{maps:put(Key, NewValue, State), ExpectedValue};
	    ValueInStore ->
		{State, ValueInStore}
	end,
    SideEffects = side_effects(Index, NewState),
    {NewState, {{read, ReadValue}, {index, Index}, {term, Term}}, SideEffects}.

side_effects(RaftIndex, MachineState) ->
    case application:get_env(ergw_cluster, release_cursor_every) of
	{ok, NegativeOrZero}
	  when NegativeOrZero =< 0 ->
	    [];
	{ok, Every} ->
	    case release_cursor(RaftIndex, Every) of
		release_cursor ->
		    [{release_cursor, RaftIndex, MachineState}];
		_ ->
		    []
	    end
    end.

release_cursor(Index, Every) ->
    case Index rem Every of
	0 ->
	    release_cursor;
	_ ->
	    do_not_release_cursor
    end.

find_query([], Config) ->
    {ok, Config};
find_query([K|Next], Config) when is_map_key(K, Config) ->
    find_query(Next, maps:get(K, Config));
find_query(_, _) ->
    false.
