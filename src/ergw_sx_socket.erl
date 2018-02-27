%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sx_socket).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([validate_options/1, start_link/1, start_sx_socket/1]).
-export([call/2, call/3, call/5, id/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-type sequence_number() :: 0 .. 16#ffffff.

-record(state, {
	  name,
	  node,
	  socket     :: gen_socket:socket(),

	  seq_no = 1 :: sequence_number(),
	  pending    :: gb_trees:tree(sequence_number(), term())
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
	    lager:Level(Fmt "~s(V: ~w, SEID: ~w, Seq: ~w): ~p", Args ++ [pfcp_packet:msg_description_v1(MsgType), Version, SEID, SeqNo, [lager:pr(E, ?MODULE) || E <- IEList]])
	catch
	    _:_ -> ok
	end).

%%====================================================================
%% API
%%====================================================================

start_sx_socket(Opts) ->
    ergw_sup:start_sx_socket(Opts).

start_link(Opts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Opts, []).

call(Peer, Msg) ->
    Req = make_send_req(Peer, ?T1, ?N1, Msg, undefined),
    gen_server:call(?SERVER, {call, Req}).

call(Peer, Msg, {_,_,_} = CbInfo) ->
    call(Peer, ?T1, ?N1, Msg, CbInfo).

call(Peer, T1, N1, Msg, {_,_,_} = CbInfo) ->
    Req = make_send_req(Peer, T1, N1, Msg, CbInfo),
    gen_server:cast(?SERVER, {call, Req}).

id() ->
    gen_server:call(?SERVER, id).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(SOCKET_OPTS, [netdev, netns, freebind, reuseaddr, rcvbuf]).
-define(SocketDefaults, [{node, "invalid"},
			 {name, "invalid"},
			 {ip, invalid}]).

validate_options(Values0) ->
    Values = if is_list(Values0) ->
		     proplists:unfold(Values0);
		true ->
		     Values0
	     end,
     ergw_config:validate_options(fun validate_option/2, Values, ?SocketDefaults, map).

validate_option(node, Value) when is_atom(Value) ->
    Value;
validate_option(name, Value) when is_atom(Value) ->
    Value;
validate_option(ip, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Value;
validate_option(netdev, Value)
  when is_list(Value); is_binary(Value) ->
    Value;
validate_option(netns, Value)
  when is_list(Value); is_binary(Value) ->
    Value;
validate_option(freebind, Value) when is_boolean(Value) ->
    Value;
validate_option(reuseaddr, Value) when is_boolean(Value) ->
    Value;
validate_option(rcvbuf, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(#{name := Name, node := Node, ip := IP} = Opts) ->
    process_flag(trap_exit, true),

    SocketOpts = maps:with(?SOCKET_OPTS, Opts),
    {ok, Socket} = make_sx_socket(IP, 8805, SocketOpts),

    State = #state{
	       socket = Socket,
	       name = Name,
	       node = Node,

	       seq_no = 1,
	       pending = gb_trees:empty()
	      },
    {ok, State}.

handle_call(id, _From, #state{socket = Socket, node = Node} = State) ->
    {_, IP, _} = gen_socket:getsockname(Socket),
    Reply = {ok, #node{node = Node, ip = IP}},
    {reply, Reply, State};

handle_call({call, SendReq0}, From, State0) ->
    {SendReq, State1} = prepare_send_req(SendReq0#send_req{from = From}, State0),
    State = send_request(SendReq, State1),
    {noreply, State};

handle_call(Request, _From, State) ->
    lager:error("handle_call: unknown ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({call, SendReq0}, State0) ->
    {SendReq, State1} = prepare_send_req(SendReq0, State0),
    State = send_request(SendReq, State1),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(Info = {timeout, _TRef, {request, SeqNo}}, State0) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    {Req, State1} = take_request(SeqNo, State0),
    case Req of
	#send_req{n1 = 0} = SendReq ->
	    send_request_reply(SendReq, timeout),
	    {noreply, State1};

	#send_req{n1 = N1} = SendReq ->
	    %% resend....
	    State = send_request(SendReq#send_req{n1 = N1 - 1}, State1),
	    {noreply, State};

	none ->
	    {noreply, State1}
    end;

handle_info({Socket, input_ready}, #state{socket = Socket} = State) ->
    handle_input(Socket, State);

handle_info(Info, State) ->
    lager:error("handle_info: unknown ~p, ~p", [lager:pr(Info, ?MODULE), lager:pr(State, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, #state{socket = Socket} = _State) ->
    gen_socket:close(Socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Socket functions
%%%===================================================================

family({_,_,_,_}) -> inet;
family({_,_,_,_,_,_,_,_}) -> inet6.

make_sx_socket(IP, Port, #{netns := NetNs} = Opts)
  when is_list(NetNs) ->
    {ok, Socket} = gen_socket:socketat(NetNs, family(IP), dgram, udp),
    bind_sx_socket(Socket, IP, Port, Opts);
make_sx_socket(IP, Port, Opts) ->
    {ok, Socket} = gen_socket:socket(family(IP), dgram, udp),
    bind_sx_socket(Socket, IP, Port, Opts).

bind_sx_socket(Socket, {_,_,_,_} = IP, Port, Opts) ->
    ok = socket_ip_freebind(Socket, Opts),
    ok = socket_netdev(Socket, Opts),
    ok = gen_socket:bind(Socket, {inet4, IP, Port}),
    ok = gen_socket:setsockopt(Socket, sol_ip, recverr, true),
    ok = gen_socket:setsockopt(Socket, sol_ip, mtu_discover, 0),
    ok = gen_socket:input_event(Socket, true),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    {ok, Socket};

bind_sx_socket(Socket, {_,_,_,_,_,_,_,_} = IP, Port, Opts) ->
    %% ok = gen_socket:setsockopt(Socket, sol_ip, recverr, true),
    ok = socket_netdev(Socket, Opts),
    ok = gen_socket:bind(Socket, {inet6, IP, Port}),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    ok = gen_socket:input_event(Socket, true),
    {ok, Socket}.

socket_ip_freebind(Socket, #{freebind := true}) ->
    gen_socket:setsockopt(Socket, sol_ip, freebind, true);
socket_ip_freebind(_, _) ->
    ok.

socket_netdev(Socket, #{netdev := Device}) ->
    BinDev = iolist_to_binary([Device, 0]),
    gen_socket:setsockopt(Socket, sol_socket, bindtodevice, BinDev);
socket_netdev(_, _) ->
    ok.

socket_setopts(Socket, rcvbuf, Size) when is_integer(Size) ->
    case gen_socket:setsockopt(Socket, sol_socket, rcvbufforce, Size) of
	ok -> ok;
	_  -> gen_socket:setsockopt(Socket, sol_socket, rcvbuf, Size)
    end;
socket_setopts(Socket, reuseaddr, true) ->
    ok = gen_socket:setsockopt(Socket, sol_socket, reuseaddr, true);
socket_setopts(_Socket, _, _) ->
    ok.

handle_input(Socket, State) ->
    case gen_socket:recvfrom(Socket) of
	{error, _} ->
	    handle_err_input(Socket, State);

	{ok, {_, IP, Port}, Data} ->
	    ArrivalTS = erlang:monotonic_time(),
	    ok = gen_socket:input_event(Socket, true),
	    handle_message(ArrivalTS, IP, Port, Data, State);

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
		    IP, _Port, _State)
  when Code == ?ICMP_HOST_UNREACH; Code == ?ICMP_PORT_UNREACH ->
    lager:debug("ICMP indication for ~s: ~p", [inet:ntoa(IP), Code]),
    ok;

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

%%%===================================================================
%%% Sx Message functions
%%%===================================================================

handle_message(ArrivalTS, IP, Port, Data, State0) ->
    lager:debug("handle message ~s:~w: ~p", [inet:ntoa(IP), Port, Data]),
    try
	Msg = pfcp_packet:decode(Data),
	State = handle_message_1(ArrivalTS, IP, Port, Msg, State0),
	{noreply, State}
    catch
	Class:Error ->
	    lager:debug("UDP invalid msg: ~p:~p", [Class, Error]),
	    {noreply, State0}
    end.

handle_message_1(ArrivalTS, IP, Port, #pfcp{type = MsgType} = Msg, State) ->
    ?log_pfcp(debug, "handle message ~s:~w: ", [inet:ntoa(IP), Port], Msg),
    case pfcp_msg_type(MsgType) of
	response ->
	    handle_response(ArrivalTS, IP, Port, Msg, State);
	request ->
	    %%TODO:
	    %% ReqKey = make_request(ArrivalTS, IP, Port, Msg, State),
	    %% handle_request(ReqKey, Msg, State);
	    State;
	_ ->
	    State
    end.

handle_response(ArrivalTS, IP, _Port, #pfcp{seq_no = SeqNo} = Msg, State0) ->
    {Req, State} = take_request(SeqNo, State0),
    case Req of
	none -> %% duplicate, drop silently
	    ?log_pfcp(debug, "~p: duplicate response: ~p: ", [self(), SeqNo], Msg),
	    State;

	#send_req{} = SendReq ->
	    ?log_pfcp(info, "~p: found response: ~p: ", [self(), SeqNo], Msg),
	    send_request_reply(SendReq, Msg),
	    State
    end.

%%%===================================================================
%%% older version compat stuff
%%%===================================================================

-ifdef(HAS_TAKE_ANY).
-define('gb_trees:take_any', gb_trees:take_any).
-else.
-define('gb_trees:take_any', gb_trees_take_any).
gb_trees_take_any(Key, Tree) ->
    case gb_trees:lookup(Key, Tree) of
	none ->
	    error;
	{value, Value} ->
	    {Value, gb_trees:delete(Key, Tree)}
    end.
-endif.

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
    lager:info("PrepSend: ~p", [lager:pr(SendReq, ?MODULE)]),
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
    {Msg#pfcp{seq_no = SeqNo}, State#state{seq_no = SeqNo + 1}}.

start_request(#send_req{t1 = Timeout, msg = Msg} = SendReq, State) ->
    #pfcp{seq_no = SeqNo} = Msg,
    TRef = erlang:start_timer(Timeout, self(), {request, SeqNo}),
    State#state{pending = gb_trees:insert(SeqNo, {SendReq, TRef}, State#state.pending)}.

take_request(SeqNo, #state{pending = PendingIn} = State) ->
    case ?'gb_trees:take_any'(SeqNo, PendingIn) of
	error ->
	    {none, State};

	{{Req, TRef}, PendingOut} ->
	    cancel_timer(TRef),
	    {Req, State#state{pending = PendingOut}}
    end.

sendto({_,_,_,_} = RemoteIP, Port, Data, #state{socket = Socket}) ->
    gen_socket:sendto(Socket, {inet4, RemoteIP, Port}, Data);
sendto({_,_,_,_,_,_,_,_} = RemoteIP, Port, Data, #state{socket = Socket}) ->
    gen_socket:sendto(Socket, {inet6, RemoteIP, Port}, Data).

send_request(#send_req{address = DstIP, data = Data} = SendReq, State0) ->
    sendto(DstIP, 8805, Data, State0),
    start_request(SendReq, State0).

send_request_reply(#send_req{cb_info = {M, F, A}} = SendReq, Reply) ->
    lager:info("send_request_reply: ~p", [lager:pr(SendReq, ?MODULE)]),
    apply(M, F, A ++ [Reply]);
send_request_reply(#send_req{from = {_, _} = From} = SendReq, Reply) ->
    lager:info("send_request_reply: ~p", [lager:pr(SendReq, ?MODULE)]),
    gen_server:reply(From, Reply).
