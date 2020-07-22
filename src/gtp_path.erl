%% Copyright 2015, 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_path).

-behavior(gen_statem).

-compile({parse_transform, cut}).
% -compile({no_auto_import,[register/2]}).

%% API
-export([start_link/4, all/1,
	 maybe_new_path/3,
	 handle_request/2, handle_response/3,
	 bind/1, bind/2, bind_with_pm/1, unbind/1, down/2,
	 get_handler/2, info/1]).

%% Validate environment Variables
-export([validate_options/1]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-ifdef(TEST).
-export([ping/3, stop/1]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

%% echo_timer is the status of the echo send to the remote peer.
%% Note that the State peer = 'INACTIVE' is on applicable for outgoing 
%% monitored peers (proxy mode).
-record(state, {peer :: 'UP' | 'DOWN' | 'INACTIVE', % State of remote peer
                echo_timer :: 'stopped' | 'echo_to_send' |
                              'awaiting_response' | 'peer_down'}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(GtpPort, Version, RemoteIP, Args) ->
    Opts = [{hibernate_after, 5000},
	    {spawn_opt,[{fullsweep_after, 0}]}],
    gen_statem:start_link(?MODULE, [GtpPort, Version, RemoteIP, Args], Opts).

maybe_new_path(GtpPort, Version, RemoteIP) ->
    maybe_new_path(GtpPort, Version, RemoteIP, false). % Def, No down peer monitoring

maybe_new_path(GtpPort, Version, RemoteIP, PDMonF) ->
    case get(GtpPort, Version, RemoteIP) of
	Path when is_pid(Path) ->
	    Path;
	_ ->
	    Args = application:get_env(ergw, path_management, []),
	    ArgsNorm = normalise(Args, []),
	    {ok, Path} = gtp_path_sup:new_path(GtpPort, Version, RemoteIP,
					       [{'pd_mon_f',PDMonF} | ArgsNorm]),
	    Path
    end.

handle_request(#request{gtp_port = GtpPort, ip = IP} = ReqKey,
	       #gtp{version = Version} = Msg) ->
    Path = maybe_new_path(GtpPort, Version, IP),
    gen_statem:cast(Path, {handle_request, ReqKey, Msg}).

handle_response(Path, Request, Response) ->
    gen_statem:cast(Path, {handle_response, Request, Response}).

bind_with_pm(#context{remote_restart_counter = RestartCounter} = Context) ->
    path_recovery(RestartCounter, bind_path_with_pm(Context, true)).

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

stop(Path) ->
    gen_statem:call(Path, '$stop').

-endif.


%%%===================================================================
%%% Options Validation
%%%===================================================================
validate_options(Values) ->
    ergw_config:validate_options(fun validate_option/2, Values, [], list).

%% echo retry interval timeout in Seconds
validate_option(t3, Value) when is_integer(Value) andalso Value > 0 ->
    Value;
%% echo retry Count
validate_option(n3, Value) when is_integer(Value) andalso Value > 0 ->
    Value;
%% echo ping interval (minimum value 60 seconds, 3GPP 23.007, Chap 20)
validate_option(ping, Value) when is_integer(Value) andalso Value >= 60 ->
    Value;
%% peer down echo check if restored interval in seconds (>= 60)
validate_option(pd_mon_t, Value) when is_integer(Value) andalso Value >= 60 -> 
    Value;
%% peer down monitoring duration in seconds (>= 60)
validate_option(pd_mon_dur, Value) when is_integer(Value) andalso Value >= 60 ->
    Value;
validate_option(Par, Value) ->
    throw({error, {options, {Par, Value}}}).

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
                   echo_timer = 'stopped'},

% Timer value: echo    = echo interval when peer is up.
% Timer valUe: pd_echo = echo interval when peer is down (proxy mode)
% Timer value: pd_dur  = Total duration for which echos are sent to 
%                        down peer, before the path is cleared (Proxy Mode)
% Note that the gen_statem timer 'name' in the Action arg is the same as 
% the timer value atom name above. 
    Data = #{
             % Path Info Keys
	     gtp_port => GtpPort, % #gtp_port{}
	     version  => Version, % v1 | v2
	     handler  => get_handler(GtpPort, Version),
	     ip       => RemoteIP,
	     recovery => undefined, % undefined | non_neg_integer
	     pd_mon_f => proplists:get_value(pd_mon_f, Args, false), % true | false
	     % Echo Info values
	     t3       => proplists:get_value(t3, Args, timer:seconds(10)),
	     n3       => proplists:get_value(n3, Args, 5),
	     echo     => proplists:get_value(ping, Args, timer:seconds(60)),
	     pd_echo  => proplists:get_value(pd_mon_t, Args, timer:seconds(300)),
	     pd_dur   => proplists:get_value(pd_mon_dur, Args, timer:seconds(7200)),       
	     % Table Info Keys
	     table    => ets_new()  % tid
        },

    ?LOG(debug, "State: ~p Data: ~p", [State, Data]),
    {ok, State, Data}.

<<<<<<< HEAD
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
=======
handle_event(enter, _OldState, _State, _Data) ->
>>>>>>> rebasing on master changes 22-July-2020
    keep_state_and_data;

handle_event({call, From}, all, _State, #{table := TID}) ->
    Reply = ets:tab2list(TID),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {bind, Pid}, State0, 
	     #{recovery := RestartCounter} = Data) ->
    State = register(Pid, State0, Data),
    {next_state, State, Data, [{reply, From, {ok, RestartCounter}}]};

handle_event({call, From}, {bind, Pid, RestartCounter}, State0, Data0) ->
    {State1, Data} = update_restart_counter(RestartCounter, State0, Data0),
    State = register(Pid, State1, Data),
    {next_state, State, Data, [{reply, From, ok}]};

handle_event({call, From}, {unbind, Pid}, State0, Data) ->
    State = unregister(Pid, State0, Data),
    case State of
	#state{echo_timer = 'stopped'} ->
	    Actions = timeout_action([{reply, From, ok}], infinity, 'echo'),
	    {next_state, State, Data, Actions};
	_ ->
	    {keep_state, Data, [{reply, From, ok}]}
    end;

handle_event({call, From}, info, State,
	     #{table := TID, gtp_port := #gtp_port{name = Name},
	       version := Version, ip := IP}) ->
    Cnt = ets:info(TID, size),
    Reply = #{path => self(), port => Name, tunnels => Cnt,
	      version => Version, ip => IP, state => State},
    {keep_state_and_data, [{reply, From, Reply}]};

%% test support
handle_event({call, From}, '$stop', _State, _Data) ->
    {stop_and_reply, normal, [{reply, From, ok}]};

handle_event({call, From}, Request, _State, Data) ->
    ?LOG(warning, "handle_event(call,...): ~p", [Request]),
    {keep_state_and_data, [{reply, From, ok}]};

%% If an echo request received from down peer i.e state = 'INACTIVE', then
%% cancel peer down duration timer, Peer down echo timer.
%% wait for first GTP Msg to start sending normal echos again. 
handle_event(cast, {handle_request, ReqKey, #gtp{type = echo_request} = Msg0}, 
	     #state{peer = 'INACTIVE'} = State0,
	     #{gtp_port := GtpPort, ip := RemoteIP, handler := Handler} = Data0) ->
    ?LOG(debug, "echo_request from inactive peer: ~p", [Msg0]),
    try gtp_packet:decode_ies(Msg0) of
        Msg = #gtp{} ->
            {State, Data} = handle_recovery_ie(Msg, State0, Data0),

            ResponseIEs = Handler:build_recovery(echo_response, GtpPort, true, []),
            Response = Msg#gtp{type = echo_response, ie = ResponseIEs},
            ergw_gtp_c_socket:send_response(ReqKey, Response, false),
            gtp_path_reg:remove_down_peer(RemoteIP),
            Actions0 = timeout_action([], infinity, 'pd_echo'),
            Actions = timeout_action(Actions0, infinity, 'pd_dur'),
            {next_state, State#state{peer ='DOWN', echo_timer = 'stopped'}, Data, 
             Actions}
    catch
	Class:Error ->
	    ?LOG(error, "GTP decoding failed with ~p:~p for ~p", [Class, Error, Msg0]),
	    {noreply, State0}
    end;

handle_event(cast, {handle_request, ReqKey, #gtp{type = echo_request} = Msg0},
	     State0, #{gtp_port := GtpPort, handler := Handler} = Data0) ->
    ?LOG(debug, "echo_request: ~p", [Msg0]),
    try gtp_packet:decode_ies(Msg0) of
	Msg = #gtp{} ->

	    {State, Data} = handle_recovery_ie(Msg, State0, Data0),

	    ResponseIEs = Handler:build_recovery(echo_response, GtpPort, true, []),
	    Response = Msg#gtp{type = echo_response, ie = ResponseIEs},
	    ergw_gtp_c_socket:send_response(ReqKey, Response, false),
	    {next_state, State, Data}
    catch
	Class:Error ->
	    ?LOG(error, "GTP decoding failed with ~p:~p for ~p",
		 [Class, Error, Msg0]),
	    {keep_state, Data0}
    end;

handle_event(cast, down, State, Data0) ->
    {State, Data} = path_down(undefined, State, Data0),
    {next_state, State, Data};

handle_event(cast,{handle_response, echo_request, #gtp{type = echo_response} = Msg},
	     State0, #{echo := EchoInterval} = Data0) ->
    ?LOG(debug, "echo_response: ~p", [Msg]),
    {State1, Data1} = handle_recovery_ie(Msg, State0, Data0),
    {State, Data, Actions} = echo_response(Msg, State1, Data1),
    case State of
        #state{echo_timer = 'echo_to_send'} ->
            Actions1 = timeout_action(Actions, EchoInterval, 'echo'),
            {next_state, State, Data, Actions1};
        _ ->
            {next_state, State, Data, Actions}
    end;

% Echo timeout after 10 Sec when node is down,
% do nothing, node still down, send next send echo when erlang timer expires
handle_event(cast, {handle_response, echo_request, timeout = Msg},
	     #state{peer = 'INACTIVE', echo_timer = 'peer_down'},
	     #{pd_echo := PDEchoInterval})->
    ?LOG(debug, "echo timeout_from_down_peer: ~p", [Msg]),
    Actions = timeout_action([], PDEchoInterval, 'pd_echo'),
    {keep_state_and_data, Actions};

handle_event(cast,{handle_response, echo_request, timeout = Msg}, State0, Data0) ->
    ?LOG(debug, "echo_response: ~p", [Msg]),
    {State, Data, Actions0} = echo_response(Msg, State0, Data0),
    Actions = timeout_action(Actions0, infinity, 'echo'),
    {next_state, State, Data, Actions};

%% test support
handle_event(cast, '$ping', #state{echo_timer = 'awaiting_response'}, _Data) ->
    keep_state_and_data;
handle_event(cast, '$ping', #state{echo_timer = 'echo_to_send'} = State0, Data) ->
    State = send_echo_request(State0, Data),
    Actions = timeout_action([], infinity, 'echo'),
    {next_state, State, Data, Actions};
handle_event(cast, '$ping', #state{echo_timer = 'peer_down'} = State0, Data) ->
    State = monitor_down_peer(State0, Data),
    {next_state, State, Data};
    handle_event(cast, '$ping', _State, _Data) ->
        {keep_state_and_data};
    
handle_event(cast, Msg, _State, _Data) ->
    ?LOG(error, "~p: ~w: handle_event(cast, ...): ~p", [self(), ?MODULE, Msg]),
    keep_state_and_data;

handle_event(info,{'DOWN', _MonitorRef, process, Pid, _Info}, State0, Data) ->
    State = unregister(Pid, State0, Data),
    case State of
	#state{echo_timer = 'stopped'} ->
	    Actions = timeout_action([], infinity, 'echo'),
	    {next_state, State, Data, Actions};
	_ ->
	    {keep_state, Data}
    end;

handle_event(info, Info, _State, Data) ->
    ?LOG(error, "~p: ~w: handle_event(info, ...): ~p", [self(), ?MODULE, Info]),
    {keep_state, Data};

handle_event({timeout, 'echo'}, _,
	     #state{echo_timer = 'echo_to_send'} = State0, Data) ->
    ?LOG(debug, "handle_event timeout: timer ~p, State ~p", ['echo', State0]),
    State = send_echo_request(State0, Data),
    Actions = timeout_action([], infinity, 'echo'),
    {next_state, State, Data, Actions};

% Time to send the next echo to the down peer
handle_event({timeout, 'pd_echo'}, _,
	     #state{peer = 'INACTIVE', echo_timer = 'peer_down'} = State0, 
	     Data) ->
    ?LOG(debug, "handle_event timeout: timer ~p, State ~p", ['pd_echo', State0]),
    State1 = monitor_down_peer(State0, Data),
    {next_state, State1, Data};

% Peer down monitoring duration expired, node still down. Terminate PATH! 
% Allocated RemoteIP peer may have been removed (likely by DNS).
% If remote peer is still configured in DNS or ergw env then the path 
% is created again and monitoring process of down node restarts, after 
% failure of first CSR sent to the peer. 
handle_event({timeout, 'pd_dur'}, _,
	     #state{peer = 'INACTIVE', echo_timer = 'peer_down'} = State,
	     #{gtp_port := #gtp_port{name = PortName}, version := Version, ip := RemoteIP}) ->
    ?LOG(debug, "handle_event timeout: timer ~p, State ~p", ['pd_dur', State]),
    gtp_path_reg:remove_down_peer(RemoteIP),
    gtp_path_reg:unregister({PortName, Version, RemoteIP}),
    {keep_state_and_data, [{stop, pd_mon_timeout}]};

% Any timeout received in any other state do nothing, Should not happen.
handle_event({timeout, _}, _, _State, Data) ->
    ?LOG(error, "handle_event timeout: ~p", [Data]),
    {keep_state, Data}.

% Monitoring down peer for too long, kill path process
terminate(pd_mon_timeout, State, _data) ->
    ?LOG(error, "terminate Path, peer down for too long: State ~p", [State]),
    ok;

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

update_restart_counter(RestartCounter, State, #{recovery := undefined} = Data) ->
    {State, Data#{recovery => RestartCounter}};
update_restart_counter(RestartCounter, State, #{recovery := RestartCounter} = Data) ->
    {State, Data};
%% A down peer has come up, update recovery counter.
update_restart_counter(NewRestartCounter, #state{echo_timer = 'peer_down'} = State,
		       #{ip := IP, recovery := OldRestartCounter} = Data)
  when ?SMALLER(OldRestartCounter, NewRestartCounter) ->
    ?LOG(warning, "GSN ~s down peer now up (~w != ~w)",
	 [inet:ntoa(IP), OldRestartCounter, NewRestartCounter]),
    {State, Data#{recovery => NewRestartCounter}};
update_restart_counter(NewRestartCounter, State,
		       #{ip := IP, recovery := OldRestartCounter} = Data)
  when ?SMALLER(OldRestartCounter, NewRestartCounter) ->
    ?LOG(warning, "GSN ~s restarted (~w != ~w)",
	 [inet:ntoa(IP), OldRestartCounter, NewRestartCounter]),
    path_down(NewRestartCounter, State, Data);

update_restart_counter(NewRestartCounter, State,
		       #{ip := IP, recovery := OldRestartCounter} = Data)
  when not ?SMALLER(OldRestartCounter, NewRestartCounter) ->
    ?LOG(warning, "possible race on message with restart counter for GSN ~s (old: ~w, new: ~w)",
	 [inet:ntoa(IP), OldRestartCounter, NewRestartCounter]),
    {State, Data}.

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
handle_recovery_ie(_Msg, State, Data) ->
    {State, Data}.

ets_new() ->
    ets:new(?MODULE, [public, ordered_set, {keypos, 1}]).

ets_foreach(TID, Fun) ->
    ets_foreach(TID, Fun, ets:match(TID, {'$1'}, 100)).

ets_foreach(_TID, _Fun, '$end_of_table') ->
    ok;
foreach_context({Pid, Iter}, Fun) ->
    Fun(Pid),
    foreach_context(gb_sets:next(Iter), Fun).

register(Pid, State, #{table := TID} = Data) ->
    ?LOG(debug, "~s: register(~p)", [?MODULE, Pid]),
    erlang:monitor(process, Pid),
    ets:insert(TID, {Pid}),
    update_path_counter(ets:info(TID, size), State, Data).

unregister(Pid, State, #{table := TID} = Data) ->
    ets:delete(TID, Pid),
    update_path_counter(ets:info(TID, size), State, Data).

update_path_counter(PathCounter, State, 
                    #{gtp_port := GtpPort, version := Version, ip := IP} = Data) ->
    ergw_prometheus:gtp_path_contexts(GtpPort, IP, Version, PathCounter),
    if PathCounter =:= 0 ->
	    [{{timeout, echo}, 0, stop_echo}];
       true ->
	    start_echo_request(State, Data)
    end.

bind_path(#gtp{version = Version}, Context) ->
    bind_path(Context#context{version = Version}).

bind_path(#context{version = Version, control_port = CntlGtpPort,
		   remote_control_teid = #fq_teid{ip = RemoteCntlIP}} = Context) ->
    Path = maybe_new_path(CntlGtpPort, Version, RemoteCntlIP),
    Context#context{path = Path}.

bind_path_with_pm(#context{version = Version, control_port = CntlGtpPort,
			   remote_control_teid = #fq_teid{ip = RemoteCntlIP}} = Context,
		  PeerDownMonF) ->
    Path = maybe_new_path(CntlGtpPort, Version, RemoteCntlIP, PeerDownMonF),
    Context#context{path = Path}.

path_recovery(RestartCounter, #context{path = Path} = Context)
  when is_integer(RestartCounter) ->
    ok = gen_statem:call(Path, {bind, self(), RestartCounter}),
    Context#context{remote_restart_counter = RestartCounter};
path_recovery(_RestartCounter, #context{path = Path} = Context) ->
    {ok, PathRestartCounter} = gen_statem:call(Path, {bind, self()}),
    Context#context{remote_restart_counter = PathRestartCounter}.

start_echo_request(#state{echo_timer = 'stopped'} = State, Data) ->
    send_echo_request(State, Data);
start_echo_request(State, _Data) ->
    State.

stop_echo_request(#state{echo_timer = 'peer_down'} = State) ->
    State;
stop_echo_request(State) ->
    State#state{echo_timer = 'stopped'}.

send_echo_request(State, #{gtp_port := GtpPort, handler := Handler, ip := DstIP,
			   t3 := T3, n3 := N3}) ->
    Msg = Handler:build_echo_request(GtpPort),
    Ref = erlang:make_ref(),
    CbInfo = {?MODULE, handle_response, [self(), echo_request, Ref]},
    ergw_gtp_c_socket:send_request(GtpPort, DstIP, ?GTP1c_PORT, T3, N3, Msg, CbInfo),
    State#state{echo_timer = 'awaiting_response'}.

%% Okay, valid response received, the downed peer node has come up. 
%% Stop echo sending and wait for it to trigger again in the normal way, 
%% i.e on first msg to peer. Also cancel peer duration timer.
echo_response(#gtp{} = Msg, #state{echo_timer = 'peer_down'} = State,
	      #{ip := IP} = Data) ->
    ?LOG(debug, "echo_response_from_down_peer: ~p", [Msg]),
    gtp_path_reg:remove_down_peer(IP),
    Actions = timeout_action([], infinity, pd_dur),
    {State#state{peer = 'DOWN', echo_timer = stopped}, Data, Actions};
%Error response from down Peer, Ignore, reset pd_echo timer
echo_response(_Msg, #state{echo_timer = 'peer_down'},
	      #{pd_echo := PDEchoInterval}) ->
    Actions = timeout_action([],PDEchoInterval, 'pd_echo'),
    {keep_state_and_data, Actions};
echo_response(Msg, #state{echo_timer = 'awaiting_response'} = State, Data) ->
    update_path_state(Msg, State, Data);
echo_response(Msg, State, Data) ->
    update_path_state(Msg, State, Data).

update_path_state(#gtp{}, State, Data) ->
    {State#state{peer = 'UP', echo_timer = 'echo_to_send'}, Data, []};
% If path maintenance is required set duration to monitor path.
update_path_state(_, State0, 
		  #{pd_mon_f := true, pd_dur := PDDurInterval, ip := IP} = Data0) ->
    {State1, Data} = path_down(undefined, State0, Data0),
    gtp_path_reg:add_down_peer(IP),
    State = monitor_down_peer(State1, Data),
    Actions = timeout_action([], PDDurInterval, 'pd_dur'),
    {State, Data, Actions};
update_path_state(_, State0, Data0) ->
    {State1, Data} = path_down(undefined, State0, Data0),
    State = State1#state{peer = 'DOWN'},
    {State, Data, []}.
path_down(RestartCounter, State, #{table := TID} = Data0) ->
    Path = self(),
    proc_lib:spawn(fun() ->
			   ets_foreach(TID, gtp_context:path_restart(_, Path)),
			   ets:delete(TID)
		   end),
    Data = Data0#{table => ets_new(), recovery => RestartCounter},
    {update_path_counter(0, State, Data), Data}.

% Event Content field is not used, set to same value as timer name.
timeout_action(Actions, Timeout, Name)
  when is_integer(Timeout) orelse Timeout =:= infinity;
       is_atom(Name) ->
    [{{timeout, Name}, Timeout, Name} | Actions];
timeout_action(Actions, _, _) ->
    Actions.

% Only the egress nodes are monitored when down. 
% Send echo request to down peer
monitor_down_peer(State, #{gtp_port := GtpPort, handler := Handler, ip := DstIP,
			   t3 := T3}) ->
    Msg = Handler:build_echo_request(GtpPort),
    CbInfo = {?MODULE, handle_response, [self(), echo_request]},
    ergw_gtp_c_socket:send_request(GtpPort, DstIP, ?GTP1c_PORT, T3, 1, Msg, CbInfo),
    State#state{peer = 'INACTIVE', echo_timer = 'peer_down'}.

% normalise values to milliseconds
normalise([], NewArgs) ->
    NewArgs;
normalise([{n3, Val} | Rest], NewArgs) ->
    normalise(Rest, [{n3, Val} | NewArgs]);
normalise([{Par, Val} | Rest], NewArgs) ->
    normalise(Rest, [{Par, timer:seconds(Val)} | NewArgs]).
