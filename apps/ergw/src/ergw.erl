%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw).

-behavior(gen_statem).

-compile({parse_transform, do}).

%% API
-export([start_link/1,
	 wait_till_ready/0,
	 wait_till_running/0,
	 is_ready/0,
	 is_running/0]).

-ignore_xref([start_link/1]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================

start_link(Config) ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, Config, []).

wait_till_ready() ->
    ok = gen_statem:call(?SERVER, wait_till_ready, infinity).

wait_till_running() ->
    ok = gen_statem:call(?SERVER, wait_till_running, infinity).

is_ready() ->
    gen_statem:call(?SERVER, is_ready).

is_running() ->
    gen_statem:call(?SERVER, is_running).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

callback_mode() -> [handle_event_function].

init(Config) ->
    process_flag(trap_exit, true),
    Now = erlang:monotonic_time(),

    {_, Mref} = erlang:spawn_monitor(
		  fun() -> exit(ergw_cluster:wait_till_ready()) end),
    {ok, startup, #{init => Now, startup => Mref, config => Config}}.

handle_event({call, From}, wait_till_ready, State, _Data)
  when State =:= ready; State =:= running ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, _From}, wait_till_ready, _State, _Data) ->
    {keep_state_and_data, [postpone]};

handle_event({call, From}, wait_till_running, running, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, _From}, wait_till_running, _State, _Data) ->
    {keep_state_and_data, [postpone]};

handle_event({call, From}, is_ready, State, _Data) ->
    Reply = {reply, From, State == ready},
    {keep_state_and_data, [Reply]};

handle_event({call, From}, is_running, State, _Data) ->
    Reply = {reply, From, State == running},
    {keep_state_and_data, [Reply]};

handle_event(info, {'DOWN', Mref, _, _, ok}, startup,
	     #{init := Now, startup := Mref, config := Config} = Data) ->
    ?LOG(info, "ergw: starting cluster, runtime system started in ~w ms",
	 [erlang:convert_time_unit(erlang:monotonic_time() - Now, native, millisecond)]),

    Cluster = maps:get(cluster, Config, #{}),
    {_, Mref} = erlang:spawn_monitor(
		  fun() -> exit(ergw_cluster:start(Cluster)) end),
    {next_state, ready, Data#{startup => Mref}};

handle_event(info, {'DOWN', Mref, _, _, Reason}, startup, #{startup := Mref}) ->
    ?LOG(critical, "ergw: support applications failed to start with ~0p", [Reason]),
    init:stop(1),
    {stop, {shutdown, Reason}};

handle_event(info, {'DOWN', Mref, _, _, ok}, ready,
	     #{init := Now, startup := Mref, config := Config} = Data) ->
    ergw_config:apply(Config),

    ?LOG(info, "ergw: ready to process requests, system started in ~w ms",
	 [erlang:convert_time_unit(erlang:monotonic_time() - Now, native, millisecond)]),
    {next_state, running, maps:remove(startup, Data)};

handle_event(info, {'DOWN', Mref, _, _, Reason}, ready, #{startup := Mref}) ->
    ?LOG(critical, "cluster support failed to start with ~0p", [Reason]),
    init:stop(1),
    {stop, {shutdown, Reason}};

handle_event(Event, Info, _State, _Data) ->
    ?LOG(error, "~p: ~w: handle_event(~p, ...): ~p", [self(), ?MODULE, Event, Info]),
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
