%% Copyright 2018 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gtp_raw_socket).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_link/1, forward/5]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-record(state, {
	  gtp_port   :: #gtp_port{},
	  socket     :: gen_socket:socket(),
	  restart_counter}).

-record(forward_req, {
	  src_addr :: inet:ip_address(),
	  src_port :: inet:port_number(),
	  dst_addr :: inet:ip_address(),
	  dst_port :: inet:port_number(),
	  data     :: binary(),
	  msg      :: #gtp{}
	 }).

-define(EXO_PERF_OPTS, [{time_span, 300 * 1000}]).		%% 5 min histogram

%%====================================================================
%% API
%%====================================================================

start_link({Name, SocketOpts}) ->
    gen_server:start_link(?MODULE, [Name, SocketOpts], []).

forward(#gtp_port{type = 'gtp-raw'} = GtpPort,
	#request{ip = SrcIP, port = SrcPort},
	DstIP, DstPort, #gtp{} = Msg) ->
    cast(GtpPort, make_forward_req(SrcIP, SrcPort, DstIP, DstPort, Msg));
forward(#gtp_port{type = 'gtp-raw'} = GtpPort,
	#request{ip = SrcIP, port = SrcPort},
	DstIP, DstPort, Data) ->
    cast(GtpPort, {forward, SrcIP, SrcPort, DstIP, DstPort, Data}).

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

    {ok, S} = make_gtp_socket(IP, 0, SocketOpts),
    {ok, RCnt} = gtp_config:get_restart_counter(),
    VRF = case SocketOpts of
	      #{vrf := VRF0} when is_binary(VRF0) ->
		  VRF0;
	      _ -> vrf:normalize_name(Name)
	  end,

    GtpPort = #gtp_port{
		 name = Name,
		 vrf = VRF,
		 type = maps:get(type, SocketOpts, 'gtp-raw'),
		 pid = self(),
		 ip = IP,
		 restart_counter = RCnt
		},

    init_exometer(GtpPort),
    ergw_gtp_socket_reg:register(Name, GtpPort),

    State = #state{
	       gtp_port = GtpPort,
	       socket = S,
	       restart_counter = RCnt},
    {ok, State}.

handle_call(Request, _From, State) ->
    lager:error("handle_call: unknown ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast(#forward_req{src_addr = SrcIP, src_port = SrcPort,
			 dst_addr = DstIP, dst_port = DstPort, msg = Msg},
	    #state{gtp_port = GtpPort} = State) ->
    message_counter(tx, GtpPort, DstIP, Msg),
    Data = gtp_packet:encode(Msg),
    forward(SrcIP, SrcPort, DstIP, DstPort, Data, State),
    {noreply, State};

handle_cast({forward, SrcIP, SrcPort, DstIP, DstPort, Data}, State)
  when is_binary(Data) ->
    forward(SrcIP, SrcPort, DstIP, DstPort, Data, State),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

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

make_forward_req(SrcIP, SrcPort, DstIP, DstPort, Msg) ->
    #forward_req{
       src_addr = SrcIP,
       src_port = SrcPort,
       dst_addr = DstIP,
       dst_port = DstPort,
       msg = gtp_packet:encode_ies(Msg)
      }.

forward(SrcIP, SrcPort, DstIP, DstPort, Data, State) ->
    Pkt = ergw_inet:make_udp(ergw_inet:ip2bin(SrcIP), ergw_inet:ip2bin(DstIP),
			     SrcPort, DstPort, Data),
    sendto(DstIP, DstPort, Pkt, State).

sendto({_,_,_,_} = RemoteIP, Port, Data, #state{socket = Socket}) ->
    gen_socket:sendto(Socket, {inet4, RemoteIP, Port}, Data);
sendto({_,_,_,_,_,_,_,_} = RemoteIP, Port, Data, #state{socket = Socket}) ->
    %%TODO: IPv6 sending requires sendmsg support with ancillary data
    error(not_implemented_yet),
    gen_socket:sendto(Socket, {inet6, RemoteIP, Port}, Data).

%%%===================================================================
%%% Socket Helper
%%%===================================================================

family({_,_,_,_}) -> inet;
family({_,_,_,_,_,_,_,_}) -> inet6.

make_gtp_socket(IP, Port, #{netns := NetNs} = Opts)
  when is_list(NetNs) ->
    {ok, Socket} = gen_socket:socketat(NetNs, family(IP), raw, udp),
    bind_gtp_socket(Socket, IP, Port, Opts);
make_gtp_socket(IP, Port, Opts) ->
    {ok, Socket} = gen_socket:socket(family(IP), raw, udp),
    bind_gtp_socket(Socket, IP, Port, Opts).

bind_gtp_socket(Socket, {_,_,_,_} = IP, Port, Opts) ->
    ok = socket_ip_freebind(Socket, Opts),
    ok = socket_netdev(Socket, Opts),
    ok = gen_socket:bind(Socket, {inet4, IP, Port}),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    ok = socket_setopts(Socket, hdrincl, true),
    ok = gen_socket:input_event(Socket, true),
    {ok, Socket};

bind_gtp_socket(Socket, {_,_,_,_,_,_,_,_} = IP, Port, Opts) ->
    %% ok = gen_socket:setsockopt(Socket, sol_ip, recverr, true),
    ok = socket_ip_freebind(Socket, Opts),
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
socket_setopts(Socket, hdrincl, true) ->
    ok = gen_socket:setsockopt(Socket, sol_ip, hdrincl, true);
socket_setopts(_Socket, _, _) ->
    ok.

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
    exometer_new([socket, 'gtp-raw', Name, rx, Version, MsgType, count], counter),
    exometer_new([socket, 'gtp-raw', Name, tx, Version, MsgType, count], counter).

init_exometer(#gtp_port{name = Name, type = 'gtp-raw'}) ->
    exometer_new([socket, 'gtp-raw', Name, rx, v1, unsupported], counter),
    exometer_new([socket, 'gtp-raw', Name, tx, v1, unsupported], counter),
    lists:foreach(exo_reg_msg(Name, v1, _), gtp_v1_u:gtp_msg_types()),
    ok;
init_exometer(_) ->
    ok.

message_counter_apply(Name, RemoteIP, Direction, Version, MsgInfo) ->
    case exometer:update([socket, 'gtp-raw', Name, Direction, Version | MsgInfo], 1) of
	{error, undefined} ->
	    exometer:update([socket, 'gtp-raw', Name, Direction, Version, unsupported], 1),
	    exometer:update_or_create([path, Name, RemoteIP, Direction, Version, unsupported], 1, counter, []);
	Other ->
	    exometer:update_or_create([path, Name, RemoteIP, Direction, Version | MsgInfo], 1, counter, []),
	    Other
    end.

message_counter(Direction, #gtp_port{name = Name, type = 'gtp-raw'},
		RemoteIP, #gtp{version = Version, type = MsgType}) ->
    message_counter_apply(Name, RemoteIP, Direction, Version, [MsgType, count]).
