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
-export([start_link/0, alloc_tei/1, release_tei/2]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4, terminate/3, code_change/4]).

-export([validate_option/1]).

-include("include/ergw.hrl").

-define(SERVER, ?MODULE).
-define(SAVE_TIMEOUT, 1000).
-define(MAX_TRIES, 10).
-define(POW(X, Y), trunc(math:pow(X, Y))).

-record(data, {node_id, block_id, prefix, prefix_len, tid, save_cnt}).

%%%=========================================================================
%%%  API
%%%=========================================================================

start_link() ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).

%% with_keyfun/2
with_keyfun(#request{gtp_port = Port}, Fun) ->
    with_keyfun(Port, Fun);
with_keyfun(#gtp_port{name = Name} = Port, Fun) ->
    Fun(Name, gtp_context:port_teid_key(Port, _));
with_keyfun(#pfcp_ctx{name = Name} = PCtx, Fun) ->
    Fun(Name, ergw_pfcp:ctx_teid_key(PCtx, _)).

%% alloc_tei/1
alloc_tei(Port) ->
    with_keyfun(Port, fun alloc_tei/2).

%% alloc_tei/2
alloc_tei(Name, KeyFun) ->
    gen_server:call(?SERVER, {alloc_tei, Name, KeyFun}).

%% release_tei/2
release_tei(Port, TEI) ->
    with_keyfun(Port, release_tei(_, TEI, _)).

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

init([]) ->
    TID = ets:new(?SERVER, [ordered_set, {keypos, 1}]),

    Data = #data{tid = TID},

    {ok, #{}, Data}.

handle_event({call, From}, {alloc_tei, Name, KeyFun}, State, Data) ->
    RndState = maybe_init_rnd(Name, State),
    alloc_tei(From, Name, KeyFun, ?MAX_TRIES, RndState, State, Data);

handle_event({call, From}, {release_tei, _Name, TEI, KeyFun}, _State, #data{tid = TID}) ->
    ets:delete(TID, KeyFun(TEI)),
    Actions = [{reply, From, ok}],
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

alloc_tei_reply(From, Reply, Name, RndState, State, Data) ->
    Actions = [{reply, From, Reply}],
    {next_state, State#{Name => RndState}, Data, Actions}.

alloc_tei(From, Name, _KeyFun, 0, RndState, State, Data) ->
    alloc_tei_reply(From, {error, no_tei}, Name, RndState, State, Data);
alloc_tei(From, Name, KeyFun, Cnt, RndState0, State, #data{tid = TID} = Data0) ->
    Data = #data{prefix = Prefix0, prefix_len = PrefixLen} = maybe_update_data(Data0),
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

maybe_update_data(#data{prefix = undefined, prefix_len = undefined} = Data) ->
    {ok, {Prefix, PrefixLen}} = application:get_env(ergw, teid),
    Data#data{prefix = Prefix, prefix_len = PrefixLen};
maybe_update_data(Data) ->
    Data.