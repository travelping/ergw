%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_config).

-compile({parse_transform, cut}).

%% API
-export([load_config/1, validate_options/2]).

-define(DefaultOptions, [{plmn_id, {<<"001">>, <<"01">>}},
			 {sockets, []},
			 {handlers, []},
			 {vrfs, []},
			 {apns, []}]).

%%%===================================================================
%%% API
%%%===================================================================

load_config(Config0) ->
    Config = validate_config(Config0),
    ergw:set_plmn_id(proplists:get_value(plmn_id, Config)),
    lists:foreach(fun load_socket/1, proplists:get_value(sockets, Config)),
    lists:foreach(fun load_handler/1, proplists:get_value(handlers, Config)),
    lists:foreach(fun load_vrf/1, proplists:get_value(vrfs, Config)),
    lists:foreach(fun load_apn/1, proplists:get_value(apns, Config)),
    ok.

%%%===================================================================
%%% Options Validation
%%%===================================================================

validate_options(_Fun, []) ->
        [];
validate_options(Fun, [Opt | Tail]) when is_atom(Opt) ->
        [Fun(Opt, true) | validate_options(Fun, Tail)];
validate_options(Fun, [{Opt, Value} | Tail]) ->
        [{Opt, Fun(Opt, Value)} | validate_options(Fun, Tail)].

validate_config(Options) ->
    Opts = lists:keymerge(1, lists:keysort(1, Options), lists:keysort(1, ?DefaultOptions)),
    validate_options(fun validate_option/2, Opts).

validate_option(plmn_id, {MCC, MNC} = Value) ->
    case validate_mcc_mcn(MCC, MNC) of
	ok -> Value;
	_  -> throw({error, {options, {plmn_id, Value}}})
    end;
validate_option(sockets, Value) when is_list(Value), length(Value) >= 1 ->
    validate_options(fun validate_sockets_option/2, Value);
validate_option(handlers, Value) when is_list(Value), length(Value) >= 1 ->
    validate_options(fun validate_handlers_option/2, Value);
validate_option(vrfs, Value) when is_list(Value) ->
    validate_options(fun validate_vrfs_option/2, Value);
validate_option(apns, Value) when is_list(Value) ->
    validate_options(fun validate_apns_option/2, Value);
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
validate_socket_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_handlers_option(Opt, Value)
  when is_list(Value) andalso
       (Opt == 'gn' orelse Opt == 's5s8' orelse Opt == 's2a') ->
    Handler = proplists:get_value(handler, Value),
    case code:ensure_loaded(Handler) of
	{module, _} ->
	    ok;
	_ ->
	    throw({error, {options, {handler, Value}}})
    end,
    maps:from_list(Handler:validate_options(Value));
validate_handlers_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_vrfs_option(Opt, Values)
  when is_atom(Opt), is_list(Values) ->
    vrf:validate_options(Values);
validate_vrfs_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_apns_option('_', Value) when is_list(Value) ->
    maps:from_list(validate_options(fun validate_apn_option/2, Value));
validate_apns_option(APN, Value) when is_list(APN), is_list(Value) ->
    maps:from_list(validate_options(fun validate_apn_option/2, Value));
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
        throw({error, {options, {Protocol, maps:to_list(Value)}}}).

load_vrf({Name, Options}) ->
    ergw:start_vrf(Name, Options).

load_apn({APN, #{vrf := VRF} = Opts0}) ->
    Opts = maps:without([vrf], Opts0),
    ergw:attach_vrf(APN, VRF, Opts).
