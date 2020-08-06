%% Copyright 2015-2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_ip_pool).

%% API
-export([start_ip_pool/2, send_request/2, wait_response/1, release/1,
	 requested/1, addr/1, ip/1, opts/1]).
-export([static_ip/2]).
-export([get/5]).
-export([validate_options/1, validate_name/2]).

-include_lib("kernel/include/logger.hrl").

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

%%====================================================================
%% API
%%====================================================================

start_ip_pool(Name, Opts) ->
    with_pool(Name, fun(Handler) -> apply(Handler, ?FUNCTION_NAME, [Name, Opts]) end).

send_request(ClientId, Requests) ->
    [send_pool_request(ClientId, R) || R <- Requests].

wait_response(RequestIds) ->
    [wait_pool_response(R) || R <- RequestIds].

release(AllocInfos) ->
    [pool_release(AI) || AI <- AllocInfos].

requested(AllocInfo) ->
    AllocInfo:requested().

addr(AllocInfo) ->
    case ip(AllocInfo) of
	{IP, _} -> IP;
	Other -> Other
    end.

ip(AllocInfo) ->
    alloc_info(AllocInfo, ip).

opts(AllocInfo) ->
    alloc_info(AllocInfo, opts).

%% compat wrapper
get(Pool, ClientId, IP, PrefixLen, Opts) ->
    ReqId = send_request(ClientId, [{Pool, IP, PrefixLen, Opts}]),
    [AllocInfo] = wait_response(ReqId),
    AllocInfo.

static_ip(IP, PrefixLen) ->
    {'$static', {IP, PrefixLen}}.

%%%====================================================================
%%% Options Validation
%%%===================================================================

validate_options(Options) ->
    ?LOG(debug, "IP Pool Options: ~p", [Options]),
    case ergw_config:get_opt(handler, Options, ergw_local_pool) of
	ergw_local_pool ->
	    ergw_local_pool:validate_options(Options);
	ergw_dhcp_pool ->
	    ergw_dhcp_pool:validate_options(Options);
	Handler ->
	    throw({error, {options, {handler, Handler}}})
    end.

validate_name(_, Name) when is_binary(Name) ->
    Name;
validate_name(_, Name) when is_list(Name) ->
    unicode:characters_to_binary(Name, utf8);
validate_name(_, Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8);
validate_name(Opt, Name) ->
   throw({error, {options, {Opt, Name}}}).

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
    case application:get_env(ergw, ip_pools) of
	{ok, #{Pool := #{handler := Handler}}} ->
	    Fun(Handler);
	_ ->
	    {error, not_found}
    end.

send_pool_request(_ClientId, skip) ->
    skip;
send_pool_request(ClientId, {Pool, _, _, _} = Req) ->
    with_pool(Pool, fun(Handler) -> {Handler, (catch apply(Handler, ?FUNCTION_NAME, [ClientId, Req]))} end).

wait_pool_response(skip) ->
    skip;
wait_pool_response({error, _Reason} = Error) ->
    Error;
wait_pool_response({Handler, ReqId}) ->
    Handler:wait_pool_response(ReqId).

pool_release(AI) ->
    alloc_info(AI, release).
