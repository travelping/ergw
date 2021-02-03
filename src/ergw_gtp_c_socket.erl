%% Copyright 2015,2018 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gtp_c_socket).

-behavior(gen_server).
-behavior(ergw_gtp_socket).

-compile({parse_transform, cut}).

%% API
-export([start_link/1,
	 info/1, send/5, send_response/3,
	 send_request/7, send_request/8, resend_request/2]).
-export([get_seq_no/2, get_uniq_id/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-ifdef(TEST).
-export([get_request_q/1, get_response_q/1, send_reply/2, make_send_req/8]).

-define(MAKE_SEND_REQ, ?MODULE:make_send_req).
-else.
-define(MAKE_SEND_REQ, make_send_req).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-type v1_sequence_number() :: 0 .. 16#ffff.
-type v2_sequence_number() :: 0 .. 16#7fffff.
-type sequence_id() :: {v1, v1_sequence_number()} |
		       {v2, v2_sequence_number()}.

-export_type([sequence_id/0]).

-record(state, {
	  gtp_socket :: #socket{},
	  info       :: #gtp_socket_info{},

	  recv_socket    :: socket:socket(),
	  send_socket    :: socket:socket(),
	  burst_size = 1 :: non_neg_integer(),

	  v1_seq_no = 0 :: v1_sequence_number(),
	  v2_seq_no = 0 :: v2_sequence_number(),
	  pending    :: gb_trees:tree(sequence_id(), term()),
	  requests,
	  responses,

	  unique_id
	 }).

-record(send_req, {
	  req_id  :: term(),
	  src     :: gtp | any,
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

%%====================================================================
%% API
%%====================================================================

start_link(SocketOpts) ->
    Opts = [{hibernate_after, 5000},
	    {spawn_opt,[{fullsweep_after, 16}]}],
    gen_server:start_link(?MODULE, SocketOpts, Opts).

info(Socket) ->
    call(Socket, info).

send(Socket, Src, IP, Port, Data) ->
    cast(Socket, {send, Src, IP, Port, Data}).

send_response(#request{socket = Socket} = ReqKey, Msg, DoCache) ->
    message_counter(tx, ReqKey, Msg),
    Data = gtp_packet:encode(Msg),
    cast(Socket, {send_response, ReqKey, Data, DoCache}).

%% send_request/8
send_request(Socket, Src, DstIP, DstPort, T3, N3, Msg, CbInfo) ->
    ?LOG(debug, "~p: gtp_socket send_request to ~s(~p):~w: ~p",
	 [self(), inet:ntoa(DstIP), DstIP, DstPort, Msg]),
    cast(Socket, ?MAKE_SEND_REQ(undefined, Src, DstIP, DstPort, T3, N3, Msg, CbInfo)).

%% send_request/7
send_request(Socket, Src, DstIP, DstPort, ReqId, Msg, CbInfo) ->
    ?LOG(debug, "~p: gtp_socket send_request ~p to ~s:~w: ~p",
		[self(), ReqId, inet:ntoa(DstIP), DstPort, Msg]),
    cast(Socket, ?MAKE_SEND_REQ(ReqId, Src, DstIP, DstPort, ?T3 * 2, 0, Msg, CbInfo)).

resend_request(Socket, ReqId) ->
    cast(Socket, {resend_request, ReqId}).

get_seq_no(Socket, ReqId) ->
    call(Socket, {get_seq_no, ReqId}).

get_uniq_id(Socket) ->
    call(Socket, get_uniq_id).

-ifdef(TEST).
get_request_q(Socket) ->
    call(Socket, get_request_q).

get_response_q(Socket) ->
    call(Socket, get_response_q).
-endif.

%%%===================================================================
%%% call/cast wrapper for #socket
%%%===================================================================

cast(#socket{pid = Handler}, Request) ->
    gen_server:cast(Handler, Request).

call(#socket{pid = Handler}, Request) ->
    gen_server:call(Handler, Request).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(#{name := Name, ip := IP, burst_size := BurstSize,
       send_port := SendPort} = SocketOpts) ->
    process_flag(trap_exit, true),

    {ok, RecvSocket} = ergw_gtp_socket:make_gtp_socket(IP, ?GTP1c_PORT, SocketOpts),
    SendSocket =
	case SendPort of
	    _ when is_integer(SendPort) ->
		{ok, SndSocket} = ergw_gtp_socket:make_gtp_socket(IP, SendPort, SocketOpts),
		self() ! {'$socket', SndSocket, select, undefined},
		SndSocket;
	    false ->
		RecvSocket
	end,

    VRF = case SocketOpts of
	      #{vrf := VRF0} when is_binary(VRF0) ->
		  VRF0;
	      _ -> vrf:normalize_name(Name)
	  end,

    GtpSocket =
	#socket{
	   name = Name,
	   type = maps:get(type, SocketOpts, 'gtp-c'),
	   pid = self()
	  },
    ergw_socket_reg:register('gtp-c', Name, GtpSocket),

    State = #state{
	       gtp_socket = GtpSocket,
	       info = #gtp_socket_info{vrf = VRF, ip = IP},

	       recv_socket = RecvSocket,
	       send_socket = SendSocket,
	       burst_size = BurstSize,

	       v1_seq_no = 0,
	       v2_seq_no = 0,
	       pending = gb_trees:empty(),
	       requests = ergw_cache:new(?T3 * 4, requests),
	       responses = ergw_cache:new(?CACHE_TIMEOUT, responses),

	       unique_id = rand:uniform(16#ffffffff)
	      },
    self() ! {'$socket', RecvSocket, select, undefined},
    {ok, State}.

handle_call(info, _From, #state{info = Info} = State) ->
    {reply, Info, State};

handle_call(get_uniq_id, _From, #state{unique_id = Id} = State) ->
    {reply, Id, State#state{unique_id = galois_lfsr_32(Id)}};

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
    ?LOG(error, "handle_call: unknown ~p", [Request]),
    {reply, ok, State}.

handle_cast({send, Src, IP, Port, Data}, State)
  when is_binary(Data) ->
    sendto(Src, IP, Port, Data, State),
    {noreply, State};

handle_cast({send_response, ReqKey, Data, DoCache}, State0)
  when is_binary(Data) ->
    State = do_send_response(ReqKey, Data, DoCache, State0),
    {noreply, State};

handle_cast(#send_req{} = SendReq0, #state{gtp_socket = Socket} = State0) ->
    {SendReq, State1} = prepare_send_req(SendReq0, State0),
    message_counter(tx, Socket, SendReq),
    State = send_request(SendReq, State1),
    {noreply, State};

handle_cast({resend_request, ReqId}, #state{gtp_socket = Socket} = State0) ->
    ?LOG(debug, "~p: gtp_socket resend_request ~p", [self(), ReqId]),

    case request_q_peek(ReqId, State0) of
	{value, SendReq} ->
	    message_counter(tx, Socket, SendReq, retransmit),
	    State = send_request(SendReq, State0),
	    {noreply, State};

	_ ->
	    {noreply, State0}
    end;

handle_cast(Msg, State) ->
    ?LOG(error, "handle_cast: unknown ~p", [Msg]),
    {noreply, State}.

handle_info(Info = {timeout, _TRef, {request, SeqId}}, #state{gtp_socket = Socket} = State0) ->
    ?LOG(debug, "handle_info: ~p", [Info]),
    {Req, State1} = take_request(SeqId, State0),
    case Req of
	#send_req{n3 = 0} = SendReq ->
	    send_request_reply(SendReq, timeout),
	    message_counter(tx, Socket, SendReq, timeout),
	    {noreply, State1};

	#send_req{n3 = N3} = SendReq ->
	    %% resend....
	    message_counter(tx, Socket, SendReq, retransmit),
	    State = send_request(SendReq#send_req{n3 = N3 - 1}, State1),
	    {noreply, State};

	none ->
	    {noreply, State1}
    end;

handle_info({timeout, TRef, requests}, #state{requests = Requests} = State) ->
    {noreply, State#state{requests = ergw_cache:expire(TRef, Requests)}};

handle_info({timeout, TRef, responses}, #state{responses = Responses} = State) ->
    {noreply, State#state{responses = ergw_cache:expire(TRef, Responses)}};

handle_info({'$socket', Socket, select, Info}, #state{recv_socket = Socket} = State) ->
    handle_input(Socket, gtp, Info, State);

handle_info({'$socket', Socket, abort, Info}, #state{recv_socket = Socket} = State) ->
    handle_input(Socket, gtp, Info, State);

handle_info({'$socket', Socket, select, Info}, #state{send_socket = Socket} = State) ->
    handle_input(Socket, any, Info, State);

handle_info({'$socket', Socket, abort, Info}, #state{send_socket = Socket} = State) ->
    handle_input(Socket, any, Info, State);

handle_info(Info, State) ->
    ?LOG(error, "~s:handle_info: unknown ~p, ~p",
		[?MODULE, Info, State]),
    {noreply, State}.

terminate(_Reason, #state{recv_socket = RecvSocket, send_socket = SendSocket} = _State) ->
    socket:close(RecvSocket),
    case SendSocket of
	RecvSocket -> ok;
	_ -> socket:close(SendSocket)
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

galois_lfsr_32(V) ->
    %% 32-bit maximal-period Galois LFSR
    (V bsr 1) bxor (-(V band 1) band 16#80200003).

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
    {Msg#gtp{seq_no = SeqNo}, State#state{v1_seq_no = (SeqNo + 1) band 16#ffff}};
new_sequence_number(#gtp{version = v2, type = Type} = Msg,
		    #state{v2_seq_no = SeqNo} = State0) ->
    State = State0#state{v2_seq_no = (SeqNo + 1) band 16#7fffff},
    if Type =:= modify_bearer_command;
       Type =:= delete_bearer_command;
       Type =:= bearer_resource_command ->
	    {Msg#gtp{seq_no = SeqNo bor 16#800000}, State};
       true ->
	    {Msg#gtp{seq_no = SeqNo}, State}
    end.

family({_,_,_,_}) -> inet;
family({_,_,_,_,_,_,_,_}) -> inet6.

make_send_req(ReqId, Src, Address, Port, T3, N3, Msg, CbInfo) ->
    #send_req{
       req_id = ReqId,
       src = Src,
       address = Address,
       port = Port,
       t3 = T3,
       n3 = N3,
       msg = gtp_packet:encode_ies(Msg),
       cb_info = CbInfo,
       send_ts = erlang:monotonic_time()
      }.

make_request(ArrivalTS, Src, IP, Port, Msg, #state{gtp_socket = Socket, info = Info}) ->
    ergw_gtp_socket:make_request(ArrivalTS, Src, IP, Port, Msg, Socket, Info).

handle_input(Socket, Src, Info, #state{burst_size = BurstSize} = State) ->
    handle_input(Socket, Src, Info, 0, BurstSize, State).

handle_input(Socket, _Src, _Info, Cnt, Max, State0)
  when Cnt >= Max ->
    %% break the loop and restart
    self() ! {'$socket', Socket, select, undefined},
    {noreply, State0};

handle_input(Socket, Src, Info, Cnt, Max, State0) ->
    case socket:recvfrom(Socket, 0, [], nowait) of
	{error, _} ->
	    State = handle_err_input(Socket, State0),
	    handle_input(Socket, Src, Info, Cnt + 1, Max, State);

	{ok, {#{addr := IP, port := Port}, Data}} ->
	    ArrivalTS = erlang:monotonic_time(),
	    State = handle_message(ArrivalTS, Src, IP, Port, Data, State0),
	    handle_input(Socket, Src, Info, Cnt + 1, Max, State);

	{select, _SelectInfo} when Cnt == 0 ->
	    %% there must be something in the error queue
	    State = handle_err_input(Socket, State0),
	    handle_input(Socket, Src, Info, Cnt + 1, Max, State);

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

handle_socket_error(#{level := ip, type := ?IP_RECVERR,
		      data := <<_ErrNo:32/native-integer,
				Origin:8, Type:8, Code:8, _Pad:8,
				_Info:32/native-integer, _Data:32/native-integer,
				_/binary>>},
		    IP, _Port, #state{gtp_socket = Socket})
  when Origin == ?SO_EE_ORIGIN_ICMP, Type == ?ICMP_DEST_UNREACH,
       (Code == ?ICMP_HOST_UNREACH orelse Code == ?ICMP_PORT_UNREACH) ->
    gtp_path:icmp_error(Socket, IP);

handle_socket_error(#{level := ip, type := recverr,
		      data := #{origin := icmp, type := dest_unreach, code := Code}},
		    IP, _Port, #state{gtp_socket = Socket})
  when Code == host_unreach;
       Code == port_unreach ->
    gtp_path:icmp_error(Socket, IP);

handle_socket_error(#{level := ipv6, type := ?IPV6_RECVERR,
		      data := <<_ErrNo:32/native-integer,
				Origin:8, Type:8, Code:8, _Pad:8,
				_Info:32/native-integer, _Data:32/native-integer,
				_/binary>>},
		    IP, _Port, #state{gtp_socket = Socket})
  when Origin == ?SO_EE_ORIGIN_ICMP6, Type == ?ICMP6_DST_UNREACH,
       (Code == ?ICMP6_DST_UNREACH_ADDR orelse Code == ?ICMP6_DST_UNREACH_NOPORT) ->
    gtp_path:icmp_error(Socket, IP);

handle_socket_error(#{level := ipv6, type := recverr,
		      data := #{origin := icmp6, type := dst_unreach, code := Code}},
		    IP, _Port, #state{gtp_socket = Socket})
  when Code == addr_unreach;
       Code == port_unreach ->
    gtp_path:icmp_error(Socket, IP);

handle_socket_error(Error, IP, _Port, _State) ->
    ?LOG(debug, "got unhandled error info for ~s: ~p", [inet:ntoa(IP), Error]),
    ok.

handle_err_input(Socket, State) ->
    case socket:recvmsg(Socket, [errqueue], 0) of
	{ok, #{addr := #{addr := IP, port := Port}, ctrl := Ctrl}} ->
	    lists:foreach(handle_socket_error(_, IP, Port, State), Ctrl),
	    ok;

	{error, timeout} ->
	    ok;
	{error, ewouldblock} ->
	    ok;

	Other ->
	    ?LOG(error, "got unhandled error input: ~p", [Other])
    end,
    State.

handle_message(ArrivalTS, Src, IP, Port, Data, #state{gtp_socket = Socket} = State0) ->
    try gtp_packet:decode(Data, #{ies => binary}) of
	Msg = #gtp{} ->
	    %% TODO: handle decode failures

	    ?LOG(debug, "handle message: ~p", [{Src, IP, Port,
						State0#state.gtp_socket,
						Msg}]),
	    ergw_prometheus:gtp(rx, Socket, IP, Msg),
	    handle_message_1(ArrivalTS, Src, IP, Port, Msg, State0)
    catch
	Class:Error ->
	    ergw_prometheus:gtp_error(rx, Socket, 'malformed-requests'),
	    ?LOG(error, "GTP decoding failed with ~p:~p for ~p", [Class, Error, Data]),
	    State0
    end.

handle_message_1(_, _, _, _, #gtp{version = Version}, #state{gtp_socket = Socket} = State)
  when Version /= v1 andalso Version /= v2 ->
    ergw_prometheus:gtp_error(rx, Socket, 'version-not-supported'),
    State;

handle_message_1(ArrivalTS, Src, IP, Port, #gtp{type = echo_request} = Msg, State) ->
    ReqKey = make_request(ArrivalTS, Src, IP, Port, Msg, State),
    gtp_path:handle_request(ReqKey, Msg),
    State;

handle_message_1(ArrivalTS, Src, IP, Port, #gtp{version = Version, type = MsgType} = Msg, State) ->
    Handler =
	case Version of
	    v1 -> gtp_v1_c;
	    v2 -> gtp_v2_c
	end,
    case Handler:gtp_msg_type(MsgType) of
	response ->
	    handle_response(ArrivalTS, Src, IP, Port, Msg, State);
	request ->
	    ReqKey = make_request(ArrivalTS, Src, IP, Port, Msg, State),
	    handle_request(ReqKey, Msg, State);
	_ ->
	    State
    end.

handle_response(ArrivalTS, _Src, IP, _Port, Msg, #state{gtp_socket = Socket} = State0) ->
    SeqId = ergw_gtp_socket:make_seq_id(Msg),
    {Req, State} = take_request(SeqId, State0),
    case Req of
	none -> %% duplicate, drop silently
	    ergw_prometheus:gtp(rx, Socket, IP, Msg, duplicate),
	    ?LOG(debug, "~p: duplicate response: ~p, ~p", [self(), SeqId, gtp_c_lib:fmt_gtp(Msg)]),
	    State;

	#send_req{} = SendReq ->
	    ?LOG(debug, "~p: found response: ~p", [self(), SeqId]),
	    measure_reply(Socket, SendReq, ArrivalTS),
	    send_request_reply(SendReq, Msg),
	    State
    end.

handle_request(#request{src = Src, ip = IP, port = Port} = ReqKey, Msg,
	       #state{gtp_socket = Socket, responses = Responses} = State) ->
    case ergw_cache:get(cache_key(ReqKey), Responses) of
	{value, Data} ->
	    ergw_prometheus:gtp(rx, Socket, IP, Msg, duplicate),
	    sendto(Src, IP, Port, Data, State);

	_Other ->
	    ?LOG(debug, "HandleRequest: ~p", [_Other]),
	    ergw_context:port_message(ReqKey, Msg)
    end,
    State.

start_request(#send_req{t3 = Timeout, msg = Msg} = SendReq, State0) ->
    SeqId = ergw_gtp_socket:make_seq_id(Msg),

    %% cancel pending timeout, this can only happend when a
    %% retransmit was triggerd by the control process and not
    %% by the socket process itself
    {_, State} = take_request(SeqId, State0),

    TRef = erlang:start_timer(Timeout, self(), {request, SeqId}),
    State#state{pending = gb_trees:insert(SeqId, {SendReq, TRef}, State#state.pending)}.

take_request(SeqId, #state{pending = PendingIn} = State) ->
    case gb_trees:take_any(SeqId, PendingIn) of
	error ->
	    {none, State};

	{{Req, TRef}, PendingOut} ->
	    cancel_timer(TRef),
	    {Req, State#state{pending = PendingOut}}
    end.

socket(gtp, #state{recv_socket = Socket}) ->
    Socket;
socket(any, #state{send_socket = Socket}) ->
    Socket.

sendto(Src, RemoteIP, Port, Data, State) ->
    Dest = #{family => family(RemoteIP),
	     addr => RemoteIP,
	     port => Port},
    Socket = socket(Src, State),
    case socket:sendto(Socket, Data, Dest, nowait) of
	ok -> ok;
	Other  ->
	    ?LOG(error, "sendto(~p) failed with: ~p", [Dest, Other]),
	    ok
    end.

send_reply({M, F, A}, Reply) ->
    apply(M, F, A ++ [Reply]).

send_request_reply(#send_req{cb_info = CbInfo}, Reply) ->
    send_reply(CbInfo, Reply).

send_request(#send_req{src = Src, address = DstIP, port = DstPort, data = Data} = SendReq, State0) ->
    sendto(Src, DstIP, DstPort, Data, State0),
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
enqueue_response(_ReqKey, _Data, _DoCache, State) ->
    State.

do_send_response(#request{src = Src, ip = IP, port = Port} = ReqKey, Data, DoCache, State) ->
    sendto(Src, IP, Port, Data, State),
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
%%% Metrics collections
%%%===================================================================

%% message_counter/3
message_counter(Direction, Socket, #send_req{address = IP, msg = Msg}) ->
    ergw_prometheus:gtp(Direction, Socket, IP, Msg);
message_counter(Direction, #request{socket = Socket, ip = IP}, Msg) ->
    ergw_prometheus:gtp(Direction, Socket, IP, Msg).

%% message_counter/4
message_counter(Direction, Socket, #send_req{address = IP, msg = Msg}, Verdict) ->
    ergw_prometheus:gtp(Direction, Socket, IP, Msg, Verdict).

%% measure the time it takes our peer to reply to a request
measure_reply(Socket, #send_req{address = IP, msg = Msg, send_ts = SendTS}, ArrivalTS) ->
    ergw_prometheus:gtp_path_rtt(Socket, IP, Msg, ArrivalTS - SendTS).

%% measure the time it takes us to generate a response to a request
measure_response(#request{
		    socket = Socket,
		    version = Version, type = MsgType,
		    arrival_ts = ArrivalTS}) ->
    Duration = erlang:monotonic_time() - ArrivalTS,
    ergw_prometheus:gtp_request_duration(Socket, Version, MsgType, Duration).
