%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module( ergw_oam_handler ).

-export( [init/2, allowed_methods/2, content_types_provided/2, request_json/2] ).


allowed_methods( Request, State ) -> {[<<"GET">>], Request, State}.

content_types_provided( Request, State ) -> {[{<<"application/json">>, request_json}], Request, State}.

init( #{version := 'HTTP/2'}=Request, Options ) -> {cowboy_rest, Request, Options};
init( Request, _Options ) ->
	R = ergw_lib:cowboy_request_problem_reply( Request, 400, <<"UNSUPPORTED_HTTP_VERSION">>, <<"HTTP/2 is mandatory.">> ),
	{ok, R, done}.

request_json( #{method := <<"GET">>}=Request, _State ) ->
	APNs = application:get_env( ergw, apns, #{} ),
	JSON = jsx:encode( apn_join(APNs) ),
	{JSON, Request, done}.

%%====================================================================
%% Internal functions
%%====================================================================

apn_join( APN_map ) -> [binary:list_to_bin(lists:join(<<".">>, X)) || X <- maps:keys(APN_map), X =/= '_'].