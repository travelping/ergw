%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_ip_pool).

-behavior(gen_server).

%% API
-export([start_link/3, start_link/4,
	 allocate/2, take/3, release/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {name, type, id, first, last, shift, used, free, used_pool, free_pool}).
-record(lease, {ip, client_id}).

-include_lib("stdlib/include/ms_transform.hrl").

%%====================================================================
%% API
%%====================================================================

start_link(PoolName, Pool, Opts) ->
    gen_server:start_link(?MODULE, [PoolName, Pool], Opts).

start_link(ServerName, PoolName, Pool, Opts) ->
    gen_server:start_link(ServerName, ?MODULE, [PoolName, Pool], Opts).

allocate(Server, ClientId) ->
    gen_server:call(Server, {allocate, ClientId}).

take(Server, ClientId, IP) ->
    gen_server:call(Server, {take, ClientId, IP}).

release(Server, IP) ->
    gen_server:call(Server, {release, IP}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, {{_,_,_,_} = First, {_,_,_,_} = Last, PrefixLen}])
  when is_integer(PrefixLen),  PrefixLen =< 32 ->
    init(Name, ipv4, ip2int(First), ip2int(Last), 32 - PrefixLen);

init([Name, {{_,_,_,_,_,_,_,_} = First, {_,_,_,_,_,_,_,_} = Last, PrefixLen}])
  when is_integer(PrefixLen), PrefixLen =< 128 ->
    init(Name, ipv6, ip2int(First), ip2int(Last), 128 - PrefixLen).

init(Name, Type, First, Last, Shift) when Last >= First ->
    UsedTid = ets:new(used_pool, [set, {keypos, #lease.ip}]),
    FreeTid = ets:new(free_pool, [set, {keypos, #lease.ip}]),

    Id = inet:ntoa(int2ip(Type, First)),
    Start = First bsr Shift,
    End = Last bsr Shift,
    Size = End - Start + 1,
    lager:debug("init Pool ~w ~p - ~p (~p)", [Id, Start, End, Size]),
    init_table(FreeTid, Start, End),

    prometheus_gauge:declare([{name, ergw_ip_pool_free},
			      {labels, [name, type, id]},
			      {help, "Free IP addresses in pool"}]),
    prometheus_gauge:declare([{name, ergw_ip_pool_used},
			      {labels, [name, type, id]},
			      {help, "Used IP addresses in pool"}]),

    State = #state{name = Name,
		   type = Type,
		   id = Id,
		   first = First,
		   last = Last,
		   shift = Shift,
		   used = 0,
		   free = Size,
		   used_pool = UsedTid,
		   free_pool = FreeTid},
    metrics_sync_gauges(State),
    lager:debug("init Pool state: ~p", [lager:pr(State, ?MODULE)]),
    {ok, State}.

init_table(_tetTid, Start, End)
  when Start > End ->
    ok;
init_table(Tid, Start, End) ->
    ets:insert(Tid, #lease{ip = Start}),
    init_table(Tid, Start + 1, End).

handle_call({allocate, ClientId} = Request, _From,
	    #state{used = Used, free = Free, used_pool = UsedTid, free_pool = FreeTid} = State0)
  when Free =/= 0 ->
    lager:debug("~w: Allocate: ~p, State: ~p",
		[self(), lager:pr(Request, ?MODULE), lager:pr(State0, ?MODULE)]),

    Id = ets:first(FreeTid),
    ets:delete(FreeTid, Id),
    ets:insert(UsedTid, #lease{ip = Id, client_id = ClientId}),
    IP = id2ip(Id, State0),
    State = State0#state{used = Used + 1, free = Free - 1},
    metrics_sync_gauges(State),
    {reply, {ok, IP}, State};

handle_call({allocate, _ClientId}, _From, State) ->
    {reply, {error, full}, State};

handle_call({take, ClientId, ReqIP} = Request, _From, State0) ->
    lager:debug("~w: Allocate: ~p, State: ~p",
		[self(), lager:pr(Request, ?MODULE), lager:pr(State0, ?MODULE)]),
    {Reply, State} = take_ip(ClientId, ip2int(ReqIP), State0),
    {reply, Reply, State};

handle_call({release, {_,_,_,_} = IPv4} = Request, _From, State0) ->
    State = release_ip(ip2int(IPv4), State0),
    lager:debug("~w: Release: ~p, State: ~p",
		[self(), lager:pr(Request, ?MODULE), lager:pr(State, ?MODULE)]),
    {reply, ok, State};
handle_call({release, {{_,_,_,_} = IPv4,_}} = Request, _From, State0) ->
    State = release_ip(ip2int(IPv4), State0),
    lager:debug("~w: Release: ~p, State: ~p",
		[self(), lager:pr(Request, ?MODULE), lager:pr(State, ?MODULE)]),
    {reply, ok, State};

handle_call({release, {_,_,_,_,_,_,_,_} = IPv6} = Request, _From, State0) ->
    State = release_ip(ip2int(IPv6), State0),
    lager:debug("~w: Release: ~p, State: ~p",
		[self(), lager:pr(Request, ?MODULE), lager:pr(State, ?MODULE)]),
    {reply, ok, State};
handle_call({release, {{_,_,_,_,_,_,_,_} = IPv6,_}} = Request, _From, State0) ->
    State = release_ip(ip2int(IPv6), State0),
    lager:debug("~w: Release: ~p, State: ~p",
		[self(), lager:pr(Request, ?MODULE), lager:pr(State0, ?MODULE)]),
    {reply, ok, State};

handle_call({release, IP} = Request, _From, State) ->
    lager:error("~w: Release: ~p, State: ~p",
		[self(), lager:pr(Request, ?MODULE), lager:pr(State, ?MODULE)]),
    Reply = {error, invalid, IP},
    {reply, Reply, State};

handle_call(Request, _From, State) ->
    lager:warning("handle_call: ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    lager:debug("handle_cast: ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

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

id2ip(Id, #state{type = ipv4, shift = Shift}) ->
    {int2ip(ipv4, Id bsl Shift), 32 - Shift};
id2ip(Id, #state{type = ipv6, shift = Shift}) ->
    {int2ip(ipv6, Id bsl Shift), 128 - Shift}.


release_ip(IP, #state{first = First, last = Last,
		      shift = Shift,
		      used = Used, free = Free,
		      used_pool = UsedTid, free_pool = FreeTid} = State0)
  when IP >= First andalso IP =< Last ->
    Id = IP bsr Shift,

    case ets:take(UsedTid, Id) of
	[_] ->
	    ets:insert(FreeTid, #lease{ip = Id}),
	    State = State0#state{used = Used - 1, free = Free + 1},
	    metrics_sync_gauges(State),
	    State;
	_ ->
	    lager:warning("release of unallocated IP: ~p", [id2ip(Id, State0)]),
	    State0
    end;
release_ip(IP, #state{type = Type, first = First, last = Last} = State) ->
    lager:warning("release of out-of-pool IP: ~w < ~w < ~w",
		  [int2ip(Type, First), int2ip(Type, IP), int2ip(Type, Last)]),
    State.



take_ip(ClientId, IP, #state{first = First, last = Last,
			     shift = Shift,
			     used = Used, free = Free,
			     used_pool = UsedTid, free_pool = FreeTid} = State0)
  when IP >= First andalso IP =< Last ->
    Id = IP bsr Shift,

    case ets:take(FreeTid, Id) of
	[_] ->
	    ets:insert(UsedTid, #lease{ip = Id, client_id = ClientId}),
	    State = State0#state{used = Used + 1, free = Free - 1},
	    metrics_sync_gauges(State),
	    {{ok, id2ip(Id, State)}, State};
	_ ->
	    lager:warning("attempt to take already allocated IP: ~p", [id2ip(Id, State0)]),
	    {{error, taken}, State0}
    end;
take_ip(_ClientId, IP, #state{type = Type, first = First, last = Last} = State) ->
    lager:warning("attempt to take of out-of-pool IP: ~w < ~w < ~w",
		  [int2ip(Type, First), int2ip(Type, IP), int2ip(Type, Last)]),
    {{error, out_of_pool}, State}.

%%%===================================================================
%%% metrics functions
%%%===================================================================

metrics_sync_gauges(#state{name = Name, type = Type, id = Id,
		       used = Used, free = Free}) ->
    prometheus_gauge:set(ergw_ip_pool_free, [Name, Type, Id], Free),
    prometheus_gauge:set(ergw_ip_pool_used, [Name, Type, Id], Used),
    ok.
