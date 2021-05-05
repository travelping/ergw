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
-export([load/0, apply/1, serialize_config/1]).

-ifdef(TEST).
-export([config_meta/0,
	 load_schemas/0,
	 validate_config_with_schema/1,
	 normalize_meta/1,
	 serialize_config/2,
	 coerce_config/1,
	 coerce_config/2]).
-endif.

-ignore_xref([serialize_config/1]).

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

%% copied from ergw_aaa test suites
ergw_aaa_init(Config) ->
    Init = [product_name, rate_limits, handlers, services, functions, apps],
    lists:foreach(ergw_aaa_init(_, Config), Init).

ergw_aaa_init(product_name, #{product_name := PN0}) ->
    PN = ergw_aaa_config:validate_option(product_name, PN0),
    ergw_aaa:setopt(product_name, PN),
    PN;
ergw_aaa_init(rate_limits, #{rate_limits := Limits0}) ->
    Limits = ergw_aaa_config:validate_options(
	       fun ergw_aaa_config:validate_rate_limit/2, Limits0, []),
    ergw_aaa:setopt(rate_limits, Limits),
    Limits;
ergw_aaa_init(handlers, #{handlers := Handlers0}) ->
    Handlers = ergw_aaa_config:validate_options(
		 fun ergw_aaa_config:validate_handler/2, Handlers0, []),
    maps:map(fun ergw_aaa:add_handler/2, Handlers),
    Handlers;
ergw_aaa_init(services, #{services := Services0}) ->
    Services = ergw_aaa_config:validate_options(
		 fun ergw_aaa_config:validate_service/2, Services0, []),
    maps:map(fun ergw_aaa:add_service/2, Services),
    Services;
ergw_aaa_init(functions, #{functions := Functions0}) ->
    Functions = ergw_aaa_config:validate_options(
		  fun ergw_aaa_config:validate_function/2, Functions0, []),
    maps:map(fun ergw_aaa:add_function/2, Functions),
    Functions;
ergw_aaa_init(apps, #{apps := Apps0}) ->
    Apps = ergw_aaa_config:validate_options(fun ergw_aaa_config:validate_app/2, Apps0, []),
    maps:map(fun ergw_aaa:add_application/2, Apps),
    Apps;
ergw_aaa_init(_, _) ->
    ok.

ergw_core_init(Config) ->
    Init = [node, aaa, wait_till_running, path_management, node_selection,
	    sockets, upf_nodes, handlers, ip_pools, apns, charging, proxy_map,
	    http_api],
    lists:foreach(ergw_core_init(_, Config), Init).

ergw_core_init(node, #{node := Node}) ->
    ergw_core:start_node(Node);
ergw_core_init(aaa, #{aaa := AAA}) ->
    ergw_aaa_init(AAA);
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
ergw_core_init(http_api, #{http_api := Opts}) ->
    ergw_http_api:init(Opts);
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

optional(X) ->
    #cnf_value{type = {optional, normalize_meta(X)}}.

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
      teid            => config_meta_tei_mngr(),
      aaa             => config_meta_aaa()}.

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
	     nat_port_blocks      => {list, binary},
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
    FlowInfo = #{'Flow-Description' => optional(binary),
		 'Flow-Direction'  => optional(integer)},
    Rule = #{'Service-Identifier' => optional(atom),      %%tbd: this is most likely wrong
	     'Rating-Group' => optional(integer),
	     'Online-Rating-Group' => optional(integer),
	     'Offline-Rating-Group' => optional(integer),
	     'Flow-Information' => {list, FlowInfo},
	     %% 'Default-Bearer-Indication'
	     'TDF-Application-Identifier' => optional(binary),
	     %% 'Flow-Status'
	     %% 'QoS-Information'
	     %% 'PS-to-CS-Session-Continuity'
	     %% 'Reporting-Level'
	     'Online' => optional(integer),
	     'Offline' => optional(integer),
	     %% 'Max-PLR-DL'
	     %% 'Max-PLR-UL'
	     'Metering-Method' => optional(integer),
	     'Precedence' => optional(integer),
	     %% 'AF-Charging-Identifier'
	     %% 'Flows'
	     %% 'Monitoring-Key'
	     'Redirect-Information' => optional(binary)
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
    #{enabled       => boolean,
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
    Pool = #{
	     ip_pools => {list, binary},
	     vrf => vrf,
	     nat_port_blocks => {list, binary},
	     ip_versions => {list, atom}
	    },
    Default = #{
		vrfs           => {klist, {name, vrf}, VRF},
		ue_ip_pools    => {list, Pool},
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
    #{required_upff => upff,
      default => Default,
      entries => {map, {name, binary}, Node}}.

config_meta_path_management() ->
    #{t3 => integer,                           % echo retry interval
      n3 => integer,                           % echo retry count

      echo => echo,                            % echo ping interval
      idle =>
	  #{echo    => echo,                   % time to keep the path entry when idle
	    timeout => timeout},               % echo retry interval when idle
      suspect =>
	  #{echo    => echo,                   % time to keep the path entry when suspect
	    timeout => timeout},               % echo retry interval when suspect
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

config_meta_aaa() ->
    #{product_name => config_meta_aaa_product_name(),
      rate_limits => config_meta_aaa_rate_limits(),
      functions => config_meta_aaa_functions(),
      handlers => config_meta_aaa_handlers(),
      services => config_meta_aaa_services(),
      apps => config_meta_aaa_apps()}.

config_meta_aaa_product_name() ->
    binary.

config_meta_aaa_rate_limits() ->
    Meta = #{outstanding_requests => integer, rate => integer},
    {klist, {host, binary}, Meta}.

config_meta_aaa_functions() ->
    {klist, {name, binary}, {delegate, fun delegate_aaa_function/1}}.

delegate_aaa_function(Map) when is_map(Map) ->
    Meta =
	case to_atom(get_key(handler, Map)) of
	    ergw_aaa_diameter ->
		config_meta_aaa_function_diameter()
	end,
    normalize_meta(Meta).

config_meta_aaa_function_diameter() ->
    Transport =
	#{connect_to => binary},
    #{handler => module,
      'Origin-Host' => host_or_ip,
      'Origin-Realm' => binary,
      transports => {list, Transport}}.

config_meta_aaa_handlers() ->
    {klist, {handler, module}, {delegate, fun delegate_aaa_handler/1}}.

delegate_aaa_handler(Map) when is_map(Map) ->
    Meta =
	case to_atom(get_key(handler, Map)) of
	    ergw_aaa_gx     -> ergw_meta_aaa_handler_gx();
	    ergw_aaa_nasreq -> ergw_meta_aaa_handler_nasreq();
	    ergw_aaa_radius -> ergw_meta_aaa_handler_radius();
	    ergw_aaa_rf     -> ergw_meta_aaa_handler_rf();
	    ergw_aaa_ro     -> ergw_meta_aaa_handler_ro();
	    ergw_aaa_static -> ergw_meta_aaa_handler_static()
	end,
    normalize_meta(Meta).

ergw_meta_aaa_handler_gx() ->
    #{handler => module,
      function => binary,
      'Destination-Host' => binary,
      'Destination-Realm' => binary,
      answers => {kvlist, {name, binary}, {avps, aaa_avp}},
      answer_if_down => binary,
      answer_if_timeout => binary,
      avp_filter => {list, binary},
      termination_cause_mapping => config_meta_term_cause_mapping()}.

ergw_meta_aaa_handler_nasreq() ->
    #{handler => module,
      function => binary,
      accounting => atom,
      'Destination-Host' => binary,
      'Destination-Realm' => binary,
      avp_filter => {list, binary},
      termination_cause_mapping => config_meta_term_cause_mapping()}.

ergw_meta_aaa_handler_radius() ->
    #{handler => module,
      server => ergw_meta_radius_server(),
      server_name => binary,
      client_name => binary,
      timeout => integer,
      retries => integer,
      async => boolean,
      avp_filter => {list, binary},
      vendor_dicts => atom,
      termination_cause_mapping => config_meta_term_cause_mapping()}.

ergw_meta_radius_server() ->
    #{ip => host_or_ip,
      port => integer,
      secret => binary}.

ergw_meta_aaa_handler_rf() ->
    #{handler => module,
      function => binary,
      accounting => atom,
      'Destination-Host' => binary,
      'Destination-Realm' => binary,
      avp_filter => {list, binary},
      termination_cause_mapping => config_meta_term_cause_mapping()}.

ergw_meta_aaa_handler_ro() ->
    #{handler => module,
      function => binary,
      'Destination-Host' => binary,
      'Destination-Realm' => binary,
      'CC-Session-Failover' => atom,
      'Credit-Control-Failure-Handling' => atom,
      answers => {kvlist, {name, binary}, {avps, aaa_avp}},
      answer_if_down => binary,
      answer_if_timeout => binary,
      answer_if_rate_limit => binary,
      tx_timeout => integer,
      max_retries => integer,
      avp_filter => {list, binary},
      termination_cause_mapping => config_meta_term_cause_mapping()}.

ergw_meta_aaa_handler_static() ->
    #{handler => module,
      defaults => aaa_avp,
      answers => {kvlist, {name, binary}, {avps, aaa_avp}},
      answer => binary}.

config_meta_term_cause_mapping() ->
    {kvlist, {cause, atom}, {code, integer}}.

config_meta_aaa_services() ->
    {klist, {service, binary}, {delegate, fun delegate_aaa_service/1}}.

delegate_aaa_service(Map) when is_map(Map) ->
    Meta =
	case (catch to_atom(get_key(handler, Map))) of
	    ergw_aaa_gx     -> ergw_meta_aaa_handler_gx();
	    ergw_aaa_nasreq -> ergw_meta_aaa_handler_nasreq();
	    ergw_aaa_radius -> ergw_meta_aaa_handler_radius();
	    ergw_aaa_rf     -> ergw_meta_aaa_handler_rf();
	    ergw_aaa_ro     -> ergw_meta_aaa_handler_ro();
	    ergw_aaa_static -> ergw_meta_aaa_handler_static();
	    _               -> ergw_meta_aaa_handler_static()
	end,
    normalize_meta(Meta).

config_meta_aaa_apps() ->
    {kvlist, {application, default_or_binary}, {procedures, aaa_procedures}}.

config_meta_aaa_application() ->
    Service = #{service => binary,
		answer => binary},
    normalize_meta({list, Service}).

%%%===================================================================
%%% normalize functions
%%%===================================================================

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

ts2meta({delegate, Meta}, V) when is_function(Meta, 1) ->
    Meta(V);
ts2meta(TypeSpec, _) when is_record(TypeSpec, cnf_value) ->
    TypeSpec;
ts2meta(TypeSpec, _) when is_map(TypeSpec) ->
    TypeSpec.

ts2meta({delegate, Meta}, KeyField, K, V) when is_map(V), is_function(Meta, 1) ->
    Meta(V#{KeyField => K});
ts2meta({delegate, Meta}, KeyField, K, _) when is_function(Meta, 1) ->
    Meta(#{KeyField => K});
ts2meta(TypeSpec, _, _, _) when is_record(TypeSpec, cnf_value) ->
    TypeSpec;
ts2meta(TypeSpec, _, _, _) when is_map(TypeSpec) ->
    TypeSpec.


%%%===================================================================
%%% Helper
%%%===================================================================

take_key(Field, Map) when is_atom(Field), is_map_key(Field, Map) ->
    maps:take(Field, Map);
take_key(Field, Map) ->
    maps:take(to_binary(Field), Map).

get_key(Field, Map, Default) when is_atom(Field), is_map_key(Field, Map) ->
    maps:get(Field, Map, Default);
get_key(Field, Map, Default) ->
    maps:get(to_binary(Field), Map, Default).

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

to_default_or_binary(V) ->
    case to_binary(V) of
	<<"default">> -> default;
	Bin           -> Bin
    end.

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

to_host_or_ip(#{<<"ipv4Addr">> := Bin}) when is_binary(Bin) ->
    {ok, IP} = inet:parse_ipv4_address(binary_to_list(Bin)),
    IP;
to_host_or_ip(#{<<"ipv6Addr">> := Bin}) when is_binary(Bin) ->
    {ok, IP} = inet:parse_ipv6_address(binary_to_list(Bin)),
    IP;
to_host_or_ip(Bin) when is_binary(Bin) ->
    Bin.

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

to_aaa_procedure(#{<<"api">> := API, <<"procedure">> := Procedure} = V, M) ->
    Steps = get_key(steps, V, []),
    Config = coerce_config(config_meta_aaa_application(), Steps),
    maps:put({to_atom(API), to_atom(Procedure)}, Config, M);
to_aaa_procedure(#{<<"procedure">> := Procedure} = V, M) ->
    Steps = get_key(steps, V, []),
    Config = coerce_config(config_meta_aaa_application(), Steps),
    maps:put(to_atom(Procedure), Config, M).

to_aaa_procedures(List) when is_list(List) ->
    lists:foldl(fun to_aaa_procedure/2, #{}, List).

to_aaa_avp('Tariff-Time-Change', V) when is_binary(V) ->
    Time = calendar:rfc3339_to_system_time(binary_to_list(V)),
    calendar:system_time_to_universal_time(Time, second);
to_aaa_avp('Tariff-Time', V) when is_binary(V) ->
    {ok, [Hour, Minute], _} = io_lib:fread("~d:~d", binary_to_list(V)),
    {Hour, Minute};
to_aaa_avp(K, V) when is_list(V) ->
    lists:map(to_aaa_avp(K, _), V);
to_aaa_avp(_K, M) when is_map(M) ->
    to_aaa_avp(M);
to_aaa_avp(_K, V) ->
    V.

to_aaa_avp(K0, V0, M) ->
    K = to_atom(K0),
    maps:put(K, to_aaa_avp(K, V0), M).

to_aaa_avp(#{<<"ipv4Addr">> := Bin}) when is_binary(Bin) ->
    {ok, IP} = inet:parse_ipv4_address(binary_to_list(Bin)),
    IP;
to_aaa_avp(#{<<"ipv6Addr">> := Bin}) when is_binary(Bin) ->
    {ok, IP} = inet:parse_ipv6_address(binary_to_list(Bin)),
    IP;
to_aaa_avp(Map) when is_map(Map) ->
    maps:fold(fun to_aaa_avp/3, #{}, Map).

to_upff(V) when is_list(V) ->
    MinUpFF = #up_function_features{_ = '_'},
    lists:foldl(
      fun(X) -> to_atom(X) end, MinUpFF, V).

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
    maps:put(coerce_config(KeyMeta, Key), coerce_config_2(ts2meta(VMeta, V), Map), Config).

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

from_host_or_ip(IP) when is_tuple(IP) ->
    from_ip_address(IP);
from_host_or_ip(Host) when is_binary(Host) ->
    Host.

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

from_aaa_procedures(K, V0, Config) when is_atom(K) ->
    V = serialize_config(config_meta_aaa_application(), V0),
    [#{procedure => K, steps => V} | Config];
from_aaa_procedures({API, Procedure}, V0, Config) ->
    V = serialize_config(config_meta_aaa_application(), V0),
    [#{api => API, procedure => Procedure, steps => V} | Config].

from_aaa_procedures(Map) when is_map(Map) ->
    maps:fold(fun from_aaa_procedures/3, [], Map).

from_time({Hour, Minute}) ->
    iolist_to_binary(io_lib:format("~2..0w:~2..0w:00Z", [Hour, Minute])).

from_aaa_avp(K, V, M) when is_map(V) ->
    maps:put(K, from_aaa_avp(V), M);
from_aaa_avp(K, V, M) when is_list(V) ->
    maps:put(K, lists:map(from_aaa_avp(K, _), V), M);
from_aaa_avp(K, V, M) ->
    maps:put(K, from_aaa_avp(K, V), M).

from_aaa_avp(_K, Map) when is_map(Map) ->
    maps:fold(fun from_aaa_avp/3, #{}, Map);
from_aaa_avp(_K, {{Year, Month, Day}, {Hour, Minute, Second}}) ->
    iolist_to_binary(
      io_lib:format("~w-~2..0w-~2..0wT~2..0w:~2..0w:~2..0wZ",
		    [Year, Month, Day, Hour, Minute, Second]));
from_aaa_avp('Tariff-Time', Time) ->
    from_time(Time);
from_aaa_avp(_K, Value) when is_list(Value) ->
    iolist_to_binary(Value);
from_aaa_avp(_K, Value) when ?IS_IPv4(Value) ->
    from_ip_address(Value);
from_aaa_avp(_K, Value) when ?IS_IPv6(Value) ->
    from_ip_address(Value);
from_aaa_avp(_K, Value) ->
    Value.

from_aaa_avp(Map) when is_map(Map) ->
    maps:fold(fun from_aaa_avp/3, #{}, Map).

from_upff(V) ->
    [X || X <- '#info-'(up_function_features), '#get-'(X, V) =:= 1].

%% complex types

from_object(Meta, K, V) when is_map(Meta), is_map_key(K, Meta) ->
    serialize_config(maps:get(K, Meta), V).

from_object(Meta, V) when is_map(V) ->
    maps:map(from_object(Meta, _, _), V).

from_list(Type, V) when is_list(V) ->
    lists:map(fun(V0) -> serialize_config(ts2meta(Type, V0), V0) end, V).

from_klist({KeyField, KeyMeta, VTypeSpec}, K, V, Config) ->
    VMeta = ts2meta(VTypeSpec, KeyField, K, V),
    [maps:put(KeyField, serialize_config(KeyMeta, K), serialize_config(VMeta, V))|Config].

from_klist(Type, V) when is_map(V) ->
    maps:fold(from_klist(Type, _, _, _), [], V).

from_kvlist({KField, KMeta, VField, VTypeSpec}, K, V, Config) ->
    VMeta = ts2meta(VTypeSpec, KField, K, V),
    [#{KField => serialize_config(KMeta, K), VField => serialize_config(VMeta, V)}|Config].

from_kvlist(Type, V) when is_map(V) ->
    maps:fold(from_kvlist(Type, _, _, _), [], V).

from_map(Type, V) when is_map(V) ->
    from_klist(Type, V).

%% processing

serialize_config(Config) ->
    Meta = config_meta(),
    serialize_config(Meta, Config).

serialize_config(#cnf_value{type = Type} = Cnf, V) when is_atom(Type) ->
    #cnf_type{serialize = F} = get_typespec(Type),
    case is_function(F, 1) of
	true ->
	    F(V);
	false ->
	    erlang:error(badarg, [Cnf, V])
    end;

serialize_config(#cnf_value{type = {Type, Opts}} = Cnf, V) ->
    #cnf_type{serialize = F} = get_typespec(Type),
    case is_function(F, 2) of
	true ->
	    F(Opts, V);
	false ->
	    erlang:error(badarg, [Cnf, V])
    end.

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
	  default_or_binary =>
	      #cnf_type{
		 coerce    = fun to_default_or_binary/1,
		 serialize = fun (V) -> V end
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
		},
	  aaa_procedures =>
	      #cnf_type{
		 coerce = fun to_aaa_procedures/1,
		 serialize = fun from_aaa_procedures/1
		},
	  aaa_avp =>
	      #cnf_type{
		 coerce = fun to_aaa_avp/1,
		 serialize = fun from_aaa_avp/1
		},
	  upff =>
	      #cnf_type{
		 coerce    = fun to_upff/1,
		 serialize = fun from_upff/1
		},
	  host_or_ip =>
	      #cnf_type{
		 coerce    = fun to_host_or_ip/1,
		 serialize = fun from_host_or_ip/1
		}
	 },
    register_typespec(Spec).

get_typespec(Type) ->
    Key = {?MODULE, typespecs},
    maps:get(Type, persistent_term:get(Key)).
