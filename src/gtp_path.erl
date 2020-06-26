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
	 handle_request/2, handle_response/3,
	 bind/1, bind/2, unbind/1, down/2,
	 get_handler/2, info/1]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-ifdef(TEST).
-export([ping/3]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

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

handle_request(#request{gtp_port = GtpPort, ip = IP} = ReqKey, 
	       #gtp{version = Version} = Msg) ->
    Path = maybe_new_path(GtpPort, Version, IP),
    gen_statem:cast(Path, {handle_request, ReqKey, Msg}).

handle_response(Path, Request, Response) ->
    gen_statem:cast(Path, {handle_response, Request, Response}).

bind(#context{remote_restart_counter = RestartCounter} = Context) ->
    path_recovery(RestartCounter, bind_path(Context)).

bind(#gtp{ie = #{{recovery, 0} := #recovery{restart_counter = RestartCounter}}
	 } = Request, Context) ->
    path_recovery(RestartCounter, bind_path(Request, Context));
bind(#gtp{ie = #{{v2_recovery, 0} := #v2_recovery{restart_counter = RestartCounter}}
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
-endif.


%%%===================================================================
%%% Protocol Module API
%%%===================================================================

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

callback_mode() -> [handle_event_function, state_enter].

% State =  'UP' | 'DOWN'
init([#gtp_port{name = PortName} = GtpPort, Version, RemoteIP, Args]) ->
    gtp_path_reg:register({PortName, Version, RemoteIP}),

    Data = #{
             % Path Info Keys
	     gtp_port   => GtpPort,
	     version    => Version,
	     handler    => get_handler(GtpPort, Version),
	     ip         => RemoteIP,
	     recovery   => undefined,
	     % Echo Info Keys
	     t3         => proplists:get_value(t3, Args, 10 * 1000), %% 10sec
	     n3         => proplists:get_value(n3, Args, 5),
	     echo       => proplists:get_value(ping, Args, 60 * 1000),
	     echo_timer => stopped,
	     % Table Info Keys
	     table      => ets_new()  % tid
	    },

    ?LOG(debug, "State = UP, Data: ~p", [Data]),
    {ok, 'UP', Data}.

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event({call, From}, all, _State, #{table := TID}) ->
    Reply = ets:tab2list(TID),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {bind, Pid}, _State, #{recovery := RestartCounter} = Data0) ->
    Data = register(Pid, Data0),
    {keep_state, Data, [{reply, From, {ok, RestartCounter}}]};

handle_event({call, From}, {bind, Pid, RestartCounter}, _State, Data0) ->
    Data1 = update_restart_counter(RestartCounter, Data0),
    Data = register(Pid, Data1),
    {keep_state, Data, [{reply, From, ok}]};

handle_event({call, From}, {unbind, Pid}, _State, Data0) ->
    Data = unregister(Pid, Data0),
    {keep_state, Data, [{reply, From, ok}]};

handle_event({call, From}, info, State, 
	     #{table := TID, gtp_port := #gtp_port{name = Name}, 
	       version := Version, ip := IP}) ->
    Cnt = ets:info(TID, size),
    Reply = #{path => self(), port => Name, tunnels => Cnt,
	      version => Version, ip => IP, state => State},
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, _From}, Request, _State, Data) ->
    ?LOG(warning, "handle_event(call,...): ~p", [Request]),
    {keep_state_and_data, [{reply, ok, Data}]};

handle_event(cast, {handle_request, ReqKey, #gtp{type = echo_request} = Msg0},
	     _State, #{gtp_port := GtpPort, handler := Handler} = Data0) ->
    ?LOG(debug, "echo_request: ~p", [Msg0]),
    try gtp_packet:decode_ies(Msg0) of
	Msg = #gtp{} ->

	    Data = handle_recovery_ie(Msg, Data0),

	    ResponseIEs = Handler:build_recovery(echo_response, GtpPort, true, []),
	    Response = Msg#gtp{type = echo_response, ie = ResponseIEs},
	    ergw_gtp_c_socket:send_response(ReqKey, Response, false),
	    {keep_state, Data}
    catch
	Class:Error ->
	    ?LOG(error, "GTP decoding failed with ~p:~p for ~p",
		 [Class, Error, Msg0]),
	    {keep_state, Data0}
    end;

handle_event(cast, down, _State, Data0) ->
    Data = path_down(undefined, Data0),
    {keep_state, Data};

handle_event(cast,{handle_response, echo_request, 
		   #gtp{type = echo_response} = Msg}, State0, Data0) ->
    ?LOG(debug, "echo_response: ~p", [Msg]),
    Data1 = handle_recovery_ie(Msg, Data0),
    {State, Data} = echo_response(Msg, State0, Data1),
    {next_state, State, Data};

handle_event(cast,{handle_response, echo_request, timeout = Msg}, State0, Data0) ->
    ?LOG(debug, "echo_response: ~p", [Msg]),
    {State, Data} = echo_response(Msg, State0, Data0),
    {next_state, State, Data};

%% test support
handle_event(cast, '$ping', _State, #{echo_timer := awaiting_response}) ->
    keep_state_and_data;
handle_event(cast, '$ping', _State, #{echo_timer := TRef} = Data0)
  when is_reference(TRef) ->
    cancel_timer(TRef),
    Data = send_echo_request(Data0),
    {keep_state, Data};

handle_event(cast, Msg, _State, _Data) ->
    ?LOG(error, "~p: ~w: handle_event(cast, ...): ~p", [self(), ?MODULE, Msg]),
    keep_state_and_data;

handle_event(info,{'DOWN', _MonitorRef, process, Pid, _Info}, _State, Data0) ->
    Data = unregister(Pid, Data0),
    {keep_state, Data};

handle_event(info, Info = {timeout, TRef, echo}, _State, #{echo_timer := TRef} = Data0) ->
    ?LOG(debug, "handle_event(info, ...): ~p", [Info]),
    Data = send_echo_request(Data0),
    {keep_state, Data};

handle_event(info, Info = {timeout, _TRef, echo}, _State, Data) ->
    ?LOG(debug, "handle_event(info, ...): ~p", [Info]),
    {keep_state, Data};

handle_event(info, Info, _State, Data) ->
    ?LOG(error, "~p: ~w: handle_event(info, ...): ~p", [self(), ?MODULE, Info]),
    {keep_state, Data}.

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

update_restart_counter(RestartCounter, #{recovery := undefined} = Data) ->
    Data#{recovery => RestartCounter};
update_restart_counter(RestartCounter, #{recovery := RestartCounter} = Data) ->
    Data;
update_restart_counter(NewRestartCounter, #{ip := IP, recovery := OldRestartCounter} = Data)
  when ?SMALLER(OldRestartCounter, NewRestartCounter) ->
    ?LOG(warning, "GSN ~s restarted (~w != ~w)",
	 [inet:ntoa(IP), OldRestartCounter, NewRestartCounter]),
    path_down(NewRestartCounter, Data);

update_restart_counter(NewRestartCounter, #{ip := IP, recovery := OldRestartCounter} = Data)
  when not ?SMALLER(OldRestartCounter, NewRestartCounter) ->
    ?LOG(warning, "possible race on message with restart counter for GSN ~s (old: ~w, new: ~w)",
	 [inet:ntoa(IP), OldRestartCounter, NewRestartCounter]),
    Data.

handle_recovery_ie(#gtp{version = v1,
			ie = #{{recovery, 0} :=
				   #recovery{restart_counter =
						 RestartCounter}}}, Data) ->
    update_restart_counter(RestartCounter, Data);

handle_recovery_ie(#gtp{version = v2,
			ie = #{{v2_recovery, 0} :=
				   #v2_recovery{restart_counter =
						    RestartCounter}}}, Data) ->
    update_restart_counter(RestartCounter, Data);
handle_recovery_ie(_Msg, Data) ->
    Data.

ets_new() ->
    ets:new(?MODULE, [public, ordered_set, {keypos, 1}]).

ets_foreach(TID, Fun) ->
    ets_foreach(TID, Fun, ets:match(TID, {'$1'}, 100)).

ets_foreach(_TID, _Fun, '$end_of_table') ->
    ok;
ets_foreach(TID, Fun, {Pids, Continuation})
  when is_list(Pids) ->
    lists:foreach(fun([Pid]) -> Fun(Pid) end, Pids),
    ets_foreach(TID, Fun, ets:match_object(Continuation)).

register(Pid, #{table := TID} = Data) ->
    ?LOG(debug, "~s: register(~p)", [?MODULE, Pid]),
    erlang:monitor(process, Pid),
    ets:insert(TID, {Pid}),
    update_path_counter(ets:info(TID, size), Data).

unregister(Pid, #{table := TID} = Data) ->
    ets:delete(TID, Pid),
    update_path_counter(ets:info(TID, size), Data).

update_path_counter(PathCounter, #{gtp_port := GtpPort, version := Version, ip := IP} = Data) ->
    ergw_prometheus:gtp_path_contexts(GtpPort, IP, Version, PathCounter),
    if PathCounter =:= 0 ->
	    stop_echo_request(Data);
       true ->
	    start_echo_request(Data)
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

cancel_timer(Ref) ->
    case erlang:cancel_timer(Ref) of
        false ->
            receive {timeout, Ref, _} -> 0
            after 0 -> false
            end;
        RemainingTime ->
            RemainingTime
    end.

start_echo_request(#{echo_timer := stopped} = Data) ->
    send_echo_request(Data);
start_echo_request(Data) ->
    Data.

stop_echo_request(#{echo_timer := EchoTRef} = Data) ->
    if is_reference(EchoTRef) ->
	    cancel_timer(EchoTRef);
       true ->
	    ok
    end,
    Data#{echo_timer => stopped}.

send_echo_request(#{gtp_port := GtpPort, handler := Handler, ip := DstIP,
		    t3 := T3, n3 := N3} = Data) ->
    Msg = Handler:build_echo_request(GtpPort),
    CbInfo = {?MODULE, handle_response, [self(), echo_request]},
    ergw_gtp_c_socket:send_request(GtpPort, DstIP, ?GTP1c_PORT, T3, N3, Msg, CbInfo),
    Data#{echo_timer => awaiting_response}.

echo_response(Msg, State0, #{echo := EchoInterval, 
			     echo_timer := awaiting_response} = Data0) ->
    {State, Data} = update_path_state(Msg, State0, Data0),
    TRef = erlang:start_timer(EchoInterval, self(), echo),
    {State, Data#{echo_timer => TRef}};
echo_response(Msg, State, Data) ->
    update_path_state(Msg, State, Data).

update_path_state(#gtp{}, _State, Data) ->
    {'UP', Data};
update_path_state(_, _State, Data) ->
    {'DOWN', path_down(undefined, Data)}.

path_down(RestartCounter, #{table := TID} = Data0) ->
    Path = self(),
    proc_lib:spawn(fun() ->
			   ets_foreach(TID, gtp_context:path_restart(_, Path)),
			   ets:delete(TID)
		   end),
    Data = Data0#{table => ets_new(), recovery => RestartCounter},
    update_path_counter(0, Data).
