%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_config).

-compile({parse_transform, cut}).
-compile({parse_transform, do}).

-compile({no_auto_import,[put/2]}).

%% API
-export([load/0,
	 apply/1,
	 %% ergw_core_init/1,
	 normalize_meta/1,
	 serialize_config/1,
	 serialize_config/2,
	 coerce_config/1,
	 coerce_config/2
	]).

-ifdef(TEST).
-export([config_meta/0, load_schemas/0, validate_config_with_schema/1]).
-endif.

-type(meta() :: term()).
-export_type([meta/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("parse_trans/include/exprecs.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-export_records([up_function_features]).

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

%%%===================================================================
%%% API
%%%===================================================================

load() ->
    load_typespecs(),
    do([error_m ||
	   load_schemas(),
	   Config <- load_config(),
	   return(Config)
       ]).

load_config() ->
    {ok, Config} = application:get_env(ergw, config),
    load_config(Config).

load_config(Config) when is_list(Config) ->
    load_config(maps:from_list(Config));
load_config(#{file := File, type := Type})
  when (is_list(File) orelse is_binary(File)) andalso
       (Type =:= yaml orelse Type =:= json) ->
    do([error_m ||
	   Bin <- file:read_file(File),
	   Config <- case Type of
			 yaml ->
			     parse_yaml(Bin);
			 json ->
			     parse_json(Bin)
		     end,
	   validate_config_with_schema(Config),
	   return(coerce_config(Config))
       ]);
load_config(Config) ->
    erlang:error(badarg, [Config]).

parse_yaml(Bin) ->
    case fast_yaml:decode(Bin, [{maps, true}, sane_scalars]) of
	{ok, [Terms]} ->
	    {ok, Terms};
	Other ->
	    Other
    end.

parse_json(Bin) ->
    try
	Dec = jsx:decode(Bin, [return_maps, {labels, binary}]),
	{ok, Dec}
    catch
	exit:badarg ->
	    {error, invalid_json}
    end.

apply(Config) ->
    ergw_core_init(Config),
    ok.

ergw_core_init(Config) ->
    Init = [node, wait_till_running, path_management, node_selection,
	    sockets, upf_nodes, handlers, ip_pools, apns, charging, proxy_map],
    lists:foreach(ergw_core_init(_, Config), Init).

ergw_core_init(node, #{node := Node}) ->
    ergw_core:start_node(Node);
ergw_core_init(wait_till_running, _) ->
    ergw_core:wait_till_running();
ergw_core_init(path_management, #{path_management := NodeSel}) ->
    ok = ergw_core:setopts(path_management, NodeSel);
ergw_core_init(node_selection, #{node_selection := NodeSel}) ->
    ok = ergw_core:setopts(node_selection, NodeSel);
ergw_core_init(sockets, #{sockets := Sockets}) ->
    maps:map(fun ergw_core:add_socket/2, Sockets);
ergw_core_init(upf_nodes, #{upf_nodes := UP}) ->
    ergw_core:setopts(sx_defaults, maps:get(default, UP, #{})),
    maps:map(fun ergw_core:add_sx_node/2, maps:get(entries, UP, #{}));
ergw_core_init(handlers, #{handlers := Handlers}) ->
    maps:map(fun ergw_core:add_handler/2, Handlers);
ergw_core_init(ip_pools, #{ip_pools := Pools}) ->
    maps:map(fun ergw_core:add_ip_pool/2, Pools);
ergw_core_init(apns, #{apns := APNs}) ->
    maps:map(fun ergw_core:add_apn/2, APNs);
ergw_core_init(charging, #{charging := Charging}) ->
    Init = [rules, rulebase, profile],
    lists:foreach(ergw_charging_init(_, Charging), Init);
ergw_core_init(proxy_map, #{proxy_map := Map}) ->
    ok = ergw_core:setopts(proxy_map, Map);
ergw_core_init(_K, _) ->
    ok.

ergw_charging_init(rules, #{rules := Rules}) ->
    maps:map(fun ergw_core:add_charging_rule/2, Rules);
ergw_charging_init(rulebase, #{rulebase := RuleBase}) ->
    maps:map(fun ergw_core:add_charging_rulebase/2, RuleBase);
ergw_charging_init(profiles, #{profiles := Profiles}) ->
    maps:map(fun ergw_core:add_charging_profile/2, Profiles);
ergw_charging_init(_, _) ->
    ok.

load_schemas() ->
    jesse:load_schemas(
      filename:join([code:lib_dir(ergw, priv), "schemas"]),
      fun (Bin) ->
	      {ok, [Terms]} = fast_yaml:decode(Bin, [{maps, true}, sane_scalars]),
	      Terms
      end).

%%%===================================================================
%%% config metadata
%%%===================================================================

config_raw_meta() ->
    #{node            => config_meta_node(),
      apns            => config_meta_apns(),
      charging        => config_meta_charging(),
      cluster         => config_meta_cluster(),
      handlers        => config_meta_handler(),
      http_api        => config_meta_http_api(),
      ip_pools        => config_meta_ip_pools(),
      metrics         => config_meta_metrics(),
      node_selection  => config_meta_node_selection(),
      upf_nodes       => config_meta_nodes(),
      path_management => config_meta_path_management(),
      proxy_map       => config_meta_proxy_map(),
      sockets         => config_meta_socket(),
      teid            => config_meta_tei_mngr()}.

config_meta() ->
    load_typespecs(),
    normalize_meta(config_raw_meta()).

config_meta_node() ->
    #{accept_new      => boolean,
      node_id         => binary,
      plmn_id         => #{mcc => mcc,
			   mnc => mnc}}.

config_meta_apns() ->
    Meta = #{vrf                  => vrf,
	     vrfs                 => {list, vrf},
	     ip_pools             => {list, binary},
	     bearer_type          => atom,
	     prefered_bearer_type => atom,
	     ipv6_ue_interface_id => ip6_ifid,
	     'MS-Primary-DNS-Server'    => ip4_address,
	     'MS-Secondary-DNS-Server'  => ip4_address,
	     'MS-Primary-NBNS-Server'   => ip4_address,
	     'MS-Secondary-NBNS-Server' => ip4_address,
	     'DNS-Server-IPv6-Address'  => {list, ip6_address},
	     '3GPP-IPv6-DNS-Servers'    => {list, ip6_address},
	     'Idle-Timeout'             => timeout
	    },
    {map, {apn, apn}, Meta}.

config_meta_charging() ->
    Triggers = #{'cgi-sai-change'            => atom,
		 'ecgi-change'               => atom,
		 'max-cond-change'           => atom,
		 'ms-time-zone-change'       => atom,
		 'qos-change'                => atom,
		 'rai-change'                => atom,
		 'rat-change'                => atom,
		 'sgsn-sgw-change'           => atom,
		 'sgsn-sgw-plmn-id-change'   => atom,
		 'tai-change'                => atom,
		 'tariff-switch-change'      => atom,
		 'user-location-info-change' => atom},
    Online = #{},
    Offline = #{enable => boolean,
		triggers => Triggers},
    Optional = fun(X) ->
		       #cnf_value{type = {optional, normalize_meta(X)}}
	       end,
    FlowInfo = #{'Flow-Description' => Optional(binary),
		 'Flow-Direction'  => Optional(integer)},
    Rule = #{'Service-Identifier' => Optional(atom),      %%tbd: this is most likely wrong
	     'Rating-Group' => Optional(integer),
	     'Online-Rating-Group' => Optional(integer),
	     'Offline-Rating-Group' => Optional(integer),
	     'Flow-Information' => {list, FlowInfo},
	     %% 'Default-Bearer-Indication'
	     'TDF-Application-Identifier' => Optional(binary),
	     %% 'Flow-Status'
	     %% 'QoS-Information'
	     %% 'PS-to-CS-Session-Continuity'
	     %% 'Reporting-Level'
	     'Online' => Optional(integer),
	     'Offline' => Optional(integer),
	     %% 'Max-PLR-DL'
	     %% 'Max-PLR-UL'
	     'Metering-Method' => Optional(integer),
	     'Precedence' => Optional(integer),
	     %% 'AF-Charging-Identifier'
	     %% 'Flows'
	     %% 'Monitoring-Key'
	     'Redirect-Information' => Optional(binary)
	     %% 'Mute-Notification'
	     %% 'AF-Signalling-Protocol'
	     %% 'Sponsor-Identity'
	     %% 'Application-Service-Provider-Identity'
	     %% 'Required-Access-Info'
	     %% 'Sharing-Key-DL'
	     %% 'Sharing-Key-UL'
	     %% 'Traffic-Steering-Policy-Identifier-DL'
	     %% 'Traffic-Steering-Policy-Identifier-UL'
	     %% 'Content-Version'
	    },
    Profile = #{online   => Online,
		offline  => Offline},
    #{rules    => {map, {name, binary}, Rule},
      rulebase => {kvlist, {name, binary}, {rules, {list, binary}}},
      profiles => {map, {name, binary}, Profile}}.

config_meta_cluster() ->
    #{enabled               => boolean,
      initial_timeout       => timeout,
      release_cursor_every  => integer,
      seed_nodes            => term
     }.

config_meta_handler() ->
    {map, {name, binary}, {delegate, fun delegate_handler/1}}.

delegate_handler(Map) when is_map(Map) ->
    Meta =
	case to_atom(get_key(handler, Map)) of
	    ggsn_gn ->
		config_meta_gtp_context();
	    pgw_s5s8 ->
		config_meta_gtp_context();
	    saegw_s11 ->
		config_meta_gtp_context();
	    ggsn_gn_proxy ->
		config_meta_gtp_proxy_context();
	    pgw_s5s8_proxy ->
		config_meta_gtp_proxy_context();
	    tdf ->
		config_meta_tdf()
	end,
    normalize_meta(Meta).

config_meta_gtp_context() ->
    #{
      handler        => atom,
      protocol       => atom,
      sockets        => {list, binary},
      node_selection => {list, binary},
      aaa            => config_meta_aaa_opts()
     }.

config_meta_aaa_opts() ->
    #{'AAA-Application-Id' => binary,
      'Username'           => config_meta_aaa_attr_mapping(),
      'Password'           => config_meta_aaa_attr_mapping(),
      '3GPP-GGSN-MCC-MNC'  => passthrough}.

config_meta_aaa_attr_mapping() ->
    #{default            => passthrough,
      from_protocol_opts => boolean}.

config_meta_gtp_proxy_context() ->
    Context = #{proxy_sockets => {list, binary},
		node_selection => {list, binary}},
    #{handler           => atom,
      protocol          => atom,
      sockets           => {list, binary},
      node_selection    => {list, binary},
      aaa               => config_meta_aaa_opts(),
      proxy_data_source => module,

      proxy_sockets     => {list, binary},
      contexts          => {klist, {name, binary}, Context}
     }.

config_meta_tdf() ->
    #{handler        => atom,
      protocol       => atom,
      node_selection => {list, binary},
      nodes          => {list, binary},
      apn            => apn
     }.

config_meta_http_api() ->
    #{
      enabled       => boolean,
      ip            => ip_address,
      port          => integer,
      ipv6_v6only   => boolean,
      num_acceptors => integer
     }.

config_meta_ip_pools() ->
    Range = #{
	      start => ip_address,
	      'end' => ip_address,
	      prefix_len => integer
	     },
    Meta = #{handler                    => module,
	     ranges                     => {list, Range},
	     'MS-Primary-DNS-Server'    => ip4_address,
	     'MS-Secondary-DNS-Server'  => ip4_address,
	     'MS-Primary-NBNS-Server'   => ip4_address,
	     'MS-Secondary-NBNS-Server' => ip4_address,
	     'DNS-Server-IPv6-Address'  => {list, ip6_address},    %tbd
	     '3GPP-IPv6-DNS-Servers'    => {list, ip6_address}},   %tbd
    {map, {name, binary}, Meta}.

config_meta_metrics() ->
    #{gtp_path_rtt_millisecond_intervals => {list, integer}}.

config_meta_node_selection() ->
    {map, {name, binary}, {delegate, fun delegate_node_selection_type/1}}.

delegate_node_selection_type(Map) when is_map(Map) ->
    Meta =
	case to_atom(get_key(type, Map)) of
	    static ->
		config_meta_static();
	    dns ->
		config_meta_dns_server()
	end,
    normalize_meta(Meta).

config_meta_static() ->
    #{type => atom,
      entries => {list, {delegate, fun delegate_static_rr_type/1}}}.

delegate_static_rr_type(Map) when is_map(Map) ->
    Meta =
	case to_atom(get_key(type, Map)) of
	    naptr ->
		config_meta_rr_naptr();
	    host ->
		config_meta_rr_host()
	end,
    normalize_meta(Meta).

config_meta_dns_server() ->
    #{type => atom,
      server => ip_address,
      port => integer}.

config_meta_rr_naptr() ->
    #{type => atom,
      name => binary,
      order => integer,
      preference => integer,
      service => atom,
      protocols => {list, atom},
      replacement => binary}.

config_meta_rr_host() ->
    #{type => atom,
      name => binary,
      ip4  => {list, ip4_address},
      ip6  => {list, ip6_address}}.

config_meta_nodes() ->
    VRF = #{
	    features => {list, atom}
	   },
    Heartbeat = #{
		  interval => timeout,
		  timeout => timeout,
		  retry => integer
		 },
    Request = #{
		timeout => timeout,
		retry => integer
	       },
    Default = #{
		vrfs           => {klist, {name, vrf}, VRF},
		ip_pools       => {list, binary},
		node_selection => binary,
		heartbeat      => Heartbeat,
		request        => Request
	       },
    Node =
	Default#{
		 connect => boolean,
		 raddr   => ip_address,
		 rport   => integer
		},
    #{default => Default,
      entries => {map, {name, binary}, Node}}.

config_meta_path_management() ->
    #{t3 => integer,                           % echo retry interval
      n3 => integer,                           % echo retry count

      echo => echo,                            % echo ping interval
      idle =>
	  #{echo    => echo,                   % time to keep the path entry when idle
	    timeout => timeout},               % echo retry interval when idle
      down =>
	  #{echo    => echo,                   % time to keep the path entry when down
	    timeout => timeout},               % echo retry interval when down
      icmp_error_handling => atom}.

config_meta_proxy_map() ->
    To = #{imsi => binary, msisdn => binary},
    IMSI = {kvlist, {from, binary}, {to, To}},
    APN = {kvlist, {from, apn}, {to, apn}},
    #{imsi => IMSI, apn => APN}.

config_meta_socket() ->
    {klist, {name, binary}, {delegate, fun delegate_socket_type/1}}.

delegate_socket_type(Map) when is_map(Map) ->
    Meta =
	case to_atom(get_key(type, Map)) of
	    'gtp-c' ->
		config_meta_gtp_socket();
	    'gtp-u' ->
		config_meta_gtp_socket();
	    'pfcp' ->
		config_meta_pfcp_socket()
	end,
    normalize_meta(Meta).

config_meta_gtp_socket() ->
    #{name => atom,
      type => atom,
      ip => ip_address,
      cluster_ip => ip_address,
      netdev => string,
      netns => string,
      vrf => vrf,
      freebind => boolean,
      reuseaddr => boolean,
      send_port => integer,
      rcvbuf => integer,
      burst_size => integer}.

config_meta_pfcp_socket() ->
    #{name => binary,
      type => atom,
      ip => ip_address,
      netdev => string,
      netns => string,
      vrf => vrf,
      freebind => boolean,
      reuseaddr => boolean,
      rcvbuf => integer,
      socket => binary,
      burst_size => integer}.

config_meta_tei_mngr() ->
    #{prefix => integer,
      len    => integer}.

normalize_meta({delegate, _} = Type) ->
    Type;
normalize_meta(#cnf_value{} = Type) ->
    Type;
normalize_meta(Object) when is_map(Object) ->
    Meta = maps:map(fun (_, V) -> normalize_meta(V) end, Object),
    #cnf_value{type = {object, Meta}};
normalize_meta({list, Type})->
    Meta = normalize_meta(Type),
    #cnf_value{type = {list, Meta}};
normalize_meta({klist, {KeyField, KeyType}, Type}) ->
    KeyMeta = meta_type(KeyType),
    Meta = normalize_meta(Type),
    #cnf_value{type = {klist, {KeyField, KeyMeta, Meta}}};
normalize_meta({kvlist, {KField, KType}, {VField, VType}}) ->
    KMeta = meta_type(KType),
    VMeta = normalize_meta(VType),
    #cnf_value{type = {kvlist, {KField, KMeta, VField, VMeta}}};
normalize_meta({map, {KeyField, KeyType}, Type})
  when is_atom(KeyType) ->
    KeyMeta = meta_type(KeyType),
    Meta = normalize_meta(Type),
    #cnf_value{type = {map, {KeyField, KeyMeta, Meta}}};
normalize_meta({map, _KeyType, _Type}) ->
    erlang:error(not_impl_yet);
normalize_meta(Type) ->
    meta_type(Type).
meta_type({Type, _} = Meta) when is_atom(Type) ->
    #cnf_value{type = Meta};
meta_type(Type) when is_atom(Type) ->
    #cnf_value{type = Type}.

%%%===================================================================
%%% Delegate Helper
%%%===================================================================

ts2meta({delegate, Meta}, V) when is_function(Meta) ->
    Meta(V);
ts2meta(TypeSpec, _) when is_record(TypeSpec, cnf_value) ->
    TypeSpec;
ts2meta(TypeSpec, _) when is_map(TypeSpec) ->
    TypeSpec.

%%%===================================================================
%%% Helper
%%%===================================================================

take_key(Field, Map) when is_atom(Field), is_map_key(Field, Map) ->
    maps:take(Field, Map);
take_key(Field, Map) ->
    maps:take(to_binary(Field), Map).

get_key(Field, Map) when is_atom(Field), is_map_key(Field, Map) ->
    maps:get(Field, Map);
get_key(Field, Map) ->
    maps:get(to_binary(Field), Map).

%%%===================================================================
%%% Options Validation
%%%===================================================================

validate_config_with_schema(Config) ->
    Schema = filename:join([code:lib_dir(ergw, priv), "schemas", "ergw_config.yaml"]),
    case jesse:validate(Schema, Config) of
	{ok, _} -> ok;
	Other -> Other
    end.

%%%===================================================================
%%% Options Coercion
%%%===================================================================

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

to_boolean(0) -> false;
to_boolean("false") -> false;
to_boolean(<<"false">>) -> false;
to_boolean(V) when is_integer(V) -> V /= 0;
to_boolean("true") -> true;
to_boolean(<<"true">>) -> true;
to_boolean(V) when is_boolean(V) -> V.

%% to_atom(V) when is_atom(V) ->
%%     V;
%% to_atom(V) when is_binary(V) ->
%%     binary_to_existing_atom(V);
%% to_atom(V) when is_list(V) ->
%%     list_to_existing_atom(V).

to_atom(V) when is_atom(V) ->
    V;
to_atom(V) when is_binary(V) ->
    binary_to_atom(V);
to_atom(V) when is_list(V) ->
    list_to_atom(V).


to_integer(V) when is_integer(V) ->
    V;
to_integer(V) when is_binary(V) ->
    binary_to_integer(V);
to_integer(V) when is_list(V) ->
    list_to_integer(V).

to_string(V) when is_list(V); is_binary(V) ->
    unicode:characters_to_list(V).

to_module(V) ->
    to_atom(V).

to_ip(Map) when is_map(Map) ->
    [{_Type, IP}] = maps:to_list(Map),
    to_ip(IP);
to_ip(IP) when is_tuple(IP) ->
    ergw_inet:ip2bin(IP);
to_ip(IP) when is_list(IP) ->
    {ok, Addr} = inet:parse_strict_address(IP),
    ergw_inet:ip2bin(Addr);
to_ip(IP) when is_binary(IP) ->
    case inet:parse_strict_address(binary_to_list(IP)) of
	{ok, Addr} -> ergw_inet:ip2bin(Addr);
	_ when size(IP) == 4; size(IP) == 16 ->
	    IP
    end.

to_ip4(IP) ->
    <<_:4/bytes>> = to_ip(IP).

to_ip6(IP) ->
    <<_:16/bytes>> = to_ip(IP).

to_ip_address(Map) when is_map(Map) ->
    [{_Type, IP}] = maps:to_list(Map),
    to_ip_address(IP);
to_ip_address({_,_,_,_} = IP) ->
    IP;
to_ip_address({_,_,_,_,_,_,_,_} = IP) ->
    IP;
to_ip_address(IP) when is_list(IP) ->
    {ok, Addr} = inet:parse_strict_address(IP),
    Addr;
to_ip_address(IP) when is_binary(IP) ->
    case inet:parse_strict_address(binary_to_list(IP)) of
	{ok, Addr} -> Addr;
	_ -> ergw_inet:bin2ip(IP)
    end.

to_ip4_address(IP) ->
    {_, _, _, _} = to_ip_address(IP).

to_ip6_address(IP) ->
    {_, _, _, _, _, _, _, _} = to_ip_address(IP).

to_apn(<<"*">>) ->
    '_';
to_apn(APN) ->
    gtp_c_lib:normalize_labels(APN).

to_timeout(infinity) ->
    infinity;
to_timeout("infinity") ->
    infinity;
to_timeout(<<"infinity">>) ->
    infinity;
to_timeout(Timeout) when is_integer(Timeout) ->
    Timeout;
to_timeout(Timeout) when is_list(Timeout) ->
    list_to_integer(Timeout);
to_timeout(Timeout) when is_binary(Timeout) ->
    binary_to_integer(Timeout);
to_timeout({day, Timeout}) ->
    to_timeout(Timeout) * 1000 * 3600 * 24;
to_timeout({hour, Timeout}) ->
    to_timeout(Timeout) * 1000 * 3600;
to_timeout({minute, Timeout}) ->
    to_timeout(Timeout) * 1000 * 60;
to_timeout({second, Timeout}) ->
   to_timeout(Timeout) * 1000;
to_timeout({millisecond, Timeout}) ->
    to_timeout(Timeout);
to_timeout({Unit, Timeout}) when not is_atom(Unit) ->
    to_timeout({to_atom(Unit), Timeout});
to_timeout(#{unit := Unit, timeout := Timeout}) ->
    to_timeout({Unit, Timeout});
to_timeout(#{timeout := Timeout}) ->
    to_timeout(Timeout);
to_timeout(#{<<"timeout">> := _} = Timeout) ->
    to_timeout(maps:fold(fun(K, V, M) -> maps:put(to_atom(K), V, M) end, #{}, Timeout)).

to_vrf({apn, APN}) ->
    << <<(size(L)):8, L/binary>> ||
	L <- binary:split(to_binary(APN), <<".">>, [global, trim_all]) >>;
to_vrf({dnn, DNN}) ->
    to_binary(DNN);
to_vrf(#{type := Type, name := Name}) when not is_atom(Type) ->
    to_vrf({to_atom(Type), Name});
to_vrf(#{name := Name}) ->
    to_vrf({apn, Name});
to_vrf(#{<<"name">> := _} = VRF) ->
    to_vrf(maps:fold(fun(K, V, M) -> maps:put(to_atom(K), V, M) end, #{}, VRF)).

to_term(V) ->
    String = to_string(V) ++ ".",
    {ok, Token, _} = erl_scan:string(String),
    {ok, AbsForm} = erl_parse:parse_exprs(Token),
    {value, Term, []} = erl_eval:exprs(AbsForm, erl_eval:new_bindings()),
    Term.

to_ip6_ifid(IfId) ->
    case (catch to_atom(IfId)) of
	V when is_atom(V) -> V;
	_ -> to_ip6_address(IfId)
    end.

to_echo(Timeout) ->
    case (catch to_atom(Timeout)) of
	off ->
	    off;
	_ ->
	    to_timeout(Timeout)
    end.

%% complex types

to_object(Meta, K, V)
  when is_atom(K), is_map(Meta), is_map_key(K, Meta) ->
    coerce_config(maps:get(K, Meta), V);
to_object(_Meta, _K, V) ->
    V.

to_object(Meta, Object) when is_map(Object) ->
    maps:fold(
      fun(K, V, M) ->
	      Key = to_atom(K),
	      maps:put(Key, to_object(Meta, Key, V), M)
      end, #{}, Object).

to_list(Meta, V) when is_list(V) ->
    lists:map(coerce_config(Meta, _), V).

to_klist({KeyField, KeyMeta, VMeta}, V, Config) ->
    {Key, Map} = take_key(KeyField, V),
    maps:put(coerce_config(KeyMeta, Key), coerce_config(VMeta, Map), Config).

to_klist(Type, V) when is_list(V) ->
    lists:foldl(to_klist(Type, _, _), #{}, V).

to_kvlist({KField, KMeta, VField, VMeta}, KV, Config) ->
    K = get_key(KField, KV),
    V = get_key(VField, KV),
    maps:put(coerce_config(KMeta, K), coerce_config(VMeta, V), Config).

to_kvlist(Type, V) when is_list(V) ->
    lists:foldl(to_kvlist(Type, _, _), #{}, V).

to_map(Type, V) when is_list(V) ->
    to_klist(Type, V).

%% processing

coerce_config(Config) ->
    Meta = config_meta(),
    coerce_config(Meta, Config).

coerce_config(Meta, V) ->
    coerce_config_2(ts2meta(Meta, V), V).

coerce_config_2(#cnf_value{type = Type}, V) when is_atom(Type) ->
   #cnf_type{coerce = F} = get_typespec(Type),
    case is_function(F, 1) of
	true ->
	    F(V);
	false ->
	    erlang:error(badarg, [Type, V])
    end;
coerce_config_2(#cnf_value{type = {Type, Opts}}, V) ->
    #cnf_type{coerce = F} = get_typespec(Type),
    case is_function(F, 2) of
	true ->
	    F(Opts, V);
	false ->
	    erlang:error(badarg, [{Type, Opts}, V])
    end.

%%%===================================================================
%%% Options Serialization
%%%===================================================================

from_ip(IP) when is_binary(IP) ->
    from_ip_address(ergw_inet:bin2ip(IP)).

from_ip_address(IP) when is_tuple(IP) ->
    Prop = if tuple_size(IP) == 4 -> 'ipv4Addr';
	      tuple_size(IP) == 8 -> 'ipv6Addr'
	   end,
    #{Prop => iolist_to_binary(inet:ntoa(IP))}.

from_ip46(IP) when is_binary(IP) ->
    from_ip46_address(ergw_inet:bin2ip(IP)).

from_ip46_address(IP) when is_tuple(IP) ->
    iolist_to_binary(inet:ntoa(IP)).

from_apn('_') ->
    <<"*">>;
from_apn(APN) ->
    iolist_to_binary(lists:join($., APN)).

from_timeout(Timeout) when not is_integer(Timeout) ->
    Timeout;
from_timeout(0) ->
    #{timeout => 0, unit => millisecond};
from_timeout(Timeout) ->
    from_timeout(Timeout, [{millisecond, 1000},
			   {second, 60},
			   {minute, 60},
			   {hour, 24},
			   {day, 1}]).

from_timeout(Timeout, [{Unit, _}]) ->
    #{unit => Unit, timeout => Timeout};
from_timeout(Timeout, [{_, Div}|T])
  when (Timeout rem Div) == 0 ->
    from_timeout(Timeout div Div, T);
from_timeout(Timeout, [{Unit, _}|_]) ->
    #{unit => Unit, timeout => Timeout}.

from_vrf(<<X:8, _/binary>> = APN) when X < 64 ->
    L = [ Part || <<Len:8, Part:Len/bytes>> <= APN ],
    #{type => apn, name => iolist_to_binary(lists:join($., L))};
from_vrf(DNN) ->
    #{type => dnn, name => DNN}.

from_string(V) ->
    unicode:characters_to_binary(V).

from_term(Term) ->
    iolist_to_binary(io_lib:format("~0p", [Term])).

from_ip6_ifid(IfId) when is_atom(IfId) ->
    IfId;
from_ip6_ifid(IfId) ->
    from_ip46_address(IfId).

from_echo(Timeout) when is_atom(Timeout) ->
    Timeout;
from_echo(Timeout) ->
    from_timeout(Timeout).

%% complex types

from_object(Meta, K, V) when is_map(Meta), is_map_key(K, Meta) ->
    serialize_config(maps:get(K, Meta), V).

from_object(Meta, V) when is_map(V) ->
    maps:map(from_object(Meta, _, _), V).

from_list(Type, V) when is_list(V) ->
    lists:map(serialize_config(Type, _), V).

from_klist({KeyField, KeyMeta, VMeta}, K, V, Config) ->
    [maps:put(KeyField, serialize_config(KeyMeta, K), serialize_config(VMeta, V))|Config].

from_klist(Type, V) when is_map(V) ->
    maps:fold(from_klist(Type, _, _, _), [], V).

from_kvlist({KField, KMeta, VField, VMeta}, K, V, Config) ->
    [#{KField => serialize_config(KMeta, K), VField => serialize_config(VMeta, V)}|Config].

from_kvlist(Type, V) when is_map(V) ->
    maps:fold(from_kvlist(Type, _, _, _), [], V).

from_map(Type, V) when is_map(V) ->
    from_klist(Type, V).

%% processing

serialize_config(Config) ->
    Meta = config_meta(),
    serialize_config(Meta, Config).

serialize_config(#cnf_value{type = Type}, V) when is_atom(Type) ->
    #cnf_type{serialize = F} = get_typespec(Type),
    F(V);

serialize_config(#cnf_value{type = {Type, Opts}}, V) ->
    #cnf_type{serialize = F} = get_typespec(Type),
    F(Opts, V).

%%%===================================================================
%%% Type Specs
%%%===================================================================

register_typespec(Spec) ->
    Key = {?MODULE, typespecs},
    S = persistent_term:get(Key, #{}),
    persistent_term:put(Key, maps:merge(S, Spec)).

load_typespecs() ->
    Spec =
	#{object =>
	      #cnf_type{
		 coerce    = fun to_object/2,
		 serialize = fun from_object/2
		},
	  list =>
	      #cnf_type{
		 coerce    = fun to_list/2,
		 serialize = fun from_list/2
		},
	  klist =>
	      #cnf_type{
		 coerce    = fun to_klist/2,
		 serialize = fun from_klist/2
		},
	  kvlist =>
	      #cnf_type{
		 coerce    = fun to_kvlist/2,
		 serialize = fun from_kvlist/2
		},
	  map =>
	      #cnf_type{
		 coerce    = fun to_map/2,
		 serialize = fun from_map/2
		},
	  passthrough =>
	      #cnf_type{
		 coerce    = fun (V) -> V end,
		 serialize = fun (V) -> V end
		},
	  optional =>
	      #cnf_type{
		 coerce    = fun(Type, Y) -> [coerce_config(Type, Y)] end,
		 serialize = fun(Type, [Y]) -> serialize_config(Type, Y) end
		},
	  term =>
	      #cnf_type{
		 coerce    = fun to_term/1,
		 serialize = fun from_term/1
		},
	  atom =>
	      #cnf_type{
		 coerce    = fun to_atom/1,
		 serialize = fun (V) -> V end
		},
	  binary =>
	      #cnf_type{
		 coerce    = fun to_binary/1,
		 serialize = fun (V) -> V end
		},
	  boolean =>
	      #cnf_type{
		 coerce    = fun to_boolean/1,
		 serialize = fun (V) -> V end
		},
	  integer =>
	      #cnf_type{
		 coerce    = fun to_integer/1,
		 serialize = fun (V) -> V end
		},
	  string =>
	      #cnf_type{
		 coerce    = fun to_string/1,
		 serialize = fun from_string/1
		},
	  module =>
	      #cnf_type{
		 coerce    = fun to_module/1,
		 serialize = fun (V) -> V end
		},
	  mcc =>
	      #cnf_type{
		 coerce    = fun to_binary/1,
		 serialize = fun (V) -> V end
		},
	  mnc =>
	      #cnf_type{
		 coerce    = fun to_binary/1,
		 serialize = fun (V) -> V end
		},
	  ip =>
	      #cnf_type{
		 coerce    = fun to_ip/1,
		 serialize = fun from_ip/1
		},
	  ip4 =>
	      #cnf_type{
		 coerce    = fun to_ip4/1,
		 serialize = fun from_ip46/1
		},
	  ip6 =>
	      #cnf_type{
		 coerce    = fun to_ip6/1,
		 serialize = fun from_ip46/1
		},
	  ip_address =>
	      #cnf_type{
		 coerce    = fun to_ip_address/1,
		 serialize = fun from_ip_address/1
		},
	  ip4_address =>
	      #cnf_type{
		 coerce    = fun to_ip4_address/1,
		 serialize = fun from_ip46_address/1
		},
	  ip6_address =>
	      #cnf_type{
		 coerce    = fun to_ip6_address/1,
		 serialize = fun from_ip46_address/1
		},
	  ip6_ifid =>
	      #cnf_type{
		 coerce    = fun to_ip6_ifid/1,
		 serialize = fun from_ip6_ifid/1
		},
	  apn =>
	      #cnf_type{
		 coerce    = fun to_apn/1,
		 serialize = fun from_apn/1
		},
	  vrf =>
	      #cnf_type{
		 coerce    = fun to_vrf/1,
		 serialize = fun from_vrf/1
		},
	  timeout =>
	      #cnf_type{
		 coerce    = fun to_timeout/1,
		 serialize = fun from_timeout/1
		},
	  echo =>
	      #cnf_type{
		 coerce = fun to_echo/1,
		 serialize = fun from_echo/1
		}
	 },
    register_typespec(Spec).

get_typespec(Type) ->
    Key = {?MODULE, typespecs},
    maps:get(Type, persistent_term:get(Key)).
