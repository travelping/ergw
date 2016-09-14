%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_socket).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_sockets/0, start_link/1,
	 send/4, send_response/4,
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

	  responses  :: gb_trees:tree({IP :: inet:ip_address(), SeqNo :: sequence_number()},
				      {Data :: binary(), TStamp :: integer()}),
	  rqueue     :: queue:queue({TStamp :: integer(), {IP :: inet:ip_address(),
							   SeqNo :: sequence_number()}}),

	  restart_counter}).

-define(T3, 10 * 1000).
-define(N3, 5).
-define(RESPONSE_TIMEOUT, (?T3 * ?N3 + (?T3 div 2))).

%%====================================================================
%% API
%%====================================================================

start_sockets() ->
    {ok, Sockets} = application:get_env(sockets),
    lists:foreach(fun(Socket) ->
			  gtp_socket_sup:new(Socket)
		  end, Sockets),
    ok.

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

send_response(GtpPort, IP, Port, Msg = #gtp{seq_no = SeqNo}) ->
    Data = gtp_packet:encode(Msg),
    cast(GtpPort, {send_response, IP, Port, SeqNo, Data}).

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

    gtp_socket_reg:register(Name, GtpPort),

    {ok, #state{gtp_port = GtpPort,
		ip = IP,
		socket = S,

		seq_no = 0,
		pending = gb_trees:empty(),

		responses = gb_trees:empty(),
		rqueue = queue:new(),

		restart_counter = RCnt}}.

handle_call(get_restart_counter, _From, #state{restart_counter = RCnt} = State) ->
    {reply, RCnt, State};

handle_call(Request, _From, State) ->
    lager:error("handle_call: unknown ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({send, IP, Port, Data}, #state{socket = Socket} = State)
  when is_binary(Data) ->
    gen_socket:sendto(Socket, {inet4, IP, Port}, Data),
    {noreply, State};

handle_cast({send_response, IP, Port, SeqNo, Data}, State0)
  when is_binary(Data) ->
    State = do_send_response(IP, Port, SeqNo, Data, State0),
    {noreply, State};

handle_cast({send_request, From, RemoteIP, T3, N3, Msg, ReqId}, State0) ->
    State = do_send_request(From, RemoteIP, T3, N3, Msg, ReqId, State0),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(Info = {timeout, TRef, {send, SeqNo}}, #state{pending = Pending} = State0) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    case gb_trees:lookup(SeqNo, Pending) of
	{value, {_RemoteIP, _T3, _N3 = 0, _Data, Sender, TRef}} ->
	    send_request_reply(Sender, timeout),
	    {noreply, State0#state{pending = gb_trees:delete(SeqNo, Pending)}};

	{value, {RemoteIP, T3, N3, Data, Sender, TRef}} ->
	    %% resent....
	    State = send_request_with_timeout(SeqNo, RemoteIP, T3, N3 - 1, Data, Sender,
					      State0#state{pending = gb_trees:delete(SeqNo, Pending)}),
	    {noreply, State}
    end;

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
    ok = gen_socket:input_event(Socket, true),
    lists:foreach(socket_setopts(Socket, _), Opts),
    {ok, Socket}.

socket_setopts(Socket, {netdev, Device})
  when is_list(Device); is_binary(Device) ->
    BinDev = iolist_to_binary([Device, 0]),
    ok = gen_socket:setsockopt(Socket, sol_socket, bindtodevice, BinDev);
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

handle_err_input(Socket, State) ->
    case gen_socket:recvmsg(Socket, ?MSG_DONTWAIT bor ?MSG_ERRQUEUE) of
	Other ->
	    lager:error("got unhandled error input: ~p", [Other]),
	    ok = gen_socket:input_event(Socket, true),
	    {noreply, State}
    end.

handle_message(IP, Port, Data, #state{gtp_port = GtpPort} = State0) ->
    Msg = gtp_packet:decode(Data),
    %% TODO: handle decode failures

    lager:debug("handle message: ~p", [{IP, Port,
					lager:pr(GtpPort, ?MODULE),
					lager:pr(Msg, ?MODULE)}]),
    State = handle_message_1(IP, Port, Msg, State0),
    {noreply, State}.

handle_message_1(IP, Port,
		 #gtp{type = echo_request} = Msg,
		 #state{gtp_port = GtpPort} = State) ->
    gtp_path:handle_request(IP, Port, GtpPort, Msg),
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
	    handle_request(IP, Port, Msg, State);
	_ ->
	    State
    end.

handle_response(_IP, _Port, #gtp{seq_no = SeqNo} = Msg, #state{pending = Pending} = State) ->
    case gb_trees:lookup(SeqNo, Pending) of
	none -> %% duplicate, drop silently
	    lager:error("~p: invalid response: ~p, ~p", [self(), SeqNo, Pending]),
	    State;

	{value, {_RemoteIP, _T3, _N3, _Data, Sender, TRef}} ->
	    lager:info("~p: found response: ~p", [self(), SeqNo]),
	    send_request_reply(Sender, Msg),
	    cancel_timer(TRef),
	    State#state{pending = gb_trees:delete(SeqNo, Pending)}
    end.

handle_request(IP, Port, #gtp{seq_no = SeqNo} = Msg,
	       #state{gtp_port = GtpPort, socket = Socket, responses = Responses} = State) ->
    Now = erlang:monotonic_time(milli_seconds),
    Key = {IP, SeqNo},
    case gb_trees:lookup(Key, Responses) of
	{value, {Data, TStamp}}  when (TStamp + ?RESPONSE_TIMEOUT) > Now ->
	    gen_socket:sendto(Socket, {inet4, IP, Port}, Data);

	_Other ->
	    lager:info("HandleRequest: ~p", [_Other]),
	    gtp_context:handle_message(IP, Port, GtpPort, Msg)
    end,
    State.

do_send_request(From, RemoteIP, T3, N3, Msg, ReqId,
	     #state{seq_no = SeqNo} = State) ->
    lager:debug("~p: gtp_socket send_request to ~p: ~p", [self(), RemoteIP, Msg]),
    Data = gtp_packet:encode(Msg#gtp{seq_no = SeqNo}),
    Sender = {From, ReqId, Msg},
    send_request_with_timeout(SeqNo, RemoteIP, T3, N3, Data, Sender,
			      State#state{seq_no = (SeqNo + 1) rem 65536}).

send_request_reply({From, ReqId, ReqMsg}, ReplyMsg) ->
    From ! {ReqId, ReqMsg, ReplyMsg}.

send_request_with_timeout(SeqNo, RemoteIP, T3, N3, Data, Sender,
			  #state{socket = Socket, pending = Pending} = State) ->
    TRef = erlang:start_timer(T3, self(), {send, SeqNo}),
    gen_socket:sendto(Socket, {inet4, RemoteIP, ?GTP1c_PORT}, Data),
    State#state{pending = gb_trees:insert(SeqNo, {RemoteIP, T3, N3, Data, Sender, TRef}, Pending)}.

timeout_queue(Now, #state{responses = Responses0, rqueue = RQueue0} = State) ->
    case queue:peek(RQueue0) of
	{value, {TStamp, Key}} when (TStamp + ?RESPONSE_TIMEOUT) < Now ->
	    {_, RQueue} = queue:out(RQueue0),
	    Responses = gb_trees:delete(Key, Responses0),
	    timeout_queue(Now, State#state{responses = Responses, rqueue = RQueue});
	_ ->
	    State
    end.

enqueue_response(IP, SeqNo, Data, #state{responses = Responses0,
					 rqueue = RQueue0} = State)
  when SeqNo /= 0 ->
    Now = erlang:monotonic_time(milli_seconds),
    Key = {IP, SeqNo},
    Responses = gb_trees:insert(Key, {Data, Now}, Responses0),
    RQueue = queue:in({Now, Key}, RQueue0),
    timeout_queue(Now, State#state{responses = Responses, rqueue = RQueue});

enqueue_response(_IP, _SeqNo, _Data, State) ->
    State.

do_send_response(IP, Port, SeqNo, Data, #state{socket = Socket} = State) ->
    gen_socket:sendto(Socket, {inet4, IP, Port}, Data),
    enqueue_response(IP, SeqNo, Data, State).
