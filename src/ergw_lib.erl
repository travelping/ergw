%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module( ergw_lib ).

-export( [cowboy_request_problem_reply/4] ).


cowboy_request_problem_reply( Request, Code, Cause, Title ) ->
	Details = #{cause  => Cause, status => Code, title  => Title},
	cowboy_req:reply( Code, #{<<"content-type">> => "application/problem+json"}, jsx:encode(Details), Request ).