%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_core_config).

-compile({parse_transform, cut}).

%% API
-export([validate_options/3,
	 mandatory_keys/2,
	 check_unique_elements/2,
	 validate_ip_cfg_opt/2,
	 to_map/1,
	 get/2, put/2
	]).

-include("ergw_core_config.hrl").

%%%===================================================================
%%% API
%%%===================================================================

to_map(M) when is_map(M) ->
    M;
to_map(L) when is_list(L) ->
    lists:foldr(
      fun({K, V}, M) when not is_map_key(K, M) ->
	      M#{K => V};
	 (K, M) when is_atom(K) ->
	      M#{K => true};
	 (Opt, _) ->
	      erlang:error(badarg, [Opt])
      end, #{}, normalize_proplists(L)).

get([Key|_] = Query, Default) ->
    case is_global_key(Key) of
	true  -> get_global_key(Query, Default);
	false -> get_local_key(Query, Default)
    end.

get_global_key(Query, Default) ->
    case ergw_global:find(Query) of
	{ok, Value} ->
	    {ok, Value};
	_ ->
	    {ok, Default}
    end.

get_local_key([Key|Next], Default) ->
    case application:get_env(ergw_core, Key) of
	{ok, Config} ->
	    get(Next, Config, Default);
	undefined when Next =:= [] ->
	    {ok, Default};
	undefined ->
	    undefined
    end.

get([], Config, _) ->
    {ok, Config};
get([K|Next], Config, Default) when is_map_key(K, Config) ->
    get(Next, maps:get(K, Config), Default);
get([_], _, Default) ->
    {ok, Default};
get(_, _, _) ->
    undefined.

put(Key, Val) ->
    case is_global_key(Key) of
	true ->
	    {ok, _} = ergw_global:put(Key, Val),
	    ok;
	false ->
	    ok = application:set_env(ergw_core, Key, Val)
    end.
%%%===================================================================
%%% Get Functions
%%% Get/Put Functions
%%%===================================================================

is_global_key(restart_count) -> true;
is_global_key(apns) -> true;
is_global_key(nodes) -> true;
is_global_key(charging) -> true;
is_global_key(path_management) -> true;
is_global_key(gtp_peers) -> true;
is_global_key(proxy_map) -> true;
is_global_key(_) -> false.


%%%===================================================================
%%% Options Validation
%%%===================================================================

check_unique_elements(Key, List) when is_list(List) ->
    UList = lists:usort(List),
    if length(UList) == length(List) ->
	    ok;
       true ->
	    Duplicate = proplists:get_keys(List) -- proplists:get_keys(UList),
	    erlang:error(badarg, [Key, Duplicate])
    end.

mandatory_keys(Keys, Map) when is_map(Map) ->
    lists:foreach(
      fun(K) ->
	      V = maps:get(K, Map, undefined),
	      if V =:= [] orelse
		 (is_map(V) andalso map_size(V) == 0) orelse
		 V =:= undefined ->
			 erlang:error(badarg, [missing, K]);
		 true ->
		      ok
	      end
      end, Keys).

validate_option(Fun, Opt, Value) when is_function(Fun, 2) ->
    {Opt, Fun(Opt, Value)};
validate_option(Fun, Opt, Value) when is_function(Fun, 1) ->
    Fun({Opt, Value}).

validate_options(Fun, M) when is_map(M) ->
    maps:fold(
      fun(K0, V0, A) ->
	      {K, V} = validate_option(Fun, K0, V0),
	      A#{K => V}
      end, #{}, M);
validate_options(_Fun, []) ->
    [];
%% validate_options(Fun, [Opt | Tail]) when is_atom(Opt) ->
%%     [validate_option(Fun, Opt, true) | validate_options(Fun, Tail)];
validate_options(Fun, [{Opt, Value} | Tail]) ->
    [validate_option(Fun, Opt, Value) | validate_options(Fun, Tail)].

normalize_proplists(L0) ->
    L = proplists:unfold(L0),
    proplists:substitute_negations([{disable, enable}], L).

%% validate_options/4
validate_options(Fun, Options, Defaults)
  when ?is_opts(Options), ?is_opts(Defaults) ->
    Opts = maps:merge(to_map(Defaults), to_map(Options)),
    validate_options(Fun, Opts).

validate_ip6(_Opt, IP) when ?IS_IPv6(IP) ->
    ergw_inet:ip2bin(IP);
validate_ip6(_Opt, <<_:128/bits>> = IP) ->
    IP;
validate_ip6(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

validate_ip_cfg_opt(Opt, {_,_,_,_} = IP)
  when Opt == 'MS-Primary-DNS-Server';
       Opt == 'MS-Secondary-DNS-Server';
       Opt == 'MS-Primary-NBNS-Server';
       Opt == 'MS-Secondary-NBNS-Server' ->
    ergw_inet:ip2bin(IP);
validate_ip_cfg_opt(Opt, <<_:32/bits>> = IP)
  when Opt == 'MS-Primary-DNS-Server';
       Opt == 'MS-Secondary-DNS-Server';
       Opt == 'MS-Primary-NBNS-Server';
       Opt == 'MS-Secondary-NBNS-Server' ->
    IP;
validate_ip_cfg_opt(Opt, DNS)
  when is_list(DNS) andalso
       (Opt == 'DNS-Server-IPv6-Address' orelse
	Opt == '3GPP-IPv6-DNS-Servers') ->
    [validate_ip6(Opt, IP) || IP <- DNS];
validate_ip_cfg_opt(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).
