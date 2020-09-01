%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module( ergw_oam_handler ).

-export( [
	allowed_methods/2,
	content_types_accepted/2,
	content_types_provided/2,
	init/2,
	request_json/2,
	response_json/2,
	resource_exists/2
] ).


allowed_methods( Request, State ) -> {[<<"GET">>, <<"HEAD">>, <<"POST">>], Request, State}.

content_types_accepted( Request, State ) -> {[{'*', request_json}], Request, State}.

content_types_provided( Request, State ) -> {[{<<"application/json">>, response_json}], Request, State}.

init( #{version := 'HTTP/2'}=Request, Options ) -> {cowboy_rest, Request, Options};
init( Request, _Options ) ->
	R = ergw_lib:cowboy_request_problem_reply( Request, 400, <<"UNSUPPORTED_HTTP_VERSION">>, <<"HTTP/2 is mandatory.">> ),
	{ok, R, done}.

request_json( #{method := <<"POST">>}=Request0, {APN, _Resource} ) ->
	{ok, Body, Request} = cowboy_req:read_body( Request0 ),
	Config = jsx:decode( Body, [return_maps, {labels, existing_atom}] ),
	try
		ergw_config:validate_apns( {APN, Config} ),
		{ok, APNs} = application:get_env( ergw, apns ),
		application:set_env( ergw, apns, APNs#{APN => Config} ),
		{true, Request, done}
	catch _Class:_Term:Stack ->
		B = binary:list_to_bin( io_lib:format("~p", [Stack]) ),
		R = ergw_lib:cowboy_request_problem_reply( Request, 400, <<"INVALID_MSG_PARAM">>, B ),
		{false, R, done}
	end.

response_json( Request, {_APN, Resource} ) ->
	{jsx:encode(Resource), Request, done}.

resource_exists( Request, [] ) ->
	APNs = application:get_env( ergw, apns, #{} ),
	APN = cowboy_req:binding( name, Request, apn_names ),
	R = resource( APN, APNs ),
	{resource_minimum_size(R) =/= 0, Request, R}.

%%====================================================================
%% Internal functions
%%====================================================================

apn_names( APN_map ) -> [apn_names_default(X) || X <- maps:keys(APN_map)].

apn_names_default( '_' ) -> <<"$DEFAULT$">>;
apn_names_default( APN ) -> binary:list_to_bin( lists:join(<<".">>, APN) ).

apn_split( APN_binary ) -> binary:split( APN_binary, <<".">>, [global] ).


resource( apn_names, APN_map ) -> {apn_names, apn_names( APN_map )};
resource( <<"$DEFAULT$">>, APN_map ) -> {'_', maps:get( '_', APN_map, #{} )};
resource( APN, APN_map ) ->
	APN_key = apn_split( APN ),
	{APN_key, maps:get( APN_key, APN_map, #{} )}.

%% APN names can be [] and return code 200.
resource_minimum_size( {apn_names, _APN_names} ) -> 1;
resource_minimum_size( {_APN, APN_map} ) -> maps:size( APN_map ).
