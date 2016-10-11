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

-record(state, {type, base, shift, size, used, free,  tid}).
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
    Tid = ets:new(pool, [ordered_set, {keypos, #lease.ip}]),
    {Type, PrefixLen1, Shift} = case size(Prefix) of
				    4 -> {ipv4,  32 - PrefixLen,  0};
				    8 -> {ipv6, 128 - PrefixLen, 64}
		    end,
    Size = (1 bsl (PrefixLen1 - Shift)),
    State = #state{type  = Type,
		   base  = ip2int(Prefix),
		   shift = Shift,
		   size  = Size,
		   used  = 0,
		   free  = Size,
		   tid   = Tid},
    lager:debug("init Pool state: ~p", [lager:pr(State, ?MODULE)]),
    {ok, State}.

handle_call({allocate, _ClientId}, _From,
	    #state{free = 0} = State) ->
    {reply, {error, full}, State};

handle_call({allocate, ClientId} = Request, _From,
	    #state{type = Type, base  = Base, shift = Shift,
		   size = Size, used  = Used, free  = Free,
		   tid  = Tid} = State) ->
    lager:warning("~w: Allocate: ~p, State: ~p", [self(), lager:pr(Request, ?MODULE), lager:pr(State, ?MODULE)]),

    Init = hash(ClientId, Size),
    case try_alloc(Init, Size, Tid) of
	Final when is_integer(Final) ->
	    ets:insert(Tid, #lease{ip = Final, client_id = ClientId}),
	    lager:debug("Final: ~p", [Final]),
	    IP = int2ip(Type, Base + (Final bsl Shift)),
	    lager:debug("IP: ~p", [IP]),

	    {reply, {ok, IP}, State#state{used = Used + 1, free = Free - 1}};
	Other ->
	    {reply, Other, State}
    end;

handle_call({release, {_,_,_,_} = IPv4}, _From, State0) ->
    State1 = do_release(ip2int(IPv4), State0),
    {reply, ok, State1};

handle_call({release, {{_,_,_,_,_,_,_,_} = IPv6, _Len}}, _From, State0) ->
    State1 = do_release(ip2int(IPv6), State0),
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

int2list(I) ->
    int2list(I, []).

int2list(0, L) ->
    lists:reverse(L);
int2list(I, L) ->
    int2list(I div 256, [I rem 256|L]).

hash(Id, Size) ->
    <<Hash:160>> = crypto:hash(sha, int2list(Id)),
    Hash rem Size.

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

try_alloc(Init, Size, Tid) ->
    MS = ets:fun2ms(fun(#lease{ip = IP} = Lease) when IP >= Init -> Lease end),
    Next = ets:select(Tid, MS, 1),
    lager:debug("try_alloc: got ~p", [Next]),
    try_alloc(Init, Size, Next, Tid).

try_alloc(Value, Size, '$end_of_table', _)
  when Value < Size ->
    Value;
try_alloc(Value, Size, '$end_of_table', Tid)
  when Value >= Size ->
    try_alloc(0, Size, Tid);
try_alloc(Value, _Size, {[#lease{ip = IP}], _Continuation}, _Tid)
  when IP > Value ->
    Value;
try_alloc(Value, Size, {[#lease{ip = Value}], Continuation}, Tid) ->
    Next = ets:select(Continuation),
    lager:debug("try_alloc: got ~p", [Next]),
    try_alloc(Value + 1, Size, Next, Tid).


do_release(IP, #state{type = Type, base = Base, shift = Shift,
		      size = Size, used = Used, free  = Free,
		      tid  = Tid} = State)
  when IP >= Base andalso IP =< Base + (Size bsl Shift) ->
    Offs = (IP - Base) bsr Shift,
    case ets:lookup(Tid, Offs) of
	[_] ->
	    ets:delete(Tid, Offs),
	    State#state{free = Free + 1, used = Used - 1};
	_ ->
	    lager:warning("release of unallocated IP: ~p, Offs: ~p, ETS: ~p", [int2ip(Type, IP), Offs, ets:tab2list(Tid)]),
	    State
    end;
do_release(IP, #state{type = Type, base = Base, shift = Shift, size = Size} = State) ->
    lager:warning("release of out-of-pool IP: ~p, ~w < ~w < ~w",
		  [int2ip(Type, IP), Base, IP, Base + (Size bsl Shift)]),
    State.
