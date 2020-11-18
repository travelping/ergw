%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sx_socket).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([validate_options/2, start_link/1]).
-export([call/3, call/5, send_response/3, id/0, seid/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-type sequence_number() :: 0 .. 16#ffffff.

-record(state, {
	  name,
	  node,
	  send_socket    :: socket:socket(),
	  recv_socket    :: socket:socket(),
	  burst_size = 1 :: non_neg_integer(),
	  gtp_socket     :: #socket{},
	  gtp_info       :: #gtp_socket_info{},

	  seq_no = 1 :: sequence_number(),
	  pending    :: gb_trees:tree(sequence_number(), term()),

	  responses
	 }).

-record(send_req, {
	  address :: inet:ip_address(),
	  t1      :: non_neg_integer(),
	  n1      :: non_neg_integer(),
	  data    :: binary(),
	  msg     :: term,
	  from    :: {reference(), pid()},
	  cb_info :: {M :: atom(), F :: atom(), A :: [term()]},
	  send_ts :: non_neg_integer()
	 }).

-define(SERVER, ?MODULE).

-define(T1, 10 * 1000).
-define(N1, 5).
-define(RESPONSE_TIMEOUT, (?T1 * ?N1 + (?T1 div 2))).
-define(CACHE_TIMEOUT, ?RESPONSE_TIMEOUT).

-define(log_pfcp(Level, Fmt, Args, PFCP),
	try
	    #pfcp{version = Version, type = MsgType, seid = SEID, seq_no = SeqNo, ie = IE} = PFCP,
	    IEList =
		if is_map(IE) -> maps:values(IE);
		   true -> IE
		end,
	    ?LOG(Level, Fmt "~s(V: ~w, SEID: ~w, Seq: ~w): ~s", Args ++
			    [pfcp_packet:msg_description_v1(MsgType), Version, SEID, SeqNo,
			     pfcp_packet:pretty_print(IEList)])
	catch
	    _:_ -> ok
	end).

%%====================================================================
%% API
%%====================================================================

start_link(Opts) ->
    proc_lib:start_link(?MODULE, init, [Opts]).

call(Peer, Msg, {_,_,_} = CbInfo) ->
    ?MODULE:call(Peer, ?T1, ?N1, Msg, CbInfo).

call(Peer, T1, N1, Msg, {_,_,_} = CbInfo) ->
    Req = make_send_req(Peer, T1, N1, Msg, CbInfo),
    gen_server:cast(?SERVER, {call, Req}).

send_response(ReqKey, Msg, DoCache) ->
    Data = pfcp_packet:encode(Msg),
    gen_server:cast(?SERVER, {send_response, ReqKey, Msg, Data, DoCache}).

id() ->
    gen_server:call(?SERVER, id).


seid() ->
    %% 64bit unique id, inspired by https://github.com/fogfish/uid
    ((erlang:monotonic_time(millisecond) band 16#3ffffffffffff) bsl 14) bor
	(erlang:unique_integer([positive]) band 16#3fff).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(SOCKET_OPTS, [netdev, netns, freebind, reuseaddr, rcvbuf]).
-define(SocketDefaults, [{node, "invalid"},
			 {socket, "invalid"},
			 {ip, invalid},
			 {burst_size, 10}]).

validate_options(Name, Values) ->
     ergw_config:validate_options(fun validate_option/2, Values,
				  [{name, Name}|?SocketDefaults], map).

validate_option(type, pfcp = Value) ->
    Value;
validate_option(node, Value) when is_atom(Value) ->
    Value;
validate_option(name, Value) when is_atom(Value) ->
    Value;
validate_option(ip, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Value;
validate_option(netdev, Value) when is_list(Value) ->
    Value;
validate_option(netdev, Value) when is_binary(Value) ->
    unicode:characters_to_list(Value, latin1);
validate_option(netns, Value) when is_list(Value) ->
    Value;
validate_option(netns, Value) when is_binary(Value) ->
    unicode:characters_to_list(Value, latin1);
validate_option(freebind, Value) when is_boolean(Value) ->
    Value;
validate_option(reuseaddr, Value) when is_boolean(Value) ->
    Value;
validate_option(rcvbuf, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(socket, Value)
  when is_atom(Value) ->
    Value;
validate_option(burst_size, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(#{name := Name, node := Node, ip := IP,
       socket := GtpSocketName, burst_size := BurstSize} = Opts) ->
    process_flag(trap_exit, true),

    SocketOpts = maps:with(?SOCKET_OPTS, Opts),
    {ok, SendSocket} = make_sx_socket(IP, 0, SocketOpts),
    {ok, RecvSocket} = make_sx_socket(IP, 8805, SocketOpts),

    register(?SERVER, self()),

    proc_lib:init_ack({ok, self()}),

    GtpSocket = ergw_socket_reg:waitfor('gtp-u', GtpSocketName),
    GtpSockInfo = ergw_gtp_socket:info(GtpSocket),

    State = #state{
	       send_socket = SendSocket,
	       recv_socket = RecvSocket,
	       name = Name,
	       node = Node,
	       burst_size = BurstSize,
	       gtp_socket = GtpSocket,
	       gtp_info = GtpSockInfo,

	       seq_no = 1,
	       pending = gb_trees:empty(),

	       responses = ergw_cache:new(?CACHE_TIMEOUT, responses)
	      },
    self() ! {'$socket', SendSocket, select, undefined},
    self() ! {'$socket', RecvSocket, select, undefined},

    gen_server:enter_loop(?MODULE, [], State, ?SERVER).

handle_call(id, _From, #state{send_socket = Socket, node = Node,
			      gtp_socket = GtpSocket,
			      gtp_info = GtpSocketInfo} = State) ->
    {ok, #{addr := IP}} = socket:sockname(Socket),
    Reply = {ok, #node{node = Node, ip = IP}, GtpSocket, GtpSocketInfo},
    {reply, Reply, State};

handle_call({call, SendReq0}, From, State0) ->
    {SendReq, State1} = prepare_send_req(SendReq0#send_req{from = From}, State0),
    message_counter(tx, State0, SendReq),
    State = send_request(SendReq, State1),
    {noreply, State};

handle_call(Request, _From, State) ->
    ?LOG(error, "handle_call: unknown ~p", [Request]),
    {reply, ok, State}.

handle_cast({call, SendReq0}, State0) ->
    {SendReq, State1} = prepare_send_req(SendReq0, State0),
    message_counter(tx, State0, SendReq),
    State = send_request(SendReq, State1),
    {noreply, State};

handle_cast({send_response, ReqKey, Msg, Data, DoCache}, State0)
  when is_binary(Data) ->
    message_counter(tx, State0, ReqKey, Msg),
    measure_request(State0, ReqKey),
    State = do_send_response(ReqKey, Data, DoCache, State0),
    {noreply, State};

handle_cast(Msg, State) ->
    ?LOG(error, "handle_cast: unknown ~p", [Msg]),
    {noreply, State}.

handle_info(Info = {timeout, _TRef, {request, SeqNo}}, State0) ->
    ?LOG(debug, "handle_info: ~p", [Info]),
    {Req, State1} = take_request(SeqNo, State0),
    case Req of
	#send_req{n1 = 0} = SendReq ->
	    message_counter(tx, State1, SendReq, timeout),
	    send_request_reply(SendReq, timeout),
	    {noreply, State1};

	#send_req{n1 = N1} = SendReq ->
	    %% resend....
	    message_counter(tx, State1, SendReq, retransmit),
	    State = send_request(SendReq#send_req{n1 = N1 - 1}, State1),
	    {noreply, State};

	none ->
	    {noreply, State1}
    end;

handle_info({timeout, TRef, responses}, #state{responses = Responses} = State) ->
    {noreply, State#state{responses = ergw_cache:expire(TRef, Responses)}};

handle_info({'$socket', Socket, select, Info}, #state{send_socket = Socket} = State) ->
    handle_input(Socket, Info, State);
handle_info({'$socket', Socket, select, Info}, #state{recv_socket = Socket} = State) ->
    handle_input(Socket, Info, State);

handle_info({'$socket', Socket, abort, Info}, #state{send_socket = Socket} = State) ->
    handle_input(Socket, Info, State);
handle_info({'$socket', Socket, abort, Info}, #state{recv_socket = Socket} = State) ->
    handle_input(Socket, Info, State);

handle_info(Info, State) ->
    ?LOG(error, "handle_info: unknown ~p, ~p", [Info, State]),
    {noreply, State}.

terminate(_Reason, #state{send_socket = SendSocket, recv_socket = RecvSocket} = _State) ->
    socket:close(SendSocket),
    socket:close(RecvSocket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Socket functions
%%%===================================================================

-if(?OTP_RELEASE =< 23).
-define(BIND_OK, {ok, _}).
-else.
-define(BIND_OK, ok).
-endif.

-record(sx_request, {
	  key		:: term(),
	  ip		:: inet:ip_address(),
	  port		:: 0 .. 65535,
	  version	:: 'v1' | 'v2',
	  type		:: atom(),
	  arrival_ts    :: integer()
	 }).

family({_,_,_,_}) -> inet;
family({_,_,_,_,_,_,_,_}) -> inet6.

make_request(ArrivalTS, IP, Port, #pfcp{version = Version, seq_no = SeqNo, type = Type}) ->
    #sx_request{
       key = {IP, Port, Type, SeqNo},
       ip = IP,
       port = Port,
       version = Version,
       type = Type,
       arrival_ts = ArrivalTS}.

make_sx_socket(IP, Port, #{netns := NetNs} = Opts)
  when is_list(NetNs) ->
    {ok, Socket} = socket:open(family(IP), dgram, udp, #{netns => NetNs}),
    bind_sx_socket(Socket, IP, Port, Opts);
make_sx_socket(IP, Port, Opts) ->
    {ok, Socket} = socket:open(family(IP), dgram, udp),
    bind_sx_socket(Socket, IP, Port, Opts).

bind_sx_socket(Socket, {_,_,_,_} = IP, Port, Opts) ->
    ok = socket_ip_freebind(Socket, Opts),
    ok = socket_netdev(Socket, Opts),
    ?BIND_OK = socket:bind(Socket, #{family => inet, addr => IP, port => Port}),
    ok = socket:setopt(Socket, ip, recverr, true),
    ok = socket:setopt(Socket, ip, mtu_discover, dont),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    {ok, Socket};

bind_sx_socket(Socket, {_,_,_,_,_,_,_,_} = IP, Port, Opts) ->
    ok = socket:setopt(Socket, ipv6, v6only, true),
    ok = socket_netdev(Socket, Opts),
    ?BIND_OK = socket:bind(Socket, #{family => inet6, addr => IP, port => Port}),
    ok = socket:setopt(Socket, ipv6, recverr, true),
    ok = socket:setopt(Socket, ipv6, mtu_discover, dont),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    {ok, Socket}.

socket_ip_freebind(Socket, #{freebind := true}) ->
    socket:setopt(Socket, ip, freebind, true);
socket_ip_freebind(_, _) ->
    ok.

socket_netdev(Socket, #{netdev := Device}) ->
    socket:setopt(Socket, socket, bindtodevice, Device);
socket_netdev(_, _) ->
    ok.

socket_setopts(Socket, rcvbuf, Size) when is_integer(Size) ->
    case socket:setopt(Socket, socket, rcvbufforce, Size) of
	ok -> ok;
	_  -> socket:setopt(Socket, socket, rcvbuf, Size)
    end;
socket_setopts(Socket, reuseaddr, true) ->
    ok = socket:setopt(Socket, socket, reuseaddr, true);
socket_setopts(_Socket, _, _) ->
    ok.

handle_input(Socket, Info, #state{burst_size = BurstSize} = State) ->
    handle_input(Socket, Info, BurstSize, State).

handle_input(Socket, _Info, 0, State0) ->
    %% break the loop and restart
    self() ! {'$socket', Socket, select, undefined},
    {noreply, State0};

handle_input(Socket, Info, Cnt, State0) ->
    case socket:recvfrom(Socket, 0, [], nowait) of
	{error, _} ->
	    State = handle_err_input(Socket, State0),
	    handle_input(Socket, Info, Cnt - 1, State);

	{ok, {#{addr := IP, port := Port}, Data}} ->
	    ArrivalTS = erlang:monotonic_time(),
	    State = handle_message(ArrivalTS, IP, Port, Data, State0),
	    handle_input(Socket, Info, Cnt - 1, State);

	{select, _SelectInfo} ->
	    {noreply, State0}
    end.

-define(IP_RECVERR,             11).
-define(IPV6_RECVERR,           25).
-define(SO_EE_ORIGIN_LOCAL,      1).
-define(SO_EE_ORIGIN_ICMP,       2).
-define(SO_EE_ORIGIN_ICMP6,      3).
-define(SO_EE_ORIGIN_TXSTATUS,   4).
-define(ICMP_DEST_UNREACH,       3).       %% Destination Unreachable
-define(ICMP_HOST_UNREACH,       1).       %% Host Unreachable
-define(ICMP_PROT_UNREACH,       2).       %% Protocol Unreachable
-define(ICMP_PORT_UNREACH,       3).       %% Port Unreachable
-define(ICMP6_DST_UNREACH,       1).
-define(ICMP6_DST_UNREACH_ADDR,  3).       %% address unreachable
-define(ICMP6_DST_UNREACH_NOPORT,4).       %% bad port

handle_dest_unreach(IP, [Data|_], #state{name = Name} = State0) when is_binary(Data) ->
    ergw_prometheus:pfcp(tx, Name, IP, unreachable),
    try pfcp_packet:decode(Data) of
	#pfcp{seq_no = SeqNo} ->
	    {Req, State} = take_request(SeqNo, State0),
	    case Req of
		none ->
		    ok;
		#send_req{} = SendReq ->
		    send_request_reply(SendReq, unreachable)
	    end,
	    State
    catch
	Class:Error:Stack ->
	    ?LOG(debug, "HandleSocketError: ~p:~p @ ~p", [Class, Error, Stack]),
	    State0
    end;
handle_dest_unreach(_, _, State) ->
    State.

handle_socket_error(#{level := ip, type := ?IP_RECVERR,
		      data := <<_ErrNo:32/native-integer,
				Origin:8, Type:8, Code:8, _Pad:8,
				_Info:32/native-integer, _Data:32/native-integer,
				_/binary>>},
		    IP, _Port, IOV, State)
  when Origin == ?SO_EE_ORIGIN_ICMP, Type == ?ICMP_DEST_UNREACH,
       (Code == ?ICMP_HOST_UNREACH orelse Code == ?ICMP_PORT_UNREACH) ->
    ?LOG(debug, "ICMP indication for ~s: ~p", [inet:ntoa(IP), Code]),
    handle_dest_unreach(IP, IOV, State);

handle_socket_error(#{level := ip, type := recverr,
		      data := #{origin := icmp, type := dest_unreach, code := Code}},
		    IP, _Port, IOV, State)
  when Code == host_unreach;
       Code == port_unreach ->
    ?LOG(debug, "ICMP indication for ~s: ~p", [inet:ntoa(IP), Code]),
    handle_dest_unreach(IP, IOV, State);

handle_socket_error(#{level := ipv6, type := ?IPV6_RECVERR,
		      data := <<_ErrNo:32/native-integer,
				Origin:8, Type:8, Code:8, _Pad:8,
				_Info:32/native-integer, _Data:32/native-integer,
				_/binary>>},
		    IP, _Port, IOV, State)
  when Origin == ?SO_EE_ORIGIN_ICMP6, Type == ?ICMP6_DST_UNREACH,
       (Code == ?ICMP6_DST_UNREACH_ADDR orelse Code == ?ICMP6_DST_UNREACH_NOPORT) ->
    ?LOG(debug, "ICMPv6 indication for ~s: ~p", [inet:ntoa(IP), Code]),
    handle_dest_unreach(IP, IOV, State);

handle_socket_error(#{level := ipv6, type := recverr,
		      data := #{origin := icmp6, type := dest_unreach, code := Code}},
		    IP, _Port, IOV, State)
  when Code == addr_unreach;
       Code == port_unreach ->
    ?LOG(debug, "ICMPv6 indication for ~s: ~p", [inet:ntoa(IP), Code]),
    handle_dest_unreach(IP, IOV, State);

handle_socket_error(Error, IP, _Port, _IOV, State) ->
    ?LOG(debug, "got unhandled error info for ~s: ~p", [inet:ntoa(IP), Error]),
    State.

handle_err_input(Socket, State) ->
    case socket:recvmsg(Socket, [errqueue], nowait) of
	{ok, #{addr := #{addr := IP, port := Port}, iov := IOV, ctrl := Ctrl}} ->
	    lists:foldl(handle_socket_error(_, IP, Port, IOV, _), State, Ctrl);

	{select, SelectInfo} ->
	    socket:cancel(Socket, SelectInfo),
	    State;

	Other ->
	    ?LOG(error, "got unhandled error input: ~p", [Other]),
	    State
    end.

%%%===================================================================
%%% Sx Message functions
%%%===================================================================

handle_message(ArrivalTS, IP, Port, Data, #state{name = Name} = State0) ->
    ?LOG(debug, "handle message ~s:~w: ~p", [inet:ntoa(IP), Port, Data]),
    try
	Msg = pfcp_packet:decode(Data),
	ergw_prometheus:pfcp(rx, Name, IP, Msg),
	handle_message_1(ArrivalTS, IP, Port, Msg, State0)
    catch
	Class:Error:Stack ->
	    ?LOG(debug, "UDP invalid msg: ~p:~p @ ~p", [Class, Error, Stack]),
	    ergw_prometheus:pfcp(rx, Name, IP, 'malformed-message'),
	    State0
    end.

handle_message_1(ArrivalTS, IP, Port, #pfcp{type = MsgType} = Msg, State) ->
    ?log_pfcp(debug, "handle message ~s:~w: ", [inet:ntoa(IP), Port], Msg),
    case pfcp_msg_type(MsgType) of
	response ->
	    handle_response(ArrivalTS, IP, Port, Msg, State);
	request ->
	    ReqKey = make_request(ArrivalTS, IP, Port, Msg),
	    handle_request(ReqKey, Msg, State);
	_ ->
	    State
    end.

handle_response(ArrivalTS, IP, _Port, #pfcp{seq_no = SeqNo} = Msg,
		#state{name = Name} = State0) ->
    {Req, State} = take_request(SeqNo, State0),
    case Req of
	none -> %% duplicate, drop silently
	    ergw_prometheus:pfcp(rx, Name, IP, Msg, duplicate),
	    ?log_pfcp(debug, "~p: duplicate response: ~p: ", [self(), SeqNo], Msg),
	    State;

	#send_req{} = SendReq ->
	    ?log_pfcp(info, "~p: found response: ~p: ", [self(), SeqNo], Msg),
	    measure_response(State0, SendReq, ArrivalTS),
	    send_request_reply(SendReq, Msg),
	    State
    end.

handle_request(#sx_request{ip = IP, port = Port} = ReqKey, Msg,
	       #state{name = Name, responses = Responses} = State) ->
    case ergw_cache:get(cache_key(ReqKey), Responses) of
	{value, Data} ->
	    ergw_prometheus:pfcp(rx, Name, IP, Msg, duplicate),
	    sendto(response, IP, Port, Data, State);

	_Other ->
	    ergw_sx_node:handle_request(ReqKey, IP, Msg)
    end,
    State.

%%%===================================================================
%%% Internal functions
%%%===================================================================

pfcp_msg_type(heartbeat_request) ->			request;
pfcp_msg_type(heartbeat_response) ->			response;
pfcp_msg_type(pfd_management_request) ->		request;
pfcp_msg_type(pfd_management_response) ->		response;
pfcp_msg_type(association_setup_request) ->		request;
pfcp_msg_type(association_setup_response) ->		response;
pfcp_msg_type(association_update_request) ->		request;
pfcp_msg_type(association_update_response) ->		response;
pfcp_msg_type(association_release_request) ->		request;
pfcp_msg_type(association_release_response) ->		response;
pfcp_msg_type(version_not_supported_response) ->	response;
pfcp_msg_type(node_report_request) ->			request;
pfcp_msg_type(node_report_response) ->			response;
pfcp_msg_type(session_set_deletion_request) ->		request;
pfcp_msg_type(session_set_deletion_response) ->		response;
pfcp_msg_type(session_establishment_request) ->		request;
pfcp_msg_type(session_establishment_response) ->	response;
pfcp_msg_type(session_modification_request) ->		request;
pfcp_msg_type(session_modification_response) ->		response;
pfcp_msg_type(session_deletion_request) ->		request;
pfcp_msg_type(session_deletion_response) ->		response;
pfcp_msg_type(session_report_request) ->		request;
pfcp_msg_type(session_report_response) ->		response;
pfcp_msg_type(_) ->					error.

cancel_timer(Ref) ->
    case erlang:cancel_timer(Ref) of
	false ->
	    receive {timeout, Ref, _} -> 0
	    after 0 -> false
	    end;
	RemainingTime ->
	    RemainingTime
    end.

prepare_send_req(#send_req{msg = Msg0} = SendReq, State0) ->
    ?LOG(debug, "PrepSend: ~p", [SendReq]),
    {Msg, State} = new_sequence_number(Msg0, State0),
    ?log_pfcp(info, "PrepSend: ", [], Msg),
    BinMsg = pfcp_packet:encode(Msg),
    {SendReq#send_req{msg = Msg, data = BinMsg}, State}.

make_send_req(Address, T1, N1, Msg, CbInfo) ->
    #send_req{
       address = Address,
       t1 = T1,
       n1 = N1,
       msg = Msg,
       cb_info = CbInfo,
       send_ts = erlang:monotonic_time()
      }.

new_sequence_number(Msg, #state{seq_no = SeqNo} = State) ->
    {Msg#pfcp{seq_no = SeqNo}, State#state{seq_no = (SeqNo + 1) band 16#ffffff}}.

start_request(#send_req{t1 = Timeout, msg = Msg} = SendReq, State) ->
    #pfcp{seq_no = SeqNo} = Msg,
    TRef = erlang:start_timer(Timeout, self(), {request, SeqNo}),
    State#state{pending = gb_trees:insert(SeqNo, {SendReq, TRef}, State#state.pending)}.

take_request(SeqNo, #state{pending = PendingIn} = State) ->
    case gb_trees:take_any(SeqNo, PendingIn) of
	error ->
	    {none, State};

	{{Req, TRef}, PendingOut} ->
	    cancel_timer(TRef),
	    {Req, State#state{pending = PendingOut}}
    end.

sendto(Socket, RemoteIP, Port, Data) ->
    Dest = #{family => family(RemoteIP),
	     addr => RemoteIP,
	     port => Port},
    socket:sendto(Socket, Data, Dest, nowait).

sendto(request, IP, Port, Data, #state{send_socket = Socket}) ->
    sendto(Socket, IP, Port, Data);
sendto(response, IP, Port, Data, #state{recv_socket = Socket}) ->
    sendto(Socket, IP, Port, Data).


send_request(#send_req{address = DstIP, data = Data} = SendReq, State) ->
    case sendto(request, DstIP, 8805, Data, State) of
	ok ->
	    start_request(SendReq, State);
	_ ->
	    message_counter(tx, State, SendReq, unreachable),
	    send_request_reply(SendReq, unreachable),
	    State
    end.

send_request_reply(#send_req{cb_info = {M, F, A}} = SendReq, Reply) ->
    ?LOG(debug, "send_request_reply: ~p", [SendReq]),
    apply(M, F, A ++ [Reply]);
send_request_reply(#send_req{from = {_, _} = From} = SendReq, Reply) ->
    ?LOG(debug, "send_request_reply: ~p", [SendReq]),
    gen_server:reply(From, Reply).

enqueue_response(ReqKey, Data, DoCache,
		 #state{responses = Responses} = State)
  when DoCache =:= true ->
    State#state{responses =
		    ergw_cache:enter(cache_key(ReqKey), Data, ?RESPONSE_TIMEOUT, Responses)};
enqueue_response(_ReqKey, _Data, _DoCache, State) ->
    State.

do_send_response(#sx_request{ip = IP, port = Port} = ReqKey, Data, DoCache, State) ->
    sendto(response, IP, Port, Data, State),
    enqueue_response(ReqKey, Data, DoCache, State).

%%%===================================================================
%%% cache helper
%%%===================================================================

cache_key(#sx_request{key = Key}) ->
    Key;
cache_key(Object) ->
    Object.

%%%===================================================================
%%% Metrics collections
%%%===================================================================

%% message_counter/3
message_counter(Direction, #state{name = Name}, #send_req{address = IP, msg = Msg}) ->
    ergw_prometheus:pfcp(Direction, Name, IP, Msg).

%% message_counter/4
message_counter(Direction, #state{name = Name}, #sx_request{ip = IP}, #pfcp{} = Msg) ->
    ergw_prometheus:pfcp(Direction, Name, IP, Msg);
message_counter(Direction, #state{name = Name}, #send_req{address = IP}, Verdict)
  when is_atom(Verdict) ->
    ergw_prometheus:pfcp(Direction, Name, IP, Verdict).

%% measure the time it takes our peer to reply to a request
measure_response(#state{name = Name},
		 #send_req{address = IP, msg = Msg, send_ts = SendTS}, ArrivalTS) ->
    ergw_prometheus:pfcp_peer_response(Name, IP, Msg, SendTS - ArrivalTS).

%% measure the time it takes us to generate a response to a request
measure_request(#state{name = Name},
		#sx_request{type = MsgType, arrival_ts = ArrivalTS}) ->
    Duration = erlang:monotonic_time() - ArrivalTS,
    ergw_prometheus:pfcp_request_duration(Name, MsgType, Duration).
