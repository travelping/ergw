%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% simple implementation of 3GPP TS 29.598 Nudsf service
%% - functional API according to TS
%% - not optimized for anything

-module(ergw_tei_mngr).

-behavior(gen_statem).

-compile({parse_transform, cut}).

%% API
-export([start_link/1, alloc_tei/1, release_tei/2]).

-ignore_xref([start_link/1]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4, terminate/3, code_change/4]).

-export([validate_option/1]).

-include("include/ergw.hrl").
-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-define(SAVE_COUNTER, 10).
-define(SAVE_TIMEOUT, 1000).
-define(MAX_TRIES, 10).
-define(POW(X, Y), trunc(math:pow(X, Y))).

-record(data, {node_id, block_id, prefix, prefix_len, tid, save_cnt}).

%%%=========================================================================
%%%  API
%%%=========================================================================

start_link(Config) ->
    {Prefix, PrefixLen} = proplists:get_value(teid, Config),
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [Prefix, PrefixLen], []).

%% with_keyfun/2
with_keyfun(#request{socket = Socket}, Fun) ->
    with_keyfun(Socket, Fun);
with_keyfun(#socket{name = Name} = Socket, Fun) ->
    Fun(Name, gtp_context:socket_teid_key(Socket, _));
with_keyfun(#pfcp_ctx{name = Name} = PCtx, Fun) ->
    Fun(Name, ergw_pfcp:ctx_teid_key(PCtx, _)).

%% alloc_tei/1
alloc_tei(Key) ->
    with_keyfun(Key, fun alloc_tei/2).

%% alloc_tei/2
alloc_tei(Name, KeyFun) ->
    gen_server:call(?SERVER, {alloc_tei, Name, KeyFun}).

%% release_tei/2
release_tei(Key, TEI) ->
    with_keyfun(Key, release_tei(_, TEI, _)).

%% release_tei/3
release_tei(Name, TEI, KeyFun) ->
    gen_server:call(?SERVER, {release_tei, Name, TEI, KeyFun}).

%%%===================================================================
%%% Options Validation
%%%===================================================================

validate_option({Prefix, Len} = Value)
  when is_integer(Prefix), is_integer(Len),
       Len >= 0, Len =< 8, Prefix >= 0 ->
    case ?POW(2, Len) of
	X when X > Prefix -> Value;
	_ ->
	    throw({error, {options, {teid, Value}}})
    end;
validate_option(Value) ->
    throw({error, {options, {teid, Value}}}).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

callback_mode() -> handle_event_function.

init([Prefix, PrefixLen]) ->
    TID = ets:new(?SERVER, [ordered_set, {keypos, 1}]),
    NodeId = ergw:get_node_id(),
    BlockId = iolist_to_binary(["teid-prefix-", integer_to_list(Prefix)]),

    Data0 = #data{node_id = NodeId,
		  block_id = BlockId,
		  prefix = Prefix,
		  prefix_len = PrefixLen,
		  tid = TID,
		  save_cnt = ?SAVE_COUNTER},
    {State, Data} = load_data(#{}, Data0),

    {ok, State, Data}.

handle_event(state_timeout, save, State, Data) ->
    save_data(State, Data),
    {keep_state, Data#data{save_cnt = ?SAVE_COUNTER}};

handle_event({call, From}, {alloc_tei, Name, KeyFun}, State, Data) ->
    RndState = maybe_init_rnd(Name, State),
    alloc_tei(From, Name, KeyFun, ?MAX_TRIES, RndState, State, Data);

handle_event({call, From}, {release_tei, _Name, TEI, KeyFun}, _State, #data{tid = TID}) ->
    ets:delete(TID, KeyFun(TEI)),
    Actions = [{reply, From, ok}, state_timeout()],
    {keep_state_and_data, Actions};

handle_event({call, From}, Request, _State, _Data) ->
    Reply = {error, {badarg, Request}},
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event(_, _Msg, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%=========================================================================
%%%  internal functions
%%%=========================================================================

maybe_init_rnd(Name, State) when is_map_key(Name, State) ->
    maps:get(Name, State);
maybe_init_rnd(_, _) ->
    rand:seed_s(exrop).

state_timeout() ->
    {state_timeout, ?SAVE_TIMEOUT, save}.

load_data(State, #data{node_id = NodeId, block_id = BlockId} = Data) ->
    try
	{ok, Serialized} = ergw_nudsf:get(block, NodeId, BlockId),
	load_data(Serialized, State, Data)
    catch
	Class:Error ->
	    ?LOG(warning, "loading TEI manager state failed with ~p:~p", [Class, Error]),
	    create_data(State, Data),
	    {State, Data}
    end.

load_data(Serialized, State0, Data0) ->
    S = binary_to_term(Serialized),
    State = load_seed(S, State0),
    Data = load_teid(S, Data0),
    {State, Data}.

load_seed(#{seed := Seed}, State)
  when is_list(Seed) ->
    lists:foldl(fun({K,V}, S) -> S#{K => rand:seed_s(V)} end, State, Seed);
load_seed(_, State) ->
    State.

load_teid(#{teids := TEIDs}, #data{tid = TID} = Data)
  when is_list(TEIDs) ->
    true = ets:insert(TID, TEIDs),
    Data;
load_teid(_, Data) ->
    Data.

serialize_data(State, #data{tid = TID}) ->
    SeedL = maps:fold(fun(K,V,L) -> [{K, rand:export_seed_s(V)}|L] end, [], State),
    Term =
	#{seed  => SeedL,
	  teids => ets:tab2list(TID)},
    term_to_binary(Term, [{minor_version, 2}, compressed]).

save_data(State, #data{node_id = NodeId, block_id = BlockId} = Data) ->
    Serialized = serialize_data(State, Data),
    ergw_nudsf:put(block, NodeId, BlockId, Serialized).

create_data(State, #data{node_id = NodeId, block_id = BlockId,
			 prefix = Prefix, prefix_len = PrefixLen} = Data) ->
    Serialized = serialize_data(State, Data),
    Meta = #{tags => #{node_id => NodeId, prefix => Prefix, prefix_len => PrefixLen}},
    ergw_nudsf:create(NodeId, Meta, #{BlockId => Serialized}).

alloc_tei_reply(From, Reply, Name, RndState, State, Data) ->
    Actions = [{reply, From, Reply}, state_timeout()],
    {next_state, State#{Name => RndState}, Data, Actions}.

alloc_tei(From, Name, _KeyFun, 0, RndState, State, Data) ->
    alloc_tei_reply(From, {error, no_tei}, Name, RndState, State, Data);
alloc_tei(From, Name, KeyFun, Cnt, RndState0, State,
	  #data{prefix = Prefix0, prefix_len = PrefixLen, tid = TID} = Data) ->
    Prefix = Prefix0 bsl (32 - PrefixLen),
    Mask = 16#ffffffff bsr PrefixLen,
    {TEI0, RndState} = rand:uniform_s(16#fffffffe, RndState0),
    TEI = Prefix + (TEI0 band Mask),
    case ets:insert_new(TID, {KeyFun(TEI), Name}) of
	true ->
	    alloc_tei_reply(From, {ok, TEI}, Name, RndState, State, Data);
	false ->
	    alloc_tei(From, Name, KeyFun, Cnt - 1, RndState, State, Data)
    end.
