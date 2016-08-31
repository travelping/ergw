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

send(#gtp_port{type = 'gtp-c'} = GtpPort, IP, Port, Data) ->
    cast(GtpPort, {send, IP, Port, Data});
send(#gtp_port{type = 'gtp-u'} = GtpPort, IP, Port, Data) ->
    gtp_dp:send(GtpPort, IP, Port, Data).

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
					lager:pr(Msg, ?MODULE)}]),
    gtp_path:handle_message(IP, Port, GtpPort, Msg),
    {noreply, State}.

