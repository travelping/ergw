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
	 get_restart_counter/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-type sequence_number() :: 0 .. 16#ffff.

-record(state, {
	  gtp_port   :: #gtp_port{},
	  ip         :: inet:ip_address(),
	  socket     :: gen_socket:socket(),

	  seq_no = 0 :: sequence_number(),
	  pending    :: gb_trees:tree(sequence_number(), term()),

	  responses  :: gb_trees:tree(#request_key{}, {Data :: binary(), TStamp :: integer()}),
	  rqueue     :: queue:queue({TStamp :: integer(), #request_key{}}),
	  cache_timer:: reference(),

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

send_response(#request_key{gtp_port = GtpPort} = ReqKey, Msg, DoCache) ->
    message_counter(tx, GtpPort, Msg),
    Data = gtp_packet:encode(Msg),
    cast(GtpPort, {send_response, ReqKey, Data, DoCache}).

send_request(#gtp_port{type = 'gtp-c'} = GtpPort, From, RemoteIP, Msg, ReqId) ->
    send_request(GtpPort, From, RemoteIP, ?T3, ?N3, Msg, ReqId).

send_request(#gtp_port{type = 'gtp-c'} = GtpPort, From, RemoteIP, T3, N3,
	     Msg = #gtp{version = Version}, ReqId) ->
    cast(GtpPort, {send_request, From, RemoteIP, T3, N3, Msg, ReqId}),
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

    State0 = #state{
		gtp_port = GtpPort,
		ip = IP,
		socket = S,

		seq_no = 0,
		pending = gb_trees:empty(),

		responses = gb_trees:empty(),
		rqueue = queue:new(),

		restart_counter = RCnt},
    State = start_cache_timer(State0),
    {ok, State}.

handle_call(get_restart_counter, _From, #state{restart_counter = RCnt} = State) ->
    {reply, RCnt, State};

handle_call(Request, _From, State) ->
    lager:error("handle_call: unknown ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({send, IP, Port, Data}, #state{socket = Socket} = State)
  when is_binary(Data) ->
    gen_socket:sendto(Socket, {inet4, IP, Port}, Data),
    {noreply, State};

handle_cast({send_response, ReqKey, Data, DoCache}, State0)
  when is_binary(Data) ->
    State = do_send_response(ReqKey, Data, DoCache, State0),
    {noreply, State};

handle_cast({send_request, From, RemoteIP, T3, N3, Msg, ReqId}, State0) ->
    State = do_send_request(From, RemoteIP, T3, N3, Msg, ReqId, State0),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(Info = {timeout, TRef, {send, SeqNo}}, #state{gtp_port = GtpPort, pending = Pending} = State0) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    case gb_trees:lookup(SeqNo, Pending) of
	{value, {_RemoteIP, _T3, _N3 = 0, _Data, Sender, TRef}} ->
	    send_request_reply(Sender, timeout),
	    message_counter(tx, GtpPort, Sender#sender.msg, timeout),
	    {noreply, State0#state{pending = gb_trees:delete(SeqNo, Pending)}};

	{value, {RemoteIP, T3, N3, Data, Sender, TRef}} ->
	    %% resent....
	    message_counter(tx, GtpPort, Sender#sender.msg, retransmit),
	    State = send_request_with_timeout(SeqNo, RemoteIP, T3, N3 - 1, Data, Sender,
					      State0#state{pending = gb_trees:delete(SeqNo, Pending)}),
	    {noreply, State}
    end;

handle_info({timeout, TRef, cache_timeout}, #state{cache_timer = TRef} = State0) ->
    Now = erlang:monotonic_time(milli_seconds),
    State1 = timeout_queue(Now, State0),
    State = start_cache_timer(State1),
    {noreply, State};

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

make_request_key(IP, Port, #gtp{type = Type, seq_no = SeqNo}, #state{gtp_port = GtpPort}) ->
    #request_key{gtp_port = GtpPort,
		 ip = IP, port = Port,
		 type = Type, seq_no = SeqNo}.

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
	    message_counter(rx, GtpPort, Msg),
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

handle_response(_IP, _Port, #gtp{seq_no = SeqNo} = Msg, #state{gtp_port = GtpPort, pending = Pending} = State) ->
    case gb_trees:lookup(SeqNo, Pending) of
	none -> %% duplicate, drop silently
	    message_counter(rx, GtpPort, Msg, duplicate),
	    lager:error("~p: invalid response: ~p, ~p", [self(), SeqNo, Pending]),
	    State;

	{value, {_RemoteIP, _T3, _N3, _Data, Sender, TRef}} ->
	    lager:info("~p: found response: ~p", [self(), SeqNo]),
	    send_request_reply(Sender, Msg),
	    cancel_timer(TRef),
	    State#state{pending = gb_trees:delete(SeqNo, Pending)}
    end.

handle_request(#request_key{ip = IP, port = Port} = ReqKey, Msg,
	       #state{gtp_port = GtpPort, socket = Socket, responses = Responses} = State) ->
    Now = erlang:monotonic_time(milli_seconds),
    case gb_trees:lookup(ReqKey, Responses) of
	{value, {Data, TStamp}}  when (TStamp + ?RESPONSE_TIMEOUT) > Now ->
	    message_counter(rx, GtpPort, Msg, duplicate),
	    gen_socket:sendto(Socket, {inet4, IP, Port}, Data);

	_Other ->
	    lager:debug("HandleRequest: ~p", [_Other]),
	    gtp_context:handle_message(ReqKey, Msg)
    end,
    State.

do_send_request(From, RemoteIP, T3, N3, Msg, ReqId,
	     #state{gtp_port = GtpPort, seq_no = SeqNo} = State) ->
    lager:debug("~p: gtp_socket send_request to ~p: ~p", [self(), RemoteIP, Msg]),
    message_counter(tx, GtpPort, Msg),
    Data = gtp_packet:encode(Msg#gtp{seq_no = SeqNo}),
    Sender = #sender{from = From, req_id = ReqId, msg = Msg},
    send_request_with_timeout(SeqNo, RemoteIP, T3, N3, Data, Sender,
			      State#state{seq_no = (SeqNo + 1) rem 65536}).

send_request_reply(#sender{from = From, req_id = ReqId, msg = ReqMsg}, ReplyMsg) ->
    From ! {ReqId, ReqMsg, ReplyMsg}.

send_request_with_timeout(SeqNo, RemoteIP, T3, N3, Data, Sender,
			  #state{socket = Socket, pending = Pending} = State) ->
    TRef = erlang:start_timer(T3, self(), {send, SeqNo}),
    gen_socket:sendto(Socket, {inet4, RemoteIP, ?GTP1c_PORT}, Data),
    State#state{pending = gb_trees:insert(SeqNo, {RemoteIP, T3, N3, Data, Sender, TRef}, Pending)}.

start_cache_timer(State) ->
    State#state{cache_timer = erlang:start_timer(?CACHE_TIMEOUT, self(), cache_timeout)}.

timeout_queue(Now, #state{responses = Responses0, rqueue = RQueue0} = State) ->
    case queue:peek(RQueue0) of
	{value, {TStamp, ReqKey}} when (TStamp + ?RESPONSE_TIMEOUT) < Now ->
	    {_, RQueue} = queue:out(RQueue0),
	    Responses = gb_trees:delete(ReqKey, Responses0),
	    timeout_queue(Now, State#state{responses = Responses, rqueue = RQueue});
	_ ->
	    State
    end.

enqueue_response(ReqKey, Data, DoCache,
		 #state{responses = Responses0, rqueue = RQueue0} = State)
  when DoCache =:= true ->
    Now = erlang:monotonic_time(milli_seconds),
    Responses = gb_trees:insert(ReqKey, {Data, Now}, Responses0),
    RQueue = queue:in({Now, ReqKey}, RQueue0),
    timeout_queue(Now, State#state{responses = Responses, rqueue = RQueue});

enqueue_response(_ReqKey, _Data, _DoCache, State) ->
    Now = erlang:monotonic_time(milli_seconds),
    timeout_queue(Now, State).

do_send_response(#request_key{ip = IP, port = Port} = ReqKey, Data, DoCache,
		 #state{socket = Socket} = State) ->
    gen_socket:sendto(Socket, {inet4, IP, Port}, Data),
    enqueue_response(ReqKey, Data, DoCache, State).

%%%===================================================================
%%% exometer functions
%%%===================================================================

init_exometer(#gtp_port{name = Name, type = 'gtp-c'}) ->
    exometer:new([socket, 'gtp-c', Name, rx, v1, unsupported], counter),
    exometer:new([socket, 'gtp-c', Name, tx, v1, unsupported], counter),
    lists:foreach(fun(MsgType) ->
			  exometer:new([socket, 'gtp-c', Name, rx, v1, MsgType], counter),
			  exometer:new([socket, 'gtp-c', Name, rx, v1, MsgType, duplicate], counter),
			  exometer:new([socket, 'gtp-c', Name, tx, v1, MsgType], counter),
			  exometer:new([socket, 'gtp-c', Name, tx, v1, MsgType, retransmit], counter),
			  case gtp_v1_c:gtp_msg_type(MsgType) of
			      request ->
				  exometer:new([socket, 'gtp-c', Name, tx, v1, MsgType, timeout], counter);
			      _ ->
				  ok
			  end
		  end, gtp_v1_c:gtp_msg_types()),
    exometer:new([socket, 'gtp-c', Name, rx, v2, unsupported], counter),
    exometer:new([socket, 'gtp-c', Name, tx, v2, unsupported], counter),
    lists:foreach(fun(MsgType) ->
			  exometer:new([socket, 'gtp-c', Name, rx, v2, MsgType, duplicate], counter),
			  exometer:new([socket, 'gtp-c', Name, rx, v2, MsgType], counter),
			  exometer:new([socket, 'gtp-c', Name, tx, v2, MsgType, retransmit], counter),
			  exometer:new([socket, 'gtp-c', Name, tx, v2, MsgType], counter),
			  case gtp_v2_c:gtp_msg_type(MsgType) of
			      request ->
				  exometer:new([socket, 'gtp-c', Name, tx, v2, MsgType, timeout], counter);
			      _ ->
				  ok
			  end
		  end, gtp_v2_c:gtp_msg_types()),
    ok;
init_exometer(_) ->
    ok.

message_counter_apply(Name, Direction, Version, MsgInfo) ->
    case exometer:update([socket, 'gtp-c', Name, Direction, Version | MsgInfo], 1) of
	{error, undefined} ->
	    exometer:update([socket, 'gtp-c', Name, Direction, Version, unsupported], 1);
	Other ->
	    Other
    end.

message_counter(Direction,
		#gtp_port{name = Name, type = 'gtp-c'},
		#gtp{version = Version, type = MsgType}) ->
    message_counter_apply(Name, Direction, Version, [MsgType]).

message_counter(Direction,
		#gtp_port{name = Name, type = 'gtp-c'},
		#gtp{version = Version, type = MsgType},
		Verdict) ->
    message_counter_apply(Name, Direction, Version, [MsgType, Verdict]).
