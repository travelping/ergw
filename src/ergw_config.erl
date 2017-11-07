%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_config).

-compile({parse_transform, cut}).

%% API
-export([load_config/1,
	 validate_config/1,
	 validate_options/4,
	 opts_fold/3,
	 to_map/1]).

-define(DefaultOptions, [{plmn_id, {<<"001">>, <<"01">>}},
			 {accept_new, true},
			 {dp_handler, ergw_sx_erl},
			 {sockets, []},
			 {handlers, []},
			 {vrfs, []},
			 {apns, []}]).
-define(DefaultHandlerOpts, [{handler,    undefined},
			     {protocol,   undefined},
			     {sockets,    undefined},
			     {data_paths, undefined}]).

-define(is_opts(X), (is_list(X) orelse is_map(X))).

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

check_unique_keys(Key, List) when is_list(List) ->
    UList = lists:ukeysort(1, List),
    if length(UList) == length(List) ->
	    ok;
       true ->
	    Duplicate = proplists:get_keys(List) -- proplists:get_keys(UList),
	    throw({error, {options, {Key, Duplicate}}})
    end.

validate_config(Config) ->
    validate_options(fun validate_option/2, Config, ?DefaultOptions, list).

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

validate_options(Fun, Options, Defaults, ReturnType)
  when is_list(Options), is_list(Defaults) ->
    Opts0 = proplists:unfold(Options),
    Opts = lists:ukeymerge(1, lists:keysort(1, Opts0), lists:keysort(1, Defaults)),
    return_type(validate_options(Fun, Opts), ReturnType);
validate_options(Fun, Options, Defaults, ReturnType)
  when is_map(Options) andalso ?is_opts(Defaults) ->
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
	ok = ergw_loader:load(ergw_sx_api, ergw_sx, Value),
	Value
    catch
	error:{missing_exports, Missing} ->
	    throw({error, {options, {dp_handler, Value, Missing}}});
	_:Cause ->
	    ST = erlang:get_stacktrace(),
	    throw({error, {options, {dp_handler, Value, Cause, ST}}})
    end;
validate_option(sockets, Value) when is_list(Value), length(Value) >= 1 ->
    check_unique_keys(sockets, Value),
    validate_options(fun validate_sockets_option/2, Value);
validate_option(handlers, Value) when is_list(Value), length(Value) >= 1 ->
    check_unique_keys(handlers, without_opts(['gn', 's5s8'], Value)),
    validate_options(fun validate_handlers_option/2, Value);
validate_option(vrfs, Value) when is_list(Value) ->
    check_unique_keys(vrfs, Value),
    validate_options(fun validate_vrfs_option/2, Value);
validate_option(apns, Value) when is_list(Value) ->
    check_unique_keys(apns, Value),
    validate_options(fun validate_apns/1, Value);
validate_option(http_api, Value) when is_list(Value) ->
    validate_options(fun ergw_http_api:validate_options/2, Value);
validate_option(Opt, Value)
  when Opt == plmn_id;
       Opt == accept_new;
       Opt == dp_handler;
       Opt == sockets;
       Opt == handlers;
       Opt == vrfs;
       Opt == apns;
       Opt == http_api ->
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

validate_sockets_option(Opt, Values)
  when is_atom(Opt), ?is_opts(Values) ->
    case get_opt(type, Values) of
	'gtp-c' ->
	    gtp_socket:validate_options(Values);
	'gtp-u' ->
	    ergw_sx:validate_options(Values);
	_ ->
	    throw({error, {options, {Opt, Values}}})
    end;
validate_sockets_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).

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

validate_vrfs_option(Opt, Values)
  when is_atom(Opt), ?is_opts(Values) ->
    vrf:validate_options(Values);
validate_vrfs_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_apns({APN0, Value}) when ?is_opts(Value) ->
    APN =
	if APN0 =:= '_' -> APN0;
	   true         -> validate_apn_name(APN0)
	end,
    {APN, validate_options(fun validate_apn_option/2, Value, [{vrf, {invalid}}], map)};
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

validate_apn_option(vrf, Value) when is_atom(Value) ->
    Value;
validate_apn_option(Opt, Value) ->
    vrf:validate_option(Opt, Value).

load_socket({Name, Options}) ->
    ergw:start_socket(Name, Options).

load_handler({Name, #{handler  := Handler,
		      protocol := Protocol,
		      sockets  := Sockets} = Opts0}) ->
    Opts = maps:to_list(maps:without([handler, protocol, sockets], Opts0)),
    lists:foreach(ergw:attach_protocol(_, Name, Protocol, Handler, Opts), Sockets).

load_vrf({Name, Options}) ->
    ergw:start_vrf(Name, Options).

load_apn({APN, #{vrf := VRF} = Opts0}) ->
    Opts = maps:without([vrf], Opts0),
    ergw:attach_vrf(APN, VRF, Opts).
