%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sim_up).

-behaviour(gen_server).

%% API
-export([start_socket/1, start_link/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-define(SERVER, ?MODULE).

-record(state, {socket}).

%% Helper macro for declaring children of supervisor
-define(CHILD(I, Type, Args), {I, {I, start_link, Args}, permanent, 5000, Type, [I]}).

%%%===================================================================
%%% API
%%%===================================================================

start_socket(IP) ->
    {ok, _} = supervisor:start_child(ergw_sup, ?CHILD(?MODULE, worker, [IP])).

start_link(IP) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [IP], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([IP]) ->
    process_flag(trap_exit, true),

    SocketOpts =
	#{ip => IP},
    {ok, S} = make_gtp_socket(IP, ?GTP1u_PORT, SocketOpts),

    State = #state{
	       socket = S
	      },
    {ok, State}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({Socket, input_ready}, #state{socket = Socket} = State) ->
    handle_input(Socket, State).

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

family({_,_,_,_}) -> inet;
family({_,_,_,_,_,_,_,_}) -> inet6.

make_gtp_socket(IP, Port, Opts) ->
    {ok, Socket} = gen_socket:socket(family(IP), dgram, udp),
    bind_gtp_socket(Socket, IP, Port, Opts).

bind_gtp_socket(Socket, {_,_,_,_} = IP, Port, Opts) ->
    gen_socket:setsockopt(Socket, sol_ip, freebind, true),
    ok = gen_socket:bind(Socket, {inet4, IP, Port}),
    ok = gen_socket:setsockopt(Socket, sol_ip, recverr, true),
    ok = gen_socket:setsockopt(Socket, sol_ip, mtu_discover, 0),
    ok = gen_socket:input_event(Socket, true),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    {ok, Socket};

bind_gtp_socket(Socket, {_,_,_,_,_,_,_,_} = IP, Port, Opts) ->
    %% ok = gen_socket:setsockopt(Socket, sol_ip, recverr, true),
    ok = gen_socket:bind(Socket, {inet6, IP, Port}),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    ok = gen_socket:input_event(Socket, true),
    {ok, Socket}.

socket_setopts(Socket, rcvbuf, Size) when is_integer(Size) ->
    case gen_socket:setsockopt(Socket, sol_socket, rcvbufforce, Size) of
	ok -> ok;
	_  -> gen_socket:setsockopt(Socket, sol_socket, rcvbuf, Size)
    end;
socket_setopts(Socket, reuseaddr, true) ->
    ok = gen_socket:setsockopt(Socket, sol_socket, reuseaddr, true);
socket_setopts(_Socket, _, _) ->
    ok.

sendto({_,_,_,_} = RemoteIP, Port, Data, #state{socket = Socket}) ->
    gen_socket:sendto(Socket, {inet4, RemoteIP, Port}, Data);
sendto({_,_,_,_,_,_,_,_} = RemoteIP, Port, Data, #state{socket = Socket}) ->
    gen_socket:sendto(Socket, {inet6, RemoteIP, Port}, Data).

handle_input(Socket, State) ->
    case gen_socket:recvfrom(Socket) of
	{error, _} = Err ->
	    lager:error("got error from UP socket: ~p", [Err]),
	    {noreply, State};

	{ok, {_, IP, Port}, Data} ->
	    ok = gen_socket:input_event(Socket, true),
	    handle_message(IP, Port, Data, State);

	Other ->
	    lager:error("got unhandled input: ~p", [Other]),
	    ok = gen_socket:input_event(Socket, true),
	    {noreply, State}
    end.

handle_message(IP, Port, Data, State0) ->
    try gtp_packet:decode(Data, #{ies => binary}) of
	Msg = #gtp{} ->
	    State = handle_message_1(IP, Port, Msg, State0),
	    {noreply, State}
    catch
	Class:Error ->
	    lager:error("GTP decoding failed with ~p:~p for ~p", [Class, Error, Data]),
	    {noreply, State0}
    end.

handle_message_1(IP, Port, #gtp{type = echo_request} = Msg, State) ->
    ResponseIEs = [#recovery{restart_counter = 0}],
    Response = Msg#gtp{type = echo_response, ie = ResponseIEs},
    Data = gtp_packet:encode(Response),
    sendto(IP, Port, Data, State),
    State;

handle_message_1(IP, Port, Msg, State) ->
    lager:debug("UP from ~s:~w: ~p", [inet:ntoa(IP), Port, Msg]),
    State.
