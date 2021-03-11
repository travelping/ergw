%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_prometheus_collector).
-behaviour(prometheus_collector).

-include("include/ergw.hrl").
-include_lib("prometheus/include/prometheus.hrl").

-export([
    deregister_cleanup/1,
    collect_mf/2,
    collect_metrics/2,
    gather/0
]).

-ignore_xref([gather/0, collect_metrics/2]).

-import(prometheus_model_helpers, [create_mf/5, gauge_metric/2]).

-define(METRIC_NAME_PREFIX, "").

-define(METRICS, [{pfcp_sx_association_total, gauge, "Total number of PFCP Sx association"},
                  {pfcp_sx_context_total, gauge, "Total number of PFCP Sx node session counters"}]).

%%====================================================================
%% Collector API
%%====================================================================

deregister_cleanup(_) ->
    ok.

collect_mf(_Registry, Callback) ->
    Stats = gather(),
    [mf(Callback, Metric, Stats) || Metric <- ?METRICS],
    ok.

mf(Callback, {Name, Type, Help}, Stats) ->
    Callback(create_mf(?METRIC_NAME(Name), Help, Type, ?MODULE,
                       {Type, fun(S) -> maps:get(Name, S, undefined) end, Stats})),
    ok.

collect_metrics(_, {Type, Fun, Stats}) ->
    case Fun(Stats) of
        M when is_map(M) ->
            [metric(Type, Labels, Value) || {Labels, Value} <- maps:to_list(M)];
        _ ->
            undefined
    end.

metric(gauge, Labels, Value) ->
    gauge_metric(Labels, Value).

%%%===================================================================
%%% Internal functions
%%%===================================================================

gather() ->
    gather(?METRICS, #{}).

gather([], Acc) ->
    Acc;
gather([{pfcp_sx_association_total = Key, _, _}|T], Acc) ->
    gather(T, Acc#{Key => gather_sx_association()});
gather([{pfcp_sx_context_total = Key, _, _}|T], Acc) ->
    gather(T, Acc#{Key => gather_sx_context()}).

gather_sx_association() ->
    #{
        [{state, up}] => ergw_sx_node_reg:count_available()
    }.

gather_sx_context() ->
    maps:fold(fun(Name, {Pid, _}, Stats) ->
        Stats#{[{name, Name}] => ergw_sx_node_reg:count_monitors(Pid)}
    end, #{}, ergw_sx_node_reg:available()).
