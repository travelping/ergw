%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_config).

-compile({parse_transform, cut}).

%% API
-export([validate_config/1,
	 load_config/1,
	 validate_options/4,
	 validate_apn_name/1,
	 check_unique_keys/2,
	 validate_ip_cfg_opt/2,
	 opts_fold/3,
	 get_opt/3
	]).

-define(DefaultOptions, [{plmn_id, {<<"001">>, <<"01">>}},
			 {node_id, undefined},
			 {teid, {0, 0}},
			 {udsf, [{handler, ergw_nudsf_ets}]},
			 {accept_new, true},
			 {sockets, []},
			 {handlers, []},
			 {path_management, []},
			 {node_selection, [{default, {dns, undefined}}]},
			 {nodes, []},
			 {ip_pools, []},
			 {apns, []},
			 {charging, [{default, []}]}]).
-define(VrfDefaults, [{features, invalid}]).
-define(ApnDefaults, [{ip_pools, []},
		      {bearer_type, 'IPv4v6'},
		      {prefered_bearer_type, 'IPv6'},
		      {ipv6_ue_interface_id, default},
		      {'Idle-Timeout', 28800000}         %% 8hrs timer in msecs
		     ]).
-define(DefaultsNodesDefaults, [{vrfs, invalid}, {node_selection, default}]).

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

%%%===================================================================
%%% API
%%%===================================================================

load_config(Config) ->
    ergw:load_config(Config),
    lists:foreach(fun ergw:start_socket/1, proplists:get_value(sockets, Config)),
    maps:map(fun load_sx_node/2, proplists:get_value(nodes, Config)),
    lists:foreach(fun load_handler/1, proplists:get_value(handlers, Config)),
    maps:map(fun ergw:start_ip_pool/2, proplists:get_value(ip_pools, Config)),
    ergw_http_api:init(proplists:get_value(http_api, Config)),
    ok.

opts_fold(Fun, AccIn, Opts) when is_list(Opts) ->
    lists:foldl(fun({K,V}, Acc) -> Fun(K, V, Acc) end, AccIn, Opts);
opts_fold(Fun, AccIn, Opts) when is_map(Opts) ->
    maps:fold(Fun, AccIn, Opts).

%% opts_map(Fun, Opts) when is_list(Opts) ->
%%     lists:map(fun({K,V}) -> {K, Fun(K, V)} end, Opts);
%% opts_map(Fun, Opts) when is_map(Opts) ->
%%     maps:map(Fun, Opts).

to_map(List) when is_list(List) ->
    maps:from_list(List);
to_map(Map) when is_map(Map) ->
    Map.

get_opt(Key, List) when is_list(List) ->
    proplists:get_value(Key, List);
get_opt(Key, Map) when is_map(Map) ->
    maps:get(Key, Map).

get_opt(Key, List, Default) when is_list(List) ->
    proplists:get_value(Key, List, Default);
get_opt(Key, Map, Default) when is_map(Map) ->
    maps:get(Key, Map, Default).

set_opt(Key, Value, List) when is_list(List) ->
    lists:keystore(Key, 1, List, {Key, Value});
set_opt(Key, Value, Map) when is_map(Map) ->
    Map#{Key => Value}.

without_opts(Keys, List) when is_list(List) ->
    [X || X <- List, not lists:member(element(1, X), Keys)];
without_opts(Keys, Map) when is_map(Map) ->
    maps:without(Keys, Map).

take_opt(Key, List, Default) when is_list(List) ->
    case lists:keytake(Key, 1, List) of
	{value, {_, Value}, List2} ->
	    {Value, List2};
	false ->
	    {Default, List}
    end;
take_opt(Key, Map, Default) when is_map(Map) ->
    {maps:get(Key, Map, Default), maps:remove(Key, Map)}.

%%%===================================================================
%%% Options Validation
%%%===================================================================

return_type(List, list) when is_list(List) ->
    List;
return_type(List, map) when is_list(List) ->
    maps:from_list(List);
return_type(Map, map) when is_map(Map) ->
    Map;
return_type(Map, list) when is_map(Map) ->
    maps:to_list(Map).

check_unique_keys(_Key, Map) when is_map(Map) ->
    ok;
check_unique_keys(Key, List) when is_list(List) ->
    UList = lists:ukeysort(1, List),
    if length(UList) == length(List) ->
	    ok;
       true ->
	    Duplicate = proplists:get_keys(List) -- proplists:get_keys(UList),
	    throw({error, {options, {Key, Duplicate}}})
    end.

check_unique_elements(Key, List) when is_list(List) ->
    UList = lists:usort(List),
    if length(UList) == length(List) ->
	    ok;
       true ->
	    Duplicate = proplists:get_keys(List) -- proplists:get_keys(UList),
	    throw({error, {options, {Key, Duplicate}}})
    end.

mandatory_keys(Keys, Map) when is_map(Map) ->
    lists:foreach(
      fun(K) ->
	      V = maps:get(K, Map, undefined),
	      if V =:= [] orelse
		 (is_map(V) andalso map_size(V) == 0) orelse
		 V =:= undefined ->
			 throw({error, {options, {missing, K}}});
		 true ->
		      ok
	      end
      end, Keys).

-ifdef (SIMULATOR).
validate_config(Config) ->
    catch (validate_options(fun validate_option/2, Config, ?DefaultOptions, list)),
    Config.
-else.

validate_config(Config) ->
    validate_options(fun validate_option/2, Config, ?DefaultOptions, list).

-endif.

validate_option(Fun, Opt, Value) when is_function(Fun, 2) ->
    {Opt, Fun(Opt, Value)};
validate_option(Fun, Opt, Value) when is_function(Fun, 1) ->
    Fun({Opt, Value}).

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
validate_options(Fun, Options, Defaults, ReturnType)
  when is_list(Options), is_list(Defaults) ->
    Opts0 = normalize_proplists(Options),
    Opts = lists:ukeymerge(1, lists:keysort(1, Opts0), lists:keysort(1, Defaults)),
    return_type(validate_options(Fun, Opts), ReturnType);
validate_options(Fun, Options, Defaults, ReturnType)
  when is_list(Options), is_map(Defaults) ->
    Opts0 = normalize_proplists(Options),
    Opts = lists:ukeymerge(1, lists:keysort(1, Opts0),
			   lists:keysort(1, maps:to_list(Defaults))),
    return_type(validate_options(Fun, Opts), ReturnType);
validate_options(Fun, Options, Defaults, ReturnType)
  when is_map(Options) andalso ?is_opts(Defaults) ->
    Opts = maps:to_list(maps:merge(to_map(Defaults), Options)),
    return_type(validate_options(Fun, Opts), ReturnType).

validate_option(plmn_id, {MCC, MNC} = Value) ->
    case validate_mcc_mcn(MCC, MNC) of
       ok -> Value;
       _  -> throw({error, {options, {plmn_id, Value}}})
    end;
validate_option(node_id, Value) when is_binary(Value) ->
    Value;
validate_option(node_id, Value) when is_list(Value) ->
    iolist_to_binary(Value);
validate_option(accept_new, Value) when is_boolean(Value) ->
    Value;
validate_option(sockets, Value) when ?is_opts(Value) ->
    ergw_socket:validate_options(Value);
validate_option(udsf, Value) when is_list(Value); is_map(Value) ->
    ergw_nudsf_api:validate_options(Value);
validate_option(handlers, Value) when is_list(Value), length(Value) >= 1 ->
    check_unique_keys(handlers, without_opts(['gn', 's5s8'], Value)),
    validate_options(fun validate_handlers_option/2, Value);
validate_option(node_selection, Value) when ?is_opts(Value) ->
    check_unique_keys(node_selection, Value),
    validate_options(fun validate_node_selection_option/2, Value, [], map);
validate_option(nodes, Value) when ?non_empty_opts(Value) ->
    check_unique_keys(nodes, Value),
    {Defaults0, Value1} = take_opt(default, Value, []),
    Defaults = validate_default_node(Defaults0),
    NodeDefaults = Defaults#{connect => false},
    Opts = validate_options(validate_nodes(_, _, NodeDefaults), Value1, [], map),
    Opts#{default => Defaults};
validate_option(ip_pools, Value) when ?is_opts(Value) ->
    check_unique_keys(ip_pools, Value),
    validate_options(fun validate_ip_pools/1, Value, [], map);
validate_option(apns, Value) when ?is_opts(Value) ->
    check_unique_keys(apns, Value),
    validate_options(fun validate_apns/1, Value, [], map);
validate_option(http_api, Value) when ?is_opts(Value) ->
    ergw_http_api:validate_options(Value);
validate_option(charging, Opts)
  when ?non_empty_opts(Opts) ->
    check_unique_keys(charging, Opts),
    validate_options(fun ergw_charging:validate_options/1, Opts, [], map);
validate_option(proxy_map, Opts) ->
    gtp_proxy_ds:validate_options(Opts);
validate_option(path_management, Opts) when ?is_opts(Opts) ->
    gtp_path:validate_options(Opts);
validate_option(teid, Value) ->
    ergw_tei_mngr:validate_option(Value);
validate_option(Opt, Value)
  when Opt == plmn_id;
       Opt == node_id;
       Opt == accept_new;
       Opt == sockets;
       Opt == handlers;
       Opt == node_selection;
       Opt == nodes;
       Opt == ip_pools;
       Opt == apns;
       Opt == http_api;
       Opt == charging;
       Opt == proxy_map;
       Opt == path_management ->
    throw({error, {options, {Opt, Value}}});
validate_option(_Opt, Value) ->
    Value.

validate_mcc_mcn(MCC, MNC)
  when is_binary(MCC) andalso size(MCC) == 3 andalso
       is_binary(MNC) andalso (size(MNC) == 2 orelse size(MNC) == 3) ->
    try {binary_to_integer(MCC), binary_to_integer(MNC)} of
	_ -> ok
    catch
	error:badarg -> error
    end;
validate_mcc_mcn(_, _) ->
    error.

validate_handlers_option(Opt, Values0)
  when ?is_opts(Values0) ->
    Protocol = get_opt(protocol, Values0, Opt),
    Values = set_opt(protocol, Protocol, Values0),
    Handler = get_opt(handler, Values),
    case code:ensure_loaded(Handler) of
	{module, _} ->
	    ok;
	_ ->
	    throw({error, {options, {handler, Values}}})
    end,
    Handler:validate_options(Values);
validate_handlers_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).

validate_node_selection_option(Key, {Type, Opts})
  when is_atom(Key), is_atom(Type) ->
    {Type, ergw_node_selection:validate_options(Type, Opts)};
validate_node_selection_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).

validate_node_vrf_option(features, Features)
  when is_list(Features), length(Features) /= 0 ->
    Rem = lists:usort(Features) --
	['Access', 'Core', 'SGi-LAN', 'CP-Function', 'LI Function', 'TDF-Source'],
    if Rem /= [] ->
	    throw({error, {options, {features, Features}}});
       true ->
	    Features
    end;
validate_node_vrf_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).

validate_node_vrfs({Name, Opts})
  when ?is_opts(Opts) ->
    {vrf:validate_name(Name),
    validate_options(fun validate_node_vrf_option/2, Opts, ?VrfDefaults, map)};
validate_node_vrfs({Name, Opts}) ->
    throw({error, {options, {Name, Opts}}}).

validate_node_default_option(vrfs, VRFs)
  when ?non_empty_opts(VRFs) ->
    check_unique_keys(vrfs, VRFs),
    validate_options(fun validate_node_vrfs/1, VRFs, [], map);
validate_node_default_option(ip_pools, Pools)
  when is_list(Pools) ->
    V = [ergw_ip_pool:validate_name(ip_pools, Name) || Name <- Pools],
    check_unique_elements(ip_pools, V),
    V;
validate_node_default_option(node_selection, Value) ->
    Value;
validate_node_default_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).

validate_node_option(connect, Value) when is_boolean(Value) ->
    Value;
validate_node_option(node_selection, Value) ->
    Value;
validate_node_option(raddr, {_,_,_,_} = RAddr) ->
    RAddr;
validate_node_option(raddr, {_,_,_,_,_,_,_,_} = RAddr) ->
    RAddr;
validate_node_option(rport, Port) when is_integer(Port) ->
    Port;
validate_node_option(Opt, Values) ->
    validate_node_default_option(Opt, Values).

validate_default_node(Opts) when ?is_opts(Opts) ->
    validate_options(fun validate_node_default_option/2, Opts, ?DefaultsNodesDefaults, map);
validate_default_node(Opts) ->
    throw({error, {options, {nodes, default, Opts}}}).

validate_nodes(Name, Opts, Defaults)
  when is_list(Name), ?is_opts(Opts) ->
    validate_options(fun validate_node_option/2, Opts, Defaults, map);
validate_nodes(Opt, Values, _) ->
    throw({error, {options, {Opt, Values}}}).

validate_ip_pools({Name, Values})
  when ?is_opts(Values) ->
    {ergw_ip_pool:validate_name(ip_pools, Name), ergw_ip_pool:validate_options(Values)};
validate_ip_pools({Opt, Value}) ->
    throw({error, {options, {Opt, Value}}}).

validate_apns({APN0, Value}) when ?is_opts(Value) ->
    APN =
	if APN0 =:= '_' -> APN0;
	   true         -> validate_apn_name(APN0)
	end,
    Opts = validate_options(fun validate_apn_option/1, Value, ?ApnDefaults, map),
    mandatory_keys([vrfs], Opts),
    {APN, Opts};
validate_apns({Opt, Value}) ->
    throw({error, {options, {Opt, Value}}}).

validate_apn_name(APN) when is_list(APN) ->
    try
	gtp_c_lib:normalize_labels(APN)
    catch
	error:badarg ->
	    throw({error, {apn, APN}})
    end;
validate_apn_name(APN) ->
    throw({error, {apn, APN}}).

validate_apn_option({vrf, Name}) ->
    {vrfs, [vrf:validate_name(Name)]};
validate_apn_option({vrfs = Opt, VRFs})
  when is_list(VRFs), length(VRFs) /= 0 ->
    V = [vrf:validate_name(Name) || Name <- VRFs],
    check_unique_elements(Opt, V),
    {Opt, V};
validate_apn_option({ip_pools = Opt, Pools})
  when is_list(Pools) ->
    V = [ergw_ip_pool:validate_name(Opt, Name) || Name <- Pools],
    check_unique_elements(Opt, V),
    {Opt, V};
validate_apn_option({bearer_type = Opt, Type})
  when Type =:= 'IPv4'; Type =:= 'IPv6'; Type =:= 'IPv4v6' ->
    {Opt, Type};
validate_apn_option({prefered_bearer_type = Opt, Type})
  when Type =:= 'IPv4'; Type =:= 'IPv6' ->
    {Opt, Type};
validate_apn_option({ipv6_ue_interface_id = Opt, Type})
  when Type =:= default;
       Type =:= random ->
    {Opt, Type};
validate_apn_option({ipv6_ue_interface_id, {0,0,0,0,E,F,G,H}} = Opt)
  when E >= 0, E < 65536, F >= 0, F < 65536,
       G >= 0, G < 65536, H >= 0, H < 65536,
       (E + F + G + H) =/= 0 ->
    Opt;
validate_apn_option({Opt, Value})
  when Opt == 'MS-Primary-DNS-Server';   Opt == 'MS-Secondary-DNS-Server';
       Opt == 'MS-Primary-NBNS-Server';  Opt == 'MS-Secondary-NBNS-Server';
       Opt == 'DNS-Server-IPv6-Address'; Opt == '3GPP-IPv6-DNS-Servers' ->
    {Opt, validate_ip_cfg_opt(Opt, Value)};
validate_apn_option({'Idle-Timeout', Timer})
  when (is_integer(Timer) andalso Timer > 0)
       orelse Timer =:= infinity->
    {'Idle-Timeout', Timer};
validate_apn_option({Opt, Value}) ->
    throw({error, {options, {Opt, Value}}}).

validate_ip6(_Opt, IP) when ?IS_IPv6(IP) ->
    IP;
validate_ip6(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

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
    throw({error, {options, {Opt, Value}}}).

load_handler({_Name, #{protocol := ip, nodes := Nodes} = Opts0}) ->
    Opts = maps:without([protocol, nodes], Opts0),
    lists:foreach(ergw:attach_tdf(_, Opts), Nodes);

load_handler({Name, #{handler  := Handler,
		      protocol := Protocol,
		      sockets  := Sockets} = Opts0}) ->
    Opts = maps:to_list(maps:without([handler, protocol, sockets], Opts0)),
    lists:foreach(ergw:attach_protocol(_, Name, Protocol, Handler, Opts), Sockets).

load_sx_node(default, _) ->
    ok;
load_sx_node(Name, Opts) ->
    ergw:connect_sx_node(Name, Opts).
