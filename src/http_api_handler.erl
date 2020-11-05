%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(http_api_handler).

-behavior(cowboy_rest).

-export([init/2, content_types_provided/2,
         handle_request_json/2, handle_request_text/2,
         allowed_methods/2, delete_resource/2,
         content_types_accepted/2]).

%% cowboy handler methods, used in routes
-ignore_xref([handle_request_json/2, handle_request_text/2]).

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

delete_resource(Req, State) ->
    Path = cowboy_req:path(Req),
    Method = cowboy_req:method(Req),
    handle_request(Method, Path, json, Req, State).

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

handle_request(<<"DELETE">>, <<"/api/v1/contexts/", _/binary>>, json, Req, State) ->
    Value = cowboy_req:binding(count, Req),
    case catch binary_to_integer(Value) of
	Count when is_integer(Count), Count > 0 ->
	    ok = ergw_api:delete_contexts(Count),
	    Contexts = ergw_api:contexts(all),

	    Response = jsx:encode(#{contexts => erlang:length(Contexts)}),
	    Req2 = cowboy_req:set_resp_body(Response, Req),
	    {true, Req2, State};
	_ ->
	    Response = jsx:encode(#{contexts => 0}),
	    Req3 = cowboy_req:set_resp_body(Response, Req),
	    {true, Req3, State}
    end;
handle_request(_, _, Req, _, State) ->
    {false, Req, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
