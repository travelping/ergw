%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(http_api_handler).

-export([init/2, content_types_provided/2,
         handle_request/2, allowed_methods/2,
         content_types_accepted/2]).

-define(FIELDS_MAPPING, [{accept_new, 'acceptNewRequests'},
			 {plmn_id, 'plmnId'}]).

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{<<"application/json">>, handle_request}], Req, State}.

content_types_accepted(Req, State) ->
    {[{'*', handle_request}], Req, State}.

handle_request(Req, State) ->
    Path = cowboy_req:path(Req),
    Method = cowboy_req:method(Req),
    handle_request(Method, Path, Req, State).

handle_request(<<"GET">>, <<"/api/v1/version">>, Req, State) ->
    {ok, Vsn} = application:get_key(ergw, vsn),
    Response = jsx:encode(#{version => list_to_binary(Vsn)}),
    {Response, Req, State};

handle_request(<<"GET">>, <<"/api/v1/status">>, Req, State) ->
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

handle_request(<<"GET">>, <<"/api/v1/status/accept-new">>, Req, State) ->
    AcceptNew = ergw:system_info(accept_new),
    Response = jsx:encode(#{acceptNewRequests => AcceptNew}),
    {Response, Req, State};

handle_request(<<"GET">>, <<"/api/v1/metrics">>, Req, State) ->
    Metrics = ergw_api:metrics([]),
    Response = jsx:encode(Metrics),
    {Response, Req, State};

handle_request(<<"GET">>, <<"/api/v1/metrics/", _/binary>>, Req, State) ->
    Path = path_to_metric(cowboy_req:path_info(Req)),
    Metrics = ergw_api:metrics(Path),
    Response = jsx:encode(Metrics),
    {Response, Req, State};

handle_request(<<"POST">>, _, Req, State) ->
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

handle_request(_, _, Req, State) ->
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
