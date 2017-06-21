%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_api).

%% API
-export([peer/1, tunnel/1, metrics/1, metrics/2]).

%%%===================================================================
%%% API
%%%===================================================================

peer(all) ->
    Peers = gtp_path_reg:all(),
    lists:map(fun({_, Pid}) -> gtp_path:info(Pid) end, Peers);
peer({_,_,_,_} = IP) ->
    collect_peer_info(gtp_path_reg:all(IP));
peer(Port) when is_atom(Port) ->
    collect_peer_info(gtp_path_reg:all(Port)).

tunnel(all) ->
    Contexts = gtp_context_reg:all(),
    lists:foldl(fun({{_Socket, _TEID}, Pid}, Tunnels) -> collect_contexts(Pid, Tunnels) end, [], Contexts);
tunnel({_,_,_,_} = IP) ->
    lists:foldl(fun collext_path_contexts/2, [], gtp_path_reg:all(IP));
tunnel(Port) when is_atom(Port) ->
    lists:foldl(fun collext_path_contexts/2, [], gtp_path_reg:all(Port)).

metrics(Path) -> metrics(Path, json).

metrics(Path, prometheus) ->
    Metrics = exometer:get_values(Path),
    Formatted = format_metrics(Metrics, []),
    iolist_to_binary(Formatted);
metrics(Path, json) ->
    Metrics0 = lists:foldl(fun fmt_exo_entries/2, #{}, exometer:get_values(Path)),
    Metrics = lists:foldl(fun(M, A) -> maps:get(M, A) end, Metrics0, Path),
    jsx:encode(Metrics);
metrics(Path, _Format) -> metrics(Path, json).


%%%===================================================================
%%% Internal functions
%%%===================================================================
fmt_exo_entries({Path, Value}, Metrics) ->
    fmt_exo_entries(Path, Value, Metrics).

fmt_exo_entries([Path], Value, Metrics) ->
    Metrics#{Path => maps:from_list(Value)};
fmt_exo_entries([H|T], Value, Metrics) ->
    Entry = maps:get(H, Metrics, #{}),
    Metrics#{H => fmt_exo_entries(T, Value, Entry)}.

collect_peer_info(Peers) ->
    lists:map(fun gtp_path:info/1, Peers).

collext_path_contexts(Path, Tunnels) ->
        lists:foldl(fun({Pid}, TunIn) -> collect_contexts(Pid, TunIn) end, Tunnels, gtp_path:all(Path)).

collect_contexts(Context, Tunnels) ->
    io:format("Context: ~p~n", [Context]),
    Info = gtp_context:info(Context),
    [Info | Tunnels].

% converts metrics to Prometheus format
% based on github.com/GalaxyGorilla/exometer_prometheus
format_metrics([], Acc) -> Acc;
format_metrics([{Metric, DataPoints} | Metrics], Acc) ->
    Name = make_metric_name(Metric),
    Info = exometer:info(Metric),
    Type = map_type(proplists:get_value(type, Info, undefined)),
    Payload = [[<<"# TYPE ">>, Name, <<" ">>, Type, <<"\n">>] |
               [[Name, map_datapoint(DPName), <<" ">>, ioize(Value), <<"\n">>]
                || {DPName, Value} <- DataPoints, is_valid_datapoint(DPName)]],
    Payload1 = maybe_add_sum(Payload, Name, Metric, Type),
    format_metrics(Metrics, [Payload1, <<"\n">> | Acc]).

ioize(Atom) when is_atom(Atom) ->
    atom_to_binary(Atom, utf8);
ioize(Number) when is_float(Number) ->
    float_to_binary(Number, [{decimals, 4}]);
ioize(Number) when is_integer(Number) ->
    integer_to_binary(Number);
ioize(Something) ->
    Something.

maybe_add_sum(Payload, MetricName, Metric, <<"summary">>) ->
    {ok, [{mean, Mean}, {n, N}]} = exometer:get_value(Metric, [mean, n]),
    [Payload | [MetricName, <<"_sum ">>, ioize(Mean * N), <<"\n">>]];
maybe_add_sum(Payload, _MetricName, _Metric, _Else) ->
    Payload.

make_metric_name(Metric) ->
    lists:reverse(make_metric_name(Metric, [])).

make_metric_name([], Acc) -> Acc;
make_metric_name([Elem], Acc) ->
    [normalize(Elem) | Acc];
make_metric_name([Elem | Metric], Acc) ->
    make_metric_name(Metric, [<<"_">>, normalize(Elem) | Acc]).

normalize(Something) ->
    re:replace(ioize(Something), "-|\\.", "_", [global, {return,binary}]).

map_type(undefined)     -> <<"untyped">>;
map_type(counter)       -> <<"gauge">>;
map_type(gauge)         -> <<"gauge">>;
map_type(spiral)        -> <<"gauge">>;
map_type(histogram)     -> <<"summary">>;
map_type(function)      -> <<"gauge">>;
map_type(Tuple) when is_tuple(Tuple) ->
    case element(1, Tuple) of
        function -> <<"gauge">>;
        _Else    -> <<"untyped">>
    end.

map_datapoint(value)    -> <<"">>;
map_datapoint(one)      -> <<"">>;
map_datapoint(n)        -> <<"_count">>;
map_datapoint(50)       -> <<"{quantile=\"0.5\"}">>;
map_datapoint(90)       -> <<"{quantile=\"0.9\"}">>;
map_datapoint(Integer) when is_integer(Integer)  ->
    Bin = integer_to_binary(Integer),
    <<"{quantile=\"0.", Bin/binary, "\"}">>;
map_datapoint(Something)  ->
    %% this is for functions with alternative datapoints
    Bin = ioize(Something),
    <<"{datapoint=\"", Bin/binary, "\"}">>.

is_valid_datapoint(count) -> false;
is_valid_datapoint(mean) -> false;
is_valid_datapoint(min) -> false;
is_valid_datapoint(max) -> false;
is_valid_datapoint(median) -> false;
is_valid_datapoint(ms_since_reset) -> false;
is_valid_datapoint(_Else) -> true.
