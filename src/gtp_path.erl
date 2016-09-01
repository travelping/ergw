%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_path).

-behaviour(regine_server).

%% API
-export([start_link/4, get/2, all/1,
	 maybe_new_path/3, handle_request/4,
	 register/3, unregister/3,
	 handle_recovery/4,
	 get_handler/2]).

%% regine_server callbacks
-export([init/1, handle_register/4, handle_unregister/3, handle_pid_remove/3,
	 handle_death/3, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2,
	 code_change/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% API
%%%===================================================================

start_link(GtpPort, Version, RemoteIP, Args) ->
    regine_server:start_link(?MODULE, {GtpPort, Version, RemoteIP, Args}).

register(GtpPort, Version, RemoteIP) ->
    lager:debug("~s: register(~p)", [?MODULE, [GtpPort, Version, RemoteIP]]),
    Path = maybe_new_path(GtpPort, Version, RemoteIP),
    ok = regine_server:register(Path, self(), {self(), Version}, undefined),
    regine_server:call(Path, get_restart_counter).


unregister(GtpPort, Version, RemoteIP) ->
    case get(GtpPort, RemoteIP) of
	Path when is_pid(Path) ->
	    regine_server:unregister(Path, {self(), Version}, undefined);
	_ ->
	    ok
    end.

maybe_new_path(GtpPort, Version, RemoteIP) ->
    case get(GtpPort, RemoteIP) of
	Path when is_pid(Path) ->
	    Path;
	_ ->
	    {ok, Path} = gtp_path_sup:new_path(GtpPort, Version, RemoteIP, []),
	    Path
    end.

handle_request(RemoteIP, RemotePort, GtpPort, #gtp{version = Version} = Msg) ->
    Path = maybe_new_path(GtpPort, Version, RemoteIP),
    regine_server:cast(Path, {handle_request, RemotePort, Msg}).

handle_recovery(RecoveryCounter, GtpPort, Version, RemoteIP) ->
    NewPeer = do_handle_recovery(RecoveryCounter, GtpPort, Version, RemoteIP),
    {ok, NewPeer}.

get(#gtp_port{name = PortName}, IP) ->
    gtp_path_reg:lookup({PortName, IP}).

all(Path) ->
    regine_server:call(Path, all).

get_handler(#gtp_port{type = 'gtp-u'}, _) ->
    gtp_v1_u;
get_handler(#gtp_port{type = 'gtp-c'}, v1) ->
    gtp_v1_c;
get_handler(#gtp_port{type = 'gtp-c'}, v2) ->
    gtp_v2_c.

%%%===================================================================
%%% Protocol Module API
%%%===================================================================

%%%===================================================================
%%% regine callbacks
%%%===================================================================
init({#gtp_port{name = PortName} = GtpPort, Version, RemoteIP, Args}) ->
    gtp_path_reg:register({PortName, RemoteIP}),

    TID = ets:new(?MODULE, [duplicate_bag, private, {keypos, 1}]),

    State = #{table    => TID,
	      path_counter => 0,
	      gtp_port => GtpPort,
	      version  => Version,
	      handler  => get_handler(GtpPort, Version),
	      ip       => RemoteIP,
	      t3       => proplists:get_value(t3, Args, 10 * 1000), %% 10sec
	      n3       => proplists:get_value(n3, Args, 5),
	      recovery => undefined,
	      echo     => proplists:get_value(ping, Args, 60 * 1000), %% 60sec
	      echo_timer => stopped,
	      state    => 'UP'},

    lager:debug("State: ~p", [State]),
    {ok, State}.

handle_register(_Pid, Key, _Value, #{table := TID} = State0) ->
    lager:debug("~s: register(~p)", [?MODULE, Key]),
    ets:insert(TID, Key),
    State = inc_path_counter(State0),
    {ok, [Key], State}.

handle_unregister(Key = {Pid, _}, _Value, #{table := TID} = State0) ->
    ets:delete(TID, Key),
    State = dec_path_counter(State0),
    {[Pid], State}.

handle_pid_remove(_Pid, Keys, #{table := TID} = State0) ->
    lists:foreach(fun(Key) -> ets:delete(TID, Key) end, Keys),
    State = dec_path_counter(State0),
    State.

handle_death(_Pid, _Reason, State) ->
    State.

handle_call(all, _From, #{table := TID} = State) ->
    Reply = ets:tab2list(TID),
    {reply, Reply, State};

handle_call({set_restart_counter, NewRecovery}, _From, #{recovery := OldRecovery} = State) ->
    if OldRecovery =/= undefined andalso
       OldRecovery =/= NewRecovery  ->
	    %% TODO: handle Path restart ....
	    ok;
       true ->
	    ok
    end,
    IsNew = OldRecovery =:= undefined orelse OldRecovery =/= NewRecovery,
    {reply, IsNew, State#{recovery => NewRecovery}};
handle_call(get_restart_counter, _From, #{recovery := Recovery} = State) ->
    {reply, Recovery, State};

handle_call(Request, _From, State) ->
    lager:warning("handle_call: ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({handle_request, RemotePort, Msg}, State0) ->
    State = handle_request(RemotePort, Msg, State0),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("~p: ~w: handle_cast: ~p", [self(), ?MODULE, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(Info = {timeout, TRef, echo}, #{echo_timer := TRef} = State0) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    State1 = send_echo_request(State0),
    {noreply, State1};
handle_info(Info = {timeout, _TRef, echo}, State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    {noreply, State};

handle_info({echo_respone, _, Msg}, State0)->
    lager:debug("echo_response: ~p", [Msg]),
    State = echo_response(Msg, State0),
    {noreply, State};

handle_info(Info, State) ->
    lager:error("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

cancel_timer(Ref) ->
    case erlang:cancel_timer(Ref) of
        false ->
            receive {timeout, Ref, _} -> 0
            after 0 -> false
            end;
        RemainingTime ->
            RemainingTime
    end.

inc_path_counter(#{path_counter := OldPathCounter} = State0) ->
    State = State0#{path_counter := OldPathCounter + 1},
    if OldPathCounter == 0 ->
	    start_echo_request(State);
       true ->
	    State
    end.

dec_path_counter(#{path_counter := 0} = State) ->
    lager:error("attempting to release path when count == 0"),
    State;
dec_path_counter(#{path_counter := OldPathCounter} = State0) ->
    State = State0#{path_counter := OldPathCounter - 1},
    if OldPathCounter == 0 ->
	    stop_echo_request(State);
       true ->
	    State
    end.

start_echo_request(#{echo_timer := stopped} = State) ->
    send_echo_request(State);
start_echo_request(State) ->
    State.

stop_echo_request(#{echo_timer := EchoTRef} = State) ->
    if is_reference(EchoTRef) ->
	    cancel_timer(EchoTRef);
       true ->
	    ok
    end,
    State#{echo_timer => stopped}.

send_echo_request(#{gtp_port := GtpPort, handler := Handler, ip := RemoteIP,
		    t3 := T3, n3 := N3} = State) ->
    Msg = Handler:build_echo_request(),
    gtp_socket:send_request(GtpPort, self(), RemoteIP, T3, N3, Msg, echo_request),
    State#{echo_timer => awaiting_response} .

echo_response(Msg, #{echo := EchoInterval, echo_timer := awaiting_response} = State0) ->
    State = update_path_state(Msg, State0),
    TRef = erlang:start_timer(EchoInterval, self(), echo),
    State#{echo_timer => TRef} ;
echo_response(Msg, State0) ->
    update_path_state(Msg, State0).

update_path_state(#gtp{}, State) ->
    State#{state => 'UP'};
update_path_state(_, State) ->
    State#{state => 'DOWN'}.

do_handle_recovery(RecoveryCounter, GtpPort, Version, RemoteIP) ->
    lager:debug("~s: handle_recovery(~p)", [?MODULE, [RecoveryCounter, GtpPort, Version, RemoteIP]]),
    case get(GtpPort, RemoteIP) of
	Path when is_pid(Path) ->
	    do_handle_recovery_1(Path, RecoveryCounter, false);
	_ ->
	    {ok, Path} = gtp_path_sup:new_path(GtpPort, Version, RemoteIP, []),
	    do_handle_recovery_1(Path, RecoveryCounter, true)
    end.

do_handle_recovery_1(_Path, undefined, IsNew) ->
    IsNew;
do_handle_recovery_1(Path, RecoveryCounter, _IsNew) ->
    regine_server:call(Path, {set_restart_counter, RecoveryCounter}).

send_message(Port, Msg, #{gtp_port := GtpPort, ip := IP} = State) ->
    %% TODO: handle encode errors
    try
        Data = gtp_packet:encode(Msg),
	lager:debug("gtp_context send ~s to ~w:~w: ~p, ~p", [GtpPort#gtp_port.type, IP, Port, Msg, Data]),
	gtp_socket:send(GtpPort, IP, Port, Data)
    catch
	Class:Error ->
	    Stack  = erlang:get_stacktrace(),
	    lager:error("gtp send failed with ~p:~p (~p)", [Class, Error, Stack])
    end,
    State.

handle_request(RemotePort, #gtp{type = echo_request} = Req,
	       #{gtp_port := GtpPort, handler := Handler} = State) ->
    lager:debug("echo_request: ~p", [Req]),

    ResponseIEs = Handler:build_recovery(GtpPort, true),
    Response = Req#gtp{type = echo_response, ie = ResponseIEs},
    send_message(RemotePort, Response, State).
