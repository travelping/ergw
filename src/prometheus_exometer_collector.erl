%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(prometheus_exometer_collector).

-export([deregister_cleanup/1,
	 collect_mf/2]).

-import(prometheus_model_helpers, [create_mf/4]).

-include_lib("prometheus/include/prometheus.hrl").

-behaviour(prometheus_collector).

-define(METRIC_NAME_PREFIX, "erlang_vm_").

%%%=========================================================================
%%%  API
%%%=========================================================================

deregister_cleanup(_) -> ok.

-spec collect_mf(_Registry, Callback) -> ok when
      _Registry :: prometheus_registry:registry(),
      Callback :: prometheus_collector:callback().
collect_mf(_Registry, Callback) ->
    [add_exo_entry(Callback, M) || M <- exometer:find_entries([])],
    ok.

%%%=========================================================================
%%%  internal functions
%%%=========================================================================

add_exo_entry(Callback, {Name, Type, enabled}) ->
    case exometer:get_value(Name) of
	{ok, ExoValue} ->
	    Help = lists:flatten(io_lib:format("~w", [Name])),
	    Value = convert(Type, ExoValue),
	    lager:debug("add_exo_enxtry ~p, ~p, ~p, ~p (~p)",
			[make_metric_name(Name), Help, type(Type), Value, ExoValue]),
	    Callback(create_mf(make_metric_name(Name), Help, type(Type), Value));
	_ ->
	    ok
    end;
add_exo_entry(_, _) ->
    ok.

ioize(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom, utf8);
ioize(Number) when is_float(Number) ->
    float_to_binary(Number, [{decimals, 4}]);
ioize(Number) when is_integer(Number) ->
    integer_to_binary(Number);
ioize({_,_,_,_} = IP) ->
    list_to_binary(inet:ntoa(IP));
ioize({_,_,_,_,_,_,_,_} = IP) ->
    list_to_binary(inet:ntoa(IP));
ioize(Bin) when is_binary(Bin) ->
    Bin;
ioize(Something) ->
    iolist_to_binary(io_lib:format("~p", [Something])).

make_metric_name(Path) ->
    NameList = lists:join($_, lists:map(fun ioize/1, Path)),
    NameBin = iolist_to_binary(NameList),
    re:replace(NameBin, "-|\\.|:", "_", [global, {return, binary}]).

type(function) ->
    untyped;
type(histogram) ->
    summary;
type(spiral) ->
    gauge;
type(Type) ->
    Type.

convert(histogram, List) when is_list(List) ->
    Mean = proplists:get_value(mean, List),
    N = proplists:get_value(n, List),
    {N, Mean * N};
convert(spiral, List) when is_list(List) ->
    proplists:get_value(count, List, 0);
convert(_Type, List) when is_list(List) ->
    proplists:get_value(value, List, 0);
convert(_Type, {_, Value}) ->
    Value;
convert(_Type, Value) ->
    Value.
