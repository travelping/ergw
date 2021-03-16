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
	 to_map/1
	]).

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

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
