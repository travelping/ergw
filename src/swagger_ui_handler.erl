%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(swagger_ui_handler).

-export([init/2]).

init(Req, State) ->
    Req2 = cowboy_req:reply(302,  #{<<"Location">> => <<"/api/v1/spec/ui/index.html">>}, Req),
    {ok, Req2, State}.
