%% Copyright 2015-2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_ip_pool).

-behavior(gen_server).

%% API
-export([start_ip_pool/2, get/4, release/3, opts/2]).
-export([start_link/3, start_link/4]).
-export([validate_options/1, validate_option/2, validate_name/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {name, pools}).
-record(pool,  {name, type, id, first, last, shift, used, free, used_pool, free_pool}).
-record(lease, {ip, client_id}).

-include_lib("kernel/include/logger.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

-define(ZERO_IPv4, {0,0,0,0}).
-define(ZERO_IPv6, {0,0,0,0,0,0,0,0}).
-define(UE_INTERFACE_ID, {0,0,0,0,0,0,0,1}).

-define(DefaultOptions, [{ranges, []}]).
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
    ergw_ip_pool_sup:start_ip_pool(Name, Opts).

start_link(PoolName, Pool, Opts) ->
    gen_server:start_link(?MODULE, [PoolName, Pool], Opts).

start_link(ServerName, PoolName, Pool, Opts) ->
    gen_server:start_link(ServerName, ?MODULE, [PoolName, Pool], Opts).

get(Server, ClientId, IP, PrefixLen) when is_pid(Server) ->
    gen_server:call(Server, {get, ClientId, IP, PrefixLen});
get(Pool, ClientId, IP, PrefixLen) ->
    call(ergw_ip_pool_reg:lookup(Pool), {get, ClientId, IP, PrefixLen}, {error, undefined}).

release(Server, IP, PrefixLen) when is_pid(Server) ->
    gen_server:call(Server, {release, IP, PrefixLen});
release(Pool, IP, PrefixLen) ->
    call(ergw_ip_pool_reg:lookup(Pool), {release, IP, PrefixLen}, ok).

call(Server, Call, _) when is_pid(Server) ->
    gen_server:call(Server, Call);
call(_S, _, Default) ->
    Default.

opts(Type, Pool) ->
    try
	{ok, Pools} = application:get_env(ergw, ip_pools),
	PoolOpts0 = maps:get(Pool, Pools),
	PoolOpts = PoolOpts0#{name => Pool},
	case Type of
	    ipv4 -> maps:with(?IPv4Opts, PoolOpts);
	    ipv6 -> maps:with(?IPv6Opts, PoolOpts)
	end
    catch
	error:{badkey, _} ->
	    #{}
    end.

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
    validate_name(Opt, Pool);
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_name(_, Name) when is_binary(Name) ->
    Name;
validate_name(_, Name) when is_list(Name) ->
    unicode:characters_to_binary(Name, utf8);
validate_name(_, Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8);
validate_name(Opt, Name) ->
   throw({error, {options, {Opt, Name}}}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, #{ranges := Ranges}]) ->
    ergw_ip_pool_reg:register(Name),
    Pools = init_pools(Name, Ranges),
    ?LOG(debug, "init Pool state: ~p", [Pools]),
    {ok, #state{name = Name, pools = Pools}}.

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

handle_call({get, ClientId, Type, PrefixLen}, _From, #state{pools = Pools} = State)
  when is_atom(Type), is_map_key({Type, PrefixLen}, Pools) ->
    Key = {Type, PrefixLen},
    {Response, Pool} = allocate_ip(ClientId, maps:get(Key, Pools)),
    ?LOG(debug, "~w: Allocate IPv: ~p -> ~p, Pool: ~p", [self(), ClientId, Response, Pool]),
    {reply, Response, State#state{pools = maps:put(Key, Pool, Pools)}};

handle_call({get, ClientId, ReqIP, PrefixLen}, _From, #state{pools = Pools} = State)
  when is_tuple(ReqIP) ->
    Key = {type(ReqIP), PrefixLen},
    {Reply, Pool} = take_ip(ClientId, ip2int(ReqIP), maps:get(Key, Pools, undefined)),
    {reply, Reply, State#state{pools = maps:put(Key, Pool, Pools)}};

%% WTF???
%% handle_call({get, _ClientId, _Type, _PrefixLen}, _From, State) ->
%%     {reply, {error, invalid}, State};

handle_call({release, IP, PrefixLen}, _From, #state{pools = Pools} = State) ->
    Key = {type(IP), PrefixLen},
    Pool = release_ip(ip2int(IP), maps:get(Key, Pools, undefined)),
    {reply, ok, State#state{pools = maps:put(Key, Pool, Pools)}};

handle_call(Request, _From, State) ->
    ?LOG(warning, "handle_call: ~p", [Request]),
    {reply, error, State}.

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

id2ip(Id, #pool{type = ipv4, shift = Shift}) ->
    {int2ip(ipv4, Id bsl Shift), 32 - Shift};
id2ip(Id, #pool{type = ipv6, shift = Shift}) ->
    {int2ip(ipv6, Id bsl Shift), 128 - Shift}.

type(IP) when ?IS_IPv4(IP) -> ipv4;
type(IP) when ?IS_IPv6(IP) -> ipv6.

%%%===================================================================
%%% Pool functions
%%%===================================================================

init_pool(Name, Type, First, Last, Shift) ->
    UsedTid = ets:new(used_pool, [set, {keypos, #lease.ip}]),
    FreeTid = ets:new(free_pool, [set, {keypos, #lease.ip}]),

    Id = inet:ntoa(int2ip(Type, First)),
    Start = First bsr Shift,
    End = Last bsr Shift,
    Size = End - Start + 1,
    ?LOG(debug, "init Pool ~w ~p - ~p (~p)", [Id, Start, End, Size]),
    init_table(FreeTid, Start, End),

    prometheus_gauge:declare([{name, ergw_ip_pool_free},
			      {labels, [name, type, id]},
			      {help, "Free IP addresses in pool"}]),
    prometheus_gauge:declare([{name, ergw_ip_pool_used},
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

allocate_ip(ClientId, #pool{used = Used, free = Free,
			 used_pool = UsedTid, free_pool = FreeTid} = Pool0)
  when Free =/= 0 ->
    ?LOG(debug, "~w: Allocate Pool: ~p", [self(), Pool0]),

    Id = ets:first(FreeTid),
    ets:delete(FreeTid, Id),
    ets:insert(UsedTid, #lease{ip = Id, client_id = ClientId}),
    IP = id2ip(Id, Pool0),
    Pool = Pool0#pool{used = Used + 1, free = Free - 1},
    metrics_sync_gauges(Pool),
    {{ok, IP}, Pool};
allocate_ip(_ClientId, Pool) ->
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
	    ?LOG(warning, "release of unallocated IP: ~p", [id2ip(Id, Pool0)]),
	    Pool0
    end;
release_ip(IP, #pool{type = Type, first = First, last = Last} = Pool) ->
    ?LOG(warning, "release of out-of-pool IP: ~w < ~w < ~w",
	 [int2ip(Type, First), int2ip(Type, IP), int2ip(Type, Last)]),
    Pool;
release_ip(_IP, Pool) ->
    Pool.

take_ip(ClientId, IP, #pool{first = First, last = Last,
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
	    {{ok, id2ip(Id, Pool)}, Pool};
	_ ->
	    ?LOG(warning, "attempt to take already allocated IP: ~p", [id2ip(Id, Pool0)]),
	    {{error, taken}, Pool0}
    end;
take_ip(_ClientId, IP, #pool{type = Type, first = First, last = Last} = Pool) ->
    ?LOG(warning, "attempt to take of out-of-pool IP: ~w < ~w < ~w",
	 [int2ip(Type, First), int2ip(Type, IP), int2ip(Type, Last)]),
    {{error, out_of_pool}, Pool};
take_ip(_ClientId, _IP, Pool) ->
    {{error, out_of_pool}, Pool}.

%%%===================================================================
%%% metrics functions
%%%===================================================================

metrics_sync_gauges(#pool{name = Name, type = Type, id = Id,
		       used = Used, free = Free}) ->
    prometheus_gauge:set(ergw_ip_pool_free, [Name, Type, Id], Free),
    prometheus_gauge:set(ergw_ip_pool_used, [Name, Type, Id], Used),
    ok.
