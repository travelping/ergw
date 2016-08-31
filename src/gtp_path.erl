%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_path).

-behaviour(regine_server).

%% API
-export([start_link/4, get/2, all/1,
	 register/3, unregister/3,
	 send_request/3, send_request/4,
	 handle_message/4,
	 handle_response/2,
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
    case get(GtpPort, RemoteIP) of
	Path when is_pid(Path) ->
	    Path;
	_ ->
	    {ok, Path} = gtp_path_sup:new_path(GtpPort, Version, RemoteIP, [])
    end,
    ok = regine_server:register(Path, self(), {self(), Version}, undefined),
    regine_server:call(Path, get_restart_counter).


unregister(GtpPort, Version, RemoteIP) ->
    case get(GtpPort, RemoteIP) of
	Path when is_pid(Path) ->
	    regine_server:unregister(Path, {self(), Version}, undefined);
	_ ->
	    ok
    end.

handle_message(IP, Port, GtpPort,
	       #gtp{version = Version, type = MsgType, tei = 0} = Msg)
  when (Version == v1 andalso MsgType == create_pdp_context_request) orelse
       (Version == v2 andalso MsgType == create_session_request) ->
    gtp_context:new(IP, Port, GtpPort, Msg);

handle_message(IP, Port, GtpPort, #gtp{tei = TEI} = Msg)
  when TEI /= 0 ->
    gtp_context:handle_message(IP, Port, GtpPort, Msg);

handle_message(IP, _Port, GtpPort,
	       #gtp{type = echo_response} = Msg) ->
    lager:debug("handle_echo_response: ~p -> ~p", [IP, gtp_path:get(GtpPort, IP)]),
    case gtp_path:get(GtpPort, IP) of
	Path when is_pid(Path) ->
	    handle_response(Path, Msg);
	_ ->
	    ok
    end;

handle_message(IP, Port, GtpPort, Msg) ->
    lager:error("GTP Path Handle Message: ~p", [[IP, Port, GtpPort, Msg]]),
    ok.

handle_recovery(RecoveryCounter, GtpPort, Version, RemoteIP) ->
    NewPeer = do_handle_recovery(RecoveryCounter, GtpPort, Version, RemoteIP),
    {ok, NewPeer}.

handle_response(Path, Msg) ->
    regine_server:call(Path, {response, Msg}).

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

send_request(GtpPort, RemoteIP, Msg = #gtp{version = Version}, ReqId) ->
    case get(GtpPort, RemoteIP) of
	Path when is_pid(Path) ->
	    send_request(Path, Msg, ReqId);
	_ ->
	    {ok, Path} = gtp_path_sup:new_path(GtpPort, Version, RemoteIP, []),
	    send_request(Path, Msg, ReqId)
    end.

send_request(Path, Msg, ReqId)
  when is_pid(Path) ->
    regine_server:cast(Path, {send_request, Msg, ReqId}).

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
	      seq_no   => 0,
	      recovery => undefined,
	      echo     => proplists:get_value(ping, Args, 60 * 1000), %% 60sec
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

%% TODO: handle generic error responses
handle_call({response, #gtp{seq_no = SeqNo} = Msg}, _From,
	    #{pending := Pending0} = State0) ->
    lager:debug("~p: ~w: response: ~p", [self(), ?MODULE, gtp_c_lib:fmt_gtp(Msg)]),
    case gb_trees:lookup(SeqNo, Pending0) of
	none -> %% duplicate, drop silently
	    lager:error("~p: invalid response: ~p, ~p", [self(), SeqNo, Pending0]),
	    {reply, duplicate, State0};
	{value, {_T3, _N3, _Port, _ReqMsg, Fun, TRef}} ->
	    cancel_timer(TRef),
	    lager:info("~p: found response: ~p", [self(), SeqNo]),
	    Pending1 = gb_trees:delete(SeqNo, Pending0),
	    {Reply, State} = Fun(Msg, State0#{pending := Pending1}),
	    {reply, Reply, State}
    end;

handle_call(Request, _From, State) ->
    lager:warning("handle_call: ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({send_request, Msg, ReqId}, State0) ->
    lager:debug("~p: gtp_path send_request: ~p", [self(), Msg]),
    ResponseFun = fun(Response, PathState) -> {{ok, ReqId, Response}, PathState} end,
    State = do_send_request(Msg, ResponseFun, State0),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("~p: ~w: handle_cast: ~p", [self(), ?MODULE, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(Info = {timeout, TRef, {send, SeqNo}}, #{pending := Pending0} = State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    NewState =
	case gb_trees:lookup(SeqNo, Pending0) of
	    {value, {_T3, _N3 = 0, _Port, Msg, Fun, TRef}} ->
		%% TODO: handle path failure....
		lager:error("~p: gtp_path: message resent expired: ~p", [self(), Msg]),
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

final_send_message(GtpPort, IP, Port, Msg) ->
    %% TODO: handle encode errors
    try
        Data = gtp_packet:encode(Msg),
	lager:debug("gtp_path send ~s to ~w:~w: ~p, ~p",
		    [GtpPort#gtp_port.type, IP, Port,
		     gtp_c_lib:fmt_gtp(Msg), Data]),
	gtp_socket:send(GtpPort, IP, Port, Data)
    catch
	Class:Error ->
	    lager:error("gtp send (~p) failed with ~p:~p",
			[[lager:pr(GtpPort, ?MODULE), IP, Port,
			  lager:pr(Msg, ?MODULE)], Class, Error])
    end.

final_send_message(Port, Msg, #{gtp_port := GtpPort, ip := IP} = State) ->
    final_send_message(GtpPort, IP, Port, Msg),
    State.

do_send_request(#gtp{} = Msg, Fun,
		#{t3 := T3, n3 := N3, seq_no := SeqNo,
		  handler := Handler} = State)
  when is_function(Fun, 2) ->
    Port = Handler:port(),
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

send_echo_request(#{handler := Handler} = State) ->
    Msg = Handler:build_echo_request(),
    do_send_request(Msg, fun echo_response/2, State#{echo_timer => awaiting_response}).

echo_response(Msg, #{echo := EchoInterval, echo_timer := awaiting_response} = State0) ->
    lager:debug("echo_response: ~p", [Msg]),
    State = update_path_state(Msg, State0),
    TRef = erlang:start_timer(EchoInterval, self(), echo),
    {ok, State#{echo_timer => TRef}};
echo_response(Msg, State0) ->
    lager:debug("echo_response: ~p", [Msg]),
    State = update_path_state(Msg, State0),
    {ok, State}.

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
