%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_core_config).

-compile({parse_transform, cut}).

%% API
-export([load/0,
	 apply/1,
	 validate_options/3,
	 mandatory_keys/2,
	 check_unique_elements/2,
	 validate_ip_cfg_opt/2,
	 to_map/1
	]).

-ifdef(TEST).
-export([validate_config/1]).
-endif.

-define(DefaultOptions, [{plmn_id, {<<"001">>, <<"01">>}},
			 {node_id, undefined},
			 {teid, {0, 0}},
			 {accept_new, true},
			 {cluster, []},
			 {sockets, []},
			 {handlers, #{}},
			 {path_management, []},
			 {node_selection, [{default, {dns, undefined}}]},
			 {nodes, []},
			 {ip_pools, []},
			 {apns, []},
			 {charging, [{default, []}]},
			 {metrics, []}]).

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

%%%===================================================================
%%% API
%%%===================================================================

load() ->
    Config = validate_config(setup:get_all_env(ergw_core)),
    maps:foreach(fun load_env_config/2, Config),
    {ok, Config}.

load_env_config(Key, Value)
  when Key =:= cluster;
       Key =:= path_management;
       Key =:= node_selection;
       Key =:= nodes;
       Key =:= ip_pools;
       Key =:= apns;
       Key =:= charging;
       Key =:= proxy_map;
       Key =:= teid;
       Key =:= node_id;
       Key =:= metrics ->
    ok = application:set_env(ergw_core, Key, Value);
load_env_config(_, _) ->
    ok.

apply(#{sockets := Sockets, nodes := Nodes,
	handlers := Handlers, ip_pools := IPpools} = Config) ->
    maps:map(fun ergw_core:start_socket/2, Sockets),
    maps:map(fun load_sx_node/2, Nodes),
    maps:foreach(fun load_handler/2, Handlers),
    maps:map(fun ergw_core:start_ip_pool/2, IPpools),
    ergw_http_api:init(maps:get(http_api, Config, undefined)),
    ok.

to_map(M) when is_map(M) ->
    M;
to_map(L) when is_list(L) ->
    lists:foldr(
      fun({K, V}, M) when not is_map_key(K, M) ->
	      M#{K => V};
	 (K, M) when is_atom(K) ->
	      M#{K => true};
	 (Opt, _) ->
	      throw({error, {options, Opt}})
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
validate_config(Config) when ?is_opts(Config) ->
    catch (validate_options(fun validate_option/2, Config, ?DefaultOptions)),
    Config.
-else.

validate_config(Config) when ?is_opts(Config) ->
    validate_options(fun validate_option/2, Config, ?DefaultOptions).

-endif.

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

validate_option(plmn_id, {MCC, MNC} = Value) ->
    case validate_mcc_mcn(MCC, MNC) of
       ok -> Value;
       _  -> throw({error, {options, {plmn_id, Value}}})
    end;
validate_option(node_id, Value) when is_binary(Value) ->
    Value;
validate_option(node_id, Value) when is_list(Value) ->
    binary_to_atom(iolist_to_binary(Value));
validate_option(accept_new, Value) when is_boolean(Value) ->
    Value;
validate_option(cluster, Value) when ?is_opts(Value) ->
    ergw_cluster:validate_options(Value);
validate_option(sockets, Value) when ?is_opts(Value) ->
    validate_options(fun ergw_socket:validate_options/2, Value, []);
validate_option(handlers, Value) when ?non_empty_opts(Value) ->
    validate_options(fun ergw_context:validate_options/2, Value, []);
validate_option(node_selection, Value) when ?is_opts(Value) ->
    validate_options(fun ergw_node_selection:validate_options/2, Value, []);
validate_option(nodes, Values) when ?non_empty_opts(Values) ->
    ergw_sx_node:validate_options(to_map(Values));
validate_option(ip_pools, Value) when ?is_opts(Value) ->
    validate_options(fun ergw_ip_pool:validate_options/2, Value, []);
validate_option(apns, Value) when ?is_opts(Value) ->
    validate_options(fun ergw_apn:validate_options/1, Value, []);
validate_option(http_api, Value) when ?is_opts(Value) ->
    ergw_http_api:validate_options(Value);
validate_option(charging, Opts)
  when ?non_empty_opts(Opts) ->
    validate_options(fun ergw_charging:validate_options/1, Opts, []);
validate_option(proxy_map, Opts) ->
    gtp_proxy_ds:validate_options(Opts);
validate_option(path_management, Opts) when ?is_opts(Opts) ->
    gtp_path:validate_options(Opts);
validate_option(teid, Value) ->
    ergw_tei_mngr:validate_option(Value);
validate_option(metrics, Opts) ->
    ergw_prometheus:validate_options(Opts);
validate_option(Opt, Value)
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

load_handler(_Name, #{protocol := ip, nodes := Nodes} = Opts0) ->
    Opts = maps:without([protocol, nodes], Opts0),
    lists:foreach(ergw_core:attach_tdf(_, Opts), Nodes);

load_handler(Name, #{handler  := Handler,
		     protocol := Protocol,
		     sockets  := Sockets} = Opts0) ->
    Opts = maps:without([handler, sockets], Opts0),
    lists:foreach(ergw_core:attach_protocol(_, Name, Protocol, Handler, Opts), Sockets).

load_sx_node(default, _) ->
    ok;
load_sx_node(Name, Opts) ->
    ergw_core:connect_sx_node(Name, Opts).
