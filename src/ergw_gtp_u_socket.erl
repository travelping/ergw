%% Copyright 2018 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gtp_u_socket).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_link/1, send/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-record(state, {
	  gtp_port   :: #gtp_port{},

	  ip         :: inet:ip_address(),
	  socket     :: gen_socket:socket(),

	  restart_counter}).

-record(send_req, {
	  address :: inet:ip_address(),
	  port    :: inet:port_number(),
	  data    :: binary(),
	  msg     :: #gtp{}
	 }).

-define(EXO_PERF_OPTS, [{time_span, 300 * 1000}]).		%% 5 min histogram

%%====================================================================
%% API
%%====================================================================

start_link({Name, SocketOpts}) ->
    Opts = [{hibernate_after, 5000},
	    {spawn_opt,[{fullsweep_after, 16}]}],
    gen_server:start_link(?MODULE, [Name, SocketOpts], Opts).

send(#gtp_port{type = 'gtp-u'} = GtpPort, IP, Port, #gtp{} = Msg) ->
    cast(GtpPort, make_send_req(IP, Port, Msg));
send(#gtp_port{type = 'gtp-u'} = GtpPort, IP, Port, Data) ->
    cast(GtpPort, {send, IP, Port, Data}).

%%%===================================================================
%%% call/cast wrapper for gtp_port
%%%===================================================================

cast(#gtp_port{pid = Handler}, Request) ->
    gen_server:cast(Handler, Request).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, #{ip := IP} = SocketOpts]) ->
    process_flag(trap_exit, true),

    {ok, S} = ergw_gtp_socket:make_gtp_socket(IP, ?GTP1u_PORT, SocketOpts),
    {ok, RCnt} = gtp_config:get_restart_counter(),
    VRF = case SocketOpts of
	      #{vrf := VRF0} when is_binary(VRF0) ->
		  VRF0;
	      _ -> vrf:normalize_name(Name)
	  end,

    GtpPort = #gtp_port{
		 name = Name,
		 vrf = VRF,
		 type = maps:get(type, SocketOpts, 'gtp-u'),
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

	       restart_counter = RCnt},
    {ok, State}.

handle_call(Request, _From, State) ->
    lager:error("handle_call: unknown ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast(#send_req{address = IP, port = Port, msg = Msg},
	    #state{gtp_port = GtpPort} = State) ->
    message_counter(tx, GtpPort, IP, Msg),
    Data = gtp_packet:encode(Msg),
    sendto(IP, Port, Data, State),
    {noreply, State};

handle_cast({send, IP, Port, Data}, State)
  when is_binary(Data) ->
    sendto(IP, Port, Data, State),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

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

make_send_req(Address, Port, Msg) ->
    #send_req{
       address = Address,
       port = Port,
       msg = gtp_packet:encode_ies(Msg)
      }.

make_request(IP, Port, Msg, #state{gtp_port = GtpPort}) ->
    ergw_gtp_socket:make_request(0, IP, Port, Msg, GtpPort).

handle_input(Socket, State) ->
    case gen_socket:recvfrom(Socket) of
	{error, _} ->
	    handle_err_input(Socket, State);

	{ok, {_, IP, Port}, Data} ->
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
    try gtp_packet:decode(Data, #{ies => binary}) of
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
	    {noreply, State0}
    end.

handle_message_1(IP, Port, #gtp{version = v1, type = g_pdu, tei = TEI} = Msg, State)
  when TEI /= 0 ->
    ReqKey = make_request(IP, Port, Msg, State),
    ergw_context:port_message(ReqKey, Msg),
    State;
handle_message_1(IP, Port, Msg, State) ->
    lager:warning("¨unhandled GTP-U from ~s:~w: ~p",
		  [inet:ntoa(IP), Port, lager:pr(Msg, ?MODULE)]),
    State.

sendto({_,_,_,_} = RemoteIP, Port, Data, #state{socket = Socket}) ->
    gen_socket:sendto(Socket, {inet4, RemoteIP, Port}, Data);
sendto({_,_,_,_,_,_,_,_} = RemoteIP, Port, Data, #state{socket = Socket}) ->
    gen_socket:sendto(Socket, {inet6, RemoteIP, Port}, Data).

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

exo_reg_msg(Name, Version, MsgType) ->
    exometer_new([socket, 'gtp-u', Name, rx, Version, MsgType, count], counter),
    exometer_new([socket, 'gtp-u', Name, tx, Version, MsgType, count], counter).

init_exometer(#gtp_port{name = Name, type = 'gtp-u'}) ->
    exometer_new([socket, 'gtp-u', Name, rx, v1, unsupported], counter),
    exometer_new([socket, 'gtp-u', Name, tx, v1, unsupported], counter),
    lists:foreach(exo_reg_msg(Name, v1, _), gtp_v1_u:gtp_msg_types()),
    ok;
init_exometer(_) ->
    ok.

message_counter_apply(Name, RemoteIP, Direction, Version, MsgInfo) ->
    case exometer:update([socket, 'gtp-u', Name, Direction, Version | MsgInfo], 1) of
	{error, undefined} ->
	    exometer:update([socket, 'gtp-u', Name, Direction, Version, unsupported], 1),
	    exometer:update_or_create([path, Name, RemoteIP, Direction, Version, unsupported], 1, counter, []);
	Other ->
	    exometer:update_or_create([path, Name, RemoteIP, Direction, Version | MsgInfo], 1, counter, []),
	    Other
    end.

message_counter(Direction, #gtp_port{name = Name, type = 'gtp-u'},
		RemoteIP, #gtp{version = Version, type = MsgType}) ->
    message_counter_apply(Name, RemoteIP, Direction, Version, [MsgType, count]).
