%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% simple implementation of 3GPP TS 29.598 Nudsf service
%% - functional API according to TS
%% - not optimized for anything

-module(ergw_nudsf_api).

%%-compile({parse_transform, cut}).

%% API
-export([validate_options/1]).

-if(?OTP_RELEASE =< 23).
-ignore_xref([behaviour_info/1]).
-endif.

-include_lib("kernel/include/logger.hrl").

-type opts() :: #{page => non_neg_integer(),
		  range => non_neg_integer(),
		  count => boolean()}.
-type tags() :: map().
-type record_id() :: binary().
-type block_id() :: binary().
-type meta() :: #{tags => tags()}.
-type block() :: term().
-type blocks() :: #{block_id() => block()}.
-type record() :: #{meta => meta(), blocks => blocks()}.
%% TBD:
-type filter() :: map().

%%%=========================================================================
%%%  API
%%%=========================================================================

-optional_callbacks([all/0]).

-callback get_childspecs(Config :: term()) -> [supervisor:child_spec()].

%% TS 29.598, 5.2.2.2 Query

-callback get(record, RecordId :: record_id()) -> {ok, record()} | {error, not_found};
	     (meta,   RecordId :: record_id()) -> {ok, meta()}   | {error, not_found};
	     (blocks, RecordId :: record_id()) -> {ok, blocks()} | {error, not_found}.

-callback get(block, RecordId :: record_id(), BlockId :: block_id()) ->
    {ok, block()} | {error, not_found}.

%% TS 29.598, 5.2.2.2.6	Search

-callback search(Filter :: filter()) ->
    {Count :: non_neg_integer(), [record_id()]} | {error, Reason :: atom()}.
-callback search(Filter :: filter(), Opts :: opts()) ->
    {Count :: non_neg_integer(), [record_id()]} | {error, Reason :: atom()}.

%% TS 29.598, 5.2.2.3 Create

-callback create(RecordId :: record_id(), Meta :: meta(), Blocks :: blocks()) ->
    ok | {error, already_exists}.

-callback create(block, RecordId :: record_id(), BlockId :: block_id(), Block :: block()) ->
    ok | {error, already_exists | not_found}.

%% TS 29.598, 5.2.2.4 Update

-callback put(record, RecordId :: record_id(), Meta :: meta(), Blocks :: blocks()) ->
    ok | {error, not_found};
	     (block, RecordId :: record_id(), BlockId :: block_id(), Block :: block()) ->
    ok | {error, not_found}.

-callback put(meta, RecordId :: record_id(), Meta :: meta()) ->
    ok | {error, not_found}.

%% TS 29.598, 5.2.2.5 Delete

-callback delete(record, RecordId :: record_id()) ->
    ok | {error, not_found}.

-callback delete(block, RecordId :: record_id(), BlockId :: block_id()) ->
    ok | {error, not_found}.

-callback all() -> #{record_id() => record()}.
-callback wipe() -> ok.

-callback validate_options(Values :: map() | list()) ->
    map().

%%%===================================================================
%%% Options Validation
%%%===================================================================

get_opt(Key, List) when is_list(List) ->
    proplists:get_value(Key, List);
get_opt(Key, Map) when is_map(Map) ->
    maps:get(Key, Map).

validate_options(Values) ->
    Handler = get_opt(handler, Values),
    case code:ensure_loaded(ergw_nudsf) of
	{module, _} ->
	    ok;
	_ ->
	    try
		ok = ergw_loader:load(ergw_nudsf_api, ergw_nudsf, Handler)
	    catch
		error:{missing_exports, Missing} ->
		    throw({error, {options, {{udsf, handler}, Handler, Missing}}});
		_:Cause:ST ->
		    throw({error, {options, {{udsf, handler}, Handler, Cause, ST}}})
	    end
    end,
    Handler:validate_options(Values).
