%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(http_status_handler).

-behavior(cowboy_handler).

-export([init/2]).

init(Req0, Opts) ->
    Method = cowboy_req:method(Req0),
    Path = cowboy_req:path_info(Req0),
    Req = status(Method, Path, Req0),
    {ok, Req, Opts}.

status(<<"GET">>, [<<"ready">>], Req) ->
    Headers = #{<<"content-type">> => <<"text/plain; charset=utf-8">>},
    case (catch ergw_core:ready()) of
	true -> cowboy_req:reply(200, Headers, <<"yes">>, Req);
	_    -> cowboy_req:reply(503, Headers, <<"no">>, Req)
    end;
status(<<"GET">>, _, Req) ->
    %% Not found
    cowboy_req:reply(404, Req);
status(_, _, Req) ->
    %% Method not allowed.
    cowboy_req:reply(405, Req).
