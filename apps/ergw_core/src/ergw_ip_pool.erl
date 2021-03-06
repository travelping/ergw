%% Copyright 2015-2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_ip_pool).

%% API
-export([start_ip_pool/2, send_request/2, wait_response/1, release/1,
	 addr/1, ip/1, opts/1]).
-export([static_ip/2]).
-export([validate_options/2, validate_name/2]).

-if(?OTP_RELEASE =< 23).
-ignore_xref([behaviour_info/1]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include("ergw_core_config.hrl").

%%====================================================================
%% Behavior spec
%%====================================================================

-callback start_ip_pool(Name :: binary(), Opts :: map()) -> Result :: term().
-callback send_pool_request(CliendId :: term(), Request :: term()) -> ReqId :: term().
-callback wait_pool_response(ReqId :: term()) -> Result :: term().
-callback ip(AllocInfo :: tuple()) -> Result :: term().
-callback opts(AllocInfo :: tuple()) -> Result :: term().
-callback release(AllocInfo :: tuple()) -> Result :: term().

%%====================================================================
%% API
%%====================================================================

start_ip_pool(Name, #{handler := Handler} = Opts) ->
    {ok, Pools} = ergw_core_config:get([ip_pools], #{}),
    ergw_core_config:put(ip_pools, maps:put(Name, Opts, Pools)),
    Handler:start_ip_pool(Name, Opts).

send_request(ClientId, Requests) ->
    [send_pool_request(ClientId, R) || R <- Requests].

wait_response(RequestIds) ->
    [wait_pool_response(R) || R <- RequestIds].

release(AllocInfos) ->
    [pool_release(AI) || AI <- AllocInfos].

addr(AllocInfo) ->
    case ip(AllocInfo) of
	{IP, _} -> IP;
	Other -> Other
    end.

ip(AllocInfo) ->
    alloc_info(AllocInfo, ip).

opts(AllocInfo) ->
    alloc_info(AllocInfo, opts).

static_ip(IP, PrefixLen) ->
    {'$static', {IP, PrefixLen}}.

%%%====================================================================
%%% Options Validation
%%%===================================================================

validate_options(_Name, Values0)
  when ?is_opts(Values0) ->
    Values = ergw_core_config:to_map(Values0),
    validate_pool(maps:get(handler, Values, ergw_local_pool), Values);
validate_options(Name, Values) ->
    erlang:error(badarg, [Name, Values]).

validate_pool(ergw_local_pool, Options) ->
    ergw_local_pool:validate_options(Options);
validate_pool(Handler, _Options) ->
    erlang:error(badarg, [handler, Handler]).

validate_name(_, Name) when is_binary(Name) ->
    Name;
validate_name(_, Name) when is_list(Name) ->
    unicode:characters_to_binary(Name, utf8);
validate_name(_, Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8);
validate_name(Opt, Name) ->
   erlang:error(badarg, [Opt, Name]).

%%%===================================================================
%%% Internal functions
%%%===================================================================

alloc_info(Info, F) when element(1, Info) =:= '$static' ->
    static_ip_info(F, Info);
alloc_info(Tuple, F) when is_tuple(Tuple) ->
    apply(element(1, Tuple), F, [Tuple]);
alloc_info(_, _) ->
    undefined.

static_ip_info(ip, {_, Addr}) -> Addr;
static_ip_info(opts,   _) -> #{};
static_ip_info(release, _) -> ok.

with_pool(Pool, Fun) ->
    case ergw_core_config:get([ip_pools, Pool], undefined) of
	{ok, #{handler := Handler}} ->
	    Fun(Handler);
	_ ->
	    {error, not_found}
    end.

send_pool_request(_ClientId, skip) ->
    skip;
send_pool_request(ClientId, {Pool, _, _, _} = Req) ->
    with_pool(Pool, fun(Handler) -> {Handler, apply(Handler, ?FUNCTION_NAME, [ClientId, Req])} end).

wait_pool_response(skip) ->
    skip;
wait_pool_response({error, _Reason} = Error) ->
    Error;
wait_pool_response({Handler, ReqId}) ->
    Handler:wait_pool_response(ReqId).

pool_release(AI) ->
    alloc_info(AI, release).
