%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% Note: the TEI manager does not need to be a gen_statem in this
%%       version. Most of the code here is in preparation for using
%%       external storage for the teid state...

-module(ergw_tei_mngr).

-behavior(gen_statem).

-compile({parse_transform, cut}).

%% API
-export([start_link/0, alloc_tei/1]).

-ignore_xref([start_link/0]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4, terminate/3, code_change/4]).

-export([validate_option/1, config_meta/0]).

-include("include/ergw.hrl").

-define(SERVER, ?MODULE).
-define(SAVE_TIMEOUT, 1000).
-define(MAX_TRIES, 10).
-define(POW(X, Y), trunc(math:pow(X, Y))).

-record(data, {prefix, prefix_len}).

%%%=========================================================================
%%%  API
%%%=========================================================================

start_link() ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).

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

%%%===================================================================
%%% Options Validation
%%%===================================================================

validate_option({Prefix, Len} = Value)
  when is_integer(Prefix), is_integer(Len),
       Len >= 0, Len =< 8, Prefix >= 0 ->
    case ?POW(2, Len) of
	X when X > Prefix ->
	    #{prefix => Prefix, len => Len};
	_ ->
	    throw({error, {options, {teid, Value}}})
    end;
validate_option(Value) ->
    throw({error, {options, {teid, Value}}}).

config_meta() ->
    #{prefix => {integer, 0},
      len    => {integer, 0}}.

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

callback_mode() -> handle_event_function.

init([]) ->
    {ok, #{}, #data{}}.

handle_event({call, From}, {alloc_tei, Name, KeyFun}, State, Data) ->
    RndState = maybe_init_rnd(Name, State),
    alloc_tei(From, Name, KeyFun, ?MAX_TRIES, RndState, State, Data);

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
alloc_tei(From, Name, KeyFun, Cnt, RndState0, State, Data0) ->
    Data = #data{prefix = Prefix0, prefix_len = PrefixLen} = maybe_update_data(Data0),
    Prefix = Prefix0 bsl (32 - PrefixLen),
    Mask = 16#ffffffff bsr PrefixLen,
    {TEI0, RndState} = rand:uniform_s(16#fffffffe, RndState0),
    TEI = Prefix + (TEI0 band Mask),
    case gtp_context_reg:lookup(KeyFun(TEI)) of
	undefined ->
	    alloc_tei_reply(From, {ok, TEI}, Name, RndState, State, Data);
	_ ->
	    alloc_tei(From, Name, KeyFun, Cnt - 1, RndState, State, Data)
    end.

maybe_update_data(#data{prefix = undefined, prefix_len = undefined} = Data) ->
    {ok, #{prefix := Prefix, len := PrefixLen}} = ergw_config:get([teid]),
    Data#data{prefix = Prefix, prefix_len = PrefixLen};
maybe_update_data(Data) ->
    Data.
