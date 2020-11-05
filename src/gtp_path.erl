%% Copyright 2015, 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_path).

-behaviour(gen_statem).

-compile({parse_transform, cut}).
-compile({no_auto_import,[register/2]}).

%% API
-export([start_link/4, all/1,
	 maybe_new_path/3,
	 handle_request/2, handle_response/4,
	 bind/1, bind/2, unbind/1, down/2,
	 get_handler/2, info/1]).

%% Validate environment Variables
-export([validate_options/1]).

-ignore_xref([start_link/4,
	      handle_response/4			% used from callback handler
	      ]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-ifdef(TEST).
-export([ping/1, ping/3, set/3, stop/1]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-record(peer, {state    :: up | down,
	       contexts :: non_neg_integer()
	      }).

%% echo_timer is the status of the echo send to the remote peer
-record(state, {peer       :: #peer{},                     %% State of remote peer
		recovery   :: 'undefined' | non_neg_integer(),
		echo       :: 'stopped' | 'echo_to_send' | 'awaiting_response'}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Socket, Version, RemoteIP, Args) ->
    Opts = [{hibernate_after, 5000},
	    {spawn_opt,[{fullsweep_after, 0}]}],
    gen_statem:start_link(?MODULE, [Socket, Version, RemoteIP, Args], Opts).

maybe_new_path(Socket, Version, RemoteIP) ->
    case get(Socket, Version, RemoteIP) of
	Path when is_pid(Path) ->
	    Path;
	_ ->
	    {ok, Args} = application:get_env(ergw, path_management),
	    {ok, Path} = gtp_path_sup:new_path(Socket, Version, RemoteIP, Args),
	    Path
    end.

handle_request(#request{socket = Socket, ip = IP} = ReqKey, #gtp{version = Version} = Msg) ->
    Path = maybe_new_path(Socket, Version, IP),
    gen_statem:cast(Path, {handle_request, ReqKey, Msg}).

handle_response(Path, Request, Ref, Response) ->
    gen_statem:cast(Path, {handle_response, Request, Ref, Response}).

bind(Tunnel) ->
    monitor_path_recovery(bind_path(Tunnel)).

bind(#gtp{ie = #{{recovery, 0} :=
		     #recovery{restart_counter = RestartCounter}}
	 } = Request, Tunnel) ->
    bind_path_recovery(RestartCounter, bind_path(Request, Tunnel));
bind(#gtp{ie = #{{v2_recovery, 0} :=
		     #v2_recovery{restart_counter = RestartCounter}}
	 } = Request, Tunnel) ->
    bind_path_recovery(RestartCounter, bind_path(Request, Tunnel));
bind(Request, Tunnel) ->
    bind_path_recovery(undefined, bind_path(Request, Tunnel)).

unbind(#tunnel{socket = Socket, version = Version, remote = #fq_teid{ip = RemoteIP}}) ->
    case get(Socket, Version, RemoteIP) of
	Path when is_pid(Path) ->
	    gen_statem:call(Path, {unbind, self()});
	_ ->
	    ok
    end.

down(Socket, IP) ->
    down(Socket, v1, IP),
    down(Socket, v2, IP).

down(Socket, Version, IP) ->
    case get(Socket, Version, IP) of
	Path when is_pid(Path) ->
	    gen_statem:cast(Path, down);
	_ ->
	    ok
    end.

get(#socket{name = SocketName}, Version, IP) ->
    gtp_path_reg:lookup({SocketName, Version, IP}).

all(Path) ->
    gen_statem:call(Path, all).

info(Path) ->
    gen_statem:call(Path, info).

get_handler(#socket{type = 'gtp-u'}, _) ->
    gtp_v1_u;
get_handler(#socket{type = 'gtp-c'}, v1) ->
    gtp_v1_c;
get_handler(#socket{type = 'gtp-c'}, v2) ->
    gtp_v2_c.

-ifdef(TEST).
ping(Path) ->
    gen_statem:call(Path, '$ping').

ping(Socket, Version, IP) ->
    case get(Socket, Version, IP) of
	Path when is_pid(Path) ->
	    ping(Path);
	_ ->
	    {error, no_found}
    end.

set(Path, Opt, Value) ->
    gen_statem:call(Path, {'$set', Opt, Value}).

stop(Path) ->
    gen_statem:call(Path, '$stop').

-endif.

%%%===================================================================
%%% Options Validation
%%%===================================================================

%% Timer value: echo    = echo interval when peer is up.

-define(Defaults, [{t3, 10 * 1000},              % echo retry interval
		   {n3,  5},                     % echo retry count
		   {echo, 60 * 1000},            % echo ping interval
		   {idle_timeout, 1800 * 1000},  % time to keep the path entry when idle
		   {idle_echo,     600 * 1000},  % echo retry interval when idle
		   {down_timeout, 3600 * 1000},  % time to keep the path entry when down
		   {down_echo,     600 * 1000}]).% echo retry interval when down

validate_options(Values) ->
    ergw_config:validate_options(fun validate_option/2, Values, ?Defaults, map).

validate_echo(_Opt, Value) when is_integer(Value), Value >= 60 * 1000 ->
    Value;
validate_echo(_Opt, off = Value) ->
    Value;
validate_echo(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_timeout(_Opt, Value) when is_integer(Value), Value >= 0 ->
    Value;
validate_timeout(_Opt, infinity = Value) ->
    Value;
validate_timeout(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_option(t3, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(n3, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(Opt, Value)
  when Opt =:= echo; Opt =:= idle_echo; Opt =:= down_echo ->
    validate_echo(Opt, Value);
validate_option(Opt, Value)
  when Opt =:= idle_timeout; Opt =:= down_timeout ->
    validate_timeout(Opt, Value);
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% Protocol Module API
%%%===================================================================

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

callback_mode() -> [handle_event_function, state_enter].

init([#socket{name = SocketName} = Socket, Version, RemoteIP, Args]) ->
    RegKey = {SocketName, Version, RemoteIP},
    gtp_path_reg:register(RegKey, up),

    State = #state{peer = #peer{state = up, contexts = 0},
		   echo = stopped},

    Data0 = maps:with([t3, n3, echo,
		       idle_timeout, idle_echo,
		       down_timeout, down_echo], Args),
    Data = Data0#{
	     %% Path Info Keys
	     socket     => Socket, % #socket{}
	     version    => Version, % v1 | v2
	     handler    => get_handler(Socket, Version),
	     ip         => RemoteIP,
	     reg_key    => RegKey,

	     contexts   => #{},
	     monitors   => #{}
	},

    ?LOG(debug, "State: ~p Data: ~p", [State, Data]),
    {ok, State, Data}.

handle_event(enter, #state{peer = Old}, #state{peer = Peer}, Data)
  when Old /= Peer ->
    peer_state_change(Old, Peer, Data),
    OldState = peer_state(Old),
    NewState = peer_state(Peer),
    {keep_state_and_data, enter_peer_state_action(OldState, NewState, Data)};

handle_event(enter, #state{echo = Old}, #state{peer = Peer, echo = Echo}, Data)
  when Old /= Echo ->
    State = peer_state(Peer),
    {keep_state_and_data, enter_state_echo_action(State, Data)};

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event({timeout, stop_echo}, stop_echo, State, Data) ->
    {next_state, State#state{echo = stopped}, Data, [{{timeout, echo}, cancel}]};

handle_event({timeout, echo}, start_echo, #state{echo = EchoT} = State0, Data)
  when EchoT =:= stopped;
       EchoT =:= idle ->
    State = send_echo_request(State0, Data),
    {next_state, State, Data};
handle_event({timeout, echo}, start_echo, _State, _Data) ->
    keep_state_and_data;

handle_event({timeout, peer}, stop, _State, #{reg_key := RegKey}) ->
    gtp_path_reg:unregister(RegKey),
    {stop, normal};

handle_event({call, From}, all, _State, #{contexts := CtxS} = _Data) ->
    Reply = maps:keys(CtxS),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {MonOrBind, Pid}, #state{peer = #peer{state = down}}, _Data)
  when MonOrBind == monitor; MonOrBind == bind ->
    Path = self(),
    proc_lib:spawn(fun() -> gtp_context:path_restart(Pid, Path) end),
    {keep_state_and_data, [{reply, From, {ok, undefined}}]};

handle_event({call, From}, {monitor, Pid}, #state{recovery = RstCnt} = State, Data) ->
    register_monitor(Pid, State, Data, [{reply, From, {ok, RstCnt}}]);

handle_event({call, From}, {bind, Pid}, #state{recovery = RstCnt} = State, Data) ->
    register_bind(Pid, State, Data, [{reply, From, {ok, RstCnt}}]);

handle_event({call, From}, {bind, Pid, RstCnt}, State, Data) ->
    case update_restart_counter(RstCnt, State, Data) of
	initial  ->
	    register_bind(Pid, State#state{recovery = RstCnt}, Data, [{reply, From, ok}]);
	peer_restart  ->
	    %% try again after state change
	    path_restart(RstCnt, State, Data, [postpone]);
	no ->
	    register_bind(Pid, State, Data, [{reply, From, ok}])
    end;

handle_event({call, From}, {unbind, Pid}, State, Data) ->
    unregister(Pid, State, Data, [{reply, From, ok}]);

handle_event({call, From}, info, #state{peer = #peer{contexts = CtxCnt}} = State,
	     #{socket := #socket{name = SocketName},
	       version := Version, ip := IP} = Data) ->
    Reply = #{path => self(), socket => SocketName, tunnels => CtxCnt,
	      version => Version, ip => IP, state => State, data => Data},
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event(cast, {handle_request, ReqKey, #gtp{type = echo_request} = Msg0},
	     State, #{socket := Socket, handler := Handler} = Data) ->
    ?LOG(debug, "echo_request: ~p", [Msg0]),
    try gtp_packet:decode_ies(Msg0) of
	Msg = #gtp{} ->
	    ResponseIEs = Handler:build_recovery(echo_response, Socket, true, []),
	    Response = Msg#gtp{type = echo_response, ie = ResponseIEs},
	    ergw_gtp_c_socket:send_response(ReqKey, Response, false),

	    handle_recovery_ie(Msg, State, Data)
    catch
	Class:Error ->
	    ?LOG(error, "GTP decoding failed with ~p:~p for ~p",
		 [Class, Error, Msg0]),
	    keep_state_and_data
    end;

handle_event(cast, {handle_response, echo_request, ReqRef, _Msg}, #state{echo = SRef}, _)
  when ReqRef /= SRef ->
    keep_state_and_data;

handle_event(cast,{handle_response, echo_request, _, #gtp{} = Msg}, State, Data) ->
    handle_recovery_ie(Msg, State#state{echo = idle}, Data);

handle_event(cast,{handle_response, echo_request, _, _Msg}, State, Data) ->
    path_restart(undefined, peer_state(down, State), Data, []);

handle_event(cast, down, State, Data) ->
    path_restart(undefined, peer_state(down, State), Data, []);

handle_event(info,{'DOWN', _MonitorRef, process, Pid, _Info}, State, Data) ->
    unregister(Pid, State, Data, []);

handle_event({timeout, 'echo'}, _, #state{echo = idle} = State0, Data) ->
    ?LOG(debug, "handle_event timeout: ~p", [Data]),
    State = send_echo_request(State0, Data),
    {next_state, State, Data};

handle_event({timeout, 'echo'}, _, _State, _Data) ->
    ?LOG(debug, "handle_event timeout: ~p", [_Data]),
    keep_state_and_data;

%% test support
handle_event({call, From}, '$ping', State0, Data) ->
    State = send_echo_request(State0, Data),
    {next_state, State, Data, [{{timeout, echo}, cancel}, {reply, From, ok}]};

handle_event({call, From}, {'$set', Opt, Value}, _State, Data) ->
    {keep_state, maps:put(Opt, Value, Data), {reply, From, maps:get(Opt, Data, undefined)}};

handle_event({call, From}, '$stop', _State, #{reg_key := RegKey}) ->
    gtp_path_reg:unregister(RegKey),
    {stop_and_reply, normal, [{reply, From, ok}]};

handle_event({call, From}, Request, _State, _Data) ->
    ?LOG(warning, "handle_event(call,...): ~p", [Request]),
    {keep_state_and_data, [{reply, From, ok}]};

handle_event(cast, Msg, _State, _Data) ->
    ?LOG(error, "~p: ~w: handle_event(cast, ...): ~p", [self(), ?MODULE, Msg]),
    keep_state_and_data;

handle_event(info, Info, _State, _Data) ->
    ?LOG(error, "~p: ~w: handle_event(info, ...): ~p", [self(), ?MODULE, Info]),
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    %% TODO: kill all PDP Context on this path
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% special enter state handlers
%%%===================================================================

peer_state(#peer{state = down}) -> down;
peer_state(#peer{state = up, contexts = 0}) -> idle;
peer_state(#peer{state = up}) -> busy.

peer_state_change(#peer{state = State}, #peer{state = State}, _) ->
    ok;
peer_state_change(_, #peer{state = State}, #{reg_key := RegKey}) ->
    gtp_path_reg:state(RegKey, State).

%%%===================================================================
%%% Internal functions
%%%===================================================================

enter_peer_state_action(State, State, _Data) ->
    [];
enter_peer_state_action(_, State, Data) ->
    [enter_state_timeout_action(State, Data),
     enter_state_echo_action(State, Data)].

enter_state_timeout_action(idle, #{idle_timeout := Timeout}) when is_integer(Timeout) ->
    {{timeout, peer}, Timeout, stop};
enter_state_timeout_action(down, #{down_timeout := Timeout}) when is_integer(Timeout) ->
    {{timeout, peer}, Timeout, stop};
enter_state_timeout_action(_State, _Data) ->
    {{timeout, peer}, cancel}.

enter_state_echo_action(busy, #{echo := EchoInterval}) when is_integer(EchoInterval) ->
    {{timeout, echo}, EchoInterval, start_echo};
enter_state_echo_action(idle, #{idle_echo := EchoInterval})
  when is_integer(EchoInterval) ->
    {{timeout, echo}, EchoInterval, start_echo};
enter_state_echo_action(down, #{down_echo := EchoInterval})
  when is_integer(EchoInterval) ->
    {{timeout, echo}, EchoInterval, start_echo};
enter_state_echo_action(_, _) ->
    {{timeout, stop_echo}, 0, stop_echo}.

foreach_context(none, _Fun) ->
    ok;
foreach_context({Pid, _, Iter}, Fun) ->
    Fun(Pid),
    foreach_context(maps:next(Iter), Fun).

peer_state(PState, #state{peer = Peer} = State) ->
    State#state{peer = Peer#peer{state = PState}}.

peer_contexts(Contexts, #state{peer = Peer} = State) ->
    State#state{peer = Peer#peer{contexts = Contexts}}.

%% 3GPP TS 23.007, Sect. 18 GTP-C-based restart procedures:
%%
%% The GTP-C entity that receives a Recovery Information Element in an Echo Response
%% or in another GTP-C message from a peer, shall compare the received remote Restart
%% counter value with the previous Restart counter value stored for that peer entity.
%%
%%   - If no previous value was stored the Restart counter value received in the Echo
%%     Response or in the GTP-C message shall be stored for the peer.
%%
%%   - If the value of a Restart counter previously stored for a peer is smaller than
%%     the Restart counter value received in the Echo Response message or the GTP-C
%%     message, taking the integer roll-over into account, this indicates that the
%%     entity that sent the Echo Response or the GTP-C message has restarted. The
%%     received, new Restart counter value shall be stored by the receiving entity,
%%     replacing the value previously stored for the peer.
%%
%%   - If the value of a Restart counter previously stored for a peer is larger than
%%     the Restart counter value received in the Echo Response message or the GTP-C message,
%%     taking the integer roll-over into account, this indicates a possible race condition
%%     (newer message arriving before the older one). The received new Restart counter value
%%     shall be discarded and an error may be logged

-define(SMALLER(S1, S2), ((S1 < S2 andalso (S2 - S1) < 128) orelse (S1 > S2 andalso (S1 - S2) > 128))).

update_restart_counter(_Counter, #state{recovery = undefined}, _Data) ->
    initial;
update_restart_counter(Counter, #state{recovery = Counter}, _Data) ->
    no;
update_restart_counter(New, #state{recovery = Old}, #{ip := IP})
  when ?SMALLER(Old, New) ->
    ?LOG(warning, "GSN ~s restarted (~w != ~w)", [inet:ntoa(IP), Old, New]),
    peer_restart;
update_restart_counter(New, #state{recovery = Old}, #{ip := IP})
  when not ?SMALLER(Old, New) ->
    ?LOG(warning, "possible race on message with restart counter for GSN ~s (old: ~w, new: ~w)",
	 [inet:ntoa(IP), Old, New]),
    no.

handle_restart_counter(RestartCounter, State0, Data) ->
    State = peer_state(up, State0),
    case update_restart_counter(RestartCounter, State, Data) of
	initial  ->
	    {next_state, State#state{recovery = RestartCounter}, Data};
	peer_restart  ->
	    path_restart(RestartCounter, State, Data, []);
	no ->
	    {next_state, State, Data}
    end.

handle_recovery_ie(#gtp{version = v1,
			ie = #{{recovery, 0} :=
				   #recovery{restart_counter =
						 RestartCounter}}}, State, Data) ->
    handle_restart_counter(RestartCounter, State, Data);

handle_recovery_ie(#gtp{version = v2,
			ie = #{{v2_recovery, 0} :=
				   #v2_recovery{restart_counter =
						    RestartCounter}}}, State, Data) ->
    handle_restart_counter(RestartCounter, State, Data);
handle_recovery_ie(#gtp{}, State, Data) ->
    {next_state, peer_state(up, State), Data}.

update_contexts(State0, #{socket := Socket, version := Version, ip := IP} = Data0,
		CtxS, Actions) ->
    Cnt = maps:size(CtxS),
    ergw_prometheus:gtp_path_contexts(Socket, IP, Version, Cnt),
    State = peer_contexts(Cnt, State0),
    Data = Data0#{contexts => CtxS},
    {next_state, State, Data, Actions}.

register_monitor(Pid, State, #{contexts := CtxS, monitors := Mons} = Data, Actions)
  when is_map_key(Pid, CtxS), is_map_key(Pid, Mons) ->
    ?LOG(debug, "~s: monitor(~p)", [?MODULE, Pid]),
    {next_state, State, Data, Actions};
register_monitor(Pid, State, #{monitors := Mons} = Data, Actions) ->
    ?LOG(debug, "~s: monitor(~p)", [?MODULE, Pid]),
    MRef = erlang:monitor(process, Pid),
    {next_state, State, Data#{monitors => maps:put(Pid, MRef, Mons)}, Actions}.

%% register_bind/5
register_bind(Pid, MRef, State, #{contexts := CtxS} = Data, Actions) ->
    update_contexts(State, Data, maps:put(Pid, MRef, CtxS), Actions).

%% register_bind/4
register_bind(Pid, State, #{monitors := Mons} = Data, Actions)
  when is_map_key(Pid, Mons)  ->
    ?LOG(debug, "~s: register(~p)", [?MODULE, Pid]),
    MRef = maps:get(Pid, Mons),
    register_bind(Pid, MRef, State, Data#{monitors => maps:remove(Pid, Mons)}, Actions);
register_bind(Pid, State, #{contexts := CtxS} = Data, Actions)
  when is_map_key(Pid, CtxS) ->
    {next_state, State, Data, Actions};
register_bind(Pid, State, Data, Actions) ->
    ?LOG(debug, "~s: register(~p)", [?MODULE, Pid]),
    MRef = erlang:monitor(process, Pid),
    register_bind(Pid, MRef, State, Data, Actions).

unregister(Pid, State, #{contexts := CtxS} = Data, Actions)
  when is_map_key(Pid, CtxS) ->
    MRef = maps:get(Pid, CtxS),
    erlang:demonitor(MRef, [flush]),
    update_contexts(State, Data, maps:remove(Pid, CtxS), Actions);
unregister(Pid, State, #{monitors := Mons} = Data, Actions)
  when is_map_key(Pid, Mons) ->
    MRef = maps:get(Pid, Mons),
    erlang:demonitor(MRef, [flush]),
    {next_state, State, Data#{monitors => maps:remove(Pid, Mons)}, Actions};
unregister(_Pid, _, _Data, Actions) ->
    {keep_state_and_data, Actions}.

bind_path(#gtp{version = Version}, Tunnel) ->
    bind_path(Tunnel#tunnel{version = Version}).

bind_path(#tunnel{socket = Socket, version = Version,
		  remote = #fq_teid{ip = RemoteCntlIP}} = Tunnel) ->
    Path = maybe_new_path(Socket, Version, RemoteCntlIP),
    Tunnel#tunnel{path = Path}.

monitor_path_recovery(#tunnel{path = Path} = Tunnel) ->
    {ok, PathRestartCounter} = gen_statem:call(Path, {monitor, self()}),
    Tunnel#tunnel{remote_restart_counter = PathRestartCounter}.

bind_path_recovery(RestartCounter, #tunnel{path = Path} = Tunnel)
  when is_integer(RestartCounter) ->
    ok = gen_statem:call(Path, {bind, self(), RestartCounter}),
    Tunnel#tunnel{remote_restart_counter = RestartCounter};
bind_path_recovery(_RestartCounter, #tunnel{path = Path} = Tunnel) ->
    {ok, PathRestartCounter} = gen_statem:call(Path, {bind, self()}),
    Tunnel#tunnel{remote_restart_counter = PathRestartCounter}.

send_echo_request(State, #{socket := Socket, handler := Handler, ip := DstIP,
			   t3 := T3, n3 := N3}) ->
    Msg = Handler:build_echo_request(),
    Ref = erlang:make_ref(),
    CbInfo = {?MODULE, handle_response, [self(), echo_request, Ref]},
    ergw_gtp_c_socket:send_request(Socket, DstIP, ?GTP1c_PORT, T3, N3, Msg, CbInfo),
    State#state{echo = Ref}.

path_restart(RestartCounter, State, #{contexts := CtxS} = Data, Actions) ->
    Path = self(),
    ResF =
	fun() ->
		foreach_context(maps:next(maps:iterator(CtxS)),
				gtp_context:path_restart(_, Path))
	end,
    proc_lib:spawn(ResF),
    update_contexts(State#state{recovery = RestartCounter}, Data, #{}, Actions).
