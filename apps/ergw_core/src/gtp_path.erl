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
-export([validate_options/1, setopts/1]).

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
	    {ok, Args} = getopts(),
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
    {t3, 10 * 1000},                  % echo retry interval
    {n3,  5},                         % echo retry count
    {echo, 60 * 1000},                % echo ping interval
    {idle, []},
    {suspect, []},
    {down, []},
    {icmp_error_handling, immediate}  % configurable GTP path ICMP error behaviour
]).
-define(IdleDefaults, [
    {timeout, 1800 * 1000},      % time to keep the path entry when idle
    {echo,     600 * 1000}       % echo retry interval when idle
]).
-define(SuspectDefaults, [
    {timeout, 300 * 1000},       % time to keep the path entry when suspect
    {echo,     60 * 1000}        % echo retry interval when suspect
]).
-define(DownDefaults, [
    {timeout, 3600 * 1000},      % time to keep the path entry when down
    {echo,     600 * 1000}       % echo retry interval when down
]).

validate_options(Values) ->
    ergw_core_config:validate_options(fun validate_option/2, Values, ?Defaults).

validate_echo(_Opt, Value) when is_integer(Value), Value >= 60 * 1000 ->
    Value;
validate_echo(_Opt, off = Value) ->
    Value;
validate_echo(Opt, Value) ->
    erlang:error(badarg, Opt ++ [echo, Value]).

validate_timeout(_Opt, Value) when is_integer(Value), Value >= 0 ->
    Value;
validate_timeout(_Opt, infinity = Value) ->
    Value;
validate_timeout(Opt, Value) ->
    erlang:error(badarg, Opt ++ [timeout, Value]).

validate_state(State, echo, Value) ->
    validate_echo([State], Value);
validate_state(State, timeout, Value) ->
    validate_timeout([State], Value);
validate_state(State, Opt, Value) ->
    erlang:error(badarg, [State, Opt, Value]).

validate_option(t3, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(n3, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(echo, Value) ->
    validate_echo([], Value);

validate_option(Opt = idle, Values) ->
    ergw_core_config:validate_options(validate_state(Opt, _, _), Values, ?IdleDefaults);
validate_option(Opt = suspect, Values) ->
    ergw_core_config:validate_options(validate_state(Opt, _, _), Values, ?SuspectDefaults);
validate_option(Opt = down, Values) ->
    ergw_core_config:validate_options(validate_state(Opt, _, _), Values, ?DownDefaults);
validate_option(icmp_error_handling, Value)
  when Value =:= immediate; Value =:= ignore ->
    Value;
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
    gtp_path_reg:register(RegKey, up),

    Data0 = maps:with([t3, n3, echo, idle, suspect, down, icmp_error_handling], Args),
    Data = Data0#{
	     %% Path Info Keys
	     socket     => Socket, % #socket{}
	     version    => Version, % v1 | v2
	     handler    => get_handler(Socket, Version),
	     ip         => RemoteIP,
	     reg_key    => RegKey,
	     time       => 0
	},

    State0 = #state{contexts = #{}, leases = #{}, echo = stopped},
    State =
	case Trigger of
	    activity ->
		State0#state{peer = up};
	    _ ->
		send_echo_request(State0#state{peer = unknown}, Data)
	end,

    gtp_path_reg:state(RegKey, State#state.peer),

    Actions = [enter_state_timeout_action(idle, Data),
	       enter_state_echo_action(idle, Data)],
    ?LOG(debug, "State: ~p~nData: ~p~nActions: ~p~n", [State, Data, Actions]),
    {ok, State, Data, Actions}.

handle_event(enter,
	     #state{peer = OldP, contexts = OldC} = OldS,
	     #state{peer = NewP, contexts = NewC} = State, Data)
  when OldP /= NewP; OldC /= NewC ->
    peer_state_change(OldS, State, Data),
    OldPState = peer_state(OldS),
    NewPState = peer_state(State),
    {keep_state_and_data, enter_peer_state_action(OldPState, NewPState, Data)};

handle_event(enter, #state{echo = Old}, #state{echo = Echo} = State, Data)
  when Old /= Echo ->
    PeerState = peer_state(State),
    {keep_state_and_data, enter_state_echo_action(PeerState, Data)};

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

handle_event({timeout, peer}, down, State, Data) ->
    ring_path_restart(undefined, Data),
    {next_state, path_recovery_change(undefined, State#state{peer = down}), Data};

handle_event({timeout, peer}, stop, _State, #{reg_key := RegKey}) ->
    gtp_path_reg:unregister(RegKey),
    {stop, normal};

handle_event({call, From}, all, #state{contexts = CtxS} = _State, _Data) ->
    Reply = maps:keys(CtxS),
    {keep_state_and_data, [{reply, From, Reply}]};

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
    {State, Data} = activity(When, What, State0, Data0),
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

handle_event(cast,{handle_response, echo_request, _, _Msg},
	     #state{peer = unknown} = State, Data) ->
    {next_state, State#state{peer = down}, Data};
handle_event(cast,{handle_response, echo_request, _, _Msg}, State, Data) ->
    {next_state, State#state{peer = suspect}, Data};

handle_event(cast, {path_restart, RstCnt}, #state{recovery = RstCnt} = _State, _Data)
  when is_integer(RstCnt) ->
    keep_state_and_data;
handle_event(cast, {path_restart, RstCnt}, State, Data) ->
    {next_state, path_recovery_change(RstCnt, State), Data};

handle_event(cast, icmp_error, _, #{icmp_error_handling := ignore}) ->
    keep_state_and_data;

handle_event(cast, icmp_error, State, Data) ->
    {next_state, State#state{peer = suspect}, Data};

handle_event(info, {'DOWN', MRef, process, _Pid, _Info}, #state{leases = Leases} = State, Data)
  when is_map_key(MRef, Leases) ->
    {next_state, State#state{leases = maps:remove(MRef, Leases)}, Data};

handle_event(info, {'DOWN', _MRef, process, Pid, _Info}, #state{contexts = CtxS} = State, Data)
  when is_map_key(Pid, CtxS) ->
    update_contexts(State#state{contexts = maps:remove(Pid, CtxS)}, Data, []);

handle_event(info,{'DOWN', _MRef, process, _Pid, _Info}, _State, _Data) ->
    keep_state_and_data;

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

enter_state_echo_action(busy, #{echo := EchoInterval}) when is_integer(EchoInterval) ->
    {{timeout, echo}, EchoInterval, start_echo};
enter_state_echo_action(idle, #{idle := #{echo := EchoInterval}})
  when is_integer(EchoInterval) ->
    {{timeout, echo}, EchoInterval, start_echo};
enter_state_echo_action(suspect, #{suspect := #{echo := EchoInterval}})
  when is_integer(EchoInterval) ->
    {{timeout, echo}, EchoInterval, start_echo};
enter_state_echo_action(down, #{down := #{echo := EchoInterval}})
  when is_integer(EchoInterval) ->
    {{timeout, echo}, EchoInterval, start_echo};
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

activity(When, #gtp{ie = #{{recovery, 0} :=
			       #recovery{restart_counter = RestartCounter}}}, State, Data) ->
    activity(When, RestartCounter, State, Data);
activity(When, #gtp{ie = #{{v2_recovery, 0} :=
			       #v2_recovery{restart_counter = RestartCounter}}}, State, Data) ->
    activity(When, RestartCounter, State, Data);
activity(When, #gtp{}, State, Data) ->
    activity(When, rx, State, Data);

activity(When, RstCnt, #state{recovery = RstCnt} = State, Data)
  when is_integer(RstCnt) ->
    rx(When, State, Data);
activity(When, RstCnt, State0, Data0)
  when is_integer(RstCnt) ->
    {Verdict, New, Data} = cas_restart_counter(RstCnt, Data0),
    State =
	case Verdict of
	    _ when Verdict == initial; Verdict == current ->
		State0#state{recovery = New};
	    peer_restart ->
		ring_path_restart(New, Data),
		path_recovery_change(New, State0);
	    _ ->
		State0
    end,
    rx(When, State, Data);

activity(When, rx, State, Data) ->
    rx(When, State, Data);
activity(_When, _What, State, Data) ->
    {State, Data}.

rx(When, State, #{last_seen := Last} = Data) when Last > When ->
    {State, Data};
rx(When, State, Data) ->
    %% TBD: reset state timeout
    {State#state{peer = up}, Data#{last_seen => When}}.

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
	    {next_state, path_recovery_change(New, State), Data};
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

send_echo_request(State, #{socket := Socket, handler := Handler, ip := DstIP,
			   t3 := T3, n3 := N3}) ->
    Msg = Handler:build_echo_request(),
    Ref = erlang:make_ref(),
    CbInfo = {?MODULE, handle_response, [self(), echo_request, Ref]},
    ergw_gtp_c_socket:send_request(Socket, any, DstIP, ?GTP1c_PORT, T3, N3, Msg, CbInfo),
    State#state{echo = Ref}.

ring_path_restart(RstCnt, #{reg_key := Key}) ->
    {ok, Ring} = riak_core_ring_manager:get_my_ring(),
    erpc:multicast(riak_core_ring:all_members(Ring),
		   ?MODULE, path_restart, [Key, RstCnt]).

path_recovery_change(RstCnt, #state{contexts = CtxS0} = State) ->
    Path = self(),
    ResF =
	fun() ->
		foreach_context(RstCnt, maps:next(maps:iterator(CtxS0)),
				gtp_context:path_restart(_, Path))
	end,
    proc_lib:spawn(ResF),
    State#state{recovery = RstCnt}.
