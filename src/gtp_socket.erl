%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_socket).

-behavior(gen_server).

%% API
-export([start_sockets/0, start_link/1,
	 send/4, get_restart_counter/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-record(state, {gtp_port, ip, socket, restart_counter}).

%%====================================================================
%% API
%%====================================================================

start_sockets() ->
    {ok, Sockets} = application:get_env(sockets),
    lists:foreach(fun(Socket) ->
			  gtp_socket_sup:new(Socket)
		  end, Sockets),
    ok.

start_link(Socket) ->
    case proplists:get_value(type, Socket, 'gtp-c') of
	'gtp-c' ->
	    gen_server:start_link(?MODULE, [Socket], []);
	'gtp-u' ->
	    gtp_dp:start_link(Socket)
    end.

send(GtpPort, IP, Port, Data) ->
    cast(GtpPort, {send, IP, Port, Data}).

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

init([Socket]) ->
    %% TODO: better config validation and handling
    Name  = proplists:get_value(name, Socket),
    IP    = proplists:get_value(ip, Socket),
    NetNs = proplists:get_value(netns, Socket),
    Type  = proplists:get_value(type, Socket, 'gtp-c'),

    {ok, S} = make_gtp_socket(NetNs, IP, ?GTP1c_PORT),

    %% FIXME: this is wrong and must go into the global startup
    RCnt = gtp_config:inc_restart_counter(),

    GtpPort = #gtp_port{name = Name, type = Type, pid = self(),
			ip = IP, restart_counter = RCnt},

    gtp_socket_reg:register(Name, GtpPort),

    {ok, #state{gtp_port = GtpPort, ip = IP, socket = S,
		restart_counter = RCnt}}.

handle_call(get_restart_counter, _From, #state{restart_counter = RCnt} = State) ->
    {reply, RCnt, State};

handle_call(Request, _From, State) ->
    lager:error("handle_call: unknown ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({send, IP, Port, Data}, #state{socket = Socket} = State) ->
    gen_socket:sendto(Socket, {inet4, IP, Port}, Data),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

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

make_gtp_socket(NetNs, {_,_,_,_} = IP, Port) when is_list(NetNs) ->
    {ok, Socket} = gen_socket:socketat(NetNs, inet, dgram, udp),
    bind_gtp_socket(Socket, IP, Port);
make_gtp_socket(_NetNs, {_,_,_,_} = IP, Port) ->
    {ok, Socket} = gen_socket:socket(inet, dgram, udp),
    bind_gtp_socket(Socket, IP, Port).

bind_gtp_socket(Socket, {_,_,_,_} = IP, Port) ->
    ok = gen_socket:bind(Socket, {inet4, IP, Port}),
    ok = gen_socket:setsockopt(Socket, sol_ip, recverr, true),
    ok = gen_socket:input_event(Socket, true),
    {ok, Socket}.

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

handle_message(IP, Port, Data, #state{gtp_port = GtpPort} = State) ->
    Msg = gtp_packet:decode(Data),
    lager:debug("handle message: ~p", [{IP, Port,
					lager:pr(GtpPort, ?MODULE),
					gtp_c_lib:fmt_gtp(Msg)}]),
    handle_message_1(IP, Port, GtpPort, Msg),
    {noreply, State}.

handle_message_1(IP, Port, GtpPort,
	       #gtp{type = echo_request} = Msg) ->
    handle_echo_request(IP, Port, GtpPort, Msg);

handle_message_1(IP, _Port, GtpPort,
	       #gtp{type = echo_response} = Msg) ->
    handle_echo_response(IP, GtpPort, Msg);

handle_message_1(IP, Port, GtpPort,
	       #gtp{version = Version, type = MsgType, tei = 0} = Msg)
  when (Version == v1 andalso MsgType == create_pdp_context_request) orelse
       (Version == v2 andalso MsgType == create_session_request) ->
    gtp_context:new(IP, Port, GtpPort, Msg);

handle_message_1(IP, Port, GtpPort, Msg) ->
    gtp_context:handle_message(IP, Port, GtpPort, Msg).

handle_echo_request(IP, Port, GtpPort,
		    #gtp{version = Version, type = echo_request, tei = TEI, seq_no = SeqNo} = Msg) ->
    ResponseIEs =
	case Version of
	    v1 -> gtp_v1_c:build_recovery(GtpPort, true);
	    v2 -> gtp_v2_c:build_recovery(GtpPort, true)
	end,
    Response = #gtp{version = Version, type = echo_response, tei = TEI, seq_no = SeqNo, ie = ResponseIEs},

    Data = gtp_packet:encode(Response),
    lager:debug("gtp ~w send to ~w:~w: ~p, ~p", [GtpPort#gtp_port.type, IP, Port, Response, Data]),
    send(GtpPort, IP, Port, Data),

    case gtp_path:get(GtpPort, IP) of
	Path when is_pid(Path) ->
	    %% for the reuqest to the path so that it can handle the restart counter
	    gtp_path:handle_request(Path, Msg);
	_ ->
	    ok
    end,
    ok.

handle_echo_response(IP, GtpPort, Msg) ->
    lager:debug("handle_echo_response: ~p -> ~p", [IP, gtp_path:get(GtpPort, IP)]),
    case gtp_path:get(GtpPort, IP) of
	Path when is_pid(Path) ->
	    gtp_path:handle_response(Path, Msg);
	_ ->
	    ok
    end,
    ok.
