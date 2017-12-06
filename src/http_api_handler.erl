%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(http_api_handler).

-include("include/ergw.hrl").
-include_lib("stdlib/include/ms_transform.hrl").

-export([init/2, content_types_provided/2,
         handle_request_json/2, handle_request_text/2,
         allowed_methods/2, delete_resource/2,
         content_types_accepted/2]).

-define(FIELDS_MAPPING, [{accept_new, 'acceptNewRequests'},
			 {plmn_id, 'plmnId'}]).

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>, <<"DELETE">>], Req, State}.

content_types_provided(Req, State) ->
    {[{<<"application/json">>, handle_request_json},
      {{<<"text">>, <<"plain">>, '*'} , handle_request_text}
     ], Req, State}.

content_types_accepted(Req, State) ->
    {[{'*', handle_request_json}], Req, State}.

handle_request_json(Req, State) ->
    Path = cowboy_req:path(Req),
    Method = cowboy_req:method(Req),
    handle_request(Method, Path, json, Req, State).

handle_request_text(Req, State) ->
    Path = cowboy_req:path(Req),
    Method = cowboy_req:method(Req),
    handle_request(Method, Path, prometheus, Req, State).

handle_request(<<"GET">>, <<"/api/v1/version">>, json, Req, State) ->
    {ok, Vsn} = application:get_key(ergw, vsn),
    Response = jsx:encode(#{version => list_to_binary(Vsn)}),
    {Response, Req, State};

handle_request(<<"GET">>, <<"/api/v1/status">>, json, Req, State) ->
    Response = ergw:system_info(),
    MappedResponse = lists:map(fun({Key, Value}) ->
					  {_, K} = lists:keyfind(Key, 1, ?FIELDS_MAPPING),
					  {K, Value}
			       end, Response),
    ResponseMap = maps:from_list(MappedResponse),
    Result = case maps:find('plmnId', ResponseMap) of
        {ok, {Mcc, Mnc}} ->
            maps:update('plmnId', [{mcc, Mcc}, {mnc, Mnc}], ResponseMap);
        _ ->
            ResponseMap
    end,
    {jsx:encode(Result), Req, State};

handle_request(<<"GET">>, <<"/api/v1/status/accept-new">>, json, Req, State) ->
    AcceptNew = ergw:system_info(accept_new),
    Response = jsx:encode(#{acceptNewRequests => AcceptNew}),
    {Response, Req, State};

handle_request(<<"GET">>, <<"/metrics">>, Format, Req, State) ->
    Metrics = metrics([], Format),
    {Metrics, Req, State};

handle_request(<<"GET">>, <<"/metrics/", _/binary>>, Format, Req, State) ->
    Path = path_to_metric(cowboy_req:path_info(Req)),
    Metrics = metrics(Path, Format),
    {Metrics, Req, State};

handle_request(<<"POST">>, _, json, Req, State) ->
    Value = cowboy_req:binding(value, Req),
    Res = case Value of
              <<"true">> ->
                  true;
              <<"false">> ->
                  false;
              _ ->
                  wrong_binding
    end,
    case Res of
        wrong_binding ->
            {false, Req, State};
        _ ->
            ergw:system_info(accept_new, Res),
            Response = jsx:encode(#{acceptNewRequests => Res}),
            Req2 = cowboy_req:set_resp_body(Response, Req),
            {true, Req2, State}
    end;

handle_request(<<"GET">>, _, json, Req, State) ->
    case cowboy_req:binding(id, Req) of
        undefined ->
            SessionsPids = get_sessions(),
            Sessions = lists:map(fun (SessionState) ->
                                         build_session_info(SessionState)
                                 end, SessionsPids),
            {jsx:encode(#{<<"Sessions">> => Sessions, <<"TotalCount">> => length(Sessions)}), Req, State};
        Id ->
            BearerId = cowboy_req:binding(bearer_id, Req),
            case find_session(Id, BearerId) of
                {error, not_found} ->
                    Req2 = cowboy_req:set_resp_body(jsx:encode(#{<<"Session">> => []}), Req),
                    {ok, Req3} = cowboy_req:reply(404, Req2),
                    {false, Req3, State};
                Pid ->
                    {jsx:encode(#{<<"Session">> => build_session_info(Pid)}), Req, State}
            end
    end;

handle_request(_, _, Req, _, State) ->
    {false, Req, State}.

delete_resource(Req, State) ->
    Path = cowboy_req:path(Req),
    PathParts = binary:split(Path, <<"/">>, [global]),
    handle_delete(PathParts, Req, State).

handle_delete([<<>>,<<"api">>,<<"v1">>,<<"sessions">>, SessionIdentity | Rest], Req, State) ->
    BearerId = case Rest of
                   [] ->
                       undefined;
                   [Id | _] ->
                       try binary_to_integer(Id) of
                           Num -> Num
                           catch _:_ -> 5
                       end
               end,
    case find_session(SessionIdentity, BearerId) of
        {error, not_found} ->
            Req2 = cowboy_req:set_resp_body(jsx:encode(#{<<"Result">> => <<"Session not found">>}), Req),
            {ok, Req3} = cowboy_req:reply(404, Req2),
            {false, Req3, State};
        Pid ->
            Req2 = cowboy_req:set_resp_body(jsx:encode(#{<<"Result">> => <<"ok">>}), Req),
            gtp_context:delete_context(Pid),
            {true, Req2, State}
    end;
handle_delete(_, Req, State) ->
    {false, Req, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

path_to_metric(Path) ->
    lists:map(fun p2m/1, Path).

p2m(Bin) ->
    case inet:parse_address(binary_to_list(Bin)) of
	{ok, IP} ->
	    IP;
	_ ->
	    case (catch binary_to_existing_atom(Bin, utf8)) of
		A when is_atom(A) ->
		    A;
		_ ->
		    Bin
	    end
    end.

exo_get_value(Name, Fun, AccIn) ->
    case exometer:get_value(Name) of
	{ok, Value} ->
	    Fun(Value, AccIn);
	{error,not_found} ->
	    AccIn
    end.

exo_entry_to_map({Name, Type, enabled}, Metrics) ->
    exo_entry_to_map(Name, {Name, Type}, Metrics).

exo_entry_to_map([Path], {Name, Type}, Metrics) ->
    exo_get_value(Name, fun(V, Acc) ->
				Entry = maps:from_list(V),
				Acc#{ioize(Path) => Entry#{type => Type}}
			end, Metrics);
exo_entry_to_map([H|T], Metric, Metrics) ->
    Key = ioize(H),
    Entry = maps:get(Key, Metrics, #{}),
    Metrics#{Key => exo_entry_to_map(T, Metric, Entry)}.

exo_entry_to_list({Name, Type, enabled}, Metrics) ->
    exo_get_value(Name, fun(V, Acc) -> [{Name, Type, V}|Acc] end, Metrics).

metrics(Path, json) ->
    Entries = lists:foldl(fun exo_entry_to_map/2, #{}, exometer:find_entries(Path)),
    Metrics = lists:foldl(fun(M, A) -> maps:get(ioize(M), A) end, Entries, Path),
    jsx:encode(Metrics);
metrics(Path, prometheus) ->
    Metrics = lists:foldl(fun exo_entry_to_list/2, [], exometer:find_entries(Path)),
    prometheus_encode(Metrics).

prometheus_encode(Metrics) ->
    lists:foldl(fun prometheus_encode/2, [], Metrics).

prometheus_encode({Path, Type, DataPoints}, Acc) ->
    Name = make_metric_name(Path),
    Payload = [[<<"# TYPE ">>, Name, <<" ">>, map_type(Type), <<"\n">>] |
               [[Name, map_datapoint(DPName), <<" ">>, ioize(Value), <<"\n">>]
                || {DPName, Value} <- DataPoints, is_valid_datapoint(DPName)]],
    Payload1 = maybe_add_sum(Name, DataPoints, Type, Payload),
    [Payload1, <<"\n">> | Acc].

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
ioize(Something) ->
    iolist_to_binary(io_lib:format("~p", [Something])).

make_metric_name(Path) ->
    NameList = lists:join($_, lists:map(fun ioize/1, Path)),
    NameBin = iolist_to_binary(NameList),
    re:replace(NameBin, "-|\\.", "_", [global, {return,binary}]).

map_type(undefined)     -> <<"untyped">>;
map_type(counter)       -> <<"counter">>;
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

maybe_add_sum(Name, DataPoints, histogram, Payload) ->
    Mean = proplists:get_value(mean, DataPoints),
    N = proplists:get_value(n, DataPoints),
    [Payload | [Name, <<"_sum ">>, ioize(Mean * N), <<"\n">>]];
maybe_add_sum(_Name, _DataPoints, _Type, Payload) ->
    Payload.

get_sessions() ->
    F = ets:fun2ms(fun ({{_SockName, {Id, _, _}}, Pid})
                         when (Id == imsi) or (Id == imei) ->
                           Pid
                   end),
    ets:select(gtp_context_reg, F).

find_session(SessionIdentity, undefined) ->
    find_session(SessionIdentity, 5);
find_session(SessionIdentity, BearerId) ->
    F = ets:fun2ms(fun({{_, {Id, SessionId, BId}}, Pid})
                         when (Id == imsi) or (Id == imei),
                              SessionIdentity == SessionId,
                              BearerId == BId ->
                           Pid
                   end),
    case ets:select(gtp_context_reg, F, 1) of
        {[Pid], _} ->
            Pid;
        _ ->
            {error, not_found}
    end.

build_session_info(Session) ->
    SessionInfo = maps:get(context, gtp_context:info(Session)),
    ControlPort = SessionInfo#context.control_port,
    DataPort = SessionInfo#context.data_port,
    Version = SessionInfo#context.version,
    APN = SessionInfo#context.apn,
    #{<<"IMSI">> => SessionInfo#context.imsi,
      <<"IMEI">> => SessionInfo#context.imei,
      <<"MSISDN">> => SessionInfo#context.msisdn,
      <<"APN">> => APN,
      <<"LocalGTPEntity">> =>
          #{<<"GTP-C">> => #{<<"Version">> => Version,
                             <<"TEID">> => SessionInfo#context.local_control_tei,
                             <<"IP">> => format_ip(ControlPort#gtp_port.ip)},
            <<"GTP-U">> => #{<<"Version">> => Version,
                             <<"TEID">> => SessionInfo#context.local_data_tei,
                             <<"IP">> => format_ip(DataPort#gtp_port.ip)}},
      <<"RemoteGTPEntity">> =>
          #{<<"GTP-C">> => #{<<"Version">> => Version,
                             <<"TEID">> => SessionInfo#context.remote_control_tei,
                             <<"IP">> => format_ip(SessionInfo#context.remote_control_ip)},
            <<"GTP-U">> => #{<<"Version">> => Version,
                             <<"TEID">> => SessionInfo#context.remote_data_tei,
                             <<"IP">> => format_ip(SessionInfo#context.remote_data_ip)}},
      <<"StartTime">> => SessionInfo#context.start_time}.

format_ip(undefined) ->
    undefined;
format_ip(Ip) ->
    list_to_binary(inet_parse:ntoa(Ip)).
