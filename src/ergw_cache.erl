%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_cache).

-export([new/2, get/2, enter/4, expire/2, to_list/1]).

%%%===================================================================
%%% exometer functions
%%%===================================================================

-record(cache, {
	  expire :: integer(),
	  key    :: term(),
	  timer  :: reference(),
	  tree   :: gb_trees:tree(Key :: term(), {Expire :: integer(), Data :: term()}),
	  queue  :: queue:queue({Expire :: integer(), Key :: term()})
	 }).

start_timer(Ref, #cache{timer = TimerRef, expire = ExpireInterval, key = Key} = Cache) ->
    if Ref =/= TimerRef andalso is_reference(TimerRef) -> erlang:cancel_timer(TimerRef);
       true -> ok
    end,
    Cache#cache{timer = erlang:start_timer(ExpireInterval, self(), Key)}.

new(ExpireInterval, Key) ->
    Cache = #cache{
	       expire = ExpireInterval,
	       key = Key,
	       tree = gb_trees:empty(),
	       queue = queue:new()
	      },
    start_timer(undefined, Cache).

get(Key, #cache{tree = Tree}) ->
    Now = erlang:monotonic_time(milli_seconds),
    case gb_trees:lookup(Key, Tree) of
	{value, {Expire, Data}}  when Expire > Now ->
	    {value, Data};

	_ ->
	    none
    end.

enter(Key, Data, TimeOut, #cache{tree = Tree0, queue = Q0} = Cache) ->
    Now = erlang:monotonic_time(milli_seconds),
    Expire = Now + TimeOut,
    Tree = gb_trees:enter(Key, {Expire, Data}, Tree0),
    Q = queue:in({Expire, Key}, Q0),
    expire_now(Now, Cache#cache{tree = Tree, queue = Q}).

expire(TRef, Cache0) when is_reference(TRef) ->
    Now = erlang:monotonic_time(milli_seconds),
    Cache = expire_now(Now, Cache0),
    start_timer(TRef, Cache).

expire_now(Now, #cache{tree = Tree0, queue = Q0} = Cache) ->
    case queue:peek(Q0) of
	{value, {Expire, Key}} when Expire < Now ->
	    Q = queue:drop(Q0),
	    Tree = case gb_trees:lookup(Key, Tree0) of
		       {value, {Expire, _}} ->
			   gb_trees:delete(Key, Tree0);
		       _ ->
			   Tree0
		   end,
	    expire_now(Now, Cache#cache{tree = Tree, queue = Q});
	_ ->
	    Cache
    end.

to_list(#cache{tree = Tree, queue = Q}) ->
    {gb_trees:to_list(Tree), queue:to_list(Q)}.
