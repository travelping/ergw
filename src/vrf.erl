%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(vrf).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_link/2, start_vrf/2, allocate_pdp_ip/4, release_pdp_ip/3,
	 validate_options/1, validate_option/2,
	 validate_name/1, normalize_name/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 get_opts/1, terminate/2, code_change/3]).

-include("include/ergw.hrl").

-record(state, {ip4_pools, ip6_pools, opts}).

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

-define(ZERO_IPv4, {0,0,0,0}).
-define(ZERO_IPv6, {0,0,0,0,0,0,0,0}).
-define(UE_INTERFACE_ID, {0,0,0,0,0,0,0,1}).

%%====================================================================
%% API
%%====================================================================

start_vrf(Name, Opts0)
  when is_binary(Name) ->
    Opts = validate_options(Opts0),
    vrf_sup:start_vrf(Name, Opts).

start_link(VRF, Opts) ->
    gen_server:start_link(?MODULE, [VRF, Opts], []).

allocate_pdp_ip(VRF, TEI, IPv4, IPv6) ->
    Req = {allocate_pdp_ip, TEI, normalize_ipv4(IPv4), normalize_ipv6(IPv6)},
    with_vrf(VRF, gen_server:call(_, Req)).
release_pdp_ip(VRF, IPv4, IPv6) ->
    Req = {release_pdp_ip, normalize_ipv4(IPv4), normalize_ipv6(IPv6)},
    with_vrf(VRF, gen_server:call(_, Req)).

get_opts(VRF) ->
    with_vrf(VRF, gen_server:call(_, get_opts)).

with_vrf(VRF, Fun) when is_binary(VRF), is_function(Fun, 1) ->
    case vrf_reg:lookup(VRF) of
	Pid when is_pid(Pid) ->
	    Fun(Pid);
	_ ->
	    {error, not_found}
    end.

validate_options(Options) ->
    lager:debug("VRF Options: ~p", [Options]),
    ergw_config:validate_options(fun validate_option/2, Options, [], map).

validate_ip_pool({Start, End, PrefixLen} = Pool)
  when ?IS_IPv4(Start), ?IS_IPv4(End), End > Start,
       is_integer(PrefixLen), PrefixLen > 0, PrefixLen =< 32 ->
    Pool;
validate_ip_pool({Start, End, PrefixLen} = Pool)
  when ?IS_IPv6(Start), ?IS_IPv6(End), End > Start,
       is_integer(PrefixLen), PrefixLen > 0, PrefixLen =< 128 ->
    if PrefixLen =:= 127 ->
	    lager:warning("a /127 IPv6 prefix is not supported"),
	    throw({error, {options, {pool, Pool}}});
       PrefixLen =/= 64 ->
	    lager:warning("3GPP only supports /64 IPv6 prefix assigment, "
			  "/~w might not work, USE AT YOUR OWN RISK!", [PrefixLen]),
	    Pool;
       true ->
	    Pool
    end;
validate_ip_pool(Pool) ->
    throw({error, {options, {pool, Pool}}}).

validate_ip6(_Opt, {_,_,_,_,_,_,_,_} = IP) ->
    IP;
validate_ip6(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_option(pools, Pools)
  when is_list(Pools), length(Pools) /= 0 ->
    [validate_ip_pool(X) || X <- Pools];
validate_option(Opt, {_,_,_,_} = IP)
  when Opt == 'MS-Primary-DNS-Server';
       Opt == 'MS-Secondary-DNS-Server';
       Opt == 'MS-Primary-NBNS-Server';
       Opt == 'MS-Secondary-NBNS-Server' ->
    IP;
validate_option(Opt, DNS)
  when is_list(DNS) andalso
       (Opt == 'DNS-Server-IPv6-Address' orelse
	Opt == '3GPP-IPv6-DNS-Servers') ->
    [validate_ip6(Opt, IP) || IP <- DNS];
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_name(Name) ->
    try
	normalize_name(Name)
    catch
	_:_ ->
	    throw({error, {options, {vrf, Name}}})
    end.

normalize_name(Name)
  when is_atom(Name) ->
    List = binary:split(atom_to_binary(Name, latin1), [<<".">>], [global, trim_all]),
    normalize_name(List);
normalize_name([Label | _] = Name)
  when is_binary(Label) ->
    << <<(size(L)):8, L/binary>> || L <- Name >>;
normalize_name(Name)
  when is_list(Name) ->
    List = binary:split(list_to_binary(Name), [<<".">>], [global, trim_all]),
    normalize_name(List);
normalize_name(Name)
  when is_binary(Name) ->
    Name.

printable_name(Name) when is_binary(Name) ->
    L = [ Part || <<Len:8, Part:Len/bytes>> <= Name ],
    unicode:characters_to_binary(lists:join($., L));
printable_name(Name) ->
    unicode:characters_to_binary(io_lib:format("~p", [Name])).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, Opts]) ->
    vrf_reg:register(normalize_name(Name)),

    VrfPoolName = printable_name(Name),
    Pools = maps:get(pools, Opts, []),
    IPv4pools = [{PrefixLen, init_pool(VrfPoolName, X)} ||
		    {First, _Last, PrefixLen} = X <- Pools, size(First) == 4],
    IPv6pools = [{PrefixLen, init_pool(VrfPoolName, X)} ||
		    {First, _Last, PrefixLen} = X <- Pools, size(First) == 8],

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

normalize_ipv4({IP, PLen} = Addr)
  when ?IS_IPv4(IP), is_integer(PLen), PLen > 0, PLen =< 32 ->
    Addr;
normalize_ipv4(IP) when ?IS_IPv4(IP) ->
    {IP, 32};
normalize_ipv4(undefined) ->
    undefined.

normalize_ipv6({?ZERO_IPv6, 0}) ->
    {?ZERO_IPv6, 64};
normalize_ipv6({IP, PLen} = Addr)
  when ?IS_IPv6(IP), is_integer(PLen), PLen > 0, PLen =< 128 ->
    Addr;
normalize_ipv6(IP) when ?IS_IPv6(IP) ->
    {IP, 64};
normalize_ipv6(undefined) ->
    undefined.

alloc_ipv4(TEI, {ReqIPv4, PrefixLen}, #state{ip4_pools = Pools}) ->
    case ReqIPv4 of
	?ZERO_IPv4 ->
	    alloc_prefix(TEI, PrefixLen, Pools);
	_ ->
	    alloc_prefix(TEI, ReqIPv4, PrefixLen, Pools)
    end;
alloc_ipv4(_TEI, _ReqIPv4, _State) ->
    undefined.

alloc_ipv6(TEI, {ReqIPv6, PrefixLen}, #state{ip6_pools = Pools}) ->
    case ReqIPv6 of
	?ZERO_IPv6 ->
	    ergw_inet:ipv6_interface_id(alloc_prefix(TEI, PrefixLen, Pools), ?UE_INTERFACE_ID);
	_ ->
	    ergw_inet:ipv6_interface_id(alloc_prefix(TEI, ReqIPv6, PrefixLen, Pools), ReqIPv6)
    end;
alloc_ipv6(_TEI, _ReqIPv6, _State) ->
    undefined.

release_ipv4({IPv4, PrefixLen}, #state{ip4_pools = Pools}) ->
    release_ip(IPv4, PrefixLen, Pools);
release_ipv4(_IP, _State) ->
    ok.

release_ipv6({IPv6, PrefixLen}, #state{ip6_pools = Pools}) ->
    release_ip(IPv6, PrefixLen, Pools);
release_ipv6(_IP, _State) ->
    ok.

init_pool(Name, X) ->
    %% TODO: to supervise or not to supervise??????
    {ok, Pid} = gtp_ip_pool:start_link(Name, X, []),
    Pid.

with_pool(Fun, PrefixLen, Pools) ->
    case lists:keyfind(PrefixLen, 1, Pools) of
	{_, Pool} ->
	    case Fun(Pool) of
		{ok, IP} ->
		    IP;
		_Other ->
		    undefined
	    end;
	_ ->
	    lager:error("no pool"),
	    undefined
    end.

alloc_prefix(TEI, PrefixLen, Pools) ->
    with_pool(fun(Pool) -> gtp_ip_pool:allocate(Pool, TEI) end, PrefixLen, Pools).

alloc_prefix(TEI, IP, PrefixLen, Pools) ->
    with_pool(fun(Pool) -> gtp_ip_pool:take(Pool, TEI, IP) end, PrefixLen, Pools).

release_ip(IP, PrefixLen, Pools) ->
    case lists:keyfind(PrefixLen, 1, Pools) of
	{_, Pool} ->
	    gtp_ip_pool:release(Pool, IP);
	_ ->
	    ok
    end.
