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

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-record(state, {
	  gtp_port   :: #gtp_port{},

	  ip         :: inet:ip_address(),
	  socket     :: socket:socket(),
	  burst_size = 1 :: non_neg_integer(),

	  restart_counter}).

-record(send_req, {
	  address :: inet:ip_address(),
	  port    :: inet:port_number(),
	  data    :: binary(),
	  msg     :: #gtp{}
	 }).

%%====================================================================
%% API
%%====================================================================

start_link(SocketOpts) ->
    Opts = [{hibernate_after, 5000},
	    {spawn_opt,[{fullsweep_after, 16}]}],
    gen_server:start_link(?MODULE, SocketOpts, Opts).

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

init(#{name := Name, ip := IP, burst_size := BurstSize} = SocketOpts) ->
    process_flag(trap_exit, true),

    {ok, Socket} = ergw_gtp_socket:make_gtp_socket(IP, ?GTP1u_PORT, SocketOpts),
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

    ergw_socket_reg:register('gtp-u', Name, GtpPort),

    State = #state{
	       gtp_port = GtpPort,

	       ip = IP,
	       socket = Socket,
	       burst_size = BurstSize,

	       restart_counter = RCnt},
    self() ! {'$socket', Socket, select, undefined},
    {ok, State}.

handle_call(Request, _From, State) ->
    ?LOG(error, "handle_call: unknown ~p", [Request]),
    {reply, ok, State}.

handle_cast(#send_req{address = IP, port = Port, msg = Msg},
	    #state{gtp_port = GtpPort} = State) ->
    ergw_prometheus:gtp(tx, GtpPort, IP, Msg),
    Data = gtp_packet:encode(Msg),
    sendto(IP, Port, Data, State),
    {noreply, State};

handle_cast({send, IP, Port, Data}, State)
  when is_binary(Data) ->
    sendto(IP, Port, Data, State),
    {noreply, State};

handle_cast(Msg, State) ->
    ?LOG(error, "handle_cast: unknown ~p", [Msg]),
    {noreply, State}.

handle_info({'$socket', Socket, select, Info}, #state{socket = Socket} = State) ->
    handle_input(Socket, Info, State);

handle_info({'$socket', Socket, abort, Info}, #state{socket = Socket} = State) ->
    handle_input(Socket, Info, State);

handle_info(Info, State) ->
    ?LOG(error, "~s:handle_info: unknown ~p, ~p",
		[?MODULE, Info, State]),
    {noreply, State}.

terminate(_Reason, #state{socket = Socket} = _State) ->
    socket:close(Socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

family({_,_,_,_}) -> inet;
family({_,_,_,_,_,_,_,_}) -> inet6.

make_send_req(Address, Port, Msg) ->
    #send_req{
       address = Address,
       port = Port,
       msg = gtp_packet:encode_ies(Msg)
      }.

make_request(IP, Port, Msg, #state{gtp_port = GtpPort}) ->
    ergw_gtp_socket:make_request(0, IP, Port, Msg, GtpPort).

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
	    State = handle_message(IP, Port, Data, State0),
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

handle_socket_error(#{level := ip, type := ?IP_RECVERR,
		      data := <<_ErrNo:32/native-integer,
				Origin:8, Type:8, Code:8, _Pad:8,
				_Info:32/native-integer, _Data:32/native-integer,
				_/binary>>},
		    IP, _Port, #state{gtp_port = GtpPort})
  when Origin == ?SO_EE_ORIGIN_ICMP, Type == ?ICMP_DEST_UNREACH,
       (Code == ?ICMP_HOST_UNREACH orelse Code == ?ICMP_PORT_UNREACH) ->
    gtp_path:down(GtpPort, IP);

handle_socket_error(#{level := ip, type := recverr,
		      data := #{origin := icmp, type := dest_unreach, code := Code}},
		    IP, _Port, #state{gtp_port = GtpPort})
  when Code == host_unreach;
       Code == port_unreach ->
    gtp_path:down(GtpPort, IP);

handle_socket_error(#{level := ipv6, type := ?IPV6_RECVERR,
		      data := <<_ErrNo:32/native-integer,
				Origin:8, Type:8, Code:8, _Pad:8,
				_Info:32/native-integer, _Data:32/native-integer,
				_/binary>>},
		    IP, _Port, #state{gtp_port = GtpPort})
  when Origin == ?SO_EE_ORIGIN_ICMP6, Type == ?ICMP6_DST_UNREACH,
       (Code == ?ICMP6_DST_UNREACH_ADDR orelse Code == ?ICMP6_DST_UNREACH_NOPORT) ->
    gtp_path:down(GtpPort, IP);

handle_socket_error(#{level := ipv6, type := recverr,
		      data := #{origin := icmp6, type := dst_unreach, code := Code}},
		    IP, _Port, #state{gtp_port = GtpPort})
  when Code == addr_unreach;
       Code == port_unreach ->
    gtp_path:down(GtpPort, IP);

handle_socket_error(Error, IP, _Port, _State) ->
    ?LOG(debug, "got unhandled error info for ~s: ~p", [inet:ntoa(IP), Error]),
    ok.

handle_err_input(Socket, State) ->
    case socket:recvmsg(Socket, [errqueue], nowait) of
	{ok, #{addr := #{addr := IP, port := Port}, ctrl := Ctrl}} ->
	    lists:foreach(handle_socket_error(_, IP, Port, State), Ctrl),
	    ok;

	{select, SelectInfo} ->
	    socket:cancel(Socket, SelectInfo);

	Other ->
	    ?LOG(error, "got unhandled error input: ~p", [Other])
    end,
    State.

handle_message(IP, Port, Data, #state{gtp_port = GtpPort} = State0) ->
    try gtp_packet:decode(Data, #{ies => binary}) of
	Msg = #gtp{} ->
	    %% TODO: handle decode failures

	    ?LOG(debug, "handle message: ~p", [{IP, Port,
						State0#state.gtp_port,
						Msg}]),
	    ergw_prometheus:gtp(rx, GtpPort, IP, Msg),
	    handle_message_1(IP, Port, Msg, State0)
    catch
	Class:Error ->
	    ?LOG(error, "GTP decoding failed with ~p:~p for ~p", [Class, Error, Data]),
	    State0
    end.

handle_message_1(IP, Port, #gtp{version = v1, type = g_pdu, tei = TEI} = Msg, State)
  when TEI /= 0 ->
    ReqKey = make_request(IP, Port, Msg, State),
    ergw_context:port_message(ReqKey, Msg),
    State;
handle_message_1(IP, Port, Msg, State) ->
    ?LOG(warning, "¨unhandled GTP-U from ~s:~w: ~p",
		  [inet:ntoa(IP), Port, Msg]),
    State.

sendto(RemoteIP, Port, Data, #state{socket = Socket}) ->
    Dest = #{family => family(RemoteIP),
	     addr => RemoteIP,
	     port => Port},
    case socket:sendto(Socket, Data, Dest, nowait) of
	ok -> ok;
	Other  ->
	    ?LOG(error, "sendto(~p) failed with: ~p", [Dest, Other]),
	    ok
    end.
