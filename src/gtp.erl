%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp).

-behavior(gen_server).

%% API
-export([new/2, send/5,
	 create_pdp_context/6,
	 delete_pdp_context/6,
	 allocate_pdp_ip/4,
	 release_pdp_ip/3]).
-export([test/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gtplib/include/gtp_packet.hrl").

-define(GTP0_PORT,	3386).
-define(GTP1c_PORT,	2123).
-define(GTP1u_PORT,	2152).

-record(state, {ip, gtp0, gtp1c, gtp1u, gtp_dev, restart_counter, ip4_pools, ip6_pools}).

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

send(Handler, Type, IP, Port, Data) ->
    gen_server:cast(Handler, {send, Type, IP, Port, Data}).

create_pdp_context(Handler, Version, IP, MS, LocalTEI, RemoteTEI) ->
    gen_server:call(Handler, {create_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}).

delete_pdp_context(Handler, Version, IP, MS, LocalTEI, RemoteTEI) ->
    gen_server:call(Handler, {delete_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}).

allocate_pdp_ip(Handler, TEI, IPv4, IPv6) ->
    gen_server:call(Handler, {allocate_pdp_ip, TEI, IPv4, IPv6}).

release_pdp_ip(Handler, IPv4, IPv6) ->
    gen_server:call(Handler, {release_pdp_ip, IPv4, IPv6}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([IP, Opts]) ->
    Pools = proplists:get_value(pools, Opts, []),
    IPv4pools = [init_pool(X) || {Prefix, _Len} = X <- Pools, size(Prefix) == 4],
    IPv6pools = [init_pool(X) || {Prefix, _Len} = X <- Pools, size(Prefix) == 8],

    lager:debug("IPv4Pools ~p", [IPv4pools]),
    lager:debug("IPv6Pools ~p", [IPv6pools]),

    SocketOpts = [binary, {ip, IP}, {active, true}],
    {ok, GTP0} = gen_udp:open(?GTP0_PORT, SocketOpts),
    {ok, GTP1c} = gen_udp:open(?GTP1c_PORT, SocketOpts),
    {ok, GTP1u} = gen_udp:open(?GTP1u_PORT, SocketOpts),

    {ok, FD0} = inet:getfd(GTP0),
    {ok, FD1u} = inet:getfd(GTP1u),
    {ok, GTPDev} = gtp_kernel:dev_create("gtp0", FD0, FD1u, Opts),
    RCnt = gtp_config:inc_restart_counter(),

    {ok, #state{ip = IP, gtp0 = GTP0, gtp1c = GTP1c, gtp1u = GTP1u,
		gtp_dev = GTPDev, restart_counter = RCnt,
		ip4_pools = IPv4pools, ip6_pools = IPv6pools}}.

handle_call({create_pdp_context, Version, IP, MS, LocalTEI, RemoteTEI}, _From,
	    #state{gtp_dev = GTPDev} = State) ->
    Reply = gtp_kernel:create_pdp_context(GTPDev, Version, IP, MS, LocalTEI, RemoteTEI),
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
    lager:warning("handle_call: ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({send, 'gtp-c', IP, Port, Data}, #state{gtp1c = GTP1c} = State) ->
    gen_udp:send(GTP1c, IP, Port, Data),
    {noreply, State};

handle_cast({send, 'gtp-u', IP, Port, Data}, #state{gtp1u = GTP1u} = State) ->
    gen_udp:send(GTP1u, IP, Port, Data),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:debug("handle_cast: ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info({udp, GTP1c, IP, Port, Data}, #state{gtp1c = GTP1c} = State) ->
    handle_message('gtp-c', IP, Port, Data, State);
handle_info({udp, GTP1u, IP, Port, Data}, #state{gtp1u = GTP1u} = State) ->
    handle_message('gtp-u', IP, Port, Data, State);
handle_info(Info, State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_message(Type, IP, Port, Data, #state{ip = LocalIP} = State) ->
    Msg = gtp_packet:decode(Data),
    Peer = gtp_path:get(Type, IP, self(), LocalIP),
    gtp_path:handle_message(Peer, Port, Msg),
    {noreply, State}.

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
