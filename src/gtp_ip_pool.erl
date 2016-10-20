%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_ip_pool).

-behavior(gen_server).

%% API
-export([start_link/2, start_link/3,
	 allocate/2, release/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(state, {type, base, shift, size, free, max_alloc, used_pool, free_pool}).
-record(lease, {ip, client_id}).

-include_lib("stdlib/include/ms_transform.hrl").

%%====================================================================
%% API
%%====================================================================

start_link(Pool, Opts) ->
    gen_server:start_link(?MODULE, Pool, Opts).

start_link(ServerName, Pool, Opts) ->
    gen_server:start_link(ServerName, ?MODULE, Pool, Opts).

allocate(Server, ClientId) ->
    gen_server:call(Server, {allocate, ClientId}).

release(Server, IP) ->
    gen_server:call(Server, {release, IP}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init({Prefix, PrefixLen}) ->
    UsedTid = ets:new(used_pool, [set, {keypos, #lease.ip}]),
    FreeTid = ets:new(free_pool, [set, {keypos, #lease.ip}]),
    {Type, PrefixLen1, Shift} = case size(Prefix) of
				    4 -> {ipv4,  32 - PrefixLen,  0};
				    8 -> {ipv6, 128 - PrefixLen, 64}
		    end,
    Size = (1 bsl (PrefixLen1 - Shift)),
    State = #state{type  = Type,
		   base  = ip2int(Prefix),
		   shift = Shift,
		   size  = Size,
		   free  = 0,
		   max_alloc = 0,
		   used_pool = UsedTid,
		   free_pool = FreeTid},
    lager:debug("init Pool state: ~p", [lager:pr(State, ?MODULE)]),
    {ok, State}.

handle_call({allocate, ClientId} = Request, _From,
	    #state{size = Size, free = Free, max_alloc = MaxAlloc,
		   used_pool = UsedTid} = State0)
  when MaxAlloc < Size andalso Free == 0 ->
    lager:debug("~w: Allocate: ~p, State: ~p", [self(), lager:pr(Request, ?MODULE), lager:pr(State0, ?MODULE)]),

    ets:insert(UsedTid, #lease{ip = MaxAlloc, client_id = ClientId}),
    State = State0#state{max_alloc = MaxAlloc + 1},
    IP = id2ip(MaxAlloc, State),

    {reply, {ok, IP}, State};

handle_call({allocate, ClientId} = Request, _From,
	    #state{free = Free, free_pool = FreeTid, used_pool = UsedTid} = State)
  when Free =/= 0 ->
    lager:debug("~w: Allocate: ~p, State: ~p", [self(), lager:pr(Request, ?MODULE), lager:pr(State, ?MODULE)]),

    Id = ets:first(FreeTid),
    ets:delete(FreeTid, Id),
    ets:insert(UsedTid, #lease{ip = Id, client_id = ClientId}),
    IP = id2ip(Id, State),

    {reply, {ok, IP}, State};

handle_call({allocate, _ClientId}, _From, State) ->
    {reply, {error, full}, State};

handle_call({release, {_,_,_,_} = IPv4}, _From, State0) ->
    State1 = release_ip(ip2int(IPv4), State0),
    {reply, ok, State1};

handle_call({release, {{_,_,_,_,_,_,_,_} = IPv6, _Len}}, _From, State0) ->
    State1 = release_ip(ip2int(IPv6), State0),
    {reply, ok, State1};

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
    {{A, B, C, D, E, F, G, H}, 64}.

id2ip(Id, #state{type = Type, base = Base, shift = Shift}) ->
    int2ip(Type, Base + (Id bsl Shift)).

release_ip(IP, #state{base = Base, shift = Shift, size = Size,
		      used_pool = UsedTid, free_pool = FreeTid} = State)
  when IP >= Base andalso IP =< Base + (Size bsl Shift) ->
    Id = (IP - Base) bsr Shift,

    case ets:lookup(UsedTid, Id) of
	[_] ->
	    ets:delete(UsedTid, Id),
	    ets:insert(FreeTid, #lease{ip = Id});
	_ ->
	    lager:warning("release of unallocated IP: ~p", [id2ip(Id, State)])
    end,
    State;
release_ip(IP, #state{type = Type, base = Base, shift = Shift, size = Size} = State) ->
    lager:warning("release of out-of-pool IP: ~p, ~w < ~w < ~w",
		  [int2ip(Type, IP), Base, IP, Base + (Size bsl Shift)]),
    State.
