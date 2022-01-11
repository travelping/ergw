%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(http_controller_handler).

-behavior(cowboy_rest).

-export([init/2, content_types_provided/2, handle_request_json/2,
         allowed_methods/2, delete_resource/2, content_types_accepted/2]).

-ignore_xref([handle_request_json/2]).

-include_lib("kernel/include/logger.hrl").

-define(CONTENT_TYPE_PROBLEM_JSON, #{<<"content-type">> => "application/problem+json"}).

init(Req0, State) ->
    case cowboy_req:version(Req0) of
        'HTTP/2' ->
            {cowboy_rest, Req0, State};
        _ ->
            Body = jsx:encode(#{
                title  => <<"HTTP/2 is mandatory.">>,
                status => 505,
                cause  => <<"UNSUPPORTED_HTTP_VERSION">>
            }),
            Req = cowboy_req:reply(505, ?CONTENT_TYPE_PROBLEM_JSON, Body, Req0),
            {ok, Req, done}
    end.

allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

content_types_provided(Req, State) ->
    {[{<<"application/json">>, handle_request_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{'*', handle_request_json}], Req, State}.

delete_resource(Req, State) ->
    Path = cowboy_req:path(Req),
    Method = cowboy_req:method(Req),
    handle_request(Method, Path, Req, State).

handle_request_json(Req, State) ->
    Path = cowboy_req:path(Req),
    Method = cowboy_req:method(Req),
    handle_request(Method, Path, Req, State).

%%%===================================================================
%%% Handler of request
%%%===================================================================

handle_request(<<"POST">>, <<"/api/v1/controller">>, Req0, State) ->
    {ok, Body, Req} = read_body(Req0),
    case validate_json_req(Body) of
        {ok, Response} ->
            reply(200, Req, jsx:encode(Response), State);
        {error, invalid_json} ->
            Response = rfc7807(<<"Invalid JSON">>, <<"INVALID_JSON">>, []),
            reply(400, Req, Response, State);
        {error, InvalidParams} ->
            Response = rfc7807(<<"Invalid JSON params">>, <<"INVALID_JSON_PARAM">>, InvalidParams),
            reply(400, Req, Response, State)
    end.

%%%===================================================================
%%% Helper functions
%%%===================================================================

validate_json_req(JsonBin) ->
    case json_to_map(JsonBin) of
        {ok, Map} ->
            apply_config(Map);
        Error ->
            Error
    end.

% Jesse errors: https://github.com/for-GET/jesse/blob/1.5.6/src/jesse_error.erl#L40
apply_config(Map) ->
    case catch ergw_config:reload_config(Map) of
        {ok, Config} ->
            _ = maps:fold(fun add_config_part/3, #{}, Config),
            % @TODO for response collect all keys of config what was successfully applied
            {ok, #{type => <<"success">>}};
        {error, [_|_] = Errors} = Reason ->
            ?LOG(warning, "~p", [Reason]),
            Params = lists:map(fun build_error_params/1, Errors),
            {error, Params};
        Error ->
            ?LOG(warning, "Unhandled error ~p~nfor config ~p", [Error, Map]),
            {error, []}
    end.

build_error_params({Type, Schema, Error, Data, Path}) ->
    #{
        type => atom_to_binary(Type),
        schema => Schema,
        error => atom_to_binary(Error),
        data => Data,
        path => Path
    }.

add_config_part(K, V, Acc) ->
    Result = ergw_config:ergw_core_init(K, #{K => V}),
    ?LOG(info, "The ~p added with result ~p", [K, Result]),
    Acc#{K => Result}.

json_to_map(JsonBin) ->
    case catch jsx:decode(JsonBin) of
        #{} = Map ->
            {ok, Map};
        _ ->
            {error, invalid_json}
    end.

read_body(Req) ->
    read_body(Req, <<>>).

read_body(Req0, Acc) ->
    case cowboy_req:read_body(Req0) of
        {ok, Data, Req} ->
            {ok, <<Acc/binary, Data/binary>>, Req};
        {more, Data, Req} ->
            read_body(Req, <<Acc/binary, Data/binary>>)
    end.

reply(StatusCode, Req0, Body, State) ->
    Req = case StatusCode of
        200 ->
            cowboy_req:reply(StatusCode, #{}, Body, Req0);
        400 ->
            cowboy_req:reply(StatusCode, ?CONTENT_TYPE_PROBLEM_JSON, Body, Req0)
    end,
    {stop, Req, State}.

%% https://datatracker.ietf.org/doc/html/rfc7807
rfc7807(Title, Cause, []) ->
    jsx:encode(#{
        title  => Title,
        status => 400,
        cause  => Cause
    });
rfc7807(Title, Cause, InvalidParams) ->
    jsx:encode(#{
        title  => Title,
        status => 400,
        cause  => Cause,
        'invalid-params' => InvalidParams
    }).
