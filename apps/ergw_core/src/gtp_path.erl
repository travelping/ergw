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
-export([start_link/5, all/1,
	 gateway_nodes/3,
	 handle_request/2, handle_response/4,
	 activity/2, activity/5,
	 aquire_lease/1, release_lease/2,
	 bind_tunnel/1, unbind_tunnel/1,
	 icmp_error/2, path_restart/2,
	 get_handler/2, info/1, sync_state/3]).

%% Validate environment Variables
-export([validate_options/1, validate_options/2,
	 setopts/1, set_peer_opts/2]).

-ignore_xref([start_link/5,
	      path_restart/2,
	      handle_response/4,		% used from callback handler
	      sync_state/3
	      ]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-ifdef(TEST).
-export([ping/1, ping/3, set/3, stop/1, maybe_new_path/4]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("ergw_core_config.hrl").
-include("include/ergw.hrl").

%% echo_timer is the status of the echo send to the remote peer
-record(state, {peer       :: unknown | up | down | suspect,
		contexts   :: map(),
		leases     :: map(),
		recovery   :: 'undefined' | non_neg_integer(),
		echo       :: 'stopped' | 'echo_to_send' | 'awaiting_response'}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(Socket, Version, RemoteIP, Trigger, Args) ->
    Opts = [{hibernate_after, 5000},
	    {spawn_opt,[{fullsweep_after, 0}]}],
    gen_statem:start_link(?MODULE, [Socket, Version, RemoteIP, Trigger, Args], Opts).

setopts(Opts0) ->
    Opts = validate_options(Opts0),
    ergw_core_config:put(path_management, Opts).

getopts() ->
    case ergw_core_config:get([path_management], []) of
	{ok, Opts0} = Args when is_map(Opts0) ->
	    Args;
	{ok, Opts0} when is_list(Opts0) ->
	    Opts = validate_options(Opts0),
	    ergw_core_config:put(path_management, Opts),
	    {ok, Opts}
    end.

set_peer_opts(Peer, Opts0) when ?IS_IP(Peer) ->
    Opts = validate_options(Opts0),
    {ok, Peers} = ergw_core_config:get([gtp_peers], #{}),
    ergw_core_config:put(gtp_peers, Peers#{Peer => Opts}).

get_peer_opts(Peer) ->
    {ok, Peers} = ergw_core_config:get([gtp_peers], #{}),
    maps:get(Peer, Peers, #{}).

gateway_nodes(Socket, Version, Nodes) ->
    proc_lib:spawn(
      fun() ->
	      lists:foreach(
		fun({_Name, _, _, IP4, IP6}) ->
			lists:foreach(maybe_new_path(Socket, Version, _, detect), IP4),
			lists:foreach(maybe_new_path(Socket, Version, _, detect), IP6)
		end, Nodes)
      end).

maybe_new_path(Socket, Version, RemoteIP, Trigger) ->
    case get(Socket, Version, RemoteIP) of
	Path when is_pid(Path) ->
	    Path;
	_ ->
	    {ok, Args0} = getopts(),
	    PeerArgs = get_peer_opts(RemoteIP),
	    Args = maps:merge(Args0, PeerArgs),
	    {ok, Path} = gtp_path_sup:new_path(Socket, Version, RemoteIP, Trigger, Args),
	    Path
    end.

handle_request(#request{socket = Socket, ip = IP} = ReqKey, #gtp{version = Version} = Msg) ->
    Path = maybe_new_path(Socket, Version, IP, activity),
    gen_statem:cast(Path, {handle_request, ReqKey, Msg}).

handle_response(Path, Request, Ref, Response) ->
    gen_statem:cast(Path, {handle_response, Request, Ref, Response}).

aquire_lease(Tunnel) ->
    safe_aquire_lease(get_path(Tunnel, lease)).

release_lease(LRef, #tunnel{path = Path}) ->
    gen_statem:cast(Path, {release_lease, LRef}).

activity(#request{socket = Socket, ip = IP, version = Version, arrival_ts = TS}, Event) ->
    Path = maybe_new_path(Socket, Version, IP, activity),
    gen_statem:cast(Path, {activity, TS, Event}).

activity(Socket, IP, Version, TS, Event) ->
    case get(Socket, Version, IP) of
	Path when is_pid(Path) ->
	    gen_statem:cast(Path, {activity, TS, Event});
	_ ->
	    ok
    end.

bind_tunnel(Tunnel) ->
    safe_bind_tunnel(get_path(Tunnel, bind)).

unbind_tunnel(#tunnel{path = Path}) ->
    gen_statem:cast(Path, {unbind_tunnel, self()}).

icmp_error(Socket, IP) ->
    icmp_error(Socket, v1, IP),
    icmp_error(Socket, v2, IP).

icmp_error(Socket, Version, IP) ->
    case get(Socket, Version, IP) of
	Path when is_pid(Path) ->
	    gen_statem:cast(Path, icmp_error);
	_ ->
	    ok
    end.

path_restart(Key, RstCnt) ->
    case gtp_path_reg:lookup(Key) of
	Path when is_pid(Path) ->
	    gen_statem:cast(Path, {path_restart, RstCnt});
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

sync_state(Key, OldState, State) ->
    error(badarg, [Key, OldState, State]).

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

-define(Defaults, [
    {busy, []},
    {idle, []},
    {suspect, []},
    {down, []}
]).
-define(IdleDefaults, [
    {timeout, 1800 * 1000},      % time to keep the path entry when idle
    {t3,        10 * 1000},      % echo retry interval
    {n3,                5},      % echo retry count
    {echo,     600 * 1000},      % echo retry interval when idle
    {events, []}
]).
-define(BusyDefaults, [
    {t3,        10 * 1000},      % echo retry interval
    {n3,                5},      % echo retry count
    {echo,     600 * 1000},      % echo retry interval when idle
    {events, []}
]).
-define(SuspectDefaults, [
    {timeout, 300 * 1000},       % time to keep the path entry when suspect
    {t3,       10 * 1000},       % echo retry interval
    {n3,               5},       % echo retry count
    {echo,     60 * 1000},       % echo retry interval when suspect
    {events, []}
]).
-define(DownDefaults, [
    {timeout, 3600 * 1000},      % time to keep the path entry when down
    {t3,        10 * 1000},      % echo retry interval
    {n3,                5},      % echo retry count
    {echo,     600 * 1000},      % echo retry interval when down
    {events, []},
    {notify, active}
]).

-define(EventDefaults, [
    {icmp_error, warning},
    {echo_timeout, critical}
]).

validate_options(Values) ->
    ergw_core_config:validate_options(fun validate_option/2, Values, ?Defaults).

validate_options(Peer, Values) when ?IS_IP(Peer) ->
    ergw_core_config:validate_options(fun validate_option/2, Values, ?Defaults);
validate_options(Peer, Values) ->
    erlang:error(badarg, [Peer, Values]).

validate_echo(_Opt, Value) when is_integer(Value), Value >= 60 * 1000 ->
    Value;
validate_echo(_Opt, off = Value) ->
    Value;
validate_echo(_Opt, #{initial := Initial, 'scaleFactor' := ScaleF, max := Max} = Value)
  when is_integer(Initial), is_integer(ScaleF), is_integer(Max), Max > Initial ->
    Value;
validate_echo(Opt, Value) ->
    erlang:error(badarg, Opt ++ [echo, Value]).

validate_timeout(_Opt, Value) when is_integer(Value), Value >= 0 ->
    Value;
validate_timeout(_Opt, infinity = Value) ->
    Value;
validate_timeout(Opt, Value) ->
    erlang:error(badarg, Opt ++ [timeout, Value]).

validate_event_opts(Ev, Severity)
  when (Ev =:= icmp_error orelse
	Ev =:= echo_timeout)
       andalso
       (Severity =:= critical orelse
	Severity =:= warning orelse
	Severity =:= info) ->
    Severity;
validate_event_opts(Ev, Severity) ->
    erlang:error(badarg, [Ev, Severity]).

validate_state(_State, t3, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_state(_State, n3, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_state(State, echo, Value) ->
    validate_echo([State], Value);
validate_state(State, timeout, Value)
  when State =:= suspect; State =:= down; State =:= idle ->
    validate_timeout([State], Value);
validate_state(_State, events, Values) ->
    ergw_core_config:validate_options(fun validate_event_opts/2, Values, ?EventDefaults);
validate_state(down, notify, Value)
  when Value =:= active; Value =:= silent ->
    Value;
validate_state(State, Opt, Value) ->
    erlang:error(badarg, [State, Opt, Value]).

validate_option(Opt = idle, Values) ->
    ergw_core_config:validate_options(validate_state(Opt, _, _), Values, ?IdleDefaults);
validate_option(Opt = busy, Values) ->
    ergw_core_config:validate_options(validate_state(Opt, _, _), Values, ?BusyDefaults);
validate_option(Opt = suspect, Values) ->
    ergw_core_config:validate_options(validate_state(Opt, _, _), Values, ?SuspectDefaults);
validate_option(Opt = down, Values) ->
    ergw_core_config:validate_options(validate_state(Opt, _, _), Values, ?DownDefaults);
validate_option(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

%%%===================================================================
%%% Protocol Module API
%%%===================================================================

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

callback_mode() -> [handle_event_function, state_enter].

init([#socket{name = SocketName} = Socket, Version, RemoteIP, Trigger, Args]) ->
    RegKey = {SocketName, Version, RemoteIP},
    Now = erlang:monotonic_time(),

    Data0 = maps:with([busy, idle, suspect, down], Args),
    Data1 = Data0#{
	     %% Path Info Keys
	     socket     => Socket, % #socket{}
	     version    => Version, % v1 | v2
	     handler    => get_handler(Socket, Version),
	     ip         => RemoteIP,
	     reg_key    => RegKey,
	     time       => 0,
	     last_seen  => Now,
	     last_echo_request => Now,
	     last_echo_response => Now,
	     last_message => Now,
	     echo_cnt   => 0,
	     going_down => false
	},

    State0 = #state{contexts = #{}, leases = #{}, echo = stopped},
    {State, Data} =
	case Trigger of
	    activity ->
		{State0#state{peer = up}, Data1};
	    _ ->
		send_echo_request(State0#state{peer = unknown}, Data1)
	end,

    gtp_path_reg:register(RegKey, State#state.peer),

    Actions = [enter_state_timeout_action(idle, Data),
	       enter_state_echo_action(idle, Data)],
    ?LOG(debug, "State: ~p~nData: ~p~nActions: ~p~n", [State, Data, Actions]),
    {ok, State, Data, Actions}.

handle_event(enter, #state{peer = OldPS} = OldS, #state{peer = down} = State, Data0)
  when OldPS =/= down ->
    Data = Data0#{echo_cnt => 0, going_down => false},
    peer_state_change(OldS, State, Data),
    path_recovery_change(State, Data),
    {keep_state, Data};

handle_event(enter,
	     #state{peer = OldP, contexts = OldC} = OldS,
	     #state{peer = NewP, contexts = NewC} = State, Data0)
  when OldP /= NewP; OldC /= NewC ->
    Data =
	if OldP =/= NewP ->
		%% a state transition cancels the going down flag
		Data0#{echo_cnt => 0, going_down => false};
	   true ->
		Data0
	end,
    peer_state_change(OldS, State, Data),
    OldPState = peer_state(OldS),
    NewPState = peer_state(State),
    {keep_state, Data, enter_peer_state_action(OldPState, NewPState, Data)};

handle_event(enter, #state{echo = Old}, #state{echo = Echo} = State, Data)
  when Old /= Echo andalso not is_reference(Echo) ->
    PeerState = peer_state(State),
    {keep_state_and_data, enter_state_echo_action(PeerState, Data)};

handle_event(enter, _OldState, #state{leases = Leases}, #{going_down := true} = Data)
  when map_size(Leases) =:= 0 ->
    %% trigger a immediate down timeout
    {keep_state, Data#{going_down => false}, [{{timeout, peer}, 0, down}]};
handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event({timeout, stop_echo}, stop_echo, State, Data) ->
    {next_state, State#state{echo = stopped}, Data, [{{timeout, echo}, cancel}]};

handle_event({timeout, echo}, start_echo, #state{echo = EchoT} = State0, Data0)
  when EchoT =:= stopped;
       EchoT =:= idle ->
    {State, Data} = send_echo_request(State0, Data0),
    {next_state, State, Data};
handle_event({timeout, echo}, start_echo, _State, _Data) ->
    keep_state_and_data;

handle_event({timeout, peer}, down, #state{leases = Leases} = State, Data)
  when map_size(Leases) =:= 0 ->
    {next_state, State#state{peer = down, recovery = undefined}, Data#{going_down => false}};
handle_event({timeout, peer}, down, #state{leases = Leases} = State, Data)
  when map_size(Leases) =/= 0 ->
    {next_state, State#state{recovery = undefined}, Data#{going_down => true}};

handle_event({timeout, peer}, stop, #state{peer = up},
	     #{last_message := LastMsg, idle := #{timeout := Timeout}, reg_key := RegKey})
  when is_integer(Timeout), Timeout /= 0 ->
    Now = erlang:monotonic_time(millisecond),
    Last = erlang:convert_time_unit(LastMsg, native, millisecond),
    case Timeout - (Now - Last) of
	X when X > 0 ->
	    %% reset timeout
	    {keep_state_and_data, [{{timeout, peer}, X, stop}]};
	_ ->
	    gtp_path_reg:unregister(RegKey),
	    {stop, normal}
    end;
handle_event({timeout, peer}, stop, _State, #{reg_key := RegKey}) ->
    gtp_path_reg:unregister(RegKey),
    {stop, normal};

handle_event({call, From}, all, #state{contexts = CtxS} = _State, _Data) ->
    Reply = maps:keys(CtxS),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {aquire_lease, _}, _State, #{going_down := true}) ->
    {keep_state_and_data, [{reply, From, {error, down}}]};
handle_event({call, From}, {aquire_lease, _}, #state{peer = down}, _Data) ->
    {keep_state_and_data, [{reply, From, {error, down}}]};
handle_event({call, From}, {aquire_lease, Pid}, State, Data) ->
    aquire_lease(From, Pid, State, Data);

handle_event(cast, {release_lease, LRef}, State, Data) ->
    release_lease(LRef, State, Data);

handle_event({call, From}, {bind_tunnel, _}, #state{peer = down}, _Data) ->
    %% this should not happen
    ?LOG(error, "Context Bind request in peer down state"),
    {keep_state_and_data, [{reply, From, {error, down}}]};
handle_event({call, From}, {bind_tunnel, Pid}, #state{recovery = RstCnt} = State, Data) ->
    bind_tunnel(Pid, State, Data, [{reply, From, {ok, RstCnt}}]);

handle_event(cast, {unbind_tunnel, Pid}, State, Data) ->
    unbind_tunnel(Pid, State, Data);

handle_event(cast, {activity, When, What}, State0, Data0) ->
    {State, Data} = activity(When, What, {State0, Data0}),
    {next_state, State, Data};

handle_event({call, From}, info, #state{contexts = CtxS} = State,
	     #{socket := #socket{name = SocketName},
	       version := Version, ip := IP} = Data) ->
    Reply = #{path => self(), socket => SocketName, tunnels => maps:size(CtxS),
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
    peer_state_event_action(echo_timeout, State#state{echo = idle}, Data);

handle_event(cast, {path_restart, RstCnt}, #state{recovery = RstCnt} = _State, _Data)
  when is_integer(RstCnt) ->
    keep_state_and_data;
handle_event(cast, {path_restart, RstCnt}, State, Data) when is_integer(RstCnt) ->
    {next_state, path_recovery_change(State#state{recovery = RstCnt}, Data), Data};
handle_event(cast, {path_restart, undefined}, State, Data) ->
    {next_state, State#state{peer = down, recovery = undefined}, Data};

handle_event(cast, icmp_error, State, Data) ->
    peer_state_event_action(icmp_error, State, Data);

handle_event(info, {'DOWN', MRef, process, _Pid, _Info}, #state{leases = Leases} = State, Data)
  when is_map_key(MRef, Leases) ->
    {next_state, State#state{leases = maps:remove(MRef, Leases)}, Data};

handle_event(info, {'DOWN', _MRef, process, Pid, _Info}, #state{contexts = CtxS} = State, Data)
  when is_map_key(Pid, CtxS) ->
    update_contexts(State#state{contexts = maps:remove(Pid, CtxS)}, Data, []);

handle_event(info,{'DOWN', _MRef, process, _Pid, _Info}, _State, _Data) ->
    keep_state_and_data;

handle_event({timeout, 'echo'}, _, #state{echo = idle} = State0, Data0) ->
    ?LOG(debug, "handle_event timeout: ~p", [Data0]),
    {State, Data} = send_echo_request(State0, Data0),
    {next_state, State, Data};

handle_event({timeout, 'echo'}, _, _State, _Data) ->
    ?LOG(debug, "handle_event timeout: ~p", [_Data]),
    keep_state_and_data;

%% test support
handle_event({call, From}, '$ping', State0, Data0) ->
    {State, Data} = send_echo_request(State0, Data0),
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

peer_state(#state{peer = up, contexts = CtxS})
  when map_size(CtxS) =:= 0 -> idle;
peer_state(#state{peer = up, contexts = CtxS})
  when map_size(CtxS) =/= 0 -> busy;
peer_state(#state{peer = State}) when is_atom(State) -> State.

peer_state_change(#state{peer = State}, #state{peer = State}, _) ->
    ok;
peer_state_change(_, #state{peer = State}, #{reg_key := RegKey}) ->
    gtp_path_reg:state(RegKey, State).

%%%===================================================================
%%% Internal functions
%%%===================================================================

enter_peer_state_action(State, State, _Data) ->
    [];
enter_peer_state_action(_, State, Data) ->
    [enter_state_timeout_action(State, Data),
     enter_state_echo_action(State, Data)].

enter_state_timeout_action(idle, #{idle := #{timeout := Timeout}}) when is_integer(Timeout) ->
    {{timeout, peer}, Timeout, stop};
enter_state_timeout_action(suspect, #{suspect := #{timeout := Timeout}}) when is_integer(Timeout) ->
    {{timeout, peer}, Timeout, down};
enter_state_timeout_action(down, #{down := #{timeout := Timeout}}) when is_integer(Timeout) ->
    {{timeout, peer}, Timeout, stop};
enter_state_timeout_action(_State, _Data) ->
    {{timeout, peer}, cancel}.

state_echo_timeout(#{echo := EchoInterval}, _)
  when is_integer(EchoInterval) ->
    {{timeout, echo}, EchoInterval, start_echo};
state_echo_timeout(#{echo :=
			 #{initial := Initial,
			   'scaleFactor' := ScaleF,
			   max := Max}},
		   #{echo_cnt := Cnt}) ->
    EchoInterval = min(round(Initial * math:pow(ScaleF, Cnt)), Max),
    {{timeout, echo}, EchoInterval, start_echo};
state_echo_timeout(_, _) ->
    {{timeout, stop_echo}, 0, stop_echo}.

enter_state_echo_action(State, Data)
  when State =:= busy; State =:= idle; State =:= suspect; State =:= down ->
    state_echo_timeout(maps:get(State, Data), Data);
enter_state_echo_action(_, _) ->
    {{timeout, stop_echo}, 0, stop_echo}.

foreach_context(_, none, _Fun) ->
    ok;
foreach_context(NewCnt, {Pid, {OldCnt, _}, Iter}, Fun) ->
    if OldCnt =/= NewCnt -> Fun(Pid);
       NewCnt =:= undefined -> Fun(Pid);
       true -> ok
    end,
    foreach_context(NewCnt, maps:next(Iter), Fun).

rx_rst_cnt(RstCnt, {#state{recovery = RstCnt}, _} = StateData) ->
    StateData;
rx_rst_cnt(RstCnt, {State0, Data0})
  when is_integer(RstCnt) ->
    {Verdict, New, Data} = cas_restart_counter(RstCnt, Data0),
    State =
	case Verdict of
	    _ when Verdict == initial; Verdict == current ->
		State0#state{recovery = New};
	    peer_restart ->
		ring_path_restart(New, Data),
		path_recovery_change(State0#state{recovery = New}, Data);
	    _ ->
		State0
	end,
    {State, Data};
rx_rst_cnt(_, StateData) ->
    StateData.

activity(When, #gtp{type = Type,
		    ie = #{{recovery, 0} :=
			       #recovery{restart_counter = RestartCounter}}}, StateData) ->
    activity(When, Type, rx_rst_cnt(RestartCounter, StateData));
activity(When, #gtp{type = Type,
		    ie = #{{v2_recovery, 0} :=
			       #v2_recovery{restart_counter = RestartCounter}}}, StateData) ->
    activity(When, Type, rx_rst_cnt(RestartCounter, StateData));
activity(When, #gtp{type = Type}, StateData) ->
    activity(When, Type, StateData);

activity(When, echo_request, StateData) ->
    rx(last_seen, When, rx(last_echo_request, When, StateData));
activity(When, echo_response, StateData) ->
    rx(last_seen, When, rx(last_echo_response, When, StateData));
activity(When, _Type, StateData) ->
    rx(last_seen, When, rx(last_message, When, StateData)).

rx(What, When, {State, Data}) ->
    case maps:get(What, Data, When) of
	X when X > When ->
	    {State#state{peer = up}, Data#{What => When}};
	_ ->
	    {State, Data}
    end.

cas_restart_counter(Counter, #{time := Time0, reg_key := Key} = Data) ->
    case gtp_path_db_vnode:cas_restart_counter(Key, Counter, Time0 + 1) of
	{ok, #{result := Result}} ->
	    {Verdict, New, Time} =
		lists:foldl(
		  fun({_Location, {_, _, T1} = R}, {_, _, T2})
			when T1 > T2 -> R;
		     (_, A) -> A
		  end,
		  {fail, Counter, Time0}, Result),
	    {Verdict, New, Data#{time => Time}};
	_Res ->
	    {fail, Counter, Data}
    end.

handle_restart_counter(RestartCounter, State0, Data0) ->
    State = State0#state{peer = up},
    {Verdict, New, Data} = cas_restart_counter(RestartCounter, Data0),
    case Verdict of
	_ when Verdict == initial; Verdict == current ->
	    {next_state, State#state{recovery = New}, Data};
	peer_restart  ->
	    ring_path_restart(New, Data),
	    {next_state, path_recovery_change(State#state{recovery = New}, Data), Data};
	_ ->
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
    {next_state, State#state{peer = up}, Data}.

update_contexts(#state{contexts = CtxS} = State,
		#{socket := Socket, version := Version, ip := IP} = Data, Actions) ->
    ergw_prometheus:gtp_path_contexts(Socket, IP, Version, maps:size(CtxS)),
    {next_state, State, Data, Actions}.

aquire_lease(From, Pid, #state{recovery = RstCnt, leases = Leases} = State, Data) ->
    ?LOG(debug, "~s: lease(~p)", [?MODULE, Pid]),
    MRef = erlang:monitor(process, Pid),
    Actions = [{reply, From, {ok, {MRef, RstCnt}}}],
    {next_state, State#state{leases = maps:put(Pid, MRef, Leases)}, Data, Actions}.

release_lease(MRef, #state{leases = Leases} = State, Data) ->
    ?LOG(debug, "~s: lease(~p)", [?MODULE, MRef]),
    erlang:demonitor(MRef),
    {next_state, State#state{leases = maps:remove(MRef, Leases)}, Data}.

%% bind_tunnel/4
bind_tunnel(Pid, #state{recovery = RstCnt, contexts = CtxS} = State0, Data, Actions)
  when is_map_key(Pid, CtxS) ->
    case maps:get(Pid, CtxS) of
	{undefined, MRef} ->
	    ?LOG(emergency, "Switching tunnel bind from unknown to new restart counter ~w. "
		 "Despite the log level is this not a ciritical problem. However it is "
		 "not expected that this occurs outside of unit tests and should be "
		 "reported (but only once, please).", [RstCnt]),
	    State = State0#state{contexts = maps:put(Pid, {RstCnt, MRef}, CtxS)},
	    {next_state, State, Data, Actions};
	_ ->
	    {keep_state_and_data, Actions}
    end;
bind_tunnel(Pid, #state{recovery = RstCnt, contexts = CtxS} = State, Data, Actions) ->
    ?LOG(debug, "~s: register(~p)", [?MODULE, Pid]),
    MRef = erlang:monitor(process, Pid),
    update_contexts(State#state{contexts = maps:put(Pid, {RstCnt, MRef}, CtxS)}, Data, Actions).

unbind_tunnel(Pid, #state{contexts = CtxS} = State, Data)
  when is_map_key(Pid, CtxS) ->
    {_, MRef} = maps:get(Pid, CtxS),
    erlang:demonitor(MRef),
    update_contexts(State#state{contexts = maps:remove(Pid, CtxS)}, Data, []);
unbind_tunnel(_Pid, _State, _Data) ->
    keep_state_and_data.

%% assign_path/1
get_path(#tunnel{socket = Socket, version = Version,
		 remote = #fq_teid{ip = RemoteCntlIP}} = Tunnel, Trigger) ->
    Path = maybe_new_path(Socket, Version, RemoteCntlIP, Trigger),
    Tunnel#tunnel{path = Path}.

%% path might have died, returned a sensible error regardless
safe_aquire_lease(#tunnel{path = Path} = Tunnel) ->
    try gen_statem:call(Path, {aquire_lease, self()}) of
	{ok, {LRef, PathRestartCounter}} ->
	    {ok, {LRef, Tunnel#tunnel{remote_restart_counter = PathRestartCounter}}};
	{error, _} = Error ->
	    Error
    catch
	exit:{noproc, _} ->
	    {error, rejected}
    end.

%% path might have died, returned a sensible error regardless
safe_bind_tunnel(#tunnel{path = Path} = Tunnel) ->
    try gen_statem:call(Path, {bind_tunnel, self()}) of
	{ok, PathRestartCounter} ->
	    {ok, Tunnel#tunnel{remote_restart_counter = PathRestartCounter}};
	{error, _} = Error ->
	    Error
    catch
	exit:{noproc, _} ->
	    {error, rejected}
    end.

peer_state_cfg(State, Data) ->
    CfgState =
	case peer_state(State) of
	    PeerState when PeerState =:= busy; PeerState =:= idle;
			   PeerState =:= suspect; PeerState =:= down ->
		PeerState;
	    _ ->
		busy
	end,
    maps:get(CfgState, Data).

peer_state_event_action(_Event, #state{peer = down}, _Data) ->
    %% peer is already down, no need to transition anywhere
    keep_state_and_data;
peer_state_event_action(Event, State, Data) ->
    #{events := #{Event := Severity}} = peer_state_cfg(State, Data),
    ?LOG(debug, "got peer event ~p at serverity level ~p in state ~p",
	 [Event, Severity, State#state.peer]),
    case Severity of
	info ->
	    keep_state_and_data;
	warning ->
	    {next_state, State#state{peer = suspect}, Data};
	critical ->
	    {next_state, State#state{peer = down, recovery = undefined}, Data}
    end.

send_echo_request(State, #{socket := Socket, handler := Handler,
			   ip := DstIP, echo_cnt := Cnt} = Data) ->
    #{t3 := T3, n3 := N3} = peer_state_cfg(State, Data),
    Msg = Handler:build_echo_request(),
    Ref = erlang:make_ref(),
    CbInfo = {?MODULE, handle_response, [self(), echo_request, Ref]},
    ergw_gtp_c_socket:send_request(Socket, any, DstIP, ?GTP1c_PORT, T3, N3, Msg, CbInfo),
    {State#state{echo = Ref}, Data#{echo_cnt => Cnt + 1}}.

ring_path_restart(RstCnt, #{reg_key := Key}) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    erpc:multicast(riak_core_ring:all_members(Ring),
		   ?MODULE, path_restart, [Key, RstCnt]).

path_recovery_change(#state{recovery = RstCnt, contexts = CtxS0} = State,
		    #{down := #{notify := Notify}}) ->
    Path = self(),
    ResF =
	fun() ->
		foreach_context(RstCnt, maps:next(maps:iterator(CtxS0)),
				gtp_context:peer_down(_, Path, Notify))
	end,
    proc_lib:spawn(ResF),
    State.
