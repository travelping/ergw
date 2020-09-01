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


allowed_methods( Request, State ) -> {[<<"GET">>, <<"HEAD">>, <<"POST">>, <<"PATCH">>], Request, State}.

content_types_accepted( Request, State ) -> {[{'*', request_json}], Request, State}.

content_types_provided( Request, State ) -> {[{<<"application/json">>, response_json}], Request, State}.

init( #{version := 'HTTP/2'}=Request, Options ) -> {cowboy_rest, Request, Options};
init( Request, _Options ) ->
	R = ergw_lib:cowboy_request_problem_reply( Request, 400, <<"UNSUPPORTED_HTTP_VERSION">>, <<"HTTP/2 is mandatory.">> ),
	{ok, R, done}.

request_json( #{method := <<"PATCH">>}=Request0, {APN, _Resource} ) ->
	{New_config, Request} = body_json( Request0 ),
	Config = merge_config( APN, New_config ),
	Result = validate_config( APN, Config ),
	R = request_with_body( Result, Config, Request ),
	set_env( Result, APN, Config, R );
request_json( #{method := <<"POST">>}=Request0, {APN, _Resource} ) ->
	{Config, Request} = body_json( Request0 ),
	Result = validate_config( APN, Config ),
	set_env( Result, APN, Config, Request ) .

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


body_json( Request0 ) ->
	{ok, Body, Request} = cowboy_req:read_body( Request0 ),
	{jsx:decode( Body, [return_maps, {labels, existing_atom}] ), Request}.


%% Replace all old values with new ones.
%% Null is not an allowed value.
%% New values that are null means to remove old ones.
merge_config( APN, Config ) ->
	{ok, #{APN := Old_config}} = application:get_env( ergw, apns ),
	maps:fold( fun merge_config_remove_null/3, #{}, maps:merge(Old_config, Config) ).

merge_config_remove_null( _Key, null, Acc ) -> Acc;
merge_config_remove_null( Key, Value, Acc ) -> Acc#{Key => Value}.


request_with_body( ok, Config, Request ) -> cowboy_req:set_resp_body( jsx:encode(Config), Request );
request_with_body( {error, _Error}, _Config, Request ) -> Request.


resource( apn_names, APN_map ) -> {apn_names, apn_names( APN_map )};
resource( <<"$DEFAULT$">>, APN_map ) -> {'_', maps:get( '_', APN_map, #{} )};
resource( APN, APN_map ) ->
	APN_key = apn_split( APN ),
	{APN_key, maps:get( APN_key, APN_map, #{} )}.

%% APN names can be [] and return code 200.
resource_minimum_size( {apn_names, _APN_names} ) -> 1;
resource_minimum_size( {_APN, APN_map} ) -> maps:size( APN_map ).


set_env( ok, APN, Config, Request ) ->
	{ok, APNs} = application:get_env( ergw, apns ),
	application:set_env( ergw, apns, APNs#{APN => Config} ),
	{true, Request, done};
set_env( {error, Error}, _APN, _Config, Request ) ->
	R = ergw_lib:cowboy_request_problem_reply( Request, 400, <<"INVALID_MSG_PARAM">>, Error ),
	{false, R, done}.


validate_config( APN, Config ) ->
	try
		ergw_config:validate_apns( {APN, Config} ),
		ok
	catch _Class:_Term:Stack ->
		{error, binary:list_to_bin( io_lib:format("~p", [Stack]) )}
	end.
