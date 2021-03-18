%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_config).

-compile({parse_transform, cut}).

%% API
-export([load/0,
	 apply/1,
	 validate_options/3
	]).

-ifdef(TEST).
-export([validate_config/1]).
-endif.

-define(DefaultOptions, [{node, #{}},
			 {cluster, #{}},
			 {sockets, #{}},
			 {handlers, #{}},
			 {path_management, []},
			 {node_selection, [{default, {dns, undefined}}]},
			 {nodes, #{}},
			 {ip_pools, #{}},
			 {apns, #{}},
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
    Config = validate_config(setup:get_all_env(ergw)),
    {ok, Config}.

apply(#{node := Node,
	node_selection := NodeSel,
	sockets := Sockets,
	nodes := Nodes,
	handlers := Handlers,
	ip_pools := IPpools
       } = Config) ->
    ok = ergw_core:start_node(Node),
    ok = ergw_core:setopts(node_selection, NodeSel),
    maps:map(fun ergw_core:add_socket/2, Sockets),
    maps:map(fun ergw_core:add_sx_node/2, Nodes),
    maps:map(fun ergw_core:add_handler/2, Handlers),
    maps:map(fun ergw_core:add_ip_pool/2, IPpools),
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

validate_config(Config) when ?is_opts(Config) ->
    validate_options(fun validate_option/2, Config, ?DefaultOptions).

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

validate_option(node, Value) when ?is_opts(Value) ->
    ergw_core:validate_options(Value);
validate_option(cluster, Value) when ?is_opts(Value) ->
    ergw_cluster:validate_options(Value);
validate_option(sockets, Value) when ?is_opts(Value) ->
    validate_options(fun ergw_socket:validate_options/2, Value, []);
validate_option(handlers, Value) when ?non_empty_opts(Value) ->
    validate_options(fun ergw_context:validate_options/2, Value, []);
validate_option(node_selection, Values) when ?is_opts(Values) ->
    ergw_node_selection:validate_options(to_map(Values));
validate_option(upf_nodes, Values) when ?non_empty_opts(Values) ->
    validate_options(fun validate_upf_nodes/2, to_map(Values),
		      [{default, #{}}, {nodes, #{}}]);
validate_option(ip_pools, Value) when ?is_opts(Value) ->
    validate_options(fun ergw_ip_pool:validate_options/2, Value, []);
validate_option(apns, Value) when ?is_opts(Value) ->
    validate_options(fun ergw_apn:validate_options/1, Value, []);
validate_option(http_api, Value) when ?is_opts(Value) ->
    ergw_http_api:validate_options(Value);
validate_option(charging, Opts)
  when ?non_empty_opts(Opts) ->
    ergw_charging:validate_options(Opts);
validate_option(proxy_map, Opts) ->
    gtp_proxy_ds:validate_options(Opts);
validate_option(path_management, Opts) when ?is_opts(Opts) ->
    gtp_path:validate_options(Opts);
validate_option(metrics, Opts) ->
    ergw_prometheus:validate_options(Opts);
validate_option(Opt, Value)
  when Opt == node;
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

validate_upf_nodes(default, Values) ->
    ergw_sx_node:validate_defaults(Values);
validate_upf_nodes(nodes, Nodes) ->
    validate_options(fun ergw_sx_node:validate_options/2, to_map(Nodes));
validate_upf_nodes(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).
