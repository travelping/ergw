%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_config).

-compile({parse_transform, cut}).

%% API
-export([load_config/1,
	 validate_options/4,
	 opts_fold/3,
	 to_map/1]).

-define(DefaultOptions, [{plmn_id, {<<"001">>, <<"01">>}},
			 {accept_new, true},
			 {dp_handler, gtp_dp_kmod},
			 {sockets, []},
			 {handlers, []},
			 {vrfs, []},
			 {apns, []}]).

%%%===================================================================
%%% API
%%%===================================================================

load_config(Config0) ->
    Config = validate_config(Config0),
    ergw:load_config(Config),
    lists:foreach(fun load_socket/1, proplists:get_value(sockets, Config)),
    lists:foreach(fun load_handler/1, proplists:get_value(handlers, Config)),
    lists:foreach(fun load_vrf/1, proplists:get_value(vrfs, Config)),
    lists:foreach(fun load_apn/1, proplists:get_value(apns, Config)),
    ergw_http_api:init(),
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

validate_config(Config) ->
    validate_options(fun validate_option/2, Config, ?DefaultOptions, list).

validate_options(_Fun, []) ->
        [];
validate_options(Fun, [Opt | Tail]) when is_atom(Opt) ->
        [Fun(Opt, true) | validate_options(Fun, Tail)];
validate_options(Fun, [{Opt, Value} | Tail]) ->
        [{Opt, Fun(Opt, Value)} | validate_options(Fun, Tail)].

validate_options(Fun, Options, Defaults, ReturnType)
  when is_list(Options), is_list(Defaults) ->
    Opts = lists:ukeymerge(1, lists:keysort(1, Options), lists:keysort(1, Defaults)),
    return_type(validate_options(Fun, Opts), ReturnType);
validate_options(Fun, Options, Defaults, ReturnType)
  when is_map(Options), (is_map(Defaults) orelse is_list(Defaults)) ->
    Opts = maps:merge(to_map(Defaults), Options),
    return_type(maps:map(Fun, Opts), ReturnType).

validate_option(plmn_id, {MCC, MNC} = Value) ->
    case validate_mcc_mcn(MCC, MNC) of
       ok -> Value;
       _  -> throw({error, {options, {plmn_id, Value}}})
    end;
validate_option(accept_new, Value) when is_boolean(Value) ->
    Value;
validate_option(dp_handler, Value) when is_atom(Value) ->
    try
	ok = ergw_loader:load(gtp_dp_api, gtp_dp, Value)
    catch
	error:{missing_exports, Missing} ->
	    throw({error, {options, {dp_handler, Value, Missing}}});
	_:Cause ->
	    ST = erlang:get_stacktrace(),
	    throw({error, {options, {dp_handler, Value, Cause, ST}}})
    end;
validate_option(sockets, Value) when is_list(Value), length(Value) >= 1 ->
    validate_options(fun validate_sockets_option/2, Value);
validate_option(handlers, Value) when is_list(Value), length(Value) >= 1 ->
    validate_options(fun validate_handlers_option/2, Value);
validate_option(vrfs, Value) when is_list(Value) ->
    validate_options(fun validate_vrfs_option/2, Value);
validate_option(apns, Value) when is_list(Value) ->
    validate_options(fun validate_apns_option/2, Value);
validate_option(http_api, Value) when is_list(Value) ->
    validate_options(fun ergw_http_api:validate_options/2, Value);
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

validate_sockets_option(Opt, Value) when is_atom(Opt), is_list(Value) ->
    validate_options(fun validate_socket_option/2, Value);
validate_sockets_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_socket_option(name, Value) when is_atom(Value) ->
    Value;
validate_socket_option(type, Value)
  when Value == 'gtp-c'; Value == 'gtp-u' ->
    Value;
validate_socket_option(node, Value) when is_atom(Value) ->
    Value;
validate_socket_option(ip, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Value;
validate_socket_option(netdev, Value)
  when is_list(Value); is_binary(Value) ->
    Value;
validate_socket_option(netns, Value)
  when is_list(Value); is_binary(Value) ->
    Value;
validate_socket_option(freebind, true) ->
    freebind;
validate_socket_option(reuseaddr, true) ->
    true;
validate_socket_option(rcvbuf, Value) when is_integer(Value) ->
    Value;
validate_socket_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_handlers_option(Opt, Value)
  when is_list(Value) andalso
       (Opt == 'gn' orelse Opt == 's5s8') ->
    Handler = proplists:get_value(handler, Value),
    case code:ensure_loaded(Handler) of
	{module, _} ->
	    ok;
	_ ->
	    throw({error, {options, {handler, Value}}})
    end,
    Handler:validate_options(Value);
validate_handlers_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_vrfs_option(Opt, Values)
  when is_atom(Opt), is_list(Values) ->
    vrf:validate_options(Values);
validate_vrfs_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_apns_option('_', Value) when is_list(Value) ->
    validate_options(fun validate_apn_option/2, Value, [], map);
validate_apns_option(APN, Value) when is_list(APN), is_list(Value) ->
    validate_options(fun validate_apn_option/2, Value, [], map);
validate_apns_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_apn_option(vrf, Value) when is_atom(Value) ->
    Value;
validate_apn_option(Opt, Value) ->
    vrf:validate_option(Opt, Value).

load_socket({Name, Options}) ->
    ergw:start_socket(Name, Options).

load_handler({Protocol, #{handler := Handler,
			  sockets := Sockets} = Opts0}) ->
    Opts = maps:to_list(maps:without([handler, sockets], Opts0)),
    lists:foreach(ergw:attach_protocol(_, Protocol, Handler, Opts), Sockets);
load_handler({Protocol, Value}) ->
        throw({error, {options, {Protocol, Value}}}).

load_vrf({Name, Options}) ->
    ergw:start_vrf(Name, Options).

load_apn({APN, #{vrf := VRF} = Opts0}) ->
    Opts = maps:without([vrf], Opts0),
    ergw:attach_vrf(APN, VRF, Opts).
