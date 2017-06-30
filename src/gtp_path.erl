%% Copyright 2015, 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_path).

-behaviour(gen_server).

-compile({parse_transform, cut}).
-compile({no_auto_import,[register/2]}).

%% API
-export([start_link/4, all/1,
	 maybe_new_path/3, handle_request/2,
	 bind/1, bind/2, unbind/1, down/2,
	 get_handler/2, info/1,
	 exometer_update_rtt/5]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 code_change/3, terminate/2]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-record(state, {table		:: ets:tid(),
		path_counter	:: non_neg_integer(),
		gtp_port	:: #gtp_port{},
		version		:: 'v1' | 'v2',
		handler		:: atom(),
		ip		:: inet:ip_address(),
		t3		:: non_neg_integer(),
		n3		:: non_neg_integer(),
		recovery	:: 'undefined' | non_neg_integer(),
		echo		:: non_neg_integer(),
		echo_timer	:: 'stopped' | 'awaiting_response' | reference(),
		state		:: 'UP' | 'DOWN' }).

%% defaults for exometer probes
-define(EXO_CONTEXTS_OPTS, []).

%%%===================================================================
%%% API
%%%===================================================================

start_link(GtpPort, Version, RemoteIP, Args) ->
    gen_server:start_link(?MODULE, [GtpPort, Version, RemoteIP, Args], []).

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
    gen_server:cast(Path, {handle_request, ReqKey, Msg}).

bind(#context{remote_restart_counter = RestartCounter} = Context) ->
    path_recovery(RestartCounter, bind_path(Context)).

bind(#gtp{ie = #{{recovery, 0} :=
		     #recovery{restart_counter = RestartCounter}}}, Context) ->
    path_recovery(RestartCounter, bind_path(Context));
bind(#gtp{ie = #{{v2_recovery, 0} :=
		     #v2_recovery{restart_counter = RestartCounter}}}, Context) ->
    path_recovery(RestartCounter, bind_path(Context));
bind(_Request, Context) ->
    path_recovery(undefined, bind_path(Context)).

unbind(#context{version = Version, control_port = GtpPort, remote_control_ip = RemoteIP}) ->
    case get(GtpPort, Version, RemoteIP) of
	Path when is_pid(Path) ->
	    gen_server:call(Path, {unbind, self()});
       _ ->
           ok
    end.

down(GtpPort, IP) ->
    down(GtpPort, v1, IP),
    down(GtpPort, v2, IP).

down(GtpPort, Version, IP) ->
    case get(GtpPort, Version, IP) of
	Path when is_pid(Path) ->
	    gen_server:cast(Path, down);
	_ ->
	    ok
    end.

get(#gtp_port{name = PortName}, Version, IP) ->
    gtp_path_reg:lookup({PortName, Version, IP}).

all(Path) ->
    gen_server:call(Path, all).

info(Path) ->
    gen_server:call(Path, info).

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
%%% gen_server callbacks
%%%===================================================================
init([#gtp_port{name = PortName} = GtpPort, Version, RemoteIP, Args]) ->
    gtp_path_reg:register({PortName, Version, RemoteIP}),

    State0 = #state{
		path_counter = 0,
		gtp_port     = GtpPort,
		version      = Version,
		handler      = get_handler(GtpPort, Version),
		ip           = RemoteIP,
		t3           = proplists:get_value(t3, Args, 10 * 1000), %% 10sec
		n3           = proplists:get_value(n3, Args, 5),
		recovery     = undefined,
		echo         = proplists:get_value(ping, Args, 60 * 1000), %% 60sec
		echo_timer   = stopped,
		state        = 'UP'},
    exometer_new(State0),
    State = ets_new(State0),

    lager:debug("State: ~p", [State]),
    {ok, State}.

handle_call(all, _From, #state{table = TID} = State) ->
    Reply = ets:tab2list(TID),
    {reply, Reply, State};

handle_call({bind, Pid}, _From, #state{recovery = RestartCounter} = State0) ->
    State = register(Pid, State0),
    {reply, {ok, RestartCounter}, State};

handle_call({bind, Pid, RestartCounter}, _From, State0) ->
    State1 = update_restart_counter(RestartCounter, State0),
    State = register(Pid, State1),
    {reply, ok, State};

handle_call({unbind, Pid}, _From, State0) ->
    State = unregister(Pid, State0),
    {reply, ok, State};

handle_call(info, _From, #state{
			    gtp_port = #gtp_port{name = Name},
			    path_counter = Cnt, version = Version,
			    ip = IP, state = S} = State) ->
    Reply = #{path => self(), port => Name, tunnels => Cnt,
	      version => Version, ip => IP, state => S},
    {reply, Reply, State};

handle_call(Request, _From, State) ->
    lager:warning("handle_call: ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({handle_request, ReqKey, #gtp{type = echo_request} = Msg},
	    #state{gtp_port = GtpPort, handler = Handler} = State0) ->
    lager:debug("echo_request: ~p", [Msg]),

    State = handle_recovery_ie(Msg, State0),

    ResponseIEs = Handler:build_recovery(GtpPort, true, []),
    Response = Msg#gtp{type = echo_response, ie = ResponseIEs},
    gtp_socket:send_response(ReqKey, Response, false),

    {noreply, State};

handle_cast(down, #state{table = TID} = State0) ->
    Path = self(),
    proc_lib:spawn(fun() ->
			   ets_foreach(TID, gtp_context:path_restart(_, Path)),
			   ets:delete(TID)
		   end),
    State = ets_new(State0#state{recovery = undefined}),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("~p: ~w: handle_cast: ~p", [self(), ?MODULE, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info({'DOWN', _MonitorRef, process, Pid, _Info}, State0) ->
    State = unregister(Pid, State0),
    {noreply, State};

handle_info(Info = {timeout, TRef, echo}, #state{echo_timer = TRef} = State0) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    State1 = send_echo_request(State0),
    {noreply, State1};

handle_info(Info = {timeout, _TRef, echo}, State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    {noreply, State};

handle_info({echo_request, _, Msg}, State0)->
    lager:debug("echo_response: ~p", [Msg]),
    State1 = handle_recovery_ie(Msg, State0),
    State = echo_response(Msg, State1),
    {noreply, State};

handle_info(Info, State) ->
    lager:error("~p: ~w: handle_info: ~p", [self(), ?MODULE, lager:pr(Info, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, State) ->
    %% TODO: kill all PDP Context on this path
    exometer_delete(State),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

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

update_restart_counter(RestartCounter, #state{recovery = undefined} = State) ->
    State#state{recovery = RestartCounter};
update_restart_counter(RestartCounter, #state{recovery = RestartCounter} = State) ->
    State;
update_restart_counter(NewRestartCounter, #state{table = TID, ip = IP,
						 recovery = OldRestartCounter} = State)
  when ?SMALLER(OldRestartCounter, NewRestartCounter) ->
    lager:warning("GSN ~s restarted (~w != ~w)",
		  [inet:ntoa(IP), OldRestartCounter, NewRestartCounter]),
    Path = self(),
    proc_lib:spawn(fun() ->
			   ets_foreach(TID, gtp_context:path_restart(_, Path)),
			   ets:delete(TID)
		   end),
    ets_new(State#state{recovery = NewRestartCounter});

update_restart_counter(NewRestartCounter, #state{ip = IP, recovery = OldRestartCounter} = State)
  when not ?SMALLER(OldRestartCounter, NewRestartCounter) ->
    lager:warning("possible race on message with restart counter for GSN ~s (old: ~w, new: ~w)",
		  [inet:ntoa(IP), OldRestartCounter, NewRestartCounter]),
    State.

handle_recovery_ie(#gtp{version = v1,
			ie = #{{recovery, 0} :=
				   #recovery{restart_counter =
						 RestartCounter}}}, State) ->
    update_restart_counter(RestartCounter, State);

handle_recovery_ie(#gtp{version = v2,
			ie = #{{v2_recovery, 0} :=
				   #v2_recovery{restart_counter =
						    RestartCounter}}}, State) ->
    update_restart_counter(RestartCounter, State);
handle_recovery_ie(_Msg, State) ->
    State.

ets_new(State) ->
    TID = ets:new(?MODULE, [public, ordered_set, {keypos, 1}]),
    State#state{table = TID}.

ets_foreach(TID, Fun) ->
    ets_foreach(TID, Fun, ets:match(TID, {'$1'}, 100)).

ets_foreach(_TID, _Fun, '$end_of_table') ->
    ok;
ets_foreach(TID, Fun, {Pids, Continuation})
  when is_list(Pids) ->
    lists:foreach(fun([Pid]) -> Fun(Pid) end, Pids),
    ets_foreach(TID, Fun, ets:match_object(Continuation)).

register(Pid, #state{table = TID} = State0) ->
    lager:debug("~s: register(~p)", [?MODULE, Pid]),
    erlang:monitor(process, Pid),
    ets:insert(TID, {Pid}),
    inc_path_counter(State0).

unregister(Pid, #state{table = TID} = State0) ->
    ets:delete(TID, Pid),
    dec_path_counter(State0).


bind_path(#context{version = Version, control_port = CntlGtpPort,
		   remote_control_ip = RemoteCntlIP} = Context) ->
    Path = maybe_new_path(CntlGtpPort, Version, RemoteCntlIP),
    Context#context{path = Path}.

path_recovery(RestartCounter, #context{path = Path} = Context)
  when is_integer(RestartCounter) ->
    ok = gen_server:call(Path, {bind, self(), RestartCounter}),
    Context#context{remote_restart_counter = RestartCounter};
path_recovery(_RestartCounter, #context{path = Path} = Context) ->
    {ok, PathRestartCounter} = gen_server:call(Path, {bind, self()}),
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

inc_path_counter(#state{path_counter = OldPathCounter} = State0) ->
    State = State0#state{path_counter = OldPathCounter + 1},
    update_path_counter(State),
    if OldPathCounter == 0 ->
	    start_echo_request(State);
       true ->
	    State
    end.

dec_path_counter(#state{path_counter = 0} = State) ->
    lager:error("attempting to release path when count == 0"),
    State;
dec_path_counter(#state{path_counter = OldPathCounter} = State0) ->
    NewPathCounter = OldPathCounter - 1,
    State = State0#state{path_counter = NewPathCounter},
    update_path_counter(State),
    if NewPathCounter == 0 ->
	    stop_echo_request(State);
       true ->
	    State
    end.

start_echo_request(#state{echo_timer = stopped} = State) ->
    send_echo_request(State);
start_echo_request(State) ->
    State.

stop_echo_request(#state{echo_timer = EchoTRef} = State) ->
    if is_reference(EchoTRef) ->
	    cancel_timer(EchoTRef);
       true ->
	    ok
    end,
    State#state{echo_timer = stopped}.

send_echo_request(#state{gtp_port = GtpPort, handler = Handler, ip = RemoteIP,
			 t3 = T3, n3 = N3} = State) ->
    Msg = Handler:build_echo_request(GtpPort),
    gtp_socket:send_request(GtpPort, self(), RemoteIP, T3, N3, Msg, echo_request),
    State#state{echo_timer = awaiting_response} .

echo_response(Msg, #state{echo = EchoInterval,
			  echo_timer = awaiting_response} = State0) ->
    State = update_path_state(Msg, State0),
    TRef = erlang:start_timer(EchoInterval, self(), echo),
    State#state{echo_timer = TRef} ;
echo_response(Msg, State0) ->
    update_path_state(Msg, State0).

update_path_state(#gtp{}, State) ->
    State#state{state = 'UP'};
update_path_state(_, State) ->
    State#state{state = 'DOWN'}.

%%%===================================================================
%%% ExoMeter functions
%%%===================================================================

exo_hist_opts(echo_request) ->
    %% 1 hour might seem long, but we only send one echo request per 60 seconds
    [{time_span, 3600 * 1000}];
exo_hist_opts(_MsgType) ->
    %% 5 min histogram
    [{time_span, 300 * 1000}].

foreach_request(Handler, Fun) ->
    Requests = lists:filter(fun(X) -> Handler:gtp_msg_type(X) =:= request end,
			    Handler:gtp_msg_types()),
    lists:foreach(Fun, Requests).

exo_reg_rtt(Name, IP, Version, MsgType) ->
    exometer:re_register([path, Name, IP, rtt, Version, MsgType],
			 histogram, exo_hist_opts(MsgType)).

update_path_counter(#state{path_counter = PathCounter,
			   gtp_port = #gtp_port{name = Name}, ip = IP}) ->
    exometer:update_or_create([path, Name, IP, contexts], PathCounter, gauge, ?EXO_CONTEXTS_OPTS).

exometer_new(#state{gtp_port = #gtp_port{name = Name}, ip = IP}) ->
    exometer:re_register([path, Name, IP, contexts], gauge, ?EXO_CONTEXTS_OPTS),
    foreach_request(gtp_v1_c, exo_reg_rtt(Name, IP, v1, _)),
    foreach_request(gtp_v2_c, exo_reg_rtt(Name, IP, v2, _)),
    ok.

exometer_delete(#state{gtp_port = #gtp_port{name = Name}, ip = IP}) ->
    exometer:delete([path, Name, IP, contexts]),
    foreach_request(gtp_v1_c, exometer:delete([path, Name, IP, rtt, v1, _])),
    foreach_request(gtp_v2_c, exometer:delete([path, Name, IP, rtt, v2, _])),
    ok;
exometer_delete(_) ->
    ok.

exometer_update_rtt(#gtp_port{name = Name}, IP, Version, MsgType, RTT) ->
    exometer:update([path, Name, IP, rtt, Version, MsgType], RTT).
