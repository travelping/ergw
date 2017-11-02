%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_socket).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([validate_options/1,
	 start_socket/2, start_link/1,
	 send/4, send_response/3,
	 send_request/6, send_request/7, resend_request/2,
	 get_restart_counter/1]).
-export([get_request_q/1, get_response_q/1, get_seq_no/2]).

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
	  requests,
	  responses,

	  restart_counter}).

-record(send_req, {
	  req_id  :: term(),
	  address :: inet:ip_address(),
	  port    :: inet:port_number(),
	  t3      :: non_neg_integer(),
	  n3      :: non_neg_integer(),
	  data    :: binary(),
	  msg     :: #gtp{},
	  cb_info :: {M :: atom(), F :: atom(), A :: [term()]},
	  send_ts :: non_neg_integer()
	 }).

-define(T3, 10 * 1000).
-define(N3, 5).
-define(RESPONSE_TIMEOUT, (?T3 * ?N3 + (?T3 div 2))).
-define(CACHE_TIMEOUT, ?RESPONSE_TIMEOUT).

-define(EXO_PERF_OPTS, [{time_span, 300 * 1000}]).		%% 5 min histogram

%%====================================================================
%% API
%%====================================================================

start_socket(Name, Opts)
  when is_atom(Name) ->
    gtp_socket_sup:new({Name, Opts}).

start_link('gtp-c', {Name, SocketOpts}) ->
    gen_server:start_link(?MODULE, [Name, SocketOpts], []);
start_link('gtp-u', Socket) ->
    gtp_dp:start_link(Socket).

start_link(Socket = {_Name, #{type := Type}}) ->
    start_link(Type, Socket);
start_link(Socket = {_Name, SocketOpts})
  when is_list(SocketOpts) ->
    Type = proplists:get_value(type, SocketOpts, 'gtp-c'),
    start_link(Type, Socket).

send(#gtp_port{type = 'gtp-c'} = GtpPort, IP, Port, Data) ->
    cast(GtpPort, {send, IP, Port, Data});
send(#gtp_port{type = 'gtp-u'} = GtpPort, IP, Port, Data) ->
    gtp_dp:send(GtpPort, IP, Port, Data).

send_response(#request{gtp_port = GtpPort, ip = RemoteIP} = ReqKey, Msg, DoCache) ->
    message_counter(tx, GtpPort, RemoteIP, Msg),
    Data = gtp_packet:encode(Msg),
    cast(GtpPort, {send_response, ReqKey, Data, DoCache}).

send_request(#gtp_port{type = 'gtp-c'} = GtpPort, DstIP, DstPort, T3, N3,
	     Msg = #gtp{version = Version}, CbInfo) ->
    lager:debug("~p: gtp_socket send_request to ~s:~w: ~p",
		[self(), inet:ntoa(DstIP), DstPort, Msg]),

    cast(GtpPort, make_send_req(undefined, DstIP, DstPort, T3, N3, Msg, CbInfo)),
    gtp_path:maybe_new_path(GtpPort, Version, DstIP).

send_request(#gtp_port{type = 'gtp-c'} = GtpPort, DstIP, DstPort, ReqId,
	     Msg = #gtp{version = Version}, CbInfo) ->
    lager:debug("~p: gtp_socket send_request ~p to ~s:~w: ~p",
		[self(), ReqId, inet:ntoa(DstIP), DstPort, Msg]),

    cast(GtpPort, make_send_req(ReqId, DstIP, DstPort, ?T3 * 2, 0, Msg, CbInfo)),
    gtp_path:maybe_new_path(GtpPort, Version, DstIP).

resend_request(#gtp_port{type = 'gtp-c'} = GtpPort, ReqId) ->
    cast(GtpPort, {resend_request, ReqId}).

get_restart_counter(GtpPort) ->
    call(GtpPort, get_restart_counter).

get_request_q(GtpPort) ->
    call(GtpPort, get_request_q).

get_response_q(GtpPort) ->
    call(GtpPort, get_response_q).

get_seq_no(GtpPort, ReqId) ->
    call(GtpPort, {get_seq_no, ReqId}).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(SocketDefaults, [{ip, invalid}]).

validate_options(Values0) ->
    Values = if is_list(Values0) ->
		     proplists:unfold(Values0);
		true ->
		     Values0
	     end,
    ergw_config:validate_options(fun validate_option/2, Values, ?SocketDefaults, map).

validate_option(name, Value) when is_atom(Value) ->
    Value;
validate_option(type, 'gtp-c') ->
    'gtp-c';
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
%%% call/cast wrapper for gtp_port
%%%===================================================================

cast(#gtp_port{pid = Handler}, Request) ->
    gen_server:cast(Handler, Request).

call(#gtp_port{pid = Handler}, Request) ->
    gen_server:call(Handler, Request).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, #{ip := IP} = SocketOpts]) ->
    process_flag(trap_exit, true),

    {ok, S} = make_gtp_socket(IP, ?GTP1c_PORT, SocketOpts),
    {ok, RCnt} = gtp_config:get_restart_counter(),

    GtpPort = #gtp_port{
		 name = Name,
		 type = maps:get(type, SocketOpts, 'gtp-c'),
		 pid = self(),
		 ip = IP,
		 restart_counter = RCnt
		},

    init_exometer(GtpPort),
    gtp_socket_reg:register(Name, GtpPort),

    State = #state{
	       gtp_port = GtpPort,
	       ip = IP,
	       socket = S,

	       v1_seq_no = 0,
	       v2_seq_no = 0,
	       pending = gb_trees:empty(),
	       requests = ergw_cache:new(?T3 * 4, requests),
	       responses = ergw_cache:new(?CACHE_TIMEOUT, responses),

	       restart_counter = RCnt},
    {ok, State}.

handle_call(get_restart_counter, _From, #state{restart_counter = RCnt} = State) ->
    {reply, RCnt, State};

handle_call(get_request_q, _From, #state{requests = Requests} = State) ->
    {reply, ergw_cache:to_list(Requests), State};
handle_call(get_response_q, _From, #state{responses = Responses} = State) ->
    {reply, ergw_cache:to_list(Responses), State};

handle_call({get_seq_no, ReqId}, _From, State) ->
    case request_q_peek(ReqId, State) of
	{value, #send_req{msg = #gtp{seq_no = SeqNo}}} ->
	    {reply, {ok, SeqNo}, State};

	_ ->
	    {reply, {error, not_found}, State}
    end;

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

handle_cast(#send_req{} = SendReq0, #state{gtp_port = GtpPort} = State0) ->
    {SendReq, State1} = prepare_send_req(SendReq0, State0),
    message_counter(tx, GtpPort, SendReq),
    State = send_request(SendReq, State1),
    {noreply, State};

handle_cast({resend_request, ReqId},
	    #state{gtp_port = GtpPort} = State0) ->
    lager:debug("~p: gtp_socket resend_request ~p", [self(), ReqId]),

    case request_q_peek(ReqId, State0) of
	{value, SendReq} ->
	    message_counter(tx, GtpPort, SendReq, retransmit),
	    State = send_request(SendReq, State0),
	    {noreply, State};

	_ ->
	    {noreply, State0}
    end;

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(Info = {timeout, _TRef, {request, SeqId}}, #state{gtp_port = GtpPort} = State0) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    {Req, State1} = take_request(SeqId, State0),
    case Req of
	#send_req{n3 = 0} = SendReq ->
	    send_request_reply(SendReq, timeout),
	    message_counter(tx, GtpPort, SendReq, timeout),
	    {noreply, State1};

	#send_req{n3 = N3} = SendReq ->
	    %% resend....
	    message_counter(tx, GtpPort, SendReq, retransmit),
	    State = send_request(SendReq#send_req{n3 = N3 - 1}, State1),
	    {noreply, State};

	none ->
	    {noreply, State1}
    end;

handle_info({timeout, _TRef, requests}, #state{requests = Requests} = State) ->
    {noreply, State#state{requests = ergw_cache:expire(Requests)}};

handle_info({timeout, _TRef, responses}, #state{responses = Responses} = State) ->
    {noreply, State#state{responses = ergw_cache:expire(Responses)}};

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
    {Msg, State} = new_sequence_number(Msg0, State0),
    BinMsg = gtp_packet:encode(Msg),
    {SendReq#send_req{msg = Msg, data = BinMsg}, State}.

new_sequence_number(#gtp{seq_no = SeqNo} = Msg, State)
  when is_integer(SeqNo) ->
    {Msg, State};
new_sequence_number(#gtp{version = v1} = Msg, #state{v1_seq_no = SeqNo} = State) ->
    {Msg#gtp{seq_no = SeqNo}, State#state{v1_seq_no = (SeqNo + 1) rem 16#ffff}};
new_sequence_number(#gtp{version = v2} = Msg, #state{v2_seq_no = SeqNo} = State) ->
    {Msg#gtp{seq_no = SeqNo}, State#state{v2_seq_no = (SeqNo + 1) rem 16#7fffff}}.

make_seq_id(#gtp{version = Version, seq_no = SeqNo}) ->
    {Version, SeqNo}.

make_send_req(ReqId, Address, Port, T3, N3, Msg, CbInfo) ->
    #send_req{
       req_id = ReqId,
       address = Address,
       port = Port,
       t3 = T3,
       n3 = N3,
       msg = gtp_packet:encode_ies(Msg),
       cb_info = CbInfo,
       send_ts = erlang:monotonic_time()
      }.

make_request(ArrivalTS, IP, Port,
	     Msg = #gtp{version = Version, type = Type},
	     #state{gtp_port = GtpPort}) ->
    SeqId = make_seq_id(Msg),
    #request{
       key = {GtpPort, IP, Port, Type, SeqId},
       gtp_port = GtpPort,
       ip = IP,
       port = Port,
       version = Version,
       type = Type,
       arrival_ts = ArrivalTS}.

family({_,_,_,_}) -> inet;
family({_,_,_,_,_,_,_,_}) -> inet6.

make_gtp_socket(IP, Port, #{netns := NetNs} = Opts)
  when is_list(NetNs) ->
    {ok, Socket} = gen_socket:socketat(NetNs, family(IP), dgram, udp),
    bind_gtp_socket(Socket, IP, Port, Opts);
make_gtp_socket(IP, Port, Opts) ->
    {ok, Socket} = gen_socket:socket(family(IP), dgram, udp),
    bind_gtp_socket(Socket, IP, Port, Opts).

bind_gtp_socket(Socket, {_,_,_,_} = IP, Port, Opts) ->
    ok = socket_ip_freebind(Socket, Opts),
    ok = socket_netdev(Socket, Opts),
    ok = gen_socket:bind(Socket, {inet4, IP, Port}),
    ok = gen_socket:setsockopt(Socket, sol_ip, recverr, true),
    ok = gen_socket:setsockopt(Socket, sol_ip, mtu_discover, 0),
    ok = gen_socket:input_event(Socket, true),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    {ok, Socket};

bind_gtp_socket(Socket, {_,_,_,_,_,_,_,_} = IP, Port, Opts) ->
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

handle_message(ArrivalTS, IP, Port, Data, #state{gtp_port = GtpPort} = State0) ->
    try gtp_packet:decode(Data, #{ies => binary}) of
	Msg = #gtp{} ->
	    %% TODO: handle decode failures

	    lager:debug("handle message: ~p", [{IP, Port,
						lager:pr(State0#state.gtp_port, ?MODULE),
						lager:pr(Msg, ?MODULE)}]),
	    message_counter(rx, GtpPort, IP, Msg),
	    State = handle_message_1(ArrivalTS, IP, Port, Msg, State0),
	    {noreply, State}
    catch
	Class:Error ->
	    lager:error("GTP decoding failed with ~p:~p for ~p", [Class, Error, Data]),
	    {noreply, State0}
    end.

handle_message_1(ArrivalTS, IP, Port, #gtp{type = echo_request} = Msg, State) ->
    ReqKey = make_request(ArrivalTS, IP, Port, Msg, State),
    gtp_path:handle_request(ReqKey, Msg),
    State;

handle_message_1(ArrivalTS, IP, Port, #gtp{version = Version, type = MsgType} = Msg, State) ->
    Handler =
	case Version of
	    v1 -> gtp_v1_c;
	    v2 -> gtp_v2_c
	end,
    case Handler:gtp_msg_type(MsgType) of
	response ->
	    handle_response(ArrivalTS, IP, Port, Msg, State);
	request ->
	    ReqKey = make_request(ArrivalTS, IP, Port, Msg, State),
	    handle_request(ReqKey, Msg, State);
	_ ->
	    State
    end.

handle_response(ArrivalTS, IP, _Port, Msg, #state{gtp_port = GtpPort} = State0) ->
    SeqId = make_seq_id(Msg),
    {Req, State} = take_request(SeqId, State0),
    case Req of
	none -> %% duplicate, drop silently
	    message_counter(rx, GtpPort, IP, Msg, duplicate),
	    lager:debug("~p: duplicate response: ~p, ~p", [self(), SeqId, Msg]),
	    State;

	#send_req{} = SendReq ->
	    lager:info("~p: found response: ~p", [self(), SeqId]),
	    measure_reply(GtpPort, SendReq, ArrivalTS),
	    send_request_reply(SendReq, Msg),
	    State
    end.

handle_request(#request{ip = IP, port = Port} = ReqKey, Msg,
	       #state{gtp_port = GtpPort, responses = Responses} = State) ->
    case ergw_cache:get(cache_key(ReqKey), Responses) of
	{value, Data} ->
	    message_counter(rx, GtpPort, IP, Msg, duplicate),
	    sendto(IP, Port, Data, State);

	_Other ->
	    lager:debug("HandleRequest: ~p", [_Other]),
	    gtp_context:handle_message(ReqKey, Msg)
    end,
    State.

start_request(#send_req{t3 = Timeout, msg = Msg} = SendReq, State0) ->
    SeqId = make_seq_id(Msg),

    %% cancel pending timeout, this can only happend when a
    %% retransmit was triggerd by the control process and not
    %% by the socket process itself
    {_, State} = take_request(SeqId, State0),

    TRef = erlang:start_timer(Timeout, self(), {request, SeqId}),
    State#state{pending = gb_trees:insert(SeqId, {SendReq, TRef}, State#state.pending)}.

take_request(SeqId, #state{pending = PendingIn} = State) ->
    case ?'gb_trees:take_any'(SeqId, PendingIn) of
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

send_request_reply(#send_req{cb_info = {M, F, A}}, Reply) ->
    apply(M, F, A ++ [Reply]).

send_request(#send_req{address = DstIP, port = DstPort, data = Data} = SendReq, State0) ->
    sendto(DstIP, DstPort, Data, State0),
    State = start_request(SendReq, State0),
    request_q_in(SendReq, State).

request_q_in(#send_req{req_id = undefined}, State) ->
    State;
request_q_in(#send_req{req_id = ReqId} = SendReq, #state{requests = Requests} = State) ->
    State#state{requests = ergw_cache:enter(cache_key(ReqId), SendReq, ?RESPONSE_TIMEOUT, Requests)}.

request_q_peek(ReqId, #state{requests = Requests}) ->
    ergw_cache:get(cache_key(ReqId), Requests).

enqueue_response(ReqKey, Data, DoCache,
		 #state{responses = Responses} = State)
  when DoCache =:= true ->
    State#state{responses = ergw_cache:enter(cache_key(ReqKey), Data, ?RESPONSE_TIMEOUT, Responses)};
enqueue_response(_ReqKey, _Data, _DoCache,
		 #state{responses = Responses} = State) ->
    State#state{responses = ergw_cache:expire(Responses)}.

do_send_response(#request{ip = IP, port = Port} = ReqKey, Data, DoCache, State) ->
    sendto(IP, Port, Data, State),
    measure_response(ReqKey),
    enqueue_response(ReqKey, Data, DoCache, State).

%%%===================================================================
%%% cache helper
%%%===================================================================

cache_key(#request{key = Key}) ->
    Key;
cache_key(Object) ->
    Object.

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

foreach_request(Handler, Fun) ->
    Requests = lists:filter(fun(X) -> Handler:gtp_msg_type(X) =:= request end,
			    Handler:gtp_msg_types()),
    lists:foreach(Fun, Requests).

exo_reg_msg(Name, Version, MsgType) ->
    exometer_new([socket, 'gtp-c', Name, rx, Version, MsgType, count], counter),
    exometer_new([socket, 'gtp-c', Name, rx, Version, MsgType, duplicate], counter),
    exometer_new([socket, 'gtp-c', Name, tx, Version, MsgType, count], counter),
    exometer_new([socket, 'gtp-c', Name, tx, Version, MsgType, retransmit], counter).

exo_reg_timeout(Name, Version, MsgType) ->
    exometer_new([socket, 'gtp-c', Name, tx, Version, MsgType, timeout], counter).

init_exometer(#gtp_port{name = Name, type = 'gtp-c'}) ->
    exometer_new([socket, 'gtp-c', Name, rx, v1, unsupported], counter),
    exometer_new([socket, 'gtp-c', Name, tx, v1, unsupported], counter),
    lists:foreach(exo_reg_msg(Name, v1, _), gtp_v1_c:gtp_msg_types()),
    lists:foreach(exo_reg_msg(Name, v2, _), gtp_v2_c:gtp_msg_types()),
    foreach_request(gtp_v1_c, exo_reg_timeout(Name, v1, _)),
    foreach_request(gtp_v2_c, exo_reg_timeout(Name, v2, _)),
    exometer_new([socket, 'gtp-c', Name, rx, v2, unsupported], counter),
    exometer_new([socket, 'gtp-c', Name, tx, v2, unsupported], counter),
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

message_counter(Direction, GtpPort,
		#send_req{address = RemoteIP, msg = Msg}) ->
    message_counter(Direction, GtpPort, RemoteIP, Msg).

message_counter(Direction, GtpPort,
		#send_req{address = RemoteIP, msg = Msg}, Verdict) ->
    message_counter(Direction, GtpPort, RemoteIP, Msg, Verdict);
message_counter(Direction, #gtp_port{name = Name, type = 'gtp-c'},
		RemoteIP, #gtp{version = Version, type = MsgType}) ->
    message_counter_apply(Name, RemoteIP, Direction, Version, [MsgType]).

message_counter(Direction, #gtp_port{name = Name, type = 'gtp-c'},
		RemoteIP, #gtp{version = Version, type = MsgType},
		Verdict) ->
    message_counter_apply(Name, RemoteIP, Direction, Version, [MsgType, Verdict]).

%% measure the time it takes us to generate a response to a request
measure_response(#request{
		    gtp_port = #gtp_port{name = Name},
		    version = Version, type = MsgType,
		    arrival_ts = ArrivalTS}) ->
    Duration = erlang:convert_time_unit(erlang:monotonic_time() - ArrivalTS, native, microsecond),
    DataPoint = [socket, 'gtp-c', Name, pt, Version, MsgType],
    exometer:update_or_create(DataPoint, Duration, histogram, ?EXO_PERF_OPTS),
    ok.

%% measure the time it takes our peer to reply to a request
measure_reply(GtpPort, #send_req{address = RemoteIP,
				 msg = #gtp{version = Version, type = MsgType},
				 send_ts = SendTS},
	      ArrivalTS) ->
    RTT = erlang:convert_time_unit(ArrivalTS - SendTS, native, microsecond),
    gtp_path:exometer_update_rtt(GtpPort, RemoteIP, Version, MsgType, RTT).
