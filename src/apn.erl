%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(apn).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_link/2, allocate_pdp_ip/4, release_pdp_ip/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("include/ergw.hrl").

-record(state, {ip4_pools, ip6_pools}).

%%====================================================================
%% API
%%====================================================================

start_link(APN, Opts) ->
   gen_server:start_link(?MODULE, [APN, Opts], []).

allocate_pdp_ip(APN, TEI, IPv4, IPv6) ->
    with_apn(APN, gen_server:call(_, {allocate_pdp_ip, TEI, IPv4, IPv6})).
release_pdp_ip(APN, IPv4, IPv6) ->
    with_apn(APN, gen_server:call(_, {release_pdp_ip, IPv4, IPv6})).

with_apn(APN, Fun) when is_function(Fun, 1) ->
    case apn_reg:lookup(APN) of
	Pid when is_pid(Pid) ->
	    Fun(Pid);
	_ ->
	    {error, not_found}
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([APN, Opts]) ->
    apn_reg:register(APN),

    Pools = proplists:get_value(pools, Opts, []),
    IPv4pools = [init_pool(X) || {Prefix, _Len} = X <- Pools, size(Prefix) == 4],
    IPv6pools = [init_pool(X) || {Prefix, _Len} = X <- Pools, size(Prefix) == 8],

    lager:debug("IPv4Pools ~p", [IPv4pools]),
    lager:debug("IPv6Pools ~p", [IPv6pools]),

    {ok, #state{ip4_pools = IPv4pools, ip6_pools = IPv6pools}}.

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

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

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

release_ip(undefined, _) ->
    ok;
release_ip(_IP, []) ->
    ok;
release_ip(IP, [Pool|_]) ->
    gtp_ip_pool:release(Pool, IP).
