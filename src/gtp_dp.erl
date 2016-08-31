%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_dp).

-behavior(gen_server).

%% API
-export([start_link/0,
	 create_pdp_context/6,
	 update_pdp_context/6,
	 delete_pdp_context/6]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-record(state, {gtp_port, ip, gtp0, gtp1u, gtp_dev}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    {ok, IP}   = application:get_env(ip),
    {ok, Opts} = application:get_env(apn),
    gen_server:start_link(?MODULE, [IP, Opts], []).

send(GtpPort, Type, IP, Port, Data) ->
    cast(GtpPort, {send, Type, IP, Port, Data}).

create_pdp_context(GtpPort, Version, IP, MS, LocalTEI, RemoteTEI) ->
    call(GtpPort, {create_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}).

update_pdp_context(GtpPort, Version, IP, MS, LocalTEI, RemoteTEI) ->
    call(GtpPort, {update_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}).

delete_pdp_context(GtpPort, Version, IP, MS, LocalTEI, RemoteTEI) ->
    call(GtpPort, {delete_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}).

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

init([IP, Opts]) ->
    {ok, GTP0} = make_gtp_socket(IP, ?GTP0_PORT),
    {ok, GTP1u} = make_gtp_socket(IP, ?GTP1u_PORT),

    FD0 = gen_socket:getfd(GTP0),
    FD1u = gen_socket:getfd(GTP1u),
    {ok, GTPDev} = gtp_kernel:dev_create("gtp0", FD0, FD1u, Opts),

    GtpPort = #gtp_port{pid = self(), ip = IP},
    {ok, #state{gtp_port = GtpPort, ip = IP,
		gtp0 = GTP0, gtp1u = GTP1u, gtp_dev = GTPDev}}.

handle_call({create_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}, _From,
	    #state{gtp_dev = GTPDev} = State) ->
    Reply = gtp_kernel:create_pdp_context(GTPDev, Version, IP, MS, LocalTEI, RemoteTEI),
    {reply, Reply, State};

handle_call({update_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}, _From,
	    #state{gtp_dev = GTPDev} = State) ->
    Reply = gtp_kernel:update_pdp_context(GTPDev, Version, IP, MS, LocalTEI, RemoteTEI),
    {reply, Reply, State};

handle_call({delete_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}, _From,
	    #state{gtp_dev = GTPDev} = State) ->
    Reply = gtp_kernel:delete_pdp_context(GTPDev, Version, IP, MS, LocalTEI, RemoteTEI),
    {reply, Reply, State};

handle_call(Request, _From, State) ->
    lager:error("handle_call: unknown ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({send, 'gtp-u', IP, Port, Data}, #state{gtp1u = GTP1u} = State) ->
    gen_socket:sendto(GTP1u, {inet4, IP, Port}, Data),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info({GTP1u, input_ready}, #state{gtp1u = GTP1u} = State) ->
    handle_input('gtp-u', GTP1u, State);

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

make_gtp_socket({_,_,_,_} = IP, Port) ->
    {ok, Socket} = gen_socket:socket(inet, dgram, udp),
    ok = gen_socket:bind(Socket, {inet4, IP, Port}),
    ok = gen_socket:setsockopt(Socket, sol_ip, recverr, true),
    ok = gen_socket:input_event(Socket, true),
    {ok, Socket}.

handle_input(Type, Socket, State) ->
    case gen_socket:recvfrom(Socket) of
	{error, _} ->
	    handle_err_input(Type, Socket, State);

	{ok, {inet4, IP, Port}, Data} ->
	    ok = gen_socket:input_event(Socket, true),
	    handle_message(Type, IP, Port, Data, State);

	Other ->
	    lager:error("got unhandled input: ~p", [Other]),
	    ok = gen_socket:input_event(Socket, true),
	    {noreply, State}
    end.

handle_err_input(_Type, Socket, State) ->
    case gen_socket:recvmsg(Socket, ?MSG_DONTWAIT bor ?MSG_ERRQUEUE) of
	Other ->
	    lager:error("got unhandled error input: ~p", [Other]),
	    ok = gen_socket:input_event(Socket, true),
	    {noreply, State}
    end.

handle_message(Type, IP, Port, Data, #state{gtp_port = GtpPort} = State) ->
    Msg = gtp_packet:decode(Data),
    lager:debug("handle message: ~p", [{Type, IP, Port, GtpPort, Msg}]),
    handle_message_1(Type, IP, Port, GtpPort, Msg),
    {noreply, State}.

handle_message_1(Type, IP, Port, GtpPort,
	       #gtp{type = echo_request} = Msg) ->
    handle_echo_request(Type, IP, Port, GtpPort, Msg);

handle_message_1(Type, IP, _Port, _GtpPort,
	       #gtp{type = echo_response} = Msg) ->
    handle_echo_response(Type, IP, Msg);

handle_message_1(Type, IP, Port, GtpPort, Msg) ->
    gtp_context:handle_message(Type, IP, Port, GtpPort, Msg).

handle_echo_request(Type, IP, Port, GtpPort,
		    #gtp{version = Version, type = echo_request, tei = TEI, seq_no = SeqNo} = Msg) ->
    ResponseIEs =
	case Version of
	    v1 -> gtp_v1_c:build_recovery(GtpPort, true);
	    v2 -> gtp_v2_c:build_recovery(GtpPort, true)
	end,
    Response = #gtp{version = Version, type = echo_response, tei = TEI, seq_no = SeqNo, ie = ResponseIEs},

    Data = gtp_packet:encode(Response),
    lager:debug("gtp send ~s to ~w:~w: ~p, ~p", [Type, IP, Port, Response, Data]),
    send(GtpPort, Type, IP, Port, Data),

    case gtp_path:get(Type, IP) of
	Path when is_pid(Path) ->
	    %% for the reuqest to the path so that it can handle the restart counter
	    gtp_path:handle_request(Path, Msg);
	_ ->
	    ok
    end,
    ok.

handle_echo_response(Type, IP, Msg) ->
    lager:debug("handle_echo_response: ~p -> ~p", [{Type, IP}, gtp_path:get(Type, IP)]),
    case gtp_path:get(Type, IP) of
	Path when is_pid(Path) ->
	    gtp_path:handle_response(Path, Msg);
	_ ->
	    ok
    end,
    ok.
