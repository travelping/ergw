%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module( ergw_oam_handler ).

-export( [init/2, allowed_methods/2, content_types_provided/2, request_json/2, resource_exists/2] ).


allowed_methods( Request, State ) -> {[<<"GET">>, <<"HEAD">>], Request, State}.

content_types_provided( Request, State ) -> {[{<<"application/json">>, request_json}], Request, State}.

init( #{version := 'HTTP/2'}=Request, Options ) -> {cowboy_rest, Request, Options};
init( Request, _Options ) ->
	R = ergw_lib:cowboy_request_problem_reply( Request, 400, <<"UNSUPPORTED_HTTP_VERSION">>, <<"HTTP/2 is mandatory.">> ),
	{ok, R, done}.

request_json( Request, Resource ) ->
	{jsx:encode(Resource), Request, done}.

resource_exists( Request, [] ) ->
	APNs = application:get_env( ergw, apns, #{} ),
	R = resource( cowboy_req:binding(name, Request, apn_names), APNs ),
	{resource_minimum_size(R) =/= 0, Request, R}.

%%====================================================================
%% Internal functions
%%====================================================================

apn_names( APN_map ) -> [apn_names_default(X) || X <- maps:keys(APN_map)].

apn_names_default( '_' ) -> <<"$DEFAULT$">>;
apn_names_default( APN ) -> binary:list_to_bin( lists:join(<<".">>, APN) ).

apn_split( APN_binary ) -> binary:split( APN_binary, <<".">>, [global] ).


resource( apn_names, APN_map ) -> apn_names( APN_map );
resource( <<"$DEFAULT$">>, APN_map ) -> maps:get( '_', APN_map, #{} );
resource( APN, APN_map ) -> maps:get( apn_split(APN), APN_map, #{} ).

%% APN names can be [] and return code 200.
resource_minimum_size( APN_map ) when is_map(APN_map) -> maps:size( APN_map );
resource_minimum_size( APN_names ) when is_list(APN_names) -> 1.
