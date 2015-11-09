%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_path).

-behaviour(regine_server).

%% API
-export([start_link/5, get/2, all/1,
	 register/6, unregister/5,
	 handle_request/2, handle_response/2,
	 handle_recovery/7]).

%% regine_server callbacks
-export([init/1, handle_register/4, handle_unregister/3, handle_pid_remove/3,
	 handle_death/3, terminate/2]).
-export([handle_call/3, handle_cast/2, handle_info/2,
	 code_change/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/epgw.hrl").

%%%===================================================================
%%% API
%%%===================================================================

start_link(GtpPort, Interface, Protocol, RemoteIP, Args) ->
    regine_server:start_link(?MODULE, {GtpPort, Interface, Protocol, RemoteIP, Args}).

register(GtpPort, Interface, CntlProtocol, RemoteCntlIP, DataProtocol, RemoteDataIP) ->
    register(GtpPort, Interface, CntlProtocol, RemoteCntlIP),
    register(GtpPort, Interface, DataProtocol, RemoteDataIP).

unregister(Interface, CntlProtocol, RemoteCntlIP, DataProtocol, RemoteDataIP) ->
    unregister(Interface, CntlProtocol, RemoteCntlIP),
    unregister(Interface, DataProtocol, RemoteDataIP).

handle_recovery(RecoveryCounter, GtpPort, Interface, CntlProtocol, RemoteCntlIP, DataProtocol, RemoteDataIP) ->
    NewGTPcPeer = handle_recovery(RecoveryCounter, GtpPort, Interface, CntlProtocol, RemoteCntlIP),
    NewGTPuPeer = handle_recovery(RecoveryCounter, GtpPort, Interface, DataProtocol, RemoteDataIP),
    {ok, NewGTPcPeer, NewGTPuPeer}.

handle_request(Path, Msg) ->
    regine_server:cast(Path, {request, Msg}).

handle_response(Path, Msg) ->
    regine_server:cast(Path, {response, Msg}).

get(Type, IP) ->
    gtp_path_reg:lookup({Type, IP}).

all(Path) ->
    regine_server:call(Path, all).

%%%===================================================================
%%% Protocol Module API
%%%===================================================================

%%%===================================================================
%%% regine callbacks
%%%===================================================================
init({GtpPort, Interface, Protocol, RemoteIP, Args}) ->
    gtp_path_reg:register({Interface, RemoteIP}),
    gtp_path_reg:register({Protocol, RemoteIP}),
    gtp_path_reg:register({Protocol:type(), RemoteIP}),

    TID = ets:new(?MODULE, [duplicate_bag, private, {keypos, 1}]),

    State = #{table    => TID,
	      path_counter => 0,
	      gtp_port => GtpPort,
	      interface => Interface,
	      protocol => Protocol,
	      ip       => RemoteIP,
	      t3       => proplists:get_value(t3, Args, 10 * 1000), %% 10sec
	      n3       => proplists:get_value(n3, Args, 5),
	      seq_no   => 0,
	      recovery => undefined,
	      echo     => proplists:get_value(ping, Args, 60 * 1000), %% 60sec
	      port     => Protocol:port(),
	      pending  => gb_trees:empty(),
	      echo_timer => stopped,
	      tunnel_endpoints => gb_trees:empty(),
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

handle_cast({request, #gtp{type = echo_request}}, State) ->
    {noreply, State};
handle_cast({request, Msg}, State) ->
    lager:error("~w: unhandeld request: ~p", [?MODULE, gtp_c_lib:fmt_gtp(Msg)]),
    {noreply, State};

%% TODO: handle generic error responses
handle_cast({response, #gtp{seq_no = SeqNo} = Msg},
	    #{pending := Pending0} = State0) ->
    lager:debug("~w: response: ~p", [?MODULE, gtp_c_lib:fmt_gtp(Msg)]),
    State =
	case gb_trees:lookup(SeqNo, Pending0) of
	    none -> %% duplicate, drop silently
		State0;
	    {value, {_T3, _N3, _Port, _ReqMsg, Fun, TRef}} ->
		cancel_timer(TRef),
		Pending1 = gb_trees:delete(SeqNo, Pending0),
		Fun(Msg, State0#{pending := Pending1})
	end,
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("~w: handle_cast: ~p", [?MODULE, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(Info = {timeout, TRef, {send, SeqNo}}, #{pending := Pending0} = State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    NewState =
	case gb_trees:lookup(SeqNo, Pending0) of
	    {value, {_T3, _N3 = 0, _Port, Msg, Fun, TRef}} ->
		%% TODO: handle path failure....
		lager:error("gtp_path: message resent expired: ~p", [Msg]),
		Pending1 = gb_trees:delete(SeqNo, Pending0),
		Fun(timeout, State#{pending := Pending1});

	    {value, {T3, N3, Port, Msg, Fun, TRef}} ->
		%% resent....
		Pending1 = gb_trees:delete(SeqNo, Pending0),
		send_message_timeout(SeqNo, T3, N3 - 1, Port, Msg, Fun, State#{pending => Pending1})
	end,
    {noreply, NewState};

handle_info(Info = {timeout, TRef, echo}, #{echo_timer := TRef} = State0) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    State1 = send_echo_request(State0),
    {noreply, State1};
handle_info(Info = {timeout, _TRef, echo}, State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
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

final_send_message(GtpPort, Protocol, IP, Port, Msg) ->
    %% TODO: handle encode errors
    try
        Data = gtp_packet:encode(Msg),
	lager:debug("gtp_path send ~s to ~w:~w: ~p, ~p", [Protocol:type(), IP, Port, gtp_c_lib:fmt_gtp(Msg), Data]),
	gtp:send(GtpPort, Protocol:type(), IP, Port, Data)
    catch
	Class:Error ->
	    lager:error("gtp send failed with ~p:~p", [Class, Error])
    end.

final_send_message(Port, Msg, #{gtp_port := GtpPort, protocol := Protocol, ip := IP} = State) ->
    final_send_message(GtpPort, Protocol, IP, Port, Msg),
    State.

send_request(#gtp{} = Msg, Fun,
	     #{t3 := T3, n3 := N3, seq_no := SeqNo, port := Port} = State)
  when is_function(Fun, 2) ->
    send_message_timeout(SeqNo, T3, N3, Port,
			 Msg#gtp{seq_no = SeqNo}, Fun, State#{seq_no := SeqNo + 1}).

send_message_timeout(SeqNo, T3, N3, Port, Msg, Fun, #{pending := Pending0} = State) ->
    TRef = erlang:start_timer(T3, self(), {send, SeqNo}),
    Pending1 = gb_trees:insert(SeqNo, {T3, N3, Port, Msg, Fun, TRef}, Pending0),
    final_send_message(Port, Msg, State#{pending := Pending1}).

cancel_timer(Ref) ->
    case erlang:cancel_timer(Ref) of
        false ->
            receive {timeout, Ref, _} -> 0
            after 0 -> false
            end;
        RemainingTime ->
            RemainingTime
    end.

register(GtpPort, Interface, Protocol, RemoteIP) ->
    lager:debug("~s: register(~p)", [?MODULE, [GtpPort, Interface, Protocol, RemoteIP]]),
    case get(Protocol, RemoteIP) of
	Path when is_pid(Path) ->
	    Path;
	_ ->
	    {ok, Path} = gtp_path_sup:new_path(GtpPort, Interface, Protocol, RemoteIP, [])
    end,
    ok = regine_server:register(Path, self(), {self(), Interface}, undefined),
    regine_server:call(Path, get_restart_counter).


unregister(Interface, Protocol, RemoteIP) ->
    case get(Protocol, RemoteIP) of
	Path when is_pid(Path) ->
	    regine_server:unregister(Path, {self(), Interface}, undefined);
	_ ->
	    ok
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

send_echo_request(#{protocol := Protocol} = State) ->
    Msg = Protocol:build_echo_request(),
    send_request(Msg, fun echo_response/2, State#{echo_timer => awaiting_response}).

echo_response(Msg, #{echo := EchoInterval, echo_timer := awaiting_response} = State0) ->
    lager:debug("echo_response: ~p", [Msg]),
    State = update_path_state(Msg, State0),
    TRef = erlang:start_timer(EchoInterval, self(), echo),
    State#{echo_timer => TRef};
echo_response(Msg, State) ->
    lager:debug("echo_response: ~p", [Msg]),
    update_path_state(Msg, State).

update_path_state(#gtp{}, State) ->
    State#{state => 'UP'};
update_path_state(_, State) ->
    State#{state => 'DOWN'}.

handle_recovery(RecoveryCounter, GtpPort, Interface, Protocol, RemoteIP) ->
    lager:debug("~s: handle_recovery(~p)", [?MODULE, [RecoveryCounter, GtpPort, Protocol, RemoteIP]]),
    case get(Protocol, RemoteIP) of
	Path when is_pid(Path) ->
	    handle_recovery(Path, RecoveryCounter, false);
	_ ->
	    {ok, Path} = gtp_path_sup:new_path(GtpPort, Interface, Protocol, RemoteIP, []),
	    handle_recovery(Path, RecoveryCounter, true)
    end.

handle_recovery(_Path, undefined, IsNew) ->
    IsNew;
handle_recovery(Path, RecoveryCounter, _IsNew) ->
    regine_server:call(Path, {set_restart_counter, RecoveryCounter}).
