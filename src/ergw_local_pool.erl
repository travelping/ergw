%% Copyright 2015-2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_local_pool).

-behavior(gen_server).

%% API
-export([start_ip_pool/2, send_pool_request/2, wait_pool_response/1, release/1,
	 ip/1, opts/1, timeouts/1]).
-export([start_link/3, start_link/4]).
-export([validate_options/1, validate_option/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {name, pools, ipv4_opts, ipv6_opts}).
-record(pool,  {name, type, id, first, last, shift, used, free, used_pool, free_pool}).
-record(lease, {ip, client_id}).

-include_lib("kernel/include/logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

-define(ZERO_IPv4, {0,0,0,0}).
-define(ZERO_IPv6, {0,0,0,0,0,0,0,0}).
-define(UE_INTERFACE_ID, {0,0,0,0,0,0,0,1}).

-define(DefaultOptions, [{handler, ?MODULE}, {ranges, []}]).
-define(IPv4Opts, ['Framed-Pool',
		   'MS-Primary-DNS-Server',
		   'MS-Secondary-DNS-Server',
		   'MS-Primary-NBNS-Server',
		   'MS-Secondary-NBNS-Server']).
-define(IPv6Opts, ['Framed-IPv6-Pool',
		   'DNS-Server-IPv6-Address',
		   '3GPP-IPv6-DNS-Servers']).

%%====================================================================
%% API
%%====================================================================

start_ip_pool(Name, Opts0)
  when is_binary(Name) ->
    Opts = validate_options(Opts0),
    ergw_ip_pool_sup:start_local_pool_sup(),
    ergw_local_pool_sup:start_ip_pool(Name, Opts).

start_link(PoolName, Pool, Opts) ->
    gen_server:start_link(?MODULE, [PoolName, Pool], Opts).

start_link(ServerName, PoolName, Pool, Opts) ->
    gen_server:start_link(ServerName, ?MODULE, [PoolName, Pool], Opts).

send_pool_request(ClientId, {Pool, IP, PrefixLen, Opts}) when is_pid(Pool) ->
    send_request(Pool, {get, ClientId, IP, PrefixLen, Opts});
send_pool_request(ClientId, {Pool, IP, PrefixLen, Opts}) ->
    send_request(ergw_local_pool_reg:lookup(Pool), {get, ClientId, IP, PrefixLen, Opts}).

wait_pool_response(ReqId) ->
    case wait_response(ReqId, 1000) of
	%% {reply, {error, _}} ->
	%%     undefined;
	{reply, Reply} ->
	    Reply;
	timeout ->
	    undefined;
	{error, _} ->
	    undefined
    end.

release({_, Server, {IP, _}, Pool, _Opts}) ->
    %% see alloc_reply
    gen_server:cast(Server, {release, IP, Pool}).

-if(OTP_RELEASE >= 23).
send_request(Server, Request) ->
    gen_server:send_request(Server, Request).

wait_response(Mref, Timeout) ->
    gen_server:wait_response(Mref, Timeout).
-else.
send_request(Server, Request) ->
    ReqF = fun() -> exit({reply, gen_server:call(Server, Request)}) end,
    try spawn_monitor(ReqF) of
	{_, Mref} -> Mref
    catch
	error: system_limit = E ->
	    %% Make send_request async and fake a down message
	    Ref = erlang:make_ref(),
	    self() ! {'DOWN', Ref, process, Server, {error, E}},
	    Ref
    end.

wait_response(Mref, Timeout)
  when is_reference(Mref) ->
    receive
	{'DOWN', Mref, _, _, Reason} ->
	    Reason
    after Timeout ->
	    timeout
    end.

-endif.

ip({?MODULE, _, IP, _, _}) -> IP.
opts({?MODULE, _, _, _, Opts}) -> Opts.
timeouts({?MODULE, _, _, _, _}) ->
    {infinity, infinity, infinity}.

%%====================================================================
%%% Options Validation
%%%===================================================================

validate_options(Options) ->
    ?LOG(debug, "IP Pool Options: ~p", [Options]),
    ergw_config:validate_options(fun validate_option/2, Options, ?DefaultOptions, map).

validate_ip_range({Start, End, PrefixLen} = Range)
  when ?IS_IPv4(Start), ?IS_IPv4(End), End > Start,
       is_integer(PrefixLen), PrefixLen > 0, PrefixLen =< 32 ->
    Range;
validate_ip_range({Start, End, PrefixLen} = Range)
  when ?IS_IPv6(Start), ?IS_IPv6(End), End > Start,
       is_integer(PrefixLen), PrefixLen > 0, PrefixLen =< 128 ->
    if PrefixLen =:= 127 ->
	    ?LOG(warning, "a /127 IPv6 prefix is not supported"),
	    throw({error, {options, {range, Range}}});
       PrefixLen =/= 64 ->
	    ?LOG(warning, "3GPP only supports /64 IPv6 prefix assigment, "
		 "/~w might not work, USE AT YOUR OWN RISK!", [PrefixLen]),
	    Range;
       true ->
	    Range
    end;
validate_ip_range(Range) ->
    throw({error, {options, {range, Range}}}).

validate_option(ranges, Ranges)
  when is_list(Ranges), length(Ranges) /= 0 ->
    [validate_ip_range(X) || X <- Ranges];
validate_option(Opt, Value)
  when Opt == 'MS-Primary-DNS-Server';   Opt == 'MS-Secondary-DNS-Server';
       Opt == 'MS-Primary-NBNS-Server';  Opt == 'MS-Secondary-NBNS-Server';
       Opt == 'DNS-Server-IPv6-Address'; Opt == '3GPP-IPv6-DNS-Servers' ->
    ergw_config:validate_ip_cfg_opt(Opt, Value);
validate_option(Opt, Pool)
  when Opt =:= 'Framed-Pool';
       Opt =:= 'Framed-IPv6-Pool' ->
    ergw_ip_pool:validate_name(Opt, Pool);
validate_option(handler, Value) ->
    Value;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, #{ranges := Ranges} = Opts]) ->
    ergw_local_pool_reg:register(Name),
    Pools = init_pools(Name, Ranges),
    ?LOG(debug, "init Pool state: ~p", [Pools]),
    State = #state{
	       name = Name,
	       pools = Pools,
	       ipv4_opts = maps:with(?IPv4Opts, Opts),
	       ipv6_opts = maps:with(?IPv6Opts, Opts)
	      },
    {ok, State}.

init_pools(Name, Ranges) ->
    lists:foldl(
      fun({First, Last, PrefixLen}, Pools)
	    when ?IS_IPv4(First), ?IS_IPv4(Last),
		 is_integer(PrefixLen), PrefixLen =< 32,
		 not is_map_key({ipv4, PrefixLen}, Pools) ->
	      Pools#{{ipv4, PrefixLen} =>
			 init_pool(Name, ipv4, ip2int(First), ip2int(Last), 32 - PrefixLen)};
	 ({First, Last, PrefixLen}, Pools)
	    when ?IS_IPv6(First), ?IS_IPv6(Last),
		 is_integer(PrefixLen), PrefixLen =< 128,
		 not is_map_key({ipv6, PrefixLen}, Pools) ->
	      Pools#{{ipv6, PrefixLen} =>
			 init_pool(Name, ipv6, ip2int(First), ip2int(Last), 128 - PrefixLen)};
	 (_, Pools) ->
	      Pools
      end, #{}, Ranges).

init_table(_tetTid, Start, End)
  when Start > End ->
    ok;
init_table(Tid, Start, End) ->
    ets:insert(Tid, #lease{ip = Start}),
    init_table(Tid, Start + 1, End).

handle_call({get, ClientId, Type, PrefixLen, ReqOpts}, _From, #state{pools = Pools} = State)
  when is_atom(Type), is_map_key({Type, PrefixLen}, Pools) ->
    Key = {Type, PrefixLen},
    {Result, Pool} = allocate_ip(ClientId, ReqOpts, maps:get(Key, Pools)),
    ?LOG(debug, "~w: Allocate IPv: ~p -> ~p, Pool: ~p", [self(), ClientId, Result, Pool]),
    Reply = alloc_reply(Result, Key, State),
    {reply, Reply, State#state{pools = maps:put(Key, Pool, Pools)}};

handle_call({get, ClientId, ReqIP, PrefixLen, ReqOpts}, _From, #state{pools = Pools} = State)
  when is_tuple(ReqIP) ->
    Key = {type(ReqIP), PrefixLen},
    {Result, Pool} =
	take_ip(ClientId, ip2int(ReqIP), ReqOpts, maps:get(Key, Pools, undefined)),
    Reply = alloc_reply(Result, Key, State),
    {reply, Reply, State#state{pools = maps:put(Key, Pool, Pools)}};

handle_call(Request, _From, State) ->
    ?LOG(warning, "handle_call: ~p", [Request]),
    {reply, error, State}.

handle_cast({release, IP, Key}, #state{pools = Pools} = State) ->
    Pool = release_ip(ip2int(IP), maps:get(Key, Pools, undefined)),
    {noreply, State#state{pools = maps:put(Key, Pool, Pools)}};

handle_cast(Msg, State) ->
    ?LOG(debug, "handle_cast: ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    ?LOG(debug, "handle_info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
ip2int({A, B, C, D}) ->
    (A bsl 24) + (B bsl 16) + (C bsl 8) + D;
ip2int({A, B, C, D, E, F, G, H}) ->
    (A bsl 112) + (B bsl 96) + (C bsl 80) + (D bsl 64) +
	(E bsl 48) + (F bsl 32) + (G bsl 16) + H.

int2ip(ipv4, IP) ->
    <<A:8, B:8, C:8, D:8>> = <<IP:32>>,
    {A, B, C, D};
int2ip(ipv6, IP) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>> = <<IP:128>>,
    {A, B, C, D, E, F, G, H}.

id2ip(Id, _ReqOpts, #pool{type = ipv4, shift = Shift}) ->
    {int2ip(ipv4, Id bsl Shift), 32 - Shift};
id2ip(Id, #{'Framed-Interface-Id' := IfId}, #pool{type = ipv6, shift = Shift}) ->
    IP = {int2ip(ipv6, Id bsl Shift), 128 - Shift},
    ergw_inet:ipv6_interface_id(IP, IfId);
id2ip(Id, _ReqOpts, #pool{type = ipv6, shift = Shift}) ->
    {int2ip(ipv6, Id bsl Shift), 128 - Shift}.

type(IP) when ?IS_IPv4(IP) -> ipv4;
type(IP) when ?IS_IPv6(IP) -> ipv6.

%%%===================================================================
%%% Pool functions
%%%===================================================================

alloc_reply({ok, {IP, _} = IPv4}, Pool, #state{ipv4_opts = Opts}) when ?IS_IPv4(IP) ->
    {?MODULE, self(), IPv4, Pool, Opts};
alloc_reply({ok, {IP, _} = IPv6}, Pool, #state{ipv6_opts = Opts}) when ?IS_IPv6(IP) ->
    {?MODULE, self(), IPv6, Pool, Opts};
alloc_reply({error, _} = Error, _, _) ->
    Error.

init_pool(Name, Type, First, Last, Shift) ->
    UsedTid = ets:new(used_pool, [set, {keypos, #lease.ip}]),
    FreeTid = ets:new(free_pool, [set, {keypos, #lease.ip}]),

    Id = inet:ntoa(int2ip(Type, First)),
    Start = First bsr Shift,
    End = Last bsr Shift,
    Size = End - Start + 1,
    ?LOG(debug, "init Pool ~w ~p - ~p (~p)", [Id, Start, End, Size]),
    init_table(FreeTid, Start, End),

    prometheus_gauge:declare([{name, ergw_local_pool_free},
			      {labels, [name, type, id]},
			      {help, "Free IP addresses in pool"}]),
    prometheus_gauge:declare([{name, ergw_local_pool_used},
			      {labels, [name, type, id]},
			      {help, "Used IP addresses in pool"}]),

    Pool = #pool{
	      name = Name, type = Type, id = Id,
	      first = First, last = Last, shift = Shift,
	      used = 0, free = Size,
	      used_pool = UsedTid, free_pool = FreeTid},
    metrics_sync_gauges(Pool),
    ?LOG(debug, "init Pool state: ~p", [Pool]),
    Pool.

allocate_ip(ClientId, ReqOpts,
	    #pool{used = Used, free = Free,
		  used_pool = UsedTid, free_pool = FreeTid} = Pool0)
  when Free =/= 0 ->
    ?LOG(debug, "~w: Allocate Pool: ~p", [self(), Pool0]),

    Id = ets:first(FreeTid),
    ets:delete(FreeTid, Id),
    ets:insert(UsedTid, #lease{ip = Id, client_id = ClientId}),
    IP = id2ip(Id, ReqOpts, Pool0),
    Pool = Pool0#pool{used = Used + 1, free = Free - 1},
    metrics_sync_gauges(Pool),
    {{ok, IP}, Pool};
allocate_ip(_ClientId, _ReqOpts, Pool) ->
    {{error, empty}, Pool}.

release_ip(IP, #pool{first = First, last = Last,
		      shift = Shift,
		      used = Used, free = Free,
		      used_pool = UsedTid, free_pool = FreeTid} = Pool0)
  when IP >= First andalso IP =< Last ->
    Id = IP bsr Shift,

    case ets:take(UsedTid, Id) of
	[_] ->
	    ets:insert(FreeTid, #lease{ip = Id}),
	    Pool = Pool0#pool{used = Used - 1, free = Free + 1},
	    metrics_sync_gauges(Pool),
	    Pool;
	_ ->
	    ?LOG(warning, "release of unallocated IP: ~p", [id2ip(Id, #{}, Pool0)]),
	    Pool0
    end;
release_ip(IP, #pool{type = Type, first = First, last = Last} = Pool) ->
    ?LOG(warning, "release of out-of-pool IP: ~w < ~w < ~w",
	 [int2ip(Type, First), int2ip(Type, IP), int2ip(Type, Last)]),
    Pool;
release_ip(_IP, Pool) ->
    Pool.

take_ip(ClientId, IP, ReqOpts,
	#pool{first = First, last = Last,
	      shift = Shift,
	      used = Used, free = Free,
	      used_pool = UsedTid, free_pool = FreeTid} = Pool0)
  when IP >= First andalso IP =< Last ->
    Id = IP bsr Shift,

    case ets:take(FreeTid, Id) of
	[_] ->
	    ets:insert(UsedTid, #lease{ip = Id, client_id = ClientId}),
	    Pool = Pool0#pool{used = Used + 1, free = Free - 1},
	    metrics_sync_gauges(Pool),
	    {{ok, id2ip(Id, ReqOpts, Pool)}, Pool};
	_ ->
	    ?LOG(warning, "attempt to take already allocated IP: ~p",
		 [id2ip(Id, ReqOpts, Pool0)]),
	    {{error, taken}, Pool0}
    end;
take_ip(_ClientId, IP, _ReqOpts, #pool{type = Type, first = First, last = Last} = Pool) ->
    ?LOG(warning, "attempt to take of out-of-pool IP: ~w < ~w < ~w",
	 [int2ip(Type, First), int2ip(Type, IP), int2ip(Type, Last)]),
    {{error, out_of_pool}, Pool};
take_ip(_ClientId, _IP, _ReqOpts, Pool) ->
    {{error, out_of_pool}, Pool}.

%%%===================================================================
%%% metrics functions
%%%===================================================================

metrics_sync_gauges(#pool{name = Name, type = Type, id = Id,
		       used = Used, free = Free}) ->
    prometheus_gauge:set(ergw_local_pool_free, [Name, Type, Id], Free),
    prometheus_gauge:set(ergw_local_pool_used, [Name, Type, Id], Used),
    ok.
