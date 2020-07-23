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

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-ifdef(TEST).
-export([ping/3, stop/1]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

%% echo_timer is the status of the echo send to the remote peer
-record(state, {peer       :: 'UP' | 'DOWN',                     %% State of remote peer
		recovery   :: 'undefined' | non_neg_integer(),
		contexts   :: gb_sets:set(pid()),                %% set of context pids
		echo_timer :: 'stopped' | 'echo_to_send' | 'awaiting_response'}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(GtpPort, Version, RemoteIP, Args) ->
    Opts = [{hibernate_after, 5000},
	    {spawn_opt,[{fullsweep_after, 0}]}],
    gen_statem:start_link(?MODULE, [GtpPort, Version, RemoteIP, Args], Opts).

maybe_new_path(GtpPort, Version, RemoteIP) ->
    case get(GtpPort, Version, RemoteIP) of
	Path when is_pid(Path) ->
	    Path;
	_ ->
	    {ok, Path} = gtp_path_sup:new_path(GtpPort, Version, RemoteIP, []),
	    Path
    end.

handle_request(#request{gtp_port = GtpPort, ip = IP} = ReqKey, #gtp{version = Version} = Msg) ->
    Path = maybe_new_path(GtpPort, Version, IP),
    gen_statem:cast(Path, {handle_request, ReqKey, Msg}).

handle_response(Path, Request, Ref, Response) ->
    gen_statem:cast(Path, {handle_response, Request, Ref, Response}).

bind(#context{remote_restart_counter = RestartCounter} = Context) ->
    path_recovery(RestartCounter, bind_path(Context)).

bind(#gtp{ie = #{{recovery, 0} :=
		     #recovery{restart_counter = RestartCounter}}
	 } = Request, Context) ->
    path_recovery(RestartCounter, bind_path(Request, Context));
bind(#gtp{ie = #{{v2_recovery, 0} :=
		     #v2_recovery{restart_counter = RestartCounter}}
	 } = Request, Context) ->
    path_recovery(RestartCounter, bind_path(Request, Context));
bind(Request, Context) ->
    path_recovery(undefined, bind_path(Request, Context)).

unbind(#context{version = Version, control_port = GtpPort,
		remote_control_teid = #fq_teid{ip = RemoteIP}}) ->
    case get(GtpPort, Version, RemoteIP) of
	Path when is_pid(Path) ->
	    gen_statem:call(Path, {unbind, self()});
	_ ->
	    ok
    end.

down(GtpPort, IP) ->
    down(GtpPort, v1, IP),
    down(GtpPort, v2, IP).

down(GtpPort, Version, IP) ->
    case get(GtpPort, Version, IP) of
	Path when is_pid(Path) ->
	    gen_statem:cast(Path, down);
	_ ->
	    ok
    end.

get(#gtp_port{name = PortName}, Version, IP) ->
    gtp_path_reg:lookup({PortName, Version, IP}).

all(Path) ->
    gen_statem:call(Path, all).

info(Path) ->
    gen_statem:call(Path, info).

get_handler(#gtp_port{type = 'gtp-u'}, _) ->
    gtp_v1_u;
get_handler(#gtp_port{type = 'gtp-c'}, v1) ->
    gtp_v1_c;
get_handler(#gtp_port{type = 'gtp-c'}, v2) ->
    gtp_v2_c.

-ifdef(TEST).
ping(GtpPort, Version, IP) ->
    case get(GtpPort, Version, IP) of
	Path when is_pid(Path) ->
	    gen_statem:cast(Path, '$ping');
	_ ->
	    ok
    end.

stop(Path) ->
    gen_statem:call(Path, '$stop').

-endif.


%%%===================================================================
%%% Protocol Module API
%%%===================================================================

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

callback_mode() -> [handle_event_function, state_enter].

init([#gtp_port{name = PortName} = GtpPort, Version, RemoteIP, Args]) ->
    gtp_path_reg:register({PortName, Version, RemoteIP}),

    State = #state{peer       = 'UP',
		   contexts   = gb_sets:empty(),
		   echo_timer = stopped},

    Data = #{
	     %% Path Info Keys
	     gtp_port   => GtpPort, % #gtp_port{}
	     version    => Version, % v1 | v2
	     handler    => get_handler(GtpPort, Version),
	     ip         => RemoteIP,
	     %% Echo Info values
	     t3         => proplists:get_value(t3, Args, 10 * 1000), %% 10sec
	     n3         => proplists:get_value(n3, Args, 5),
	     echo       => proplists:get_value(ping, Args, 60 * 1000)
	},

    ?LOG(debug, "State: ~p Data: ~p", [State, Data]),
    {ok, State, Data}.

handle_event(enter, #state{contexts = OldCtxS}, #state{contexts = CtxS}, Data)
  when OldCtxS =/= CtxS ->
    Actions = update_path_counter(gb_sets:size(CtxS), Data),
    {keep_state_and_data, Actions};
handle_event(enter, #state{echo_timer = OldEchoT}, #state{echo_timer = idle},
	     #{echo := EchoInterval}) when OldEchoT =/= idle ->
    {keep_state_and_data, [{{timeout, echo}, EchoInterval, start_echo}]};
handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event({timeout, echo}, stop_echo, State, Data) ->
    {next_state, State#state{echo_timer = stopped}, Data, [{{timeout, echo}, cancel}]};

handle_event({timeout, echo}, start_echo, #state{echo_timer = EchoT} = State0, Data)
  when EchoT =:= stopped;
       EchoT =:= idle ->
    State = send_echo_request(State0, Data),
    {next_state, State, Data};
handle_event({timeout, echo}, start_echo, _State, _Data) ->
    keep_state_and_data;

handle_event({call, From}, all, #state{contexts = CtxS}, _Data) ->
    Reply = gb_sets:to_list(CtxS),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {bind, Pid}, #state{recovery = RestartCounter} = State0, Data) ->
    State = register(Pid, State0),
    {next_state, State, Data, [{reply, From, {ok, RestartCounter}}]};

handle_event({call, From}, {bind, Pid, RestartCounter}, State0, Data) ->
    State1 = update_restart_counter(RestartCounter, State0, Data),
    State = register(Pid, State1),
    {next_state, State, Data, [{reply, From, ok}]};

handle_event({call, From}, {unbind, Pid}, State0, Data) ->
    State = unregister(Pid, State0),
    {next_state, State, Data, [{reply, From, ok}]};

handle_event({call, From}, info, #state{contexts = CtxS} = State,
	     #{gtp_port := #gtp_port{name = Name},
	       version := Version, ip := IP}) ->
    Cnt = gb_sets:size(CtxS),
    Reply = #{path => self(), port => Name, tunnels => Cnt,
	      version => Version, ip => IP, state => State},
    {keep_state_and_data, [{reply, From, Reply}]};

%% test support
handle_event({call, From}, '$stop', _State, _Data) ->
    {stop_and_reply, normal, [{reply, From, ok}]};

handle_event({call, From}, Request, _State, Data) ->
    ?LOG(warning, "handle_event(call,...): ~p", [Request]),
    {keep_state_and_data, [{reply, From, ok}]};

handle_event(cast, {handle_request, ReqKey, #gtp{type = echo_request} = Msg0},
	     State0, #{gtp_port := GtpPort, handler := Handler} = Data) ->
    ?LOG(debug, "echo_request: ~p", [Msg0]),
    try gtp_packet:decode_ies(Msg0) of
	Msg = #gtp{} ->
	    State = handle_recovery_ie(Msg, State0, Data),

	    ResponseIEs = Handler:build_recovery(echo_response, GtpPort, true, []),
	    Response = Msg#gtp{type = echo_response, ie = ResponseIEs},
	    ergw_gtp_c_socket:send_response(ReqKey, Response, false),
	    {next_state, State, Data}
    catch
	Class:Error ->
	    ?LOG(error, "GTP decoding failed with ~p:~p for ~p",
		 [Class, Error, Msg0]),
	    keep_state_and_data
    end;

handle_event(cast, down, State, Data) ->
    {next_state, path_down(undefined, State), Data};

handle_event(cast, {handle_response, echo_request, ReqRef, _Msg}, #state{echo_timer = SRef}, _)
  when ReqRef /= SRef ->
    keep_state_and_data;

handle_event(cast,{handle_response, echo_request, _, Msg}, State0, Data) ->
    ?LOG(debug, "echo_response: ~p", [Msg]),
    State1 = handle_recovery_ie(Msg, State0, Data),
    State = echo_response(Msg, State1),
    {next_state, State, Data};

%% test support
handle_event(cast, '$ping', #state{echo_timer = Ref}, _Data)
  when is_reference(Ref) ->
    keep_state_and_data;
handle_event(cast, '$ping', #state{echo_timer = idle} = State0, Data) ->
    State = send_echo_request(State0, Data),
    {next_state, State, Data, [{{timeout, echo}, cancel}]};

handle_event(cast, Msg, _State, _Data) ->
    ?LOG(error, "~p: ~w: handle_event(cast, ...): ~p", [self(), ?MODULE, Msg]),
    keep_state_and_data;

handle_event(info,{'DOWN', _MonitorRef, process, Pid, _Info}, State0, Data) ->
    State = unregister(Pid, State0),
    {next_state, State, Data};

handle_event({timeout, 'echo'}, _, #state{echo_timer = idle} = State0, Data) ->
    ?LOG(debug, "handle_event timeout: ~p", [Data]),
    State = send_echo_request(State0, Data),
    {next_state, State, Data};

handle_event({timeout, 'echo'}, _, _State, _Data) ->
    ?LOG(debug, "handle_event timeout: ~p", [_Data]),
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
%%% Internal functions
%%%===================================================================

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

update_restart_counter(Counter, #state{recovery = undefined} = State, _Data) ->
    State#state{recovery = Counter};
update_restart_counter(Counter, #state{recovery = Counter} = State, _Data) ->
    State;
update_restart_counter(New, #state{recovery = Old} = State, #{ip := IP})
  when ?SMALLER(Old, New) ->
    ?LOG(warning, "GSN ~s restarted (~w != ~w)",
	 [inet:ntoa(IP), Old, New]),
    path_down(New, State);

update_restart_counter(New, #state{recovery = Old} = State, #{ip := IP})
  when not ?SMALLER(Old, New) ->
    ?LOG(warning, "possible race on message with restart counter for GSN ~s (old: ~w, new: ~w)",
	 [inet:ntoa(IP), Old, New]),
    State.

handle_recovery_ie(#gtp{version = v1,
			ie = #{{recovery, 0} :=
				   #recovery{restart_counter =
						 RestartCounter}}}, State, Data) ->
    update_restart_counter(RestartCounter, State, Data);

handle_recovery_ie(#gtp{version = v2,
			ie = #{{v2_recovery, 0} :=
				   #v2_recovery{restart_counter =
						    RestartCounter}}}, State, Data) ->
    update_restart_counter(RestartCounter, State, Data);
handle_recovery_ie(_Msg, State, _Data) ->
    State.

foreach_context(none, _Fun) ->
    ok;
foreach_context({Pid, Iter}, Fun) ->
    Fun(Pid),
    foreach_context(gb_sets:next(Iter), Fun).

register(Pid, #state{contexts = CtxS} = State) ->
    ?LOG(debug, "~s: register(~p)", [?MODULE, Pid]),
    erlang:monitor(process, Pid),
    State#state{contexts = gb_sets:add_element(Pid, CtxS)}.

unregister(Pid, #state{contexts = CtxS} = State) ->
    State#state{contexts = gb_sets:del_element(Pid, CtxS)}.

update_path_counter(PathCounter, #{gtp_port := GtpPort, version := Version, ip := IP}) ->
    ergw_prometheus:gtp_path_contexts(GtpPort, IP, Version, PathCounter),
    if PathCounter =:= 0 ->
	    [{{timeout, echo}, 0, stop_echo}];
       true ->
	    [{{timeout, echo}, 0, start_echo}]
    end.

bind_path(#gtp{version = Version}, Context) ->
    bind_path(Context#context{version = Version}).

bind_path(#context{version = Version, control_port = CntlGtpPort,
		   remote_control_teid = #fq_teid{ip = RemoteCntlIP}} = Context) ->
    Path = maybe_new_path(CntlGtpPort, Version, RemoteCntlIP),
    Context#context{path = Path}.

path_recovery(RestartCounter, #context{path = Path} = Context)
  when is_integer(RestartCounter) ->
    ok = gen_statem:call(Path, {bind, self(), RestartCounter}),
    Context#context{remote_restart_counter = RestartCounter};
path_recovery(_RestartCounter, #context{path = Path} = Context) ->
    {ok, PathRestartCounter} = gen_statem:call(Path, {bind, self()}),
    Context#context{remote_restart_counter = PathRestartCounter}.

send_echo_request(State, #{gtp_port := GtpPort, handler := Handler, ip := DstIP,
		    t3 := T3, n3 := N3}) ->
    Msg = Handler:build_echo_request(GtpPort),
    Ref = erlang:make_ref(),
    CbInfo = {?MODULE, handle_response, [self(), echo_request, Ref]},
    ergw_gtp_c_socket:send_request(GtpPort, DstIP, ?GTP1c_PORT, T3, N3, Msg, CbInfo),
    State#state{echo_timer = Ref}.

echo_response(Msg, State) ->
    update_path_state(Msg, State#state{echo_timer = idle}).

update_path_state(#gtp{}, State) ->
    State#state{peer = 'UP'};
update_path_state(_, State) ->
    path_down(undefined, State#state{peer = 'DOWN'}).

path_down(RestartCounter, #state{contexts = CtxS} = State) ->
    Path = self(),
    proc_lib:spawn(
      fun() ->
	      foreach_context(gb_sets:next(gb_sets:iterator(CtxS)),
			      gtp_context:path_restart(_, Path))
      end),
    State#state{
      recovery = RestartCounter,
      contexts = gb_sets:empty()
     }.
