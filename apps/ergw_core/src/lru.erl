%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% ets LRU cache for IP pools, scales to at least 2^24 entries.

-module(lru).

-record(lru, {queue, index}).

-export([from_list/1, to_list/1,
	 pop/1, push/2, take/2,
	 valid/1, info/1]).

-ignore_xref([?MODULE]).

from_list([{{_, _}}|_] = List) ->
    Queue = ets:new(entries, [ordered_set]),
    Index = ets:new(index, [set]),

    IndexList = [{Key, QEntry} || {{_, Key} = QEntry} <- List],

    true = ets:insert(Queue, List),
    true = ets:insert(Index, IndexList),
    #lru{queue = Queue, index = Index}.

to_list(#lru{queue = Queue}) ->
    ets:tab2list(Queue).

pop(#lru{queue = Queue, index = Index}) ->
    case ets:first(Queue) of
	{_, Key} = Entry ->
	    ets:delete(Queue, Entry),
	    ets:delete(Index, Key),
	    {ok, Key};
	'$end_of_table' ->
	    {error, empty}
    end.

push(Key, #lru{queue = Queue, index = Index}) ->
    Now = erlang:monotonic_time(),
    case ets:insert_new(Index, {Key, Now}) of
	true ->
	    ets:insert(Queue, {{Now, Key}}),
	    ok;
	false ->
	    erlang:error(badarg, [Key])
    end.

take(Key, #lru{queue = Queue, index = Index}) ->
    case ets:take(Index, Key) of
	[{_, QEntry}] ->
	    ets:delete(Queue, QEntry),
	    ok;
	_ ->
	    {error, not_found}
    end.

valid(#lru{queue = Queue, index = Index}) ->
    ets:info(Queue, size) =:= ets:info(Index, size).

info(#lru{queue = Queue, index = Index}) ->
    {ets:info(Queue, size), ets:info(Index, size)}.
