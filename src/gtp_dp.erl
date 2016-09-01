%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_dp).

-behavior(gen_server).

%% API
-export([start_link/1, send/4,
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

start_link({Name, SocketOpts}) ->
    gen_server:start_link(?MODULE, [Name, SocketOpts], []).

send(GtpPort, IP, Port, Data) ->
    cast(GtpPort, {send, IP, Port, Data}).

create_pdp_context(GtpPort, Version, IP, MS, LocalTEI, RemoteTEI) ->
    call(GtpPort, {create_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}).

update_pdp_context(GtpPort, Version, IP, MS, LocalTEI, RemoteTEI) ->
    call(GtpPort, {update_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}).

delete_pdp_context(GtpPort, Version, IP, MS, LocalTEI, RemoteTEI) ->
    call(GtpPort, {delete_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}).

%%%===================================================================
%%% call/cast wrapper for gtp_port
%%%===================================================================

%% TODO: GTP data path handler is currently not working!!
cast(#gtp_port{pid = Handler}, Request)
  when is_pid(Handler) ->
    gen_server:cast(Handler, Request);
cast(GtpPort, Request) ->
    lager:warning("GTP DP Port ~p, CAST Request ~p not implemented yet",
		  [lager:pr(GtpPort, ?MODULE), Request]).

call(#gtp_port{pid = Handler}, Request)
  when is_pid(Handler) ->
    gen_server:call(Handler, Request);
call(GtpPort, Request) ->
    lager:warning("GTP DP Port ~p, CAST Request ~p not implemented yet",
		  [lager:pr(GtpPort, ?MODULE), Request]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, SocketOpts]) ->
    %% TODO: better config validation and handling
    IP    = proplists:get_value(ip, SocketOpts),
    NetNs = proplists:get_value(netns, SocketOpts),
    Type  = proplists:get_value(type, SocketOpts, 'gtp-u'),

    {ok, GTP0} = make_gtp_socket(NetNs, IP, ?GTP0_PORT),
    {ok, GTP1u} = make_gtp_socket(NetNs, IP, ?GTP1u_PORT),

    FD0 = gen_socket:getfd(GTP0),
    FD1u = gen_socket:getfd(GTP1u),
    Opts =
	if is_list(NetNs) ->
		[{netns, NetNs}];
	   true ->
		[]
	end,
    {ok, GTPDev} = gtp_kernel:dev_create("gtp0", FD0, FD1u, Opts),

    %% FIXME: this is wrong and must go into the global startup
    RCnt = gtp_config:inc_restart_counter(),

    GtpPort = #gtp_port{name = Name, type = Type, pid = self(),
			ip = IP, restart_counter = RCnt},

    gtp_socket_reg:register(Name, GtpPort),

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
    handle_input(GTP1u, State);

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

handle_message(IP, Port, Data, #state{gtp_port = GtpPort} = State0) ->
    Msg = gtp_packet:decode(Data),
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

handle_message_1(_IP, _Port, Msg, State) ->
    lager:warning("DP Message unhandled: ~p", [lager:pr(Msg, ?MODULE)]),
    State.
