%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_compat).

-compile({parse_transform, cut}).

%% API
-export([translate_config/0, translate_config/1]).

-ignore_xref([translate_config/0, translate_config/1]).

-define(DefaultOptions, [{plmn_id, {<<"001">>, <<"01">>}},
			 {node_id, undefined},
			 {teid, {0, 0}},
			 {accept_new, true},
			 {cluster, []},
			 {sockets, []},
			 {handlers, []},
			 {path_management, []},
			 {node_selection, [{default, {dns, undefined}}]},
			 {nodes, []},
			 {ip_pools, []},
			 {apns, []},
			 {charging, [{default, []}]},
			 {metrics, []}]).
-define(VrfDefaults, [{features, invalid}]).
-define(ApnDefaults, [{ip_pools, []},
		      {bearer_type, 'IPv4v6'},
		      {prefered_bearer_type, 'IPv6'},
		      {ipv6_ue_interface_id, default},
		      {'Idle-Timeout', 28800000}         %% 8hrs timer in msecs
		     ]).
-define(DefaultsNodesDefaults, [{vrfs, invalid},
    {node_selection, default},
    {heartbeat, []},
    {request, []}]).

-define(NodeDefaultHeartbeat, [{interval, 5000}, {timeout, 500}, {retry, 5}]).
-define(NodeDefaultRequest, [{timeout, 30000}, {retry, 5}]).

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

-define(IS_IP(X), (is_tuple(X) andalso (tuple_size(X) == 4 orelse tuple_size(X) == 8))).
-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

-define(POW(X, Y), trunc(math:pow(X, Y))).

%%%===================================================================
%%% API
%%%===================================================================

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

to_binary(V) when is_binary(V) ->
    V;
to_binary(V) when is_list(V) ->
    unicode:characters_to_binary(V);
to_binary(V) when is_atom(V) ->
    atom_to_binary(V);
to_binary(V) when is_integer(V) ->
    integer_to_binary(V);
to_binary(V) ->
    iolist_to_binary(io_lib:format("~0p", [V])).

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

translate_config() ->
    JSON = get_json(),
    io:format("~s~n", [jsx:encode(JSON, [{indent, 4}])]),
    ok.

translate_config(File) ->
    JSON = get_json(),
    file:write_file(File, jsx:encode(JSON, [{indent, 4}])).

get_json() ->
    Config = setup:get_all_env(ergw),
    C0 = translate_options(fun translate_option/1, Config, ?DefaultOptions, map),
    NodeOpts = maps:with([accept_new,node_id,plmn_id], C0),
    C1 = maps:without([accept_new,node_id,plmn_id,'$setup_vars'], C0),

    AAA = setup:get_all_env(ergw_aaa),
    A1 = aaa_translate_config(AAA),

    C2 = C1#{node => NodeOpts, aaa => A1},
    ergw_config:serialize_config(C2).

translate_option({nodes, Nodes0}) ->
    Nodes = translate_option(nodes, Nodes0),
    Default = maps:get(default, Nodes),
    Entries = maps:remove(default, Nodes),
    {upf_nodes, #{default => Default, entries => Entries}};
translate_option({vrfs, VRFs}) ->
    {ip_pools, translate_vrfs_to_ip_pools(VRFs)};
translate_option({Opt, Values}) ->
    {Opt, translate_option(Opt, Values)}.

translate_option(Fun, Opt, Value) when is_function(Fun, 2) ->
    {Opt, Fun(Opt, Value)};
translate_option(Fun, Opt, Value) when is_function(Fun, 1) ->
    Fun({Opt, Value}).

translate_options(_Fun, []) ->
    [];
%% translate_options(Fun, [Opt | Tail]) when is_atom(Opt) ->
%%     [translate_option(Fun, Opt, true) | translate_options(Fun, Tail)];
translate_options(Fun, [{Opt, Value} | Tail]) ->
    [translate_option(Fun, Opt, Value) | translate_options(Fun, Tail)].

normalize_proplists(L0) ->
    L = proplists:unfold(L0),
    proplists:substitute_negations([{disable, enable}], L).

%% translate_options/4
translate_options(Fun, Options, Defaults, ReturnType)
  when is_list(Options), is_list(Defaults) ->
    Opts0 = normalize_proplists(Options),
    Opts = lists:ukeymerge(1, lists:keysort(1, Opts0), lists:keysort(1, Defaults)),
    return_type(translate_options(Fun, Opts), ReturnType);
translate_options(Fun, Options, Defaults, ReturnType)
  when is_list(Options), is_map(Defaults) ->
    Opts0 = normalize_proplists(Options),
    Opts = lists:ukeymerge(1, lists:keysort(1, Opts0),
			   lists:keysort(1, maps:to_list(Defaults))),
    return_type(translate_options(Fun, Opts), ReturnType);
translate_options(Fun, Options, Defaults, ReturnType)
  when is_map(Options) andalso ?is_opts(Defaults) ->
    Opts = maps:to_list(maps:merge(to_map(Defaults), Options)),
    return_type(translate_options(Fun, Opts), ReturnType).

translate_option(plmn_id, {MCC, MNC} = Value) ->
    case translate_mcc_mcn(MCC, MNC) of
       ok -> #{mcc => MCC, mnc => MNC};
       _  -> throw({error, {options, {plmn_id, Value}}})
    end;
translate_option(node_id, Value) when is_atom(Value), Value /= undefined ->
    Value;
translate_option(node_id, Value) when is_binary(Value) ->
    binary_to_atom(Value);
translate_option(node_id, Value) when is_list(Value) ->
    binary_to_atom(iolist_to_binary(Value));
translate_option(accept_new, Value) when is_boolean(Value) ->
    Value;
translate_option(cluster, Value) when ?is_opts(Value) ->
    ergw_cluster_translate_options(Value);
translate_option(sockets, Value) when ?is_opts(Value) ->
    ergw_socket_translate_options(Value);
translate_option(handlers, Value) when ?is_opts(Value) ->
    check_unique_keys(handlers, without_opts(['gn', 's5s8'], Value)),
    translate_options(fun translate_handlers_option/1, Value, [], map);
translate_option(node_selection, Value) when ?is_opts(Value) ->
    check_unique_keys(node_selection, Value),
    translate_options(fun translate_node_selection_option/2, Value, [], map);
translate_option(nodes, Value) when ?non_empty_opts(Value) ->
    check_unique_keys(nodes, Value),
    {Defaults0, Value1} = take_opt(default, Value, []),
    Defaults = translate_default_node(Defaults0),
    NodeDefaults = Defaults#{connect => false},
    Opts = translate_options(translate_nodes(_, NodeDefaults), Value1, [], map),
    Opts#{default => Defaults};
translate_option(ip_pools, Value) when ?is_opts(Value) ->
    check_unique_keys(ip_pools, Value),
    translate_options(fun translate_ip_pools/1, Value, [], map);
translate_option(apns, Value) when ?is_opts(Value) ->
    check_unique_keys(apns, Value),
    translate_options(fun translate_apns/1, Value, [], map);
translate_option(http_api, Value) when ?is_opts(Value) ->
    ergw_http_api_translate_options(Value);
translate_option(charging, Opts)
  when ?non_empty_opts(Opts) ->
    check_unique_keys(charging, Opts),
    C0 = translate_options(fun ergw_charging_translate_options/1, Opts, [], map),
    {P, R, RB} =
	maps:fold(
	  fun(K, V, {Profiles0, Rules0, RuleBases0}) ->
		  Profiles = Profiles0#{K => maps:without([rulebase], V)},
		  {Rules1, RuleBases1} =
		      lists:partition(
			fun({_K, V1}) -> is_map(V1) end,
			maps:to_list(maps:get(rulebase, V, #{}))),
		  Rules = maps:merge(Rules0, maps:from_list(Rules1)),
		  RuleBases = maps:merge(RuleBases0, maps:from_list(RuleBases1)),
		  {Profiles, Rules, RuleBases}
	  end, {#{}, #{}, #{}}, C0),
    #{profiles => P, rules => R, rulebase => RB};
translate_option(proxy_map, Opts) ->
    gtp_proxy_ds_translate_options(Opts);
translate_option(path_management, Opts) when ?is_opts(Opts) ->
    gtp_path_translate_options(Opts);
translate_option(teid, Value) ->
    ergw_tei_mngr_translate_option(Value);
translate_option(metrics, Opts) ->
    ergw_prometheus_translate_options(Opts);
translate_option(Opt, Value)
  when Opt == plmn_id;
       Opt == node_id;
       Opt == accept_new;
       Opt == cluster;
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
translate_option(_Opt, Value) ->
    Value.

translate_vrfs_to_ip_pools(VRFs) ->
    translate_options(fun translate_vrf_to_ip_pool/1, VRFs, [], map).

translate_vrf_to_ip_pool({Pool, Opts0}) ->
    Opts = translate_options(fun translate_ip_pool/1, Opts0, [], map),
    {<<"pool-", (to_binary(Pool))/binary>>, Opts#{handler => ergw_local_pool}}.

translate_ip_pool({pools, Pools}) ->
    Ranges =
	[#{start => Start, 'end' => End, prefix_len => PrefixLen}
	 || {Start, End, PrefixLen} <- Pools],
    {ranges, Ranges};
translate_ip_pool({K, V}) ->
    {K, V}.

translate_mcc_mcn(MCC, MNC)
  when is_binary(MCC) andalso size(MCC) == 3 andalso
       is_binary(MNC) andalso (size(MNC) == 2 orelse size(MNC) == 3) ->
    try {binary_to_integer(MCC), binary_to_integer(MNC)} of
	_ -> ok
    catch
	error:badarg -> error
    end;
translate_mcc_mcn(_, _) ->
    error.

translate_handlers_option({Opt, Values}) ->
    {to_binary(Opt), translate_handlers_option(Opt, Values)}.

translate_handlers_option(Opt, Values0)
  when ?is_opts(Values0) ->
    Protocol = get_opt(protocol, Values0, Opt),
    Values = set_opt(protocol, Protocol, Values0),
    case get_opt(handler, Values) of
	ggsn_gn ->
	    ggsn_gn_translate_options(Values);
	ggsn_gn_proxy ->
	    ggsn_gn_proxy_translate_options(Values);
	pgw_s5s8 ->
	    pgw_s5s8_translate_options(Values);
	pgw_s5s8_proxy ->
	    pgw_s5s8_proxy_translate_options(Values);
	saegw_s11 ->
	    saegw_s11_translate_options(Values);
	tdf ->
	    tdf_translate_options(Values);
	_ ->
	    throw({error, {options, {Opt, Values}}})
    end;
translate_handlers_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).

translate_node_selection_option(Key, {static, Opts})
  when is_atom(Key), is_list(Opts), length(Opts) > 0 ->
    Entries = lists:map(fun ergw_node_selection_translate_static_option/1, Opts),
    #{type => static, entries => Entries};
translate_node_selection_option(Key, {dns, Opts})
  when is_atom(Key) ->
    ergw_node_selection_translate_dns(Opts);
translate_node_selection_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).

translate_node_vrf_option(features, Features)
  when is_list(Features), length(Features) /= 0 ->
    Rem = lists:usort(Features) --
	['Access', 'Core', 'SGi-LAN', 'CP-Function', 'LI Function', 'TDF-Source'],
    if Rem /= [] ->
	    throw({error, {options, {features, Features}}});
       true ->
	    Features
    end;
translate_node_vrf_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).

translate_node_vrfs({Name, Opts})
  when ?is_opts(Opts) ->
    {vrf_translate_name(Name),
    translate_options(fun translate_node_vrf_option/2, Opts, ?VrfDefaults, map)};
translate_node_vrfs({Name, Opts}) ->
    throw({error, {options, {Name, Opts}}}).

translate_node_heartbeat({interval, Value} = Opts)
  when is_integer(Value), Value > 100 ->
    Opts;
translate_node_heartbeat({timeout, Value} = Opts)
  when is_integer(Value), Value > 100 ->
    Opts;
translate_node_heartbeat({retry, Value} = Opts)
  when is_integer(Value), Value >= 0 ->
    Opts;
translate_node_heartbeat({Opt, Value}) ->
    throw({error, {options, {Opt, Value}}}).

translate_node_request({timeout, Value} = Opts)
  when is_integer(Value), Value > 100 ->
    Opts;
translate_node_request({retry, Value} = Opts)
  when is_integer(Value), Value >= 0 ->
    Opts;
translate_node_request({Opt, Value}) ->
    throw({error, {options, {Opt, Value}}}).

translate_node_default_option({K = vrfs, VRFs})
  when ?non_empty_opts(VRFs) ->
    check_unique_keys(vrfs, VRFs),
    {K, translate_options(fun translate_node_vrfs/1, VRFs, [], map)};
translate_node_default_option({ip_pools, Pools})
  when is_list(Pools) ->
    V = [ergw_ip_pool_translate_name(ip_pools, Name) || Name <- Pools],
    check_unique_elements(ip_pools, V),
    {ue_ip_pools, [#{ip_pools => V}]};
translate_node_default_option({K = node_selection, Value}) ->
    {K, Value};
translate_node_default_option({K = heartbeat, Opts})
  when ?is_opts(Opts) ->
    {K, translate_options(fun translate_node_heartbeat/1, Opts, ?NodeDefaultHeartbeat, map)};
translate_node_default_option({K = request, Opts})
  when ?is_opts(Opts) ->
    {K, translate_options(fun translate_node_request/1, Opts, ?NodeDefaultRequest, map)};
translate_node_default_option({ue_ip_pools, _} = Opt) ->
    Opt;
translate_node_default_option({Opt, Values}) ->
    throw({error, {options, {Opt, Values}}}).

translate_node_option({K = connect, Value}) when is_boolean(Value) ->
    {K, Value};
translate_node_option({K = node_selection, Value}) ->
    {K, Value};
translate_node_option({K = raddr, {_,_,_,_} = RAddr}) ->
    {K, RAddr};
translate_node_option({K = raddr, {_,_,_,_,_,_,_,_} = RAddr}) ->
    {K, RAddr};
translate_node_option({K = rport, Port}) when is_integer(Port) ->
    {K, Port};
translate_node_option(Opt) ->
    translate_node_default_option(Opt).

translate_default_node(Opts) when ?is_opts(Opts) ->
    translate_options(fun translate_node_default_option/1, Opts, ?DefaultsNodesDefaults, map);
translate_default_node(Opts) ->
    throw({error, {options, {nodes, default, Opts}}}).

translate_nodes({Name, Opts}, Defaults)
  when is_list(Name), ?is_opts(Opts) ->
    {to_binary(Name),
     translate_options(fun translate_node_option/1, Opts, Defaults, map)};
translate_nodes({Opt, Values}, _) ->
    throw({error, {options, {Opt, Values}}}).

translate_ip_pools({Name, Values})
  when ?is_opts(Values) ->
    {ergw_ip_pool_translate_name(ip_pools, Name), ergw_ip_pool_translate_options(Values)};
translate_ip_pools({Opt, Value}) ->
    throw({error, {options, {Opt, Value}}}).

translate_apns({APN0, Value}) when ?is_opts(Value) ->
    APN =
	if APN0 =:= '_' -> APN0;
	   true         -> translate_apn_name(APN0)
	end,
    Opts0 = translate_options(fun translate_apn_option/1, Value, ?ApnDefaults, map),
    Opts =
	case Opts0 of
	    #{ip_pools := [], vrfs := VRFs} ->
		Pools =
		    [<<"pool-", (to_binary(VRF))/binary>> || #{name := VRF} <- VRFs],
		Opts0#{ip_pools => Pools};
	    _ ->
		Opts0
	end,
    mandatory_keys([vrfs], Opts),
    {APN, Opts};
translate_apns({Opt, Value}) ->
    throw({error, {options, {Opt, Value}}}).

translate_apn_name(APN) when is_list(APN) ->
    try
	gtp_c_lib:normalize_labels(APN)
    catch
	error:badarg ->
	    throw({error, {apn, APN}})
    end;
translate_apn_name(APN) ->
    throw({error, {apn, APN}}).

translate_apn_option({vrf, Name}) ->
    {vrfs, [vrf_translate_name(Name)]};
translate_apn_option({vrfs = Opt, VRFs})
  when is_list(VRFs), length(VRFs) /= 0 ->
    V = [vrf_translate_name(Name) || Name <- VRFs],
    check_unique_elements(Opt, V),
    {Opt, V};
translate_apn_option({ip_pools = Opt, Pools})
  when is_list(Pools) ->
    V = [ergw_ip_pool_translate_name(Opt, Name) || Name <- Pools],
    check_unique_elements(Opt, V),
    {Opt, V};
translate_apn_option({bearer_type = Opt, Type})
  when Type =:= 'IPv4'; Type =:= 'IPv6'; Type =:= 'IPv4v6' ->
    {Opt, Type};
translate_apn_option({prefered_bearer_type = Opt, Type})
  when Type =:= 'IPv4'; Type =:= 'IPv6' ->
    {Opt, Type};
translate_apn_option({ipv6_ue_interface_id = Opt, Type})
  when Type =:= default;
       Type =:= random ->
    {Opt, Type};
translate_apn_option({ipv6_ue_interface_id, {0,0,0,0,E,F,G,H}} = Opt)
  when E >= 0, E < 65536, F >= 0, F < 65536,
       G >= 0, G < 65536, H >= 0, H < 65536,
       (E + F + G + H) =/= 0 ->
    Opt;
translate_apn_option({Opt, Value})
  when Opt == 'MS-Primary-DNS-Server';   Opt == 'MS-Secondary-DNS-Server';
       Opt == 'MS-Primary-NBNS-Server';  Opt == 'MS-Secondary-NBNS-Server';
       Opt == 'DNS-Server-IPv6-Address'; Opt == '3GPP-IPv6-DNS-Servers' ->
    {Opt, translate_ip_cfg_opt(Opt, Value)};
translate_apn_option({'Idle-Timeout', Timer})
  when (is_integer(Timer) andalso Timer > 0)
       orelse Timer =:= infinity->
    {inactivity_timeout, Timer};
translate_apn_option({Opt, Value}) ->
    throw({error, {options, {Opt, Value}}}).

translate_ip6(_Opt, IP) when ?IS_IPv6(IP) ->
    IP;
translate_ip6(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

translate_ip_cfg_opt(Opt, {_,_,_,_} = IP)
  when Opt == 'MS-Primary-DNS-Server';
       Opt == 'MS-Secondary-DNS-Server';
       Opt == 'MS-Primary-NBNS-Server';
       Opt == 'MS-Secondary-NBNS-Server' ->
    IP;
translate_ip_cfg_opt(Opt, <<_:32/bits>> = IP)
  when Opt == 'MS-Primary-DNS-Server';
       Opt == 'MS-Secondary-DNS-Server';
       Opt == 'MS-Primary-NBNS-Server';
       Opt == 'MS-Secondary-NBNS-Server' ->
    ergw_inet:bin2ip(IP);
translate_ip_cfg_opt(Opt, DNS)
  when is_list(DNS) andalso
       (Opt == 'DNS-Server-IPv6-Address' orelse
	Opt == '3GPP-IPv6-DNS-Servers') ->
    [translate_ip6(Opt, IP) || IP <- DNS];
translate_ip_cfg_opt(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).


-define(ClusterDefaults, [{enabled, false},
			  {initial_timeout, 60 * 1000},
			  {release_cursor_every, 0},
			  {seed_nodes, {erlang, nodes, [known]}}]).

ergw_cluster_translate_options(Values) ->
    translate_options(fun ergw_cluster_translate_option/2, Values, ?ClusterDefaults, map).

ergw_cluster_translate_option(enabled, Value) when is_boolean(Value) ->
    Value;
ergw_cluster_translate_option(initial_timeout, Value)
  when is_integer(Value), Value > 0 ->
    Value;
ergw_cluster_translate_option(release_cursor_every, Value)
  when is_integer(Value) ->
    Value;
ergw_cluster_translate_option(seed_nodes, {M, F, A} = Value)
  when is_atom(M), is_atom(F), is_list(A) ->
    Value;
ergw_cluster_translate_option(seed_nodes, Nodes) when is_list(Nodes) ->
    lists:foreach(
      fun(Node) when is_atom(Node) -> ok;
	 (Node) ->
	      throw({error, {options, {seed_nodes, Node}}})
      end, Nodes),
    Nodes;
ergw_cluster_translate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

ergw_socket_translate_options(Values) when is_list(Values), length(Values) >= 1 ->
    check_unique_keys(sockets, Values),
    translate_options(fun ergw_socket_translate_option/2, Values, [], map);
ergw_socket_translate_options(Values) ->
    throw({error, {options, {sockets, Values}}}).

ergw_socket_translate_option(Name, Values)
  when is_atom(Name), ?is_opts(Values) ->
    case get_opt(type, Values, undefined) of
	'gtp-c' ->
	    ergw_gtp_socket_translate_options(Name, Values);
	'gtp-u' ->
	    ergw_gtp_socket_translate_options(Name, Values);
	'pfcp' ->
	    ergw_sx_socket_translate_options(Name, Values);
	_ ->
	    throw({error, {options, {Name, Values}}})
    end;
ergw_socket_translate_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).

-define(GtpSocketDefaults, [{ip, invalid}, {burst_size, 10}, {send_port, true}]).

ergw_gtp_socket_translate_options(Name, Values) ->
    translate_options(
      fun ergw_gtp_socket_translate_option/2, Values, [{name, Name}|?GtpSocketDefaults], map).

ergw_gtp_socket_translate_option(name, Value) when is_atom(Value) ->
    Value;
ergw_gtp_socket_translate_option(type, 'gtp-c' = Value) ->
    Value;
ergw_gtp_socket_translate_option(type, 'gtp-u' = Value) ->
    Value;
ergw_gtp_socket_translate_option(ip, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Value;
ergw_gtp_socket_translate_option(cluster_ip, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Value;
ergw_gtp_socket_translate_option(netdev, Value) when is_list(Value) ->
    Value;
ergw_gtp_socket_translate_option(netdev, Value) when is_binary(Value) ->
    unicode:characters_to_list(Value, latin1);
ergw_gtp_socket_translate_option(netns, Value) when is_list(Value) ->
    Value;
ergw_gtp_socket_translate_option(netns, Value) when is_binary(Value) ->
    unicode:characters_to_list(Value, latin1);
ergw_gtp_socket_translate_option(vrf, Value) ->
    vrf_translate_name(Value);
ergw_gtp_socket_translate_option(freebind, Value) when is_boolean(Value) ->
    Value;
ergw_gtp_socket_translate_option(reuseaddr, Value) when is_boolean(Value) ->
    Value;
ergw_gtp_socket_translate_option(send_port, Port)
  when is_integer(Port) andalso
       (Port =:= 0 orelse (Port >= 1024 andalso Port < 65536)) ->
    Port;
ergw_gtp_socket_translate_option(send_port, true) ->
    0;
ergw_gtp_socket_translate_option(send_port, false) ->
    false;
ergw_gtp_socket_translate_option(rcvbuf, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
ergw_gtp_socket_translate_option(burst_size, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
ergw_gtp_socket_translate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

-define(SxSocketDefaults, [{socket, "invalid"},
			 {ip, invalid},
			 {burst_size, 10}]).

ergw_sx_socket_translate_options(Name, Values) ->
    Opts = translate_options(fun ergw_sx_socket_translate_option/2,
			     Values, [{name, Name}|?SxSocketDefaults], map),
    maps:without([node], Opts).

ergw_sx_socket_translate_option(type, pfcp = Value) ->
    Value;
ergw_sx_socket_translate_option(node, Value) ->
    Value;
ergw_sx_socket_translate_option(name, Value) when is_atom(Value) ->
    Value;
ergw_sx_socket_translate_option(ip, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Value;
ergw_sx_socket_translate_option(netdev, Value) when is_list(Value) ->
    Value;
ergw_sx_socket_translate_option(netdev, Value) when is_binary(Value) ->
    unicode:characters_to_list(Value, latin1);
ergw_sx_socket_translate_option(netns, Value) when is_list(Value) ->
    Value;
ergw_sx_socket_translate_option(netns, Value) when is_binary(Value) ->
    unicode:characters_to_list(Value, latin1);
ergw_sx_socket_translate_option(freebind, Value) when is_boolean(Value) ->
    Value;
ergw_sx_socket_translate_option(reuseaddr, Value) when is_boolean(Value) ->
    Value;
ergw_sx_socket_translate_option(rcvbuf, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
ergw_sx_socket_translate_option(socket, Value)
  when is_atom(Value) ->
    Value;
ergw_sx_socket_translate_option(burst_size, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
ergw_sx_socket_translate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

-define(HttpDefaults, [{ip, {127, 0, 0, 1}},
		   {port, 8000},
		   {num_acceptors, 100}]).

ergw_http_api_translate_options(Values) ->
    translate_options(fun ergw_http_api_translate_option/1, Values, ?HttpDefaults, map).

ergw_http_api_translate_option({port, Port} = Opt)
  when is_integer(Port), Port >= 0, Port =< 65535 ->
    Opt;
ergw_http_api_translate_option({acceptors_num, Acceptors})
  when is_integer(Acceptors) ->
    {num_acceptors, Acceptors};
ergw_http_api_translate_option({num_acceptors, Acceptors} = Opt)
  when is_integer(Acceptors) ->
    Opt;
ergw_http_api_translate_option({ip, Value} = Opt)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Opt;
ergw_http_api_translate_option({ipv6_v6only, Value} = Opt) when is_boolean(Value) ->
    Opt;
ergw_http_api_translate_option(Opt) ->
    throw({error, {options, Opt}}).

-define(DefaultChargingOpts, [{rulebase, []}, {online, []}, {offline, []}]).
-define(DefaultRulebase, []).
-define(DefaultRuleDef, []).
-define(DefaultOnlineChargingOpts, []).
-define(DefaultOfflineChargingOpts, [{enable, true}, {triggers, []}]).
-define(DefaultOfflineChargingTriggers,
	[{'cgi-sai-change',		'container'},
	 {'ecgi-change',		'container'},
	 {'max-cond-change',		'cdr'},
	 {'ms-time-zone-change',	'cdr'},
	 {'qos-change',			'container'},
	 {'rai-change',			'container'},
	 {'rat-change',			'cdr'},
	 {'sgsn-sgw-change',		'cdr'},
	 {'sgsn-sgw-plmn-id-change',	'cdr'},
	 {'tai-change',			'container'},
	 {'tariff-switch-change',	'container'},
	 {'user-location-info-change',	'container'}]).

ergw_charging_translate_options({Key, Opts})
  when is_atom(Key), ?is_opts(Opts) ->
    {Key, translate_options(
	    fun ergw_charging_translate_charging_options/2, Opts, ?DefaultChargingOpts, map)}.

%% ergw_charging_translate_rule_def('Service-Identifier', Value) ->
%% ergw_charging_translate_rule_def('Rating-Group', Value) ->
%% ergw_charging_translate_rule_def('Flow-Information', Value) ->
%% ergw_charging_translate_rule_def('Default-Bearer-Indication', Value) ->
%% ergw_charging_translate_rule_def('TDF-Application-Identifier', Value) ->
%% ergw_charging_translate_rule_def('Flow-Status', Value) ->
%% ergw_charging_translate_rule_def('QoS-Information', Value) ->
%% ergw_charging_translate_rule_def('PS-to-CS-Session-Continuity', Value) ->
%% ergw_charging_translate_rule_def('Reporting-Level', Value) ->
%% ergw_charging_translate_rule_def('Online', Value) ->
%% ergw_charging_translate_rule_def('Offline', Value) ->
%% ergw_charging_translate_rule_def('Max-PLR-DL', Value) ->
%% ergw_charging_translate_rule_def('Max-PLR-UL', Value) ->
%% ergw_charging_translate_rule_def('Metering-Method', Value) ->
%% ergw_charging_translate_rule_def('Precedence', Value) ->
%% ergw_charging_translate_rule_def('AF-Charging-Identifier', Value) ->
%% ergw_charging_translate_rule_def('Flows', Value) ->
%% ergw_charging_translate_rule_def('Monitoring-Key', Value) ->
%% ergw_charging_translate_rule_def('Redirect-Information', Value) ->
%% ergw_charging_translate_rule_def('Mute-Notification', Value) ->
%% ergw_charging_translate_rule_def('AF-Signalling-Protocol', Value) ->
%% ergw_charging_translate_rule_def('Sponsor-Identity', Value) ->
%% ergw_charging_translate_rule_def('Application-Service-Provider-Identity', Value) ->
%% ergw_charging_translate_rule_def('Required-Access-Info', Value) ->
%% ergw_charging_translate_rule_def('Sharing-Key-DL', Value) ->
%% ergw_charging_translate_rule_def('Sharing-Key-UL', Value) ->
%% ergw_charging_translate_rule_def('Traffic-Steering-Policy-Identifier-DL', Value) ->
%% ergw_charging_translate_rule_def('Traffic-Steering-Policy-Identifier-UL', Value) ->
%% ergw_charging_translate_rule_def('Content-Version', Value) ->

ergw_charging_translate_rule_def(Key, Value)
  when is_atom(Key) andalso
       is_list(Value) andalso length(Value) /= 0 ->
    Value;
ergw_charging_translate_rule_def(Key, Value) ->
    throw({error, {options, {rule, {Key, Value}}}}).

ergw_charging_translate_rulebase(Key, [Id | _] = RuleBaseDef)
  when is_binary(Key) andalso is_binary(Id) ->
    case lists:usort(RuleBaseDef) of
	S when length(S) /= length(RuleBaseDef) ->
	    throw({error, {options, {rulebase, {Key, RuleBaseDef}}}});
	_ ->
	    ok
    end,

    lists:foreach(fun(RId) when is_binary(RId) ->
			  ok;
		     (RId) ->
			  throw({error, {options, {rule, {Key, RId}}}})
		  end, RuleBaseDef),
    RuleBaseDef;
ergw_charging_translate_rulebase(Key, Rule)
  when is_binary(Key) andalso ?non_empty_opts(Rule) ->
    check_unique_keys(Key, Rule),
    translate_options(fun ergw_charging_translate_rule_def/2, Rule, ?DefaultRuleDef, map);
ergw_charging_translate_rulebase(Key, Rule) ->
    throw({error, {options, {rulebase, {Key, Rule}}}}).

ergw_charging_translate_online_charging_options(Key, Opts) ->
    throw({error, {options, {{online, charging}, {Key, Opts}}}}).

ergw_charging_translate_offline_charging_triggers(Key, Opt)
  when (Opt == 'cdr' orelse Opt == 'off') andalso
       (Key == 'max-cond-change' orelse
	Key == 'ms-time-zone-change' orelse
	Key == 'rat-change' orelse
	Key == 'sgsn-sgw-change' orelse
	Key == 'sgsn-sgw-plmn-id-change') ->
    Opt;
ergw_charging_translate_offline_charging_triggers(Key, Opt)
  when (Opt == 'container' orelse Opt == 'off') andalso
       (Key == 'cgi-sai-change' orelse
	Key == 'ecgi-change' orelse
	Key == 'qos-change' orelse
	Key == 'rai-change' orelse
	Key == 'rat-change' orelse
	Key == 'sgsn-sgw-change' orelse
	Key == 'sgsn-sgw-plmn-id-change' orelse
	Key == 'tai-change' orelse
	Key == 'tariff-switch-change' orelse
	Key == 'user-location-info-change') ->
    Opt;
ergw_charging_translate_offline_charging_triggers(Key, Opts) ->
    throw({error, {options, {{offline, charging, triggers}, {Key, Opts}}}}).

ergw_charging_translate_offline_charging_options(enable, Opt) when is_boolean(Opt) ->
    Opt;
ergw_charging_translate_offline_charging_options(triggers, Opts) ->
    translate_options(fun ergw_charging_translate_offline_charging_triggers/2,
		     Opts, ?DefaultOfflineChargingTriggers, map);
ergw_charging_translate_offline_charging_options(Key, Opts) ->
    throw({error, {options, {{offline, charging}, {Key, Opts}}}}).


ergw_charging_translate_charging_options(rulebase, RuleBase) ->
    check_unique_keys(rulebase, RuleBase),
    translate_options(fun ergw_charging_translate_rulebase/2, RuleBase, ?DefaultRulebase, map);
ergw_charging_translate_charging_options(online, Opts) ->
    translate_options(fun ergw_charging_translate_online_charging_options/2,
		     Opts, ?DefaultOnlineChargingOpts, map);
ergw_charging_translate_charging_options(offline, Opts) ->
    translate_options(fun ergw_charging_translate_offline_charging_options/2,
		     Opts, ?DefaultOfflineChargingOpts, map);
ergw_charging_translate_charging_options(Key, Opts) ->
    throw({error, {options, {charging, {Key, Opts}}}}).


gtp_proxy_ds_translate_options(Values) ->
    translate_options(fun gtp_proxy_ds_translate_option/2, Values, [], map).

gtp_proxy_ds_translate_imsi(From, To) when is_binary(From), is_binary(To) ->
    To;
gtp_proxy_ds_translate_imsi(From, {IMSI, MSISDN} = To)
  when is_binary(From), is_binary(IMSI), is_binary(MSISDN) ->
    To;
gtp_proxy_ds_translate_imsi(From, To) ->
    throw({error, {options, {From, To}}}).

gtp_proxy_ds_translate_apn([From|_], [To|_] = APN) when is_binary(From), is_binary(To) ->
    APN;
gtp_proxy_ds_translate_apn(From, To) ->
    throw({error, {options, {From, To}}}).

gtp_proxy_ds_translate_option(imsi, Opts) when ?non_empty_opts(Opts) ->
    check_unique_keys(imsi, Opts),
    translate_options(fun gtp_proxy_ds_translate_imsi/2, Opts, [], map);
gtp_proxy_ds_translate_option(apn, Opts) when ?non_empty_opts(Opts) ->
    check_unique_keys(apn, Opts),
    translate_options(fun gtp_proxy_ds_translate_apn/2, Opts, [], map);
gtp_proxy_ds_translate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

-define(PathDefaults, [
    {t3, 10 * 1000},                  % echo retry interval
    {n3,  5},                         % echo retry count
    {echo, 60 * 1000},                % echo ping interval
    {idle_timeout, 1800 * 1000},      % time to keep the path entry when idle
    {idle_echo,     600 * 1000},      % echo retry interval when idle
    {down_timeout, 3600 * 1000},      % time to keep the path entry when down
    {down_echo,     600 * 1000},      % echo retry interval when down
    {icmp_error_handling, immediate}  % configurable GTP path ICMP error behaviour
]).

gtp_path_translate_options(Values) ->
    #{t3 := T3, n3 := N3,
      echo := BusyEcho,
      icmp_error_handling := ICMP,
      idle_echo := IdleEcho, idle_timeout := IdleTimeout,
      down_echo := DownEcho, down_timeout := DownTimeout} =
	translate_options(fun gtp_path_translate_option/2, Values, ?PathDefaults, map),

    Evs0 = #{icmp_error => warning, echo_timeout => critical},
    Events = case ICMP of
		 immediate -> Evs0#{icmp_error := critical};
		 _ -> Evs0
	     end,
    SetS = #{t3 => T3, n3 => N3, events => Events},
    #{busy => SetS#{echo => BusyEcho},
      idle => SetS#{echo => IdleEcho, timeout => IdleTimeout},
      down => SetS#{echo => DownEcho, timeout => DownTimeout, notify => active},
      suspect => SetS#{echo => 60 * 1000, timeout => 300 * 1000}}.

gtp_path_translate_echo(_Opt, Value) when is_integer(Value), Value >= 60 * 1000 ->
    Value;
gtp_path_translate_echo(_Opt, off = Value) ->
    Value;
gtp_path_translate_echo(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

gtp_path_translate_timeout(_Opt, Value) when is_integer(Value), Value >= 0 ->
    Value;
gtp_path_translate_timeout(_Opt, infinity = Value) ->
    Value;
gtp_path_translate_timeout(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

gtp_path_translate_option(t3, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
gtp_path_translate_option(n3, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
gtp_path_translate_option(Opt, Value)
  when Opt =:= echo; Opt =:= idle_echo; Opt =:= down_echo ->
    gtp_path_translate_echo(Opt, Value);
gtp_path_translate_option(Opt, Value)
  when Opt =:= idle_timeout; Opt =:= down_timeout ->
    gtp_path_translate_timeout(Opt, Value);
gtp_path_translate_option(icmp_error_handling, Value)
  when Value =:= immediate; Value =:= ignore ->
    Value;
gtp_path_translate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

ergw_tei_mngr_translate_option({Prefix, Len} = Value)
  when is_integer(Prefix), is_integer(Len),
       Len >= 0, Len =< 8, Prefix >= 0 ->
    case ?POW(2, Len) of
	X when X > Prefix -> #{prefix => Prefix, len => Len};
	_ ->
	    throw({error, {options, {teid, Value}}})
    end;
ergw_tei_mngr_translate_option(Value) ->
    throw({error, {options, {teid, Value}}}).

-define(DefaultMetricsOpts, [{gtp_path_rtt_millisecond_intervals, [10, 30, 50, 75, 100, 1000, 2000]}]).

ergw_prometheus_translate_options(Opts) ->
    translate_options(fun ergw_prometheus_translate_option/2, Opts, ?DefaultMetricsOpts, map).

ergw_prometheus_translate_option(gtp_path_rtt_millisecond_intervals = Opt, Value) ->
    case [V || V <- Value, is_integer(V), V > 0] of
	[_|_] = Value ->
	    Value;
	_ ->
	    throw({error, {options, {Opt, Value}}})
    end.

ergw_node_selection_translate_ip_list(L) ->
    lists:map(
      fun(IP) when ?IS_IP(IP) -> IP;
	 (IP) -> throw({error, {options, {ip, IP}}})
      end, L).

ergw_node_selection_translate_static_option({Label, {Order, Prio}, [{_,_}|_] = Services, Host})
  when is_list(Label),
       is_integer(Order),
       is_integer(Prio),
       is_list(Host) ->
    {[Service|_], Protocols} = lists:unzip(Services),
    #{type => naptr,
      name => to_binary(Label),
      order => Order,
      preference => Prio,
      service => to_binary(Service),
      protocols => [to_binary(P) || P <- Protocols],
      replacement => to_binary(Host)};
ergw_node_selection_translate_static_option({Host, IP4, IP6})
  when is_list(Host),
       is_list(IP4),
       is_list(IP6),
       (length(IP4) /= 0 orelse length(IP6) /= 0) ->
    #{type => host,
      name => to_binary(Host),
      ip4 => ergw_node_selection_translate_ip_list(IP4),
      ip6 => ergw_node_selection_translate_ip_list(IP6)};
ergw_node_selection_translate_static_option(Opt) ->
    throw({error, {options, {static, Opt}}}).

ergw_node_selection_translate_dns(IP) when ?IS_IP(IP) ->
    #{type => dns, server => IP, port => 53};
ergw_node_selection_translate_dns({IP, Port})
  when ?IS_IP(IP) andalso is_integer(Port) ->
    #{type => dns, server => IP, port => Port};
ergw_node_selection_translate_dns(Opts) ->
    throw({error, {dns, Opts}}).

vrf_translate_name(Name) ->
    try
	vrf_normalize_name(Name)
    catch
	_:_ ->
	    throw({error, {options, {vrf, Name}}})
    end.

vrf_normalize_name(Name)
  when is_atom(Name) ->
    List = binary:split(atom_to_binary(Name, latin1), [<<".">>], [global, trim_all]),
    vrf_normalize_name(List);
vrf_normalize_name([Label | _] = Name)
  when is_binary(Label) ->
    << <<(size(L)):8, L/binary>> || L <- Name >>;
vrf_normalize_name(Name)
  when is_list(Name) ->
    List = binary:split(list_to_binary(Name), [<<".">>], [global, trim_all]),
    vrf_normalize_name(List);
vrf_normalize_name(Name)
  when is_binary(Name) ->
    Name.

ergw_ip_pool_translate_options(Options) ->
    case get_opt(handler, Options, ergw_local_pool) of
	ergw_local_pool ->
	    ergw_local_pool_translate_options(Options);
	Handler ->
	    throw({error, {options, {handler, Handler}}})
    end.

ergw_ip_pool_translate_name(_, Name) when is_binary(Name) ->
    Name;
ergw_ip_pool_translate_name(_, Name) when is_list(Name) ->
    unicode:characters_to_binary(Name, utf8);
ergw_ip_pool_translate_name(_, Name) when is_atom(Name) ->
    atom_to_binary(Name, utf8);
ergw_ip_pool_translate_name(Opt, Name) ->
   throw({error, {options, {Opt, Name}}}).

-define(DefaultPoolOptions, [{handler, ergw_local_pool}, {ranges, []}]).

ergw_local_pool_translate_options(Options) ->
    translate_options(fun ergw_local_pool_translate_option/2, Options, ?DefaultPoolOptions, map).

ergw_local_pool_translate_ip_range({Start, End, PrefixLen} = Range)
  when ?IS_IPv4(Start), ?IS_IPv4(End), End > Start,
       is_integer(PrefixLen), PrefixLen > 0, PrefixLen =< 32 ->
    Range;
ergw_local_pool_translate_ip_range({Start, End, PrefixLen} = Range)
  when ?IS_IPv6(Start), ?IS_IPv6(End), End > Start,
       is_integer(PrefixLen), PrefixLen > 0, PrefixLen =< 128 ->
    if PrefixLen =:= 127 ->
	    throw({error, {options, {range, Range}}});
       PrefixLen =/= 64 ->
	    Range;
       true ->
	    Range
    end;
ergw_local_pool_translate_ip_range(Range) ->
    throw({error, {options, {range, Range}}}).

ergw_local_pool_translate_option(ranges, Ranges)
  when is_list(Ranges), length(Ranges) /= 0 ->
    [begin
	 {Start, End, Len} = ergw_local_pool_translate_ip_range(X),
	 #{start => Start, 'end' => End, prefix_len => Len}
     end || X <- Ranges];
ergw_local_pool_translate_option(Opt, Value)
  when Opt == 'MS-Primary-DNS-Server';   Opt == 'MS-Secondary-DNS-Server';
       Opt == 'MS-Primary-NBNS-Server';  Opt == 'MS-Secondary-NBNS-Server';
       Opt == 'DNS-Server-IPv6-Address'; Opt == '3GPP-IPv6-DNS-Servers' ->
    translate_ip_cfg_opt(Opt, Value);
ergw_local_pool_translate_option(Opt, Pool)
  when Opt =:= 'Framed-Pool';
       Opt =:= 'Framed-IPv6-Pool' ->
    ergw_ip_pool_translate_name(Opt, Pool);
ergw_local_pool_translate_option(handler, Value) ->
    Value;
ergw_local_pool_translate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).


-define(GtpContextDefaults, [{node_selection, undefined},
			  {aaa,            []}]).

-define(DefaultAAAOpts,
	#{
	  'AAA-Application-Id' => ergw_aaa_provider,
	  'Username' => #{default => <<"ergw">>,
			  from_protocol_opts => true},
	  'Password' => #{default => <<"ergw">>}
	 }).

gtp_context_translate_options(Fun, Opts, Defaults) ->
    translate_options(Fun, Opts, Defaults ++ ?GtpContextDefaults, map).

gtp_context_translate_option(protocol, Value)
  when Value == 'gn' orelse
       Value == 's5s8' orelse
       Value == 's11' ->
    Value;
gtp_context_translate_option(handler, Value) when is_atom(Value) ->
    Value;
gtp_context_translate_option(sockets, Value) when is_list(Value) ->
    Value;
gtp_context_translate_option(node_selection, [S|_] = Value)
  when is_atom(S) ->
    Value;
gtp_context_translate_option(aaa, Value) when is_list(Value); is_map(Value) ->
    opts_fold(fun gtp_context_translate_aaa_option/3, ?DefaultAAAOpts, Value);
gtp_context_translate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

gtp_context_translate_aaa_option(Key, AppId, AAA)
  when Key == appid; Key == 'AAA-Application-Id' ->
    AAA#{'AAA-Application-Id' => AppId};
gtp_context_translate_aaa_option(Key, Value, AAA)
  when (is_list(Value) orelse is_map(Value)) andalso
       (Key == 'Username' orelse Key == 'Password') ->
    %% Attr = maps:get(Key, AAA),
    %% maps:put(Key, opts_fold(gtp_context_translate_aaa_attr_option(Key, _, _, _), Attr, Value), AAA);

    %% maps:update_with(Key, fun(Attr) ->
    %% 				  opts_fold(gtp_context_translate_aaa_attr_option(Key, _, _, _), Attr, Value)
    %% 			  end, AAA);
    maps:update_with(Key, opts_fold(gtp_context_translate_aaa_attr_option(Key, _, _, _), _, Value), AAA);

gtp_context_translate_aaa_option(Key, Value, AAA)
  when Key == '3GPP-GGSN-MCC-MNC' ->
    {MCC, MNC, _} = itu_e212:split_imsi(Value),
    AAA#{'3GPP-GGSN-MCC-MNC' => {MCC, MNC}};
gtp_context_translate_aaa_option(Key, Value, _AAA) ->
    throw({error, {options, {aaa, {Key, Value}}}}).

gtp_context_translate_aaa_attr_option('Username', default, Default, Attr) ->
    Attr#{default => Default};
gtp_context_translate_aaa_attr_option('Username', from_protocol_opts, Bool, Attr)
  when Bool == true; Bool == false ->
    Attr#{from_protocol_opts => Bool};
gtp_context_translate_aaa_attr_option('Password', default, Default, Attr) ->
    Attr#{default => Default};
gtp_context_translate_aaa_attr_option(Key, Setting, Value, _Attr) ->
    throw({error, {options, {aaa_attr, {Key, Setting, Value}}}}).

-define(ProxyDefaults, [{proxy_data_source, gtp_proxy_ds},
			{proxy_sockets,     []},
			{contexts,          []}]).

-define(ProxyContextDefaults, []).

ergw_proxy_lib_translate_options(Fun, Opts, Defaults) ->
    gtp_context_translate_options(Fun, Opts, Defaults ++ ?ProxyDefaults).

ergw_proxy_lib_translate_option(proxy_data_source, Value) ->
    case code:ensure_loaded(Value) of
	{module, _} ->
	    ok;
	_ ->
	    throw({error, {options, {proxy_data_source, Value}}})
    end,
    Value;
ergw_proxy_lib_translate_option(Opt, Value)
  when Opt == proxy_sockets ->
    ergw_proxy_lib_translate_context_option(Opt, Value);
ergw_proxy_lib_translate_option(contexts, Values) when is_list(Values); is_map(Values) ->
    opts_fold(fun ergw_proxy_lib_translate_context/3, #{}, Values);
ergw_proxy_lib_translate_option(Opt, Value) ->
    gtp_context_translate_option(Opt, Value).

ergw_proxy_lib_translate_context_option(proxy_sockets, Value) when is_list(Value), Value /= [] ->
    Value;
ergw_proxy_lib_translate_context_option(node_selection, [S|_] = Value)
  when is_atom(S) ->
    Value;
ergw_proxy_lib_translate_context_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

ergw_proxy_lib_translate_context(Name, Opts0, Acc)
  when is_binary(Name) andalso ?is_opts(Opts0) ->
    Opts = translate_options(
	     fun ergw_proxy_lib_translate_context_option/2, Opts0, ?ProxyContextDefaults, map),
    Acc#{Name => Opts};
ergw_proxy_lib_translate_context(Name, Opts, _Acc) ->
    throw({error, {options, {contexts, {Name, Opts}}}}).

ggsn_gn_translate_options(Options) ->
    gtp_context_translate_options(fun ggsn_gn_translate_option/2, Options, []).

ggsn_gn_translate_option(Opt, Value) ->
    gtp_context_translate_option(Opt, Value).

pgw_s5s8_translate_options(Options) ->
    gtp_context_translate_options(fun pgw_s5s8_translate_option/2, Options, []).

pgw_s5s8_translate_option(Opt, Value) ->
    gtp_context_translate_option(Opt, Value).

saegw_s11_translate_options(Options) ->
    gtp_context_translate_options(fun saegw_s11_translate_option/2, Options, []).

saegw_s11_translate_option(Opt, Value) ->
    gtp_context_translate_option(Opt, Value).

ggsn_gn_proxy_translate_options(Opts) ->
    ergw_proxy_lib_translate_options(fun ggsn_gn_proxy_translate_option/2, Opts, ?ProxyContextDefaults).

ggsn_gn_proxy_translate_option(Opt, Value) ->
    ergw_proxy_lib_translate_option(Opt, Value).

pgw_s5s8_proxy_translate_options(Opts) ->
    ergw_proxy_lib_translate_options(fun pgw_s5s8_proxy_translate_option/2, Opts, ?ProxyContextDefaults).

pgw_s5s8_proxy_translate_option(Opt, Value) ->
    ergw_proxy_lib_translate_option(Opt, Value).

-define(TdfHandlerDefaults, [{node_selection, undefined},
			  {nodes, undefined},
			  {apn, undefined}]).

tdf_translate_options(Options) ->
    translate_options(fun tdf_translate_option/2, Options, ?TdfHandlerDefaults, map).

tdf_translate_option(protocol, ip) ->
    ip;
tdf_translate_option(handler, Value) when is_atom(Value) ->
    Value;
tdf_translate_option(node_selection, [S|_] = Value)
  when is_atom(S) ->
    Value;
tdf_translate_option(nodes, [S|_] = Value)
  when is_list(S) ->
    Value;
tdf_translate_option(apn, APN)
  when is_list(APN) ->
    translate_apn_name(APN);
tdf_translate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% ergw_aaa
%%%===================================================================

-define(DefaultRateLimit, [{outstanding_requests, 50},
			   {rate, 50}
			  ]).
-define(DefaultAAAOptions, [{product_name, "erGW-AAA"},
			 {functions, []}
			]).

aaa_translate_config(Config0) ->
    Config1 = translate_keyed_opt(functions, fun aaa_translate_function/2, Config0, []),
    Config2 = translate_keyed_opt(handlers, fun aaa_translate_handler/2, Config1, []),
    Config3 = translate_keyed_opt(services, aaa_translate_service(_, _, Config2), Config2, []),
    Config4 = translate_keyed_opt(apps, aaa_translate_app(_, _, Config3), Config3, []),
    Config = aaa_translate_rate_limits(Config4),
    translate_options(fun aaa_translate_option/2, Config, ?DefaultAAAOptions, map).

aaa_translate_option(product_name, Value)
  when is_list(Value); is_binary(Value) ->
    to_binary(Value);
aaa_translate_option(Opt, Value)
  when Opt == product_name ->
    throw({error, {options, {Opt, Value}}});
aaa_translate_option(_Opt, Value) ->
    Value.

translate_keyed_opt(Key, Fun, Config, Default) ->
    case get_opt(Key, Config, Default) of
	Values when ?is_opts(Values) ->
	    check_unique_keys(Key, Values),
	    V = translate_options(Fun, Values, [], map),
	    set_opt(Key, V, Config);
	Values ->
	    throw({error, {options, {Key, Values}}})
    end.

aaa_translate_function(_Function, Opts) ->
    translate_options(fun aaa_translate_function_option/2, Opts, [], map).

aaa_translate_function_option(transports, Opts) when is_list(Opts) ->
    lists:map(fun to_map/1, Opts);
aaa_translate_function_option(_, Opt) ->
    Opt.

aaa_translate_answers(_, {ocs_hold, GCU}) when is_list(GCU) ->
    #{avps =>
	  #{'Result-Code' => 2001,
	    'Multiple-Services-Credit-Control' => GCU},
      state => ocs_hold};
aaa_translate_answers(_, AVPs) when is_map(AVPs) ->
    #{avps => AVPs}.

aaa_translate_answers(Answers) ->
    maps:map(fun aaa_translate_answers/2, Answers).

aaa_translate_handler(ergw_aaa_static, Opts0) when is_map(Opts0) ->
    {Answers, Opts} = take_opt(answers, Opts0, #{}),
    #{answers => aaa_translate_answers(Answers), defaults => Opts};
aaa_translate_handler(ergw_aaa_radius, Opts) ->
    translate_options(fun aaa_translate_radius_option/2, Opts, [], map);
aaa_translate_handler(Handler, Opts) when is_list(Opts) ->
    aaa_translate_handler(Handler, to_map(Opts));
aaa_translate_handler(_Handler, Opts) when is_map(Opts) ->
    translate_options(fun aaa_translate_handler_option/2, Opts, [], map).

aaa_translate_radius_option(server, {IP, Port, Secret}) ->
    #{host => IP, port => Port, secret => Secret};
aaa_translate_radius_option(termination_cause_mapping, Mapping) when is_list(Mapping) ->
    to_map(Mapping);
aaa_translate_radius_option(_, Opts) ->
    Opts.

aaa_translate_handler_option(answers, Answers) ->
    aaa_translate_answers(Answers);
aaa_translate_handler_option(_, Opts) ->
    Opts.

aaa_translate_service(_Service, Opts, _Config) ->
    Handler = proplists:get_value(handler, Opts),
    aaa_translate_handler(Handler, Opts).

aaa_translate_app(App, Opts, Config) ->
    AppDef = translate_options(aaa_translate_app_option(App, _, _, Config), Opts, [], map),
    Init = maps:get(session, AppDef, []),
    Procedures = maps:get(procedures, AppDef, #{}),
    maps:map(
      fun(_, V) ->
	      lists:map(
		fun({S, [{answer, A}]}) -> #{service => S, answer => A};
		   ({S, _}) -> #{service => S};
		   (S) -> #{service => S}
		end, V)
      end, Procedures#{init => Init}).

aaa_translate_app_option(App, session, Services, Config)
  when is_list(Services) ->
    translate_options(
      aaa_translate_app_procs_svc(App, init, _, _, Config), Services, [], list);
aaa_translate_app_option(App, procedures, Procedures, Config)
  when ?is_opts(Procedures) ->
    translate_options(aaa_translate_app_procs_option(App, _, _, Config), Procedures, [], map);
aaa_translate_app_option(App, Opt, Value, _Config) ->
    throw({error, {options, {App, Opt, Value}}}).

aaa_translate_app_procs_option(App, Procedure, Services, Config)
  when is_list(Services) ->
    translate_options(
      aaa_translate_app_procs_svc(App, Procedure, _, _, Config), Services, [], list);
aaa_translate_app_procs_option(App, Procedure, Services, _Config) ->
    throw({error, {options, {App, Procedure, Services}}}).

aaa_translate_app_procs_svc(App, Procedure, Service, true, Config) ->
    aaa_translate_app_procs_svc(App, Procedure, Service, [], Config);
aaa_translate_app_procs_svc(_App, _Procedure, _Service, Opts, _Config)
  when ?is_opts(Opts) ->
    Opts;
aaa_translate_app_procs_svc(App, Procedure, Service, Opts, _Config) ->
    throw({error, {options, {App, Procedure, Service, Opts}}}).

aaa_translate_rate_limits(Config) ->
    RateLimits = get_opt(rate_limits, Config, [{default, ?DefaultRateLimit}]),
    {Default, Peers} = take_opt(default, RateLimits, ?DefaultRateLimit),
    check_unique_keys(rate_limits, Peers),
    Limits = #{default => translate_options(
			    aaa_translate_rate_limit_option(default, _, _), Default, [], map),
	       peers => translate_options(fun aaa_translate_rate_limit/2, Peers, [], map)},
    set_opt(rate_limits, Limits, Config).

aaa_translate_rate_limit(RateLimit, Opts) ->
    translate_options(
      aaa_translate_rate_limit_option(RateLimit, _, _), Opts, [], map).

aaa_translate_rate_limit_option(_RateLimit, outstanding_requests, Reqs)
  when is_integer(Reqs) andalso Reqs > 0 ->
    Reqs;
aaa_translate_rate_limit_option(_RateLimit, rate, Rate)
  when is_integer(Rate) andalso Rate > 0 andalso Rate < 100000 ->
    Rate;
aaa_translate_rate_limit_option(RateLimit, Opt, Value) ->
    throw({error, {options, {RateLimit, Opt, Value}}}).
