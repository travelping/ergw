%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(http_api_handler).

-export([init/2, content_types_provided/2,
         handle_request/2, allowed_methods/2,
         content_types_accepted/2]).

init(Req, Opts) ->
    {cowboy_rest, Req, Opts}.

allowed_methods(Req, State) ->
    {[<<"GET">>, <<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{<<"application/json">>, handle_request}], Req, State}.

content_types_accepted(Req, State) ->
    {[{<<"application/json">>, handle_request}], Req, State}.

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
    ResponseMap = maps:from_list(Response),
    Result = case maps:find(plmn_id, ResponseMap) of
        {ok, {Mcc, Mnc}} ->
            maps:update(plmn_id, [{mcc, Mcc}, {mnc, Mnc}], ResponseMap);
        _ ->
            ResponseMap
    end,
    {jsx:encode(Result), Req, State};

handle_request(<<"GET">>, <<"/api/v1/status/accept-new">>, Req, State) ->
    AcceptNew = ergw:system_info(accept_new),
    Response = jsx:encode(#{acceptNewRequest => AcceptNew}),
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
            Response = jsx:encode(#{acceptNewRequest => Res}),
            Req2 = cowboy_req:set_resp_body(Response, Req),
            {true, Req2, State}
    end;

handle_request(_, _, Req, State) ->
    {false, Req, State}.
