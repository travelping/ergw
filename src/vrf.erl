%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU Lesser General Public License
%% as published by the Free Software Foundation; either version
%% 3 of the License, or (at your option) any later version.

-module(vrf).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_link/2, start_vrf/2, allocate_pdp_ip/4, release_pdp_ip/3,
	 validate_options/1, validate_option/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 get_opts/1, terminate/2, code_change/3]).

-include("include/ergw.hrl").

-record(state, {ip4_pools, ip6_pools, opts}).

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

%%====================================================================
%% API
%%====================================================================

start_vrf(Name, Opts0)
  when is_atom(Name) ->
    Opts = validate_options(Opts0),
    vrf_sup:start_vrf(Name, Opts).

start_link(VRF, Opts) ->
    gen_server:start_link(?MODULE, [VRF, Opts], []).

allocate_pdp_ip(VRF, TEI, IPv4, IPv6) ->
    with_vrf(VRF, gen_server:call(_, {allocate_pdp_ip, TEI, IPv4, IPv6})).
release_pdp_ip(VRF, IPv4, IPv6) ->
    with_vrf(VRF, gen_server:call(_, {release_pdp_ip, IPv4, IPv6})).

get_opts(VRF) ->
    with_vrf(VRF, gen_server:call(_, get_opts)).

with_vrf(VRF, Fun) when is_atom(VRF), is_function(Fun, 1) ->
    case vrf_reg:lookup(VRF) of
	Pid when is_pid(Pid) ->
	    Fun(Pid);
	_ ->
	    {error, not_found}
    end.

validate_options(Options) ->
    lager:debug("VRF Options: ~p", [Options]),
    ergw_config:validate_options(fun validate_option/2, Options, [], map).

validate_option(pools, Value) when is_list(Value) ->
    Value;
validate_option(Opt, {_,_,_,_} = IP)
  when Opt == 'MS-Primary-DNS-Server';
       Opt == 'MS-Secondary-DNS-Server';
       Opt == 'MS-Primary-NBNS-Server';
       Opt == 'MS-Secondary-NBNS-Server' ->
    IP;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, Opts]) ->
    vrf_reg:register(Name),

    Pools = maps:get(pools, Opts, []),
    IPv4pools = [{PrefixLen, init_pool(X)} || {First, _Last, PrefixLen} = X <- Pools, size(First) == 4],
    IPv6pools = [{PrefixLen, init_pool(X)} || {First, _Last, PrefixLen} = X <- Pools, size(First) == 8],

    lager:debug("IPv4Pools ~p", [IPv4pools]),
    lager:debug("IPv6Pools ~p", [IPv6pools]),

    VrfOpts = maps:without([pools], Opts),
    State = #state{ip4_pools = IPv4pools, ip6_pools = IPv6pools, opts = VrfOpts},
    {ok, State}.

handle_call(get_opts, _From, #state{opts = Opts} = State) ->
    {reply, {ok, Opts}, State};

handle_call({allocate_pdp_ip, TEI, ReqIPv4, ReqIPv6} = Request, _From, State) ->
    lager:debug("handle_call: ~p", [Request]),
    IPv4 = alloc_ipv4(TEI, ReqIPv4, State),
    IPv6 = alloc_ipv6(TEI, ReqIPv6, State),
    {reply, {ok, IPv4, IPv6}, State};

handle_call({release_pdp_ip, IPv4, IPv6} = Request, _From, State) ->
    lager:debug("handle_call: ~p", [Request]),
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
    alloc_ip(TEI, 32, Pools);
alloc_ipv4(TEI, {{0,0,0,0},PrefixLen}, #state{ip4_pools = Pools}) ->
    alloc_ip(TEI, PrefixLen, Pools);
alloc_ipv4(_TEI, {_,_,_,_} = ReqIPv4, _State) ->
    %% check if the IP falls into one of our pool and mark a allocate if so
    {ReqIPv4, 32};
alloc_ipv4(_TEI, {{_,_,_,_},_} = ReqIPv4, _State) ->
    %% check if the IP falls into one of our pool and mark a allocate if so
    ReqIPv4.

alloc_ipv6(_TEI, undefined, _State) ->
    undefined;
alloc_ipv6(TEI, {{0,0,0,0,0,0,0,0},PrefixLen}, #state{ip6_pools = Pools}) ->
    alloc_ip(TEI, PrefixLen, Pools);
alloc_ipv6(_TEI, {{_,_,_,_,_,_,_,_},_} = ReqIPv6, _State) ->
    lager:error("alloc IPv6 not implemented"),
    %% check if the IP falls into one of our pool and mark a allocated if so
    ReqIPv6.

release_ipv4({IPv4, PrefixLen}, #state{ip4_pools = Pools})
  when ?IS_IPv4(IPv4)->
    release_ip(IPv4, PrefixLen, Pools);
release_ipv4(IPv4, #state{ip4_pools = Pools})
  when ?IS_IPv4(IPv4) ->
    release_ip(IPv4, 32, Pools);
release_ipv4(_IP, _State) ->
    ok.

release_ipv6({IPv6, PrefixLen}, #state{ip6_pools = Pools})
  when ?IS_IPv6(IPv6) ->
    release_ip(IPv6, PrefixLen, Pools);
release_ipv6(_IP, _State) ->
    ok.

init_pool(X) ->
    %% TODO: to supervise or not to supervise??????
    {ok, Pid} = gtp_ip_pool:start_link(X, []),
    Pid.

alloc_ip(TEI, PrefixLen, Pools) ->
    case lists:keyfind(PrefixLen, 1, Pools) of
	{_, Pool} ->
	    case gtp_ip_pool:allocate(Pool, TEI) of
		{ok, IP} ->
		    IP;
		_Other ->
		    undefined
	    end;
	_ ->
	    lager:error("no pool"),
	    undefined
    end.

release_ip(IP, PrefixLen, Pools) ->
    case lists:keyfind(PrefixLen, 1, Pools) of
	{_, Pool} ->
	    gtp_ip_pool:release(Pool, IP);
	_ ->
	    ok
    end.
