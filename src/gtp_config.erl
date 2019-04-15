%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_config).

%% API
-export([init/0, get_restart_counter/0]).

-define(App, ergw).

%%====================================================================
%% API
%%====================================================================

init() ->
    StateFile = setup:get_env(?App, state_file, filename:join(setup:data_dir(), "ergw.state")),
    application:set_env(?App, state_file, StateFile, [{persistent, true}]),

    State0 = read_term(StateFile),
    Count = proplists:get_value(restart_count, State0, 0),
    State1 = lists:keystore(restart_count, 1, State0, {restart_count, (Count + 1) band 16#ff}),

    lists:foreach(fun({K, V}) ->
			  application:set_env(?App, K, V, [{persistent, true}])
		  end, State1),

    write_terms(StateFile, State1),
    ok.

get_restart_counter() ->
    application:get_env(?App, restart_count).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% list_keyupdate(K, N, L, Fun) when is_integer(N), N > 0, is_function(Fun, 1) ->
%%     list_keyupdate3(K, N, L, Fun).

%% list_keyupdate3(Key, Pos, [Tup|Tail], Fun) when element(Pos, Tup) == Key ->
%%     [Fun(Tup)|Tail];
%% list_keyupdate3(Key, Pos, [H|T], Fun) ->
%%     [H|list_keyupdate3(Key, Pos, T, Fun)];
%% list_keyupdate3(_, _, [], _) -> [].

read_term(FileName) ->
    case file:consult(FileName) of
	{ok, Terms} ->
	    Terms;
	{error, Reason} ->
	    lager:error("Failed to read ~s with ~s", [FileName, file:format_error(Reason)]),
	    [];
	Other ->
	    lager:error("Failed to read ~s with ~w", [FileName, Other]),
	    []
    end.

write_terms(FileName, List) ->
    filelib:ensure_dir(FileName),
    Format = fun(Term) -> io_lib:format("~tp.~n", [Term]) end,
    Text = lists:map(Format, List),
    case file:write_file(FileName, Text) of
	ok ->
	    ok;
	{error, Reason} ->
	    lager:error("Failed to write to ~s with ~s", [FileName, file:format_error(Reason)]),
	    ok;
	Other ->
	    lager:error("Failed to write to ~s with ~w", [FileName, Other]),
	    ok
    end.
