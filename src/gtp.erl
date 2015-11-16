%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp).

-behavior(gen_server).

%% API
-export([new/2, send/5,
	 get_restart_counter/1,
	 create_pdp_context/6,
	 update_pdp_context/6,
	 delete_pdp_context/6,
	 allocate_pdp_ip/4,
	 release_pdp_ip/3]).
-export([test/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-record(state, {gtp_port, ip, gtp0, gtp1c, gtp1u, gtp_dev, restart_counter, ip4_pools, ip6_pools}).

%%====================================================================
%% API
%%====================================================================

test() ->
    Opts = [{netns, "/var/run/netns/upstream"},
	    {routes, [{{10, 180, 0, 0}, 16}]},
	    {pools,  [{{10, 180, 0, 0}, 16},
		      {{16#8001, 0, 0, 0, 0, 0, 0, 0}, 48}]}
	   ],
    new({172,20,16,168}, Opts).

-spec new(IP     :: inet:ip_address(),
	  Opts   :: [term()]) -> ok | {error, _}.

new(IP, Opts) ->
    gen_server:start_link(?MODULE, [IP, Opts], []).

send(GtpPort, Type, IP, Port, Data) ->
    cast(GtpPort, {send, Type, IP, Port, Data}).

get_restart_counter(GtpPort) ->
    call(GtpPort, get_restart_counter).

create_pdp_context(GtpPort, Version, IP, MS, LocalTEI, RemoteTEI) ->
    call(GtpPort, {create_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}).

update_pdp_context(GtpPort, Version, IP, MS, LocalTEI, RemoteTEI) ->
    call(GtpPort, {update_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}).

delete_pdp_context(GtpPort, Version, IP, MS, LocalTEI, RemoteTEI) ->
    call(GtpPort, {delete_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}).

allocate_pdp_ip(GtpPort, TEI, IPv4, IPv6) ->
    call(GtpPort, {allocate_pdp_ip, TEI, IPv4, IPv6}).

release_pdp_ip(GtpPort, IPv4, IPv6) ->
    call(GtpPort, {release_pdp_ip, IPv4, IPv6}).

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
    Pools = proplists:get_value(pools, Opts, []),
    IPv4pools = [init_pool(X) || {Prefix, _Len} = X <- Pools, size(Prefix) == 4],
    IPv6pools = [init_pool(X) || {Prefix, _Len} = X <- Pools, size(Prefix) == 8],

    lager:debug("IPv4Pools ~p", [IPv4pools]),
    lager:debug("IPv6Pools ~p", [IPv6pools]),

    {ok, GTP0} = make_gtp_socket(IP, ?GTP0_PORT),
    {ok, GTP1c} = make_gtp_socket(IP, ?GTP1c_PORT),
    {ok, GTP1u} = make_gtp_socket(IP, ?GTP1u_PORT),

    FD0 = gen_socket:getfd(GTP0),
    FD1u = gen_socket:getfd(GTP1u),
    {ok, GTPDev} = gtp_kernel:dev_create("gtp0", FD0, FD1u, Opts),
    RCnt = gtp_config:inc_restart_counter(),

    {ok, #state{gtp_port = #gtp_port{pid = self(), ip = IP, restart_counter = RCnt},
		ip = IP, gtp0 = GTP0, gtp1c = GTP1c, gtp1u = GTP1u,
		gtp_dev = GTPDev, restart_counter = RCnt,
		ip4_pools = IPv4pools, ip6_pools = IPv6pools}}.

handle_call(get_restart_counter, _From, #state{restart_counter = RCnt} = State) ->
    {reply, RCnt, State};

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

handle_call({allocate_pdp_ip, TEI, ReqIPv4, ReqIPv6} = Request, _From, State) ->
    lager:warning("handle_call: ~p", [Request]),
    IPv4 = alloc_ipv4(TEI, ReqIPv4, State),
    IPv6 = alloc_ipv6(TEI, ReqIPv6, State),
    {reply, {ok, IPv4, IPv6}, State};

handle_call({release_pdp_ip, IPv4, IPv6} = Request, _From, State) ->
    lager:warning("handle_call: ~p", [Request]),
    release_ipv4(IPv4, State),
    release_ipv6(IPv6, State),
    {reply, ok, State};

handle_call(Request, _From, State) ->
    lager:error("handle_call: unknown ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({send, 'gtp-c', IP, Port, Data}, #state{gtp1c = GTP1c} = State) ->
    gen_socket:sendto(GTP1c, {inet4, IP, Port}, Data),
    {noreply, State};

handle_cast({send, 'gtp-u', IP, Port, Data}, #state{gtp1u = GTP1u} = State) ->
    gen_socket:sendto(GTP1u, {inet4, IP, Port}, Data),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.


handle_info({GTP1c, input_ready}, #state{gtp1c = GTP1c} = State) ->
    handle_input('gtp-c', GTP1c, State);
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

handle_message_1(Type, IP, Port, GtpPort,
	       #gtp{version = Version, type = MsgType, tei = 0} = Msg)
  when (Version == v1 andalso MsgType == create_pdp_context_request) orelse
       (Version == v2 andalso MsgType == create_session_request) ->
    gtp_context:new(Type, IP, Port, GtpPort, Msg);

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

alloc_ipv4(_TEI, undefined, _State) ->
    undefined;
alloc_ipv4(TEI, {0,0,0,0}, #state{ip4_pools = Pools}) ->
    alloc_ip(TEI, Pools);
alloc_ipv4(_TEI, {_,_,_,_} = ReqIPv4, _State) ->
    %% check if the IP falls into one of our pool and mark a allocate if so
    ReqIPv4.

alloc_ipv6(_TEI, undefined, _State) ->
    undefined;
alloc_ipv6(TEI, {{0,0,0,0,0,0,0,0},_}, #state{ip6_pools = Pools}) ->
    alloc_ip(TEI, Pools);
alloc_ipv6(_TEI, {{_,_,_,_,_,_,_,_},_} = ReqIPv6, _State) ->
    lager:error("alloc IPv6 not implemented"),
    %% check if the IP falls into one of our pool and mark a allocated if so
    ReqIPv6.

release_ipv4(IPv4, #state{ip4_pools = Pools}) ->
    release_ip(IPv4, Pools).

release_ipv6(IPv6, #state{ip6_pools = Pools}) ->
    release_ip(IPv6, Pools).

init_pool(X) ->
    %% TODO: to supervise or not to supervise??????
    {ok, Pid} = gtp_ip_pool:start_link(X, []),
    Pid.

%% TODO: error handling....
alloc_ip(TEI, [Pool|_]) ->
    case gtp_ip_pool:allocate(Pool, TEI) of
	{ok, IP} ->
	    IP;
	_Other ->
	    undefined
    end;
alloc_ip(_TEI, _) ->
    lager:error("no pool"),
    undefined.

release_ip(IP, [Pool|_]) ->
    gtp_ip_pool:release(Pool, IP).
