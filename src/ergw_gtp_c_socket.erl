%% Copyright 2015,2018 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gtp_c_socket).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_link/1,
	 send/4, send_response/3,
	 send_request/6, send_request/7, resend_request/2,
	 get_restart_counter/1]).
-export([get_request_q/1, get_response_q/1, get_seq_no/2, get_uniq_id/1]).

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

	  unique_id,
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

start_link({Name, SocketOpts}) ->
    Opts = [{hibernate_after, 5000},
	    {spawn_opt,[{fullsweep_after, 16}]}],
    gen_server:start_link(?MODULE, [Name, SocketOpts], Opts).

send(#gtp_port{type = 'gtp-c'} = GtpPort, IP, Port, Data) ->
    cast(GtpPort, {send, IP, Port, Data}).

send_response(#request{gtp_port = GtpPort, ip = RemoteIP} = ReqKey, Msg, DoCache) ->
    message_counter(tx, GtpPort, RemoteIP, Msg),
    Data = gtp_packet:encode(Msg),
    cast(GtpPort, {send_response, ReqKey, Data, DoCache}).

%% send_request/7
send_request(#gtp_port{type = 'gtp-c'} = GtpPort, DstIP, DstPort, T3, N3,
	     Msg = #gtp{version = Version}, CbInfo) ->
    lager:debug("~p: gtp_socket send_request to ~s(~p):~w: ~p",
		[self(), inet:ntoa(DstIP), DstIP, DstPort, Msg]),

    cast(GtpPort, make_send_req(undefined, DstIP, DstPort, T3, N3, Msg, CbInfo)),
    gtp_path:maybe_new_path(GtpPort, Version, DstIP).

%% send_request/6
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

get_uniq_id(GtpPort) ->
    call(GtpPort, get_uniq_id).

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

    {ok, S} = ergw_gtp_socket:make_gtp_socket(IP, ?GTP1c_PORT, SocketOpts),
    {ok, RCnt} = gtp_config:get_restart_counter(),
    VRF = case SocketOpts of
	      #{vrf := VRF0} when is_binary(VRF0) ->
		  VRF0;
	      _ -> vrf:normalize_name(Name)
	  end,

    GtpPort = #gtp_port{
		 name = Name,
		 vrf = VRF,
		 type = maps:get(type, SocketOpts, 'gtp-c'),
		 pid = self(),
		 ip = IP,
		 restart_counter = RCnt
		},

    init_exometer(GtpPort),
    ergw_gtp_socket_reg:register(Name, GtpPort),

    State = #state{
	       gtp_port = GtpPort,
	       ip = IP,
	       socket = S,

	       v1_seq_no = 0,
	       v2_seq_no = 0,
	       pending = gb_trees:empty(),
	       requests = ergw_cache:new(?T3 * 4, requests),
	       responses = ergw_cache:new(?CACHE_TIMEOUT, responses),

	       unique_id = rand:uniform(16#ffffffff),
	       restart_counter = RCnt},
    {ok, State}.

handle_call(get_restart_counter, _From, #state{restart_counter = RCnt} = State) ->
    {reply, RCnt, State};

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

handle_info({timeout, TRef, requests}, #state{requests = Requests} = State) ->
    {noreply, State#state{requests = ergw_cache:expire(TRef, Requests)}};

handle_info({timeout, TRef, responses}, #state{responses = Responses} = State) ->
    {noreply, State#state{responses = ergw_cache:expire(TRef, Responses)}};

handle_info({Socket, input_ready}, #state{socket = Socket} = State) ->
    handle_input(Socket, State);

handle_info(Info, State) ->
    lager:error("~s:handle_info: unknown ~p, ~p",
		[?MODULE, lager:pr(Info, ?MODULE), lager:pr(State, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, #state{socket = Socket} = _State) ->
    gen_socket:close(Socket),
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

make_request(ArrivalTS, IP, Port, Msg, #state{gtp_port = GtpPort}) ->
    ergw_gtp_socket:make_request(ArrivalTS, IP, Port, Msg, GtpPort).

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
	    message_counter(rx, GtpPort, 'malformed-requests'),
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
    SeqId = ergw_gtp_socket:make_seq_id(Msg),
    {Req, State} = take_request(SeqId, State0),
    case Req of
	none -> %% duplicate, drop silently
	    message_counter(rx, GtpPort, IP, Msg, duplicate),
	    lager:debug("~p: duplicate response: ~p, ~p", [self(), SeqId, gtp_c_lib:fmt_gtp(Msg)]),
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
enqueue_response(_ReqKey, _Data, _DoCache, State) ->
    State.

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
    [exometer_new([socket, 'gtp-c', Name | X], counter) ||
	X <- [[rx, v1, unsupported],
	      [tx, v1, unsupported],
	      [rx, v2, unsupported],
	      [tx, v2, unsupported],
	      [rx, 'malformed-requests']]],
    lists:foreach(exo_reg_msg(Name, v1, _), gtp_v1_c:gtp_msg_types()),
    lists:foreach(exo_reg_msg(Name, v2, _), gtp_v2_c:gtp_msg_types()),
    foreach_request(gtp_v1_c, exo_reg_timeout(Name, v1, _)),
    foreach_request(gtp_v2_c, exo_reg_timeout(Name, v2, _)),
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

%% message_counter/3
message_counter(Direction, GtpPort,
		#send_req{address = RemoteIP, msg = Msg}) ->
    message_counter(Direction, GtpPort, RemoteIP, Msg);
message_counter(Direction, #gtp_port{name = Name, type = 'gtp-c'}, Verdict)
  when is_atom(Verdict) ->
    exometer:update_or_create([socket, 'gtp-c', Name, Direction, Verdict], 1, counter, []).

%% message_counter/4
message_counter(Direction, GtpPort,
		#send_req{address = RemoteIP, msg = Msg}, Verdict) ->
    message_counter(Direction, GtpPort, RemoteIP, Msg, Verdict);
message_counter(Direction, #gtp_port{name = Name, type = 'gtp-c'},
               RemoteIP, #gtp{version = Version, type = MsgType, ie = IEs}) ->
    message_counter_apply(Name, RemoteIP, Direction, Version, [MsgType, count]),
    message_counter_reply(Name, RemoteIP, Direction, Version, MsgType, IEs).

%% message_counter/5
message_counter(Direction, #gtp_port{name = Name, type = 'gtp-c'},
		RemoteIP, #gtp{version = Version, type = MsgType},
		Verdict) ->
    message_counter_apply(Name, RemoteIP, Direction, Version, [MsgType, Verdict]).

message_counter_reply(Name, _RemoteIP, Direction, Version, MsgType,
                     #{cause := #cause{value = Cause}}) ->
    message_counter_reply_update( Name, Direction, Version, MsgType, Cause );
message_counter_reply(Name, _RemoteIP, Direction, Version, MsgType,
                     #{v2_cause := #v2_cause{v2_cause = Cause}}) ->
    message_counter_reply_update( Name, Direction, Version, MsgType, Cause );
message_counter_reply(Name, _RemoteIP, Direction, Version, MsgType, IEs)
  when is_list(IEs) ->
    CauseIEs =
       lists:filter(
         fun(IE) when is_record(IE, cause) -> true;
            (IE) when is_record(IE, v2_cause) -> true;
            (_) -> false
         end, IEs),
    case CauseIEs of
       [#cause{value = Cause} | _] ->
           message_counter_reply_update( Name, Direction, Version, MsgType, Cause );
       [#v2_cause{v2_cause = Cause} | _] ->
           message_counter_reply_update( Name, Direction, Version, MsgType, Cause );
       _ ->
           ok
    end;
message_counter_reply(_Name, _RemoteIP, _Direction, _Version, _MsgType, _IEs) ->
    ok.

message_counter_reply_update( Name, Direction, Version, MsgType, Cause ) ->
    exometer:update_or_create( [socket, 'gtp-c', Name, Direction, Version, MsgType, Cause, count], 1, counter, [] ).


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
