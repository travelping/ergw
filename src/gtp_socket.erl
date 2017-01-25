%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_socket).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_socket/2, start_link/1,
	 send/4, send_response/3,
	 send_request/5, send_request/7,
	 forward_request/5,
	 get_restart_counter/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-type v1_sequence_number() :: 0 .. 16#ffff.
-type v2_sequence_number() :: 0 .. 16#7fffff.
-type sequence_id() :: {v1, v1_sequence_number()} |
		       {v2, v2_sequence_number()}.

-export_type([sequence_id/0]).

-record(state, {
	  gtp_port   :: #gtp_port{},
	  ip         :: inet:ip_address(),
	  socket     :: gen_socket:socket(),

	  v1_seq_no = 0 :: v1_sequence_number(),
	  v2_seq_no = 0 :: v2_sequence_number(),
	  pending    :: gb_trees:tree(sequence_id(), term()),
	  responses,
	  fwd_seq_ids,

	  restart_counter}).

-record(sender, {from, req_id, msg}).

-define(T3, 10 * 1000).
-define(N3, 5).
-define(RESPONSE_TIMEOUT, (?T3 * ?N3 + (?T3 div 2))).
-define(CACHE_TIMEOUT, ?RESPONSE_TIMEOUT).

%%====================================================================
%% API
%%====================================================================

start_socket(Name, Opts)
  when is_atom(Name), is_list(Opts) ->
    gtp_socket_sup:new({Name, Opts}).

start_link(Socket = {Name, SocketOpts}) ->
    case proplists:get_value(type, SocketOpts, 'gtp-c') of
	'gtp-c' ->
	    gen_server:start_link(?MODULE, [Name, SocketOpts], []);
	'gtp-u' ->
	    gtp_dp:start_link(Socket)
    end.

send(#gtp_port{type = 'gtp-c'} = GtpPort, IP, Port, Data) ->
    cast(GtpPort, {send, IP, Port, Data});
send(#gtp_port{type = 'gtp-u'} = GtpPort, IP, Port, Data) ->
    gtp_dp:send(GtpPort, IP, Port, Data).

send_response(#request_key{gtp_port = GtpPort, ip = RemoteIP} = ReqKey, Msg, DoCache) ->
    message_counter(tx, GtpPort, RemoteIP, Msg),
    Data = gtp_packet:encode(Msg),
    cast(GtpPort, {send_response, ReqKey, Data, DoCache}).

send_request(#gtp_port{type = 'gtp-c'} = GtpPort, From, RemoteIP, Msg, ReqId) ->
    send_request(GtpPort, From, RemoteIP, ?T3, ?N3, Msg, ReqId).

send_request(#gtp_port{type = 'gtp-c'} = GtpPort, From, RemoteIP, T3, N3,
	     Msg = #gtp{version = Version}, ReqId) ->
    cast(GtpPort, {send_request, From, RemoteIP, T3, N3, Msg, ReqId}),
    gtp_path:maybe_new_path(GtpPort, Version, RemoteIP).

forward_request(#gtp_port{type = 'gtp-c'} = GtpPort, From, RemoteIP,
		Msg = #gtp{version = Version}, ReqId) ->
    cast(GtpPort, {forward_request, From, RemoteIP, Msg, ReqId}),
    gtp_path:maybe_new_path(GtpPort, Version, RemoteIP).

get_restart_counter(GtpPort) ->
    call(GtpPort, get_restart_counter).

%%%===================================================================
%%% call/cast wrapper for gtp_port
%%%===================================================================

cast(#gtp_port{pid = Handler}, Request) ->
    gen_server:cast(Handler, Request).

call(#gtp_port{pid = Handler}, Request) ->
    gen_server:call(Handler, Request).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, SocketOpts]) ->
    %% TODO: better config validation and handling
    IP    = proplists:get_value(ip, SocketOpts),
    NetNs = proplists:get_value(netns, SocketOpts),
    Type  = proplists:get_value(type, SocketOpts, 'gtp-c'),

    {ok, S} = make_gtp_socket(NetNs, IP, ?GTP1c_PORT, SocketOpts),

    {ok, RCnt} = gtp_config:get_restart_counter(),
    GtpPort = #gtp_port{name = Name, type = Type, pid = self(),
			ip = IP, restart_counter = RCnt},

    init_exometer(GtpPort),
    gtp_socket_reg:register(Name, GtpPort),

    State = #state{
	       gtp_port = GtpPort,
	       ip = IP,
	       socket = S,

	       v1_seq_no = 0,
	       v2_seq_no = 0,
	       pending = gb_trees:empty(),
	       responses = cache_new(?CACHE_TIMEOUT, responses),
	       fwd_seq_ids = cache_new(?T3 * 4, fwd_seq_ids),

	       restart_counter = RCnt},
    {ok, State}.

handle_call(get_restart_counter, _From, #state{restart_counter = RCnt} = State) ->
    {reply, RCnt, State};

handle_call(Request, _From, State) ->
    lager:error("handle_call: unknown ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({send, IP, Port, Data}, State)
  when is_binary(Data) ->
    sendto(IP, Port, Data, State),
    {noreply, State};

handle_cast({send_response, ReqKey, Data, DoCache}, State0)
  when is_binary(Data) ->
    State = do_send_response(ReqKey, Data, DoCache, State0),
    {noreply, State};

handle_cast({send_request, From, RemoteIP, T3, N3, Msg, ReqId}, State0) ->
    State = do_send_request(From, RemoteIP, T3, N3, Msg, ReqId, State0),
    {noreply, State};

handle_cast({forward_request, From, RemoteIP, Msg, ReqId}, State0) ->
    State = do_forward_request(From, RemoteIP, Msg, ReqId, State0),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(Info = {timeout, _TRef, {request, SeqId}}, #state{gtp_port = GtpPort} = State0) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    {Req, State1} = take_request(SeqId, State0),
    case Req of
	{RemoteIP, _T3, _N3 = 0, _Data, Sender}
	  when is_record(Sender, sender) ->
	    send_request_reply(Sender, timeout),
	    message_counter(tx, GtpPort, RemoteIP, Sender#sender.msg, timeout),
	    {noreply, State1};

	{RemoteIP, T3, N3, Data, Sender}
	  when is_record(Sender, sender) ->
	    %% resent....
	    message_counter(tx, GtpPort, RemoteIP, Sender#sender.msg, retransmit),
	    State = send_request_with_timeout(SeqId, RemoteIP, T3, N3 - 1, Data, Sender, State1),
	    {noreply, State};

	{RemoteIP, Sender}
	  when is_record(Sender, sender) ->
	    send_request_reply(Sender, timeout),
	    message_counter(tx, GtpPort, RemoteIP, Sender#sender.msg, timeout),
	    {noreply, State1};

	none ->
	    {noreply, State1}
    end;

handle_info({timeout, _TRef, responses}, #state{responses = Responses} = State) ->
    {noreply, State#state{responses = cache_expire(Responses)}};

handle_info({timeout, _TRef, fwd_seq_ids}, #state{fwd_seq_ids = FwdSeqIds} = State) ->
    {noreply, State#state{fwd_seq_ids = cache_expire(FwdSeqIds)}};

handle_info({Socket, input_ready}, #state{socket = Socket} = State) ->
    handle_input(Socket, State);

handle_info(Info, State) ->
    lager:error("handle_info: unknown ~p, ~p", [lager:pr(Info, ?MODULE), lager:pr(State, ?MODULE)]),
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

new_sequence_number(#gtp{version = v1} = Msg, #state{v1_seq_no = SeqNo} = State) ->
    {Msg#gtp{seq_no = SeqNo}, State#state{v1_seq_no = (SeqNo + 1) rem 16#ffff}};
new_sequence_number(#gtp{version = v2} = Msg, #state{v2_seq_no = SeqNo} = State) ->
    {Msg#gtp{seq_no = SeqNo}, State#state{v2_seq_no = (SeqNo + 1) rem 16#7fffff}}.

make_seq_id(#gtp{version = Version, seq_no = SeqNo}) ->
    {Version, SeqNo}.

make_request_key(IP, Port, Msg = #gtp{type = Type}, #state{gtp_port = GtpPort}) ->
    SeqId = make_seq_id(Msg),
    #request_key{gtp_port = GtpPort,
		 ip = IP, port = Port,
		 type = Type, seq_id = SeqId}.

make_gtp_socket(NetNs, {_,_,_,_} = IP, Port, Opts) when is_list(NetNs) ->
    {ok, Socket} = gen_socket:socketat(NetNs, inet, dgram, udp),
    bind_gtp_socket(Socket, IP, Port, Opts);
make_gtp_socket(_NetNs, {_,_,_,_} = IP, Port, Opts) ->
    {ok, Socket} = gen_socket:socket(inet, dgram, udp),
    bind_gtp_socket(Socket, IP, Port, Opts).

bind_gtp_socket(Socket, {_,_,_,_} = IP, Port, Opts) ->
    case proplists:get_bool(freebind, Opts) of
	true ->
	    ok = gen_socket:setsockopt(Socket, sol_ip, freebind, true);
	_ ->
	    ok
    end,
    ok = gen_socket:bind(Socket, {inet4, IP, Port}),
    ok = gen_socket:setsockopt(Socket, sol_ip, recverr, true),
    ok = gen_socket:setsockopt(Socket, sol_ip, mtu_discover, 0),
    ok = gen_socket:input_event(Socket, true),
    lists:foreach(socket_setopts(Socket, _), Opts),
    {ok, Socket}.

socket_setopts(Socket, {netdev, Device})
  when is_list(Device); is_binary(Device) ->
    BinDev = iolist_to_binary([Device, 0]),
    ok = gen_socket:setsockopt(Socket, sol_socket, bindtodevice, BinDev);
socket_setopts(Socket, {rcvbuf, Size}) when is_integer(Size) ->
    case gen_socket:setsockopt(Socket, sol_socket, rcvbufforce, Size) of
	ok -> ok;
	_ -> gen_socket:setsockopt(Socket, sol_socket, rcvbuf, Size)
    end;
socket_setopts(_Socket, _) ->
    ok.

handle_input(Socket, State) ->
    case gen_socket:recvfrom(Socket) of
	{error, _} ->
	    handle_err_input(Socket, State);

	{ok, {inet4, IP, Port}, Data} ->
	    ok = gen_socket:input_event(Socket, true),
	    handle_message(IP, Port, Data, State);

	Other ->
	    lager:error("got unhandled input: ~p", [Other]),
	    ok = gen_socket:input_event(Socket, true),
	    {noreply, State}
    end.

-define(SO_EE_ORIGIN_LOCAL,      1).
-define(SO_EE_ORIGIN_ICMP,       2).
-define(SO_EE_ORIGIN_ICMP6,      3).
-define(SO_EE_ORIGIN_TXSTATUS,   4).
-define(ICMP_DEST_UNREACH,       3).       %% Destination Unreachable
-define(ICMP_HOST_UNREACH,       1).       %% Host Unreachable
-define(ICMP_PROT_UNREACH,       2).       %% Protocol Unreachable
-define(ICMP_PORT_UNREACH,       3).       %% Port Unreachable

handle_socket_error({?SOL_IP, ?IP_RECVERR, {sock_err, _ErrNo, ?SO_EE_ORIGIN_ICMP, ?ICMP_DEST_UNREACH, Code, _Info, _Data}},
		    IP, _Port, #state{gtp_port = GtpPort})
  when Code == ?ICMP_HOST_UNREACH; Code == ?ICMP_PORT_UNREACH ->
    gtp_path:down(GtpPort, IP);

handle_socket_error(Error, IP, _Port, _State) ->
    lager:debug("got unhandled error info for ~s: ~p", [inet:ntoa(IP), Error]),
    ok.

handle_err_input(Socket, State) ->
    case gen_socket:recvmsg(Socket, ?MSG_DONTWAIT bor ?MSG_ERRQUEUE) of
	{ok, {inet4, IP, Port}, Error, _Data} ->
	    lists:foreach(handle_socket_error(_, IP, Port, State), Error),
	    ok = gen_socket:input_event(Socket, true),
	    {noreply, State};

	Other ->
	    lager:error("got unhandled error input: ~p", [Other]),
	    ok = gen_socket:input_event(Socket, true),
	    {noreply, State}
    end.

handle_message(IP, Port, Data, #state{gtp_port = GtpPort} = State0) ->
    try gtp_packet:decode(Data) of
	Msg = #gtp{} ->
	    %% TODO: handle decode failures

	    lager:debug("handle message: ~p", [{IP, Port,
						lager:pr(State0#state.gtp_port, ?MODULE),
						lager:pr(Msg, ?MODULE)}]),
	    message_counter(rx, GtpPort, IP, Msg),
	    State = handle_message_1(IP, Port, Msg, State0),
	    {noreply, State}
    catch
	Class:Error ->
	    lager:error("GTP decoding failed with ~p:~p for ~p", [Class, Error, Data]),
	    State0
    end.

handle_message_1(IP, Port, #gtp{type = echo_request} = Msg, State) ->
    ReqKey = make_request_key(IP, Port, Msg, State),
    gtp_path:handle_request(ReqKey, Msg),
    State;

handle_message_1(IP, Port, #gtp{version = Version, type = MsgType} = Msg, State) ->
    Handler =
	case Version of
	    v1 -> gtp_v1_c;
	    v2 -> gtp_v2_c
	end,
    case Handler:gtp_msg_type(MsgType) of
	response ->
	    handle_response(IP, Port, Msg, State);
	request ->
	    ReqKey = make_request_key(IP, Port, Msg, State),
	    handle_request(ReqKey, Msg, State);
	_ ->
	    State
    end.

handle_response(IP, _Port, Msg, #state{gtp_port = GtpPort} = State0) ->
    SeqId = make_seq_id(Msg),
    {Req, State} = take_request(SeqId, State0),
    case Req of
	none -> %% duplicate, drop silently
	    message_counter(rx, GtpPort, IP, Msg, duplicate),
	    lager:error("~p: invalid response: ~p, ~p", [self(), SeqId]),
	    State;

	{_RemoteIP, _T3, _N3, _Data, Sender}
	  when is_record(Sender, sender) ->
	    lager:info("~p: found response: ~p", [self(), SeqId]),
	    send_request_reply(Sender, Msg),
	    State;

	{_RemoteIP, Sender}
	  when is_record(Sender, sender) ->
	    lager:info("~p: found response: ~p", [self(), SeqId]),
	    send_request_reply(Sender, Msg),
	    State;

	_Other ->
	    lager:error("~p: handle response failed with: ~p, ~p, ~p", [self(), SeqId, _Other, lager:pr(State, ?MODULE)]),
	    State
    end.

handle_request(#request_key{ip = IP, port = Port} = ReqKey, Msg,
	       #state{gtp_port = GtpPort, responses = Responses} = State) ->
    case cache_get(ReqKey, Responses) of
	{value, Data} ->
	    message_counter(rx, GtpPort, IP, Msg, duplicate),
	    sendto(IP, Port, Data, State);

	_Other ->
	    lager:debug("HandleRequest: ~p", [_Other]),
	    gtp_context:handle_message(ReqKey, Msg)
    end,
    State.

start_request(SeqId, Req, Timeout, #state{pending = Pending} = State) ->
    TRef = erlang:start_timer(Timeout, self(), {request, SeqId}),
    State#state{pending = gb_trees:insert(SeqId, {Req, TRef}, Pending)}.

take_request(SeqId, #state{pending = Pending} = State) ->
    case gb_trees:lookup(SeqId, Pending) of
	none ->
	    {none, State};

	{value, {Req, TRef}} ->
	    cancel_timer(TRef),
	    {Req, State#state{pending = gb_trees:delete(SeqId, Pending)}}
    end.

sendto(RemoteIP, Data, State) ->
    sendto(RemoteIP, ?GTP1c_PORT, Data, State).

sendto(RemoteIP, Port, Data, #state{socket = Socket}) ->
    gen_socket:sendto(Socket, {inet4, RemoteIP, Port}, Data).

do_send_request(From, RemoteIP, T3, N3, Msg0, ReqId,
	     #state{gtp_port = GtpPort} = State0) ->
    lager:debug("~p: gtp_socket send_request to ~p: ~p", [self(), RemoteIP, Msg0]),
    message_counter(tx, GtpPort, RemoteIP, Msg0),
    {Msg, State} = new_sequence_number(Msg0, State0),
    Data = gtp_packet:encode(Msg),
    Sender = #sender{from = From, req_id = ReqId, msg = Msg},
    SeqId = make_seq_id(Msg),
    send_request_with_timeout(SeqId, RemoteIP, T3, N3, Data, Sender, State).

send_request_reply(#sender{from = From, req_id = ReqId, msg = ReqMsg}, ReplyMsg) ->
    From ! {ReqId, ReqMsg, ReplyMsg}.

send_request_with_timeout(SeqId, RemoteIP, T3, N3, Data, Sender, State) ->
    sendto(RemoteIP, Data, State),
    start_request(SeqId, {RemoteIP, T3, N3, Data, Sender}, T3, State).

do_forward_request(From, RemoteIP, Msg0, ReqId,
		   #state{gtp_port = GtpPort, fwd_seq_ids = FwdSeqIds} = State0) ->
    lager:debug("~p: gtp_socket forward_request to ~p: ~p", [self(), RemoteIP, Msg0]),
    message_counter(tx, GtpPort, RemoteIP, Msg0),

    {Msg, State1} =
	case cache_get(ReqId, FwdSeqIds) of
	    {value, {_Version, SeqNo}} ->
		{Msg0#gtp{seq_no = SeqNo}, State0};
	    _ ->
		new_sequence_number(Msg0, State0)
	end,

    SeqId = make_seq_id(Msg),
    Sender = #sender{from = From, req_id = ReqId, msg = Msg},
    State2 = start_request(SeqId, {RemoteIP, Sender}, ?T3 * 2, State1),

    State = State2#state{fwd_seq_ids = cache_enter(ReqId, SeqId, ?RESPONSE_TIMEOUT, FwdSeqIds)},

    Data = gtp_packet:encode(Msg),
    sendto(RemoteIP, Data, State),
    State.

enqueue_response(ReqKey, Data, DoCache,
		 #state{responses = Responses} = State)
  when DoCache =:= true ->
    State#state{responses = cache_enter(ReqKey, Data, ?RESPONSE_TIMEOUT, Responses)};
enqueue_response(_ReqKey, _Data, _DoCache,
		 #state{responses = Responses} = State) ->
    State#state{responses = cache_expire(Responses)}.

do_send_response(#request_key{ip = IP, port = Port} = ReqKey, Data, DoCache, State) ->
    sendto(IP, Port, Data, State),
    enqueue_response(ReqKey, Data, DoCache, State).

%%%===================================================================
%%% exometer functions
%%%===================================================================

-record(cache, {
	  expire :: integer(),
	  key    :: term(),
	  timer  :: reference(),
	  tree   :: gb_trees:tree(Key :: term(), {Expire :: integer(), Data :: term()}),
	  queue  :: queue:queue({Expire :: integer(), Key :: term()})
	 }).

cache_start_timer(#cache{expire = ExpireInterval, key = Key} = Cache) ->
    Cache#cache{timer = erlang:start_timer(ExpireInterval, self(), Key)}.

cache_new(ExpireInterval, Key) ->
    Cache = #cache{
	       expire = ExpireInterval,
	       key = Key,
	       tree = gb_trees:empty(),
	       queue = queue:new()
	      },
    cache_start_timer(Cache).

cache_get(Key, #cache{tree = Tree}) ->
    Now = erlang:monotonic_time(milli_seconds),
    case gb_trees:lookup(Key, Tree) of
	{value, {Expire, Data}}  when Expire > Now ->
	    {value, Data};

	_ ->
	    none
    end.

cache_enter(Key, Data, TimeOut, #cache{tree = Tree0, queue = Q0} = Cache) ->
    Now = erlang:monotonic_time(milli_seconds),
    Expire = Now + TimeOut,
    Tree = gb_trees:enter(Key, {Expire, Data}, Tree0),
    Q = queue:in({Expire, Key}, Q0),
    cache_expire(Now, Cache#cache{tree = Tree, queue = Q}).

cache_expire(Cache0) ->
    Now = erlang:monotonic_time(milli_seconds),
    Cache = cache_expire(Now, Cache0),
    cache_start_timer(Cache).

cache_expire(Now, #cache{tree = Tree0, queue = Q0} = Cache) ->
    case queue:peek(Q0) of
	{value, {Expire, Key}} when Expire < Now ->
	    {_, Q} = queue:out(Q0),
	    Tree = case gb_trees:lookup(Key, Tree0) of
		       {value, {Expire, _}} ->
			   gb_trees:delete(Key, Tree0);
		       _ ->
			   Tree0
		   end,
	    cache_expire(Now, Cache#cache{tree = Tree, queue = Q});
	_ ->
	    Cache
    end.

%%%===================================================================
%%% exometer functions
%%%===================================================================

%% wrapper to reuse old entries when restarting
exometer_new(Name, Type, Opts) ->
    case exometer:ensure(Name, Type, Opts) of
	ok ->
	    ok;
	_ ->
	    exometer:re_register(Name, Type, Opts)
    end.
exometer_new(Name, Type) ->
    exometer_new(Name, Type, []).

init_exometer(#gtp_port{name = Name, type = 'gtp-c'}) ->
    exometer_new([socket, 'gtp-c', Name, rx, v1, unsupported], counter),
    exometer_new([socket, 'gtp-c', Name, tx, v1, unsupported], counter),
    lists:foreach(fun(MsgType) ->
			  exometer_new([socket, 'gtp-c', Name, rx, v1, MsgType], counter),
			  exometer_new([socket, 'gtp-c', Name, rx, v1, MsgType, duplicate], counter),
			  exometer_new([socket, 'gtp-c', Name, tx, v1, MsgType], counter),
			  exometer_new([socket, 'gtp-c', Name, tx, v1, MsgType, retransmit], counter),
			  case gtp_v1_c:gtp_msg_type(MsgType) of
			      request ->
				  exometer_new([socket, 'gtp-c', Name, tx, v1, MsgType, timeout], counter);
			      _ ->
				  ok
			  end
		  end, gtp_v1_c:gtp_msg_types()),
    exometer_new([socket, 'gtp-c', Name, rx, v2, unsupported], counter),
    exometer_new([socket, 'gtp-c', Name, tx, v2, unsupported], counter),
    lists:foreach(fun(MsgType) ->
			  exometer_new([socket, 'gtp-c', Name, rx, v2, MsgType, duplicate], counter),
			  exometer_new([socket, 'gtp-c', Name, rx, v2, MsgType], counter),
			  exometer_new([socket, 'gtp-c', Name, tx, v2, MsgType, retransmit], counter),
			  exometer_new([socket, 'gtp-c', Name, tx, v2, MsgType], counter),
			  case gtp_v2_c:gtp_msg_type(MsgType) of
			      request ->
				  exometer_new([socket, 'gtp-c', Name, tx, v2, MsgType, timeout], counter);
			      _ ->
				  ok
			  end
		  end, gtp_v2_c:gtp_msg_types()),
    ok;
init_exometer(_) ->
    ok.

message_counter_apply(Name, RemoteIP, Direction, Version, MsgInfo) ->
    case exometer:update([socket, 'gtp-c', Name, Direction, Version | MsgInfo], 1) of
	{error, undefined} ->
	    exometer:update([socket, 'gtp-c', Name, Direction, Version, unsupported], 1),
	    exometer:update_or_create([path, Name, RemoteIP, Direction, Version, unsupported], 1, counter, []);
	Other ->
	    exometer:update_or_create([path, Name, RemoteIP, Direction, Version | MsgInfo], 1, counter, []),
	    Other
    end.

message_counter(Direction, #gtp_port{name = Name, type = 'gtp-c'},
		RemoteIP, #gtp{version = Version, type = MsgType}) ->
    message_counter_apply(Name, RemoteIP, Direction, Version, [MsgType]).

message_counter(Direction, #gtp_port{name = Name, type = 'gtp-c'},
		RemoteIP, #gtp{version = Version, type = MsgType},
		Verdict) ->
    message_counter_apply(Name, RemoteIP, Direction, Version, [MsgType, Verdict]).
