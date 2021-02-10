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
	 normalize_meta/1,
	 serialize_config/1,
	 serialize_config/2,
	 coerce_config/1,
	 coerce_config/2,
	 validate_config/1,
	 validate_config/3,
	 validate_config/4,
	 register_typespec/1,
	 get_key/2, take_key/2,
	 set_value/3,
	 get/2, set/3, find/2
	]).

-export([to_atom/1, to_integer/1, to_binary/1, to_ip/1, to_timeout/1,
	 from_timeout/1, from_ip_address/1,
	 is_ip_address/1]).

%% not yet used
-ignore_xref([find/2, get/2, set/3, set_value/3]).

-ifdef(TEST).
-export([config_meta/0]).
-endif.

-type(meta() :: term()).
-export_type([meta/0]).

-include_lib("kernel/include/logger.hrl").
-include("include/ergw.hrl").

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

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

%%%===================================================================
%%% API
%%%===================================================================

load() ->
    load_typespecs(),
    {ok, Config} = ergw_config_legacy:load(),
    load_env_config(Config),
    {ok, Config}.

load_env_config(Config) ->
    maps:map(fun load_env_config/2, Config),
    ok.

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
    ok = application:set_env(ergw, Key, Value);
load_env_config(_, _) ->
    ok.

apply(#{sockets := Sockets, nodes := #{entries := Nodes},
	  handlers := Handlers, ip_pools := IPpools, http_api := HTTP}) ->
    maps:map(fun ergw:start_socket/2, Sockets),
    maps:map(fun load_sx_node/2, Nodes),
    maps:map(fun load_handler/2, Handlers),
    maps:map(fun ergw:start_ip_pool/2, IPpools),
    ergw_http_api:init(HTTP),
    ok.

load_handler(_Name, #{protocol := ip, nodes := Nodes} = Opts0) ->
    Opts = maps:without([protocol, nodes], Opts0),
    lists:foreach(ergw:attach_tdf(_, Opts), Nodes);

load_handler(Name, #{handler  := Handler,
		     protocol := Protocol,
		     sockets  := Sockets} = Opts0) ->
    Opts = maps:without([handler, protocol, sockets], Opts0),
    lists:foreach(ergw:attach_protocol(_, Name, Protocol, Handler, Opts), Sockets).

load_sx_node(Name, Opts) ->
    ergw:connect_sx_node(Name, Opts).

%%%===================================================================
%%% config metadata
%%%===================================================================

config_raw_meta() ->
	#{
	  accept_new      => {boolean, true},
	  apns            => config_meta_apns(),
	  charging        => ergw_charging:config_meta(),
	  cluster         => ergw_cluster:config_meta(),
	  handlers        => {{map, {id, binary}, {delegate, delegate_field(handler, _)}}, #{}},
	  http_api        => ergw_http_api:config_meta(),
	  ip_pools        => ergw_ip_pool:config_meta(),
	  metrics         => ergw_prometheus:config_meta(),
	  node_id         => {binary, undefined},
	  node_selection  => ergw_node_selection:config_meta(),
	  nodes           => config_meta_nodes(),
	  path_management => gtp_path:config_meta(),
	  plmn_id         => #{mcc => {mcc, <<"001">>},
			       mnc => {mnc, <<"01">>}},
	  proxy_map       => gtp_proxy_ds:config_meta(),
	  sockets         => ergw_socket:config_meta(),
	  teid            => ergw_tei_mngr:config_meta(),
	  '$end'          => {boolean, true}
	 }.

config_meta() ->
    load_typespecs(),
    normalize_meta(config_raw_meta()).

config_meta_nodes() ->
    VRF = #{
	    features =>
		{flag, atom, ['Access', 'Core', 'SGi-LAN', 'CP-Function', 'LI Function', 'TDF-Source']}
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
		vrfs           => {{klist, {id, vrf}, VRF}, #{}},
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
      entries => {map, {id, binary}, Node}}.

config_meta_apns() ->
    Meta = #{vrf                  => vrf,
	     vrfs                 => {list, vrf},
	     ip_pools             => {list, binary},
	     bearer_type          => {enum, atom, ['IPv4', 'IPv6', 'IPv4v6']},
	     prefered_bearer_type => {enum, atom, ['IPv4', 'IPv6']},
	     ipv6_ue_interface_id => ip6_ifid,
	     'MS-Primary-DNS-Server'    => ip4,
	     'MS-Secondary-DNS-Server'  => ip4,
	     'MS-Primary-NBNS-Server'   => ip4,
	     'MS-Secondary-NBNS-Server' => ip4,
	     'DNS-Server-IPv6-Address'  => {list, ip6},
	     '3GPP-IPv6-DNS-Servers'    => {list, ip6},
	     'Idle-Timeout'             => timeout
	    },
    {{map, {apn, apn}, Meta}, #{}}.

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
normalize_meta({Type, Default}) ->
    T = normalize_meta(Type),
    T#cnf_value{default = Default};
normalize_meta(Type) ->
    meta_type(Type).
meta_type({enum, Type, Values}) ->
    #cnf_value{type = {enum, {normalize_meta(Type), Values}}};
meta_type({flag, Type, Values}) ->
    #cnf_value{type = {flag, {normalize_meta(Type), Values}}};
meta_type({Type, _} = Meta) when is_atom(Type) ->
    #cnf_value{type = Meta};
meta_type(Type) when is_atom(Type) ->
    #cnf_value{type = Type}.

%%%===================================================================
%%% Delegate Helper
%%%===================================================================

delegate_field(Field, Map) when is_map(Map) ->
    Handler = to_atom(get_key(Field, Map)),
    Handler:config_meta().

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

is_mcc(MCC) when size(MCC) == 3 ->
    is_integer((catch binary_to_integer(MCC))).

is_mnc(MNC) when size(MNC) == 2; size(MNC) == 3 ->
    is_integer((catch binary_to_integer(MNC))).

is_ip(IP) ->
    is_binary(IP) andalso (size(IP) == 4 orelse size(IP) == 16).
is_ip4(IP) ->
    is_binary(IP) andalso size(IP) == 4.
is_ip6(IP) ->
    is_binary(IP) andalso size(IP) == 16.

is_ip_address(IP) ->
    is_tuple(IP) andalso (tuple_size(IP) == 4 orelse tuple_size(IP) == 8).
is_ip4_address(IP) ->
    is_tuple(IP) andalso tuple_size(IP) == 4.
is_ip6_address(IP) ->
    is_tuple(IP) andalso tuple_size(IP) == 8.

is_apn('_') -> true;
is_apn(APN) ->
    is_list(APN) andalso lists:dropwhile(fun(X) -> is_binary(X) end, APN) =:= [].

is_timeout(Timeout) ->
    (is_integer(Timeout) andalso Timeout >= 0) orelse Timeout == infinity.

is_vrf(VRF) -> is_binary(VRF).

is_module(Module) ->
    case code:ensure_loaded(Module) of
	{module, _} ->
	    true;
	_ ->
	    false
    end.

is_term(_) ->
     true.

is_enum({_, Values}, Enum) ->
    lists:member(Enum, Values).

is_flag({_, Values}, Flags) ->
    (lists:usort(Flags) -- lists:usort(Values)) == [].

is_ip6_ifid(default) -> true;
is_ip6_ifid(random)  -> true;
is_ip6_ifid({0,0,0,0,E,F,G,H}) ->
    E >= 0 andalso E < 65536 andalso
	F >= 0 andalso F < 65536 andalso
	G >= 0 andalso G < 65536 andalso
	H >= 0 andalso H < 65536 andalso
	E + F + G + H =/= 0;
is_ip6_ifid(_) -> false.

%% complex types

validate_config(Path, K, #cnf_value{} = Meta, V) when is_list(Path) ->
    validate_config(Path ++ [K], Meta, V).

validate_object(Path, Meta, K, V) when is_list(Path), is_map(Meta), is_map_key(K, Meta) ->
    validate_config(Path, K, maps:get(K, Meta), V).

validate_object(Path, Type, V) when is_list(Path), is_map(V) ->
    maps:map(validate_object(Path, Type, _, _), V),
    true;
validate_object(Path, _, _) when is_list(Path) ->
    true.

validate_list(Path, Type, V) when is_list(Path), is_list(V) ->
    [] =:= lists:dropwhile(validate_config(Path, Type, _), V).

validate_klist(Path, {_, KeyType, TypeSpec}, K, V) ->
    Meta = ts2meta(TypeSpec, V),
    validate_config(Path, KeyType, K),
    validate_config(Path, serialize_config(KeyType, K), Meta, V).

validate_klist(Path, Type, V) when is_list(Path), is_map(V) ->
    maps:map(validate_klist(Path, Type, _, _), V),
    true;
validate_klist(Path, {_, _, _}, _) when is_list(Path) ->
    false.

validate_kvlist(Path, {_, KMeta, _, VMeta}, K, V) when is_list(Path) ->
    validate_config(Path, KMeta, K),
    validate_config(Path, serialize_config(KMeta, K), VMeta, V).

validate_kvlist(Path, Type, V) when is_list(Path), is_map(V) ->
    maps:map(validate_kvlist(Path, Type, _, _), V),
    true;
validate_kvlist(Path, {_, _, _, _}, _) when is_list(Path) ->
    false.

validate_map(Path, {_KField, KMeta, TypeSpec}, K, V) when is_list(Path) ->
    Meta = ts2meta(TypeSpec, V),
    validate_config(Path, KMeta, K),
    validate_config(Path, serialize_config(KMeta, K), Meta, V).

validate_map(Path, Type, V) when is_list(Path), is_map(V) ->
    maps:map(validate_map(Path, Type, _, _), V),
    true.

%% processing

fmt_path(Path) ->
    [[$/, to_binary(P)] || P <- Path].

validate_config(Config) ->
    Meta = config_meta(),
    validate_config([], Meta, Config).

validate_type(Path, F, Opts, V) when is_list(Path), is_function(F, 3) ->
    validate_type(Path, F(Path, _, _), Opts, V);
validate_type(Path, F, Opts, V) when is_list(Path), is_function(F, 2) ->
    validate_type(Path, F(Opts, _), Opts, V);
validate_type(Path, F, _Opts, V) when is_list(Path), is_function(F, 1) ->
    try F(V) of
	true  -> true;
	false ->
	    ?LOG(error, "~s: invalid value ~p", [fmt_path(Path), V]),
	    throw({error, {options, {Path, V}}})
    catch
	Class:Error:ST when Class == error; Class == exit ->
	    ?LOG(error, "validation for ~s:~p~nfailed with ~0p:~0p~n  at ~p",
		 [fmt_path(Path), V, Class, Error, ST]),
	    throw({error, {options, {Path, V}}})
    end.

validate_config(Path, #cnf_value{type = Type}, V) when is_atom(Type) ->
    #cnf_type{validate = F} = get_typespec(Type),
    validate_type(Path, F, undefined, V);
validate_config(Path, #cnf_value{type = {Type, Opts}}, V) ->
    #cnf_type{validate = F} = get_typespec(Type),
    validate_type(Path, F, Opts, V).

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

to_atom(V) when is_atom(V) ->
    V;
to_atom(V) when is_binary(V) ->
    binary_to_existing_atom(V);
to_atom(V) when is_list(V) ->
    list_to_existing_atom(V).

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

to_enum({Type, _}, V) ->
    coerce_config(Type, V).

to_flag({Meta, _}, V) ->
    to_list(Meta, V).

%% complex types

to_object(Meta, K, V) when is_atom(K), is_map(Meta) ->
    coerce_config(maps:get(K, Meta), V).

to_object(Meta, Object) when is_map(Object) ->
    maps:fold(
      fun(K, V, M) ->
	      Key = to_atom(K),
	      maps:put(Key, to_object(Meta, Key, V), M)
      end, #{}, Object).

to_list(Meta, V) when is_list(V) ->
    lists:map(coerce_config(Meta, _), V).

to_klist({KeyField, KeyMeta, TypeSpec}, V, Config) ->
    Meta = ts2meta(TypeSpec, V),
    {Key, Map} = take_key(KeyField, V),
    maps:put(coerce_config_type(KeyMeta, Key), coerce_config(Meta, Map), Config).

to_klist(Type, V) when is_list(V) ->
    lists:foldl(to_klist(Type, _, _), #{}, V).

to_kvlist({KField, KMeta, VField, VMeta}, KV, Config) ->
    K = get_key(KField, KV),
    V = get_key(VField, KV),
    maps:put(coerce_config_type(KMeta, K), coerce_config(VMeta, V), Config).

to_kvlist(Type, V) when is_list(V) ->
    lists:foldl(to_kvlist(Type, _, _), #{}, V).

to_map({_KField, KMeta, TypeSpec}, K, V, Config) ->
    Meta = ts2meta(TypeSpec, V),
    maps:put(coerce_config_type(KMeta, K), coerce_config(Meta, V), Config).

to_map(Type, V) when is_map(V) ->
    maps:fold(to_map(Type, _, _, _), #{}, V).

%% processing

merge_default(Config, Default) when is_map(Config), is_map(Default) ->
    maps:merge(Default, Config);
merge_default(Config, _) ->
    Config.

coerce_config(Config) ->
    Meta = config_meta(),
    coerce_config(Meta, Config).

coerce_config(#cnf_value{default = Default} = Type, V) ->
    merge_default(coerce_config_type(Type, V), Default).

coerce_config_type(#cnf_value{type = Type}, V) when is_atom(Type) ->
    #cnf_type{coerce = F} = get_typespec(Type),
    F(V);
coerce_config_type(#cnf_value{type = {Type, Opts}}, V) ->
    #cnf_type{coerce = F} = get_typespec(Type),
    F(Opts, V).

%%%===================================================================
%%% Options Serialization
%%%===================================================================

from_ip(IP) when is_binary(IP) ->
    from_ip_address(ergw_inet:bin2ip(IP)).

from_ip_address(IP) when is_tuple(IP) ->
    iolist_to_binary(inet:ntoa(IP)).

from_apn('_') ->
    <<"*">>;
from_apn(APN) ->
    iolist_to_binary(lists:join($., APN)).

from_timeout(Timeout) when not is_integer(Timeout) ->
    Timeout;
from_timeout(0) ->
    #{timeout => 0};
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
    from_ip_address(IfId).

from_enum({Type, _}, V) ->
    serialize_config(Type, V).

from_flag({Meta, _}, V) ->
    from_list(Meta, V).

%% complex types

from_object(Meta, K, V) when is_map(Meta), is_map_key(K, Meta) ->
    serialize_config(maps:get(K, Meta), V).

from_object(Meta, V) when is_map(V) ->
    maps:map(from_object(Meta, _, _), V).

from_list(Type, V) when is_list(V) ->
    lists:map(serialize_config(Type, _), V).

from_klist({KeyField, KeyMeta, TypeSpec}, K, V, Config) ->
    Meta = ts2meta(TypeSpec, V),
    [maps:put(KeyField, serialize_config(KeyMeta, K), serialize_config(Meta, V))|Config].

from_klist(Type, V) when is_map(V) ->
    maps:fold(from_klist(Type, _, _, _), [], V).

from_kvlist({KField, KMeta, VField, VMeta}, K, V, Config) ->
    [#{KField => serialize_config(KMeta, K), VField => serialize_config(VMeta, V)}|Config].

from_kvlist(Type, V) when is_map(V) ->
    maps:fold(from_kvlist(Type, _, _, _), [], V).

from_map({_KField, KMeta, TypeSpec}, K, V, Config) ->
    Meta = ts2meta(TypeSpec, V),
    maps:put(serialize_config(KMeta, K), serialize_config(Meta, V), Config).

from_map(Type, V) when is_map(V) ->
    maps:fold(from_map(Type, _, _, _), #{}, V).

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
%%% Get Functions
%%%===================================================================

%% direct access to internal presentation, no type conversion

get([], Config) ->
    {ok, Config};
get([K|Next], Config) when is_map_key(K, Config) ->
    get(Next, maps:get(K, Config));
get(_, _) ->
    false.

%%%===================================================================
%%% Config Coercion
%%%===================================================================

%% set k/v, convert from external representation where needed

%% complex types

update_kv(Key, Next, Meta, Value, Default, V) ->
    Upd = case maps:find(Key, V) of
	      {ok, Old} ->
		  set(Next, Meta, Value, Old);
	      _ ->
		  set(Next, Meta, Value, Default)
	  end,
    maps:put(Key, Upd, V).

set_object([K|Next], Meta, Value, Default, V) ->
    Key = to_atom(K),
    update_kv(K, Next, maps:get(Key, Meta), Value, Default, V).

set_list(Key, Type, Value, _Default, V) when is_list(V) ->
    error(badarg, [Key, Type, Value, V]).

set_klist([K|Next], {_KeyField, KeyMeta, TypeSpec}, Value, Default, V) when is_map(V) ->
    Key = coerce_config_type(KeyMeta, K),
    Upd = case maps:find(Key, V) of
	      {ok, Old} ->
		  Meta = ts2meta(TypeSpec, Old),
		  set(Next, Meta, Value, Old);
	      _ when Next =:= [] ->
		  Meta = ts2meta(TypeSpec, Value),
		  set(Next, Meta, Value, Default);
	      _ ->
		  Meta = ts2meta(TypeSpec, Default),
		  set(Next, Meta, Value, Default)
	  end,
    maps:put(Key, Upd, V);
set_klist([K], {_KeyField, KeyMeta, TypeSpec}, Value, Default, _) when is_map(Value) ->
    Key = coerce_config_type(KeyMeta, K),
    Meta = ts2meta(TypeSpec, Value),
    #{Key => set([], Meta, Value, Default)};
set_klist([K|Next], {_KeyField, KeyMeta, TypeSpec}, Value, Default, _) when is_map(Default) ->
    Key = coerce_config_type(KeyMeta, K),
    Meta = ts2meta(TypeSpec, Default),
    #{Key => set(Next, Meta, Value, Default)}.

set_kvlist([K|Next], {_KField, KMeta, _VField, VMeta}, Value, Default, V) when is_map(V) ->
    Key = coerce_config_type(KMeta, K),
    update_kv(Key, Next, VMeta, Value, Default, V).

set_map([K|Next], {_KField, KMeta, TypeSpec}, Value, Default, V) when is_map(V) ->
    Key = coerce_config_type(KMeta, K),
    Upd = case maps:find(Key, V) of
	      {ok, Old} ->
		  Meta = ts2meta(TypeSpec, Old),
		  set(Next, Meta, Value, Old);
	      _ when Next =:= [] ->
		  Meta = ts2meta(TypeSpec, Value),
		  set(Next, Meta, Value, Default);
	      _ ->
		  Meta = ts2meta(TypeSpec, Default),
		  set(Next, Meta, Value, Default)
	  end,
    maps:put(Key, Upd, V).

%% processing

%% set/3
set(Key, Value, Config) ->
    Meta = config_meta(),
    set(Key, Meta, Value, Config).

%% set/4
set([], Type, Value, _V) ->
    coerce_config(Type, Value);

set(Key, #cnf_value{type = Type, default = Default}, Value, V) when is_atom(Type) ->
    set(Key, get_typespec(Type), [], Value, Default, V);
set(Key, #cnf_value{type = {Type, Opts}, default = Default}, Value, V) when is_atom(Type) ->
    set(Key, get_typespec(Type), [Opts], Value, Default, V).

set(Key, #cnf_type{set = F}, Opts, Value, Default, V) when is_function(F) ->
    apply(F, [Key] ++ Opts ++ [Value, Default, V]);
set(_, _, _, _, _, _) ->
    false.

%% set k/v, not conversion

set_value([], Value, _) ->
    Value;
set_value([Key], Value, Config) ->
    maps:put(Key, Value, Config);
set_value([H | Keys], Value, Config) when is_map_key(H, Config) ->
    maps:update_with(H, set_value(Keys, Value, _), Config).

%%%===================================================================
%%% Find Functions
%%%===================================================================

%% find key in external representation, return raw internal value and
%% conversion function

%% complex types

find_object([K|Next], Meta, V) when is_map(V) ->
    find_kv(K, Next, Meta, V).

find_kv(Key, Next, Meta, V) ->
    case maps:find(Key, V) of
	{ok, Value} ->
	    find(Next, Meta, Value);
	_ ->
	    false
    end.


find_list([Nth|Next], Type, V) when is_list(V), Nth =< length(V) ->
    find(Next, Type, lists:nth(Nth, V));
find_list(_, _, V) when is_list(V) ->
    false.

find_klist([K|Next], {_KeyField, KeyMeta, TypeSpec}, V) when is_map(V) ->
    Key = coerce_config_type(KeyMeta, K),
    find_kv(Key, Next, ts2meta(TypeSpec, V), V).

find_kvlist([K|Next], {_KField, KMeta, _VField, VMeta}, V) when is_map(V) ->
    Key = coerce_config_type(KMeta, K),
    find_kv(Key, Next, VMeta, V).

find_map([K|Next], {_KField, KMeta, TypeSpec}, V) when is_map(V) ->
    Key = coerce_config_type(KMeta, K),
    find_kv(Key, Next, ts2meta(TypeSpec, V), V).

%% processing
find(Key, Config) ->
    Meta = config_meta(),
    find(Key, Meta, Config).

find(Key, #cnf_value{type = Type}, V) when is_atom(Type) ->
    find(Key, get_typespec(Type), [], V);
find(Key, #cnf_value{type = {Type, Opts}}, V) when is_atom(Type) ->
    find(Key, get_typespec(Type), [Opts], V).

find([], #cnf_type{serialize = F}, Opts, V) when is_function(F) ->
    {ok, V, fun(X) -> apply(F, Opts ++ [X]) end};
find(Key, #cnf_type{find = F}, Opts, V) when is_function(F) ->
    apply(F, [Key] ++ Opts ++ [V]);
find(_, _, _, _) ->
    false.

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
		 serialize = fun from_object/2,
		 validate  = fun validate_object/3,
		 find      = fun find_object/3,
		 set       = fun set_object/5
		},
	  list =>
	      #cnf_type{
		 coerce    = fun to_list/2,
		 serialize = fun from_list/2,
		 validate  = fun validate_list/3,
		 find      = fun find_list/3,
		 set       = fun set_list/5
		},
	  klist =>
	      #cnf_type{
		 coerce    = fun to_klist/2,
		 serialize = fun from_klist/2,
		 validate  = fun validate_klist/3,
		 find      = fun find_klist/3,
		 set       = fun set_klist/5
		},
	  kvlist =>
	      #cnf_type{
		 coerce    = fun to_kvlist/2,
		 serialize = fun from_kvlist/2,
		 validate  = fun validate_kvlist/3,
		 find      = fun find_kvlist/3,
		 set       = fun set_kvlist/5
		},
	  map =>
	      #cnf_type{
		 coerce    = fun to_map/2,
		 serialize = fun from_map/2,
		 validate  = fun validate_map/3,
		 find      = fun find_map/3,
		 set       = fun set_map/5
		},
	  passthrough =>
	      #cnf_type{
		 coerce    = fun (V) -> V end,
		 serialize = fun (V) -> V end,
		 validate  = fun (_) -> true end
		},
	  term =>
	      #cnf_type{
		 coerce    = fun to_term/1,
		 serialize = fun from_term/1,
		 validate  = fun is_term/1
		},
	  atom =>
	      #cnf_type{
		 coerce    = fun to_atom/1,
		 serialize = fun (V) -> V end,
		 validate  = fun is_atom/1
		},
	  binary =>
	      #cnf_type{
		 coerce    = fun to_binary/1,
		 serialize = fun (V) -> V end,
		 validate  = fun is_binary/1
		},
	  boolean =>
	      #cnf_type{
		 coerce    = fun to_boolean/1,
		 serialize = fun (V) -> V end,
		 validate  = fun is_boolean/1
		},
	  integer =>
	      #cnf_type{
		 coerce    = fun to_integer/1,
		 serialize = fun (V) -> V end,
		 validate  = fun is_integer/1
		},
	  string =>
	      #cnf_type{
		 coerce    = fun to_string/1,
		 serialize = fun from_string/1,
		 validate  = fun is_list/1
		},
	  module =>
	      #cnf_type{
		 coerce    = fun to_module/1,
		 serialize = fun (V) -> V end,
		 validate  = fun is_module/1
		},
	  mcc =>
	      #cnf_type{
		 coerce    = fun to_binary/1,
		 serialize = fun (V) -> V end,
		 validate  = fun is_mcc/1
		},
	  mnc =>
	      #cnf_type{
		 coerce    = fun to_binary/1,
		 serialize = fun (V) -> V end,
		 validate  = fun is_mnc/1
		},
	  ip =>
	      #cnf_type{
		 coerce    = fun to_ip/1,
		 serialize = fun from_ip/1,
		 validate  = fun is_ip/1
		},
	  ip4 =>
	      #cnf_type{
		 coerce    = fun to_ip4/1,
		 serialize = fun from_ip/1,
		 validate  = fun is_ip4/1
		},
	  ip6 =>
	      #cnf_type{
		 coerce    = fun to_ip6/1,
		 serialize = fun from_ip/1,
		 validate  = fun is_ip6/1
		},
	  ip_address =>
	      #cnf_type{
		 coerce    = fun to_ip_address/1,
		 serialize = fun from_ip_address/1,
		 validate  = fun is_ip_address/1
		},
	  ip4_address =>
	      #cnf_type{
		 coerce    = fun to_ip4_address/1,
		 serialize = fun from_ip_address/1,
		 validate  = fun is_ip4_address/1
		},
	  ip6_address =>
	      #cnf_type{
		 coerce    = fun to_ip6_address/1,
		 serialize = fun from_ip_address/1,
		 validate  = fun is_ip6_address/1
		},
	  ip6_ifid =>
	      #cnf_type{
		 coerce    = fun to_ip6_ifid/1,
		 serialize = fun from_ip6_ifid/1,
		 validate  = fun is_ip6_ifid/1
		},
	  apn =>
	      #cnf_type{
		 coerce    = fun to_apn/1,
		 serialize = fun from_apn/1,
		 validate  = fun is_apn/1
		},
	  vrf =>
	      #cnf_type{
		 coerce    = fun to_vrf/1,
		 serialize = fun from_vrf/1,
		 validate  = fun is_vrf/1
		},
	  timeout =>
	      #cnf_type{
		 coerce    = fun to_timeout/1,
		 serialize = fun from_timeout/1,
		 validate  = fun is_timeout/1
		},
	  enum =>
	      #cnf_type{
		 coerce    = fun to_enum/2,
		 serialize = fun from_enum/2,
		 validate  = fun is_enum/2
		},
	  flag =>
	      #cnf_type{
		 coerce    = fun to_flag/2,
		 serialize = fun from_flag/2,
		 validate  = fun is_flag/2
		}
	 },
    register_typespec(Spec).

get_typespec(Type) ->
    Key = {?MODULE, typespecs},
    maps:get(Type, persistent_term:get(Key)).
