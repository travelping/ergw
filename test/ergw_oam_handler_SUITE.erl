%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module( ergw_oam_handler_SUITE ).

-export( [
	documentation/0,
	documentation/1,
	get_1/0,
	get_1/1,
	get_apn/0,
	get_apn/1,
	get_apn_default/0,
	get_apn_default/1,
	get_apn_not_exist/0,
	get_apn_not_exist/1,
	get_names_exist/0,
	get_names_exist/1,
	get_no_names/0,
	get_no_names/1
] ).

%% Common test callbacks
-export( [all/0, init_per_suite/1, end_per_suite/1] ).


all() -> [documentation, get_1, get_no_names, get_names_exist, get_apn, get_apn_not_exist, get_apn_default].

init_per_suite( Config ) ->
	inets:start(),
	{ok, _} = application:ensure_all_started( gun ),
	{ok, _} = application:ensure_all_started( cowboy ),
	Options = #{ip => {127,0,0,1}, port => 0},
	{ok, _Pid} = ergw_http_api:init( Options ),
	Port = erlang:integer_to_list( ranch:get_port(ergw_http_listener) ),
	API_root = "/oam/v1alpha1" ,
	API_URL = "http://localhost:" ++ Port ++ API_root ,
	Documentation_URL = "http://localhost:" ++ Port ++ "/api/v1/spec/ui" ,
	[{api_root, API_root}, {api_url, API_URL}, {documentation_url, Documentation_URL} | Config].

end_per_suite( _Config ) ->
	cowboy:stop_listener( ergw_http_listener ),
	application:stop( cowboy ),
	application:stop( gun ),
	inets:stop().

%% Test cases

%% Not testing ergw_oam_handler.erl, but where else to test Swagger UI?
documentation() -> [{doc, "OAM API documentation is available via Swagger UI"}].
documentation( Config ) ->
	URL = proplists:get_value( documentation_url, Config ),

	{ok, Result} = httpc:request( URL ),

	{{_, 200, _}, _, Body} = Result,
	"specs/oam.yaml" ++ _ = string:find( Body, "specs/oam.yaml" ).

get_1() -> [{doc, "HTTP/1 GET OAM API fail"}].
get_1( Config ) ->
	URL = proplists:get_value( api_url, Config ),

	{ok, Result} = httpc:request( URL ++ "/apns"  ),

	{{_, 400, _}, _, _Body} = Result.

get_apn() -> [{doc, "HTTP/2 GET OAM API, specific APN"}].
get_apn( Config ) ->
	APN1 = [<<"an">>, <<"apn">>],
	APN1_values = #{'Idle-Timeout' => 28800000},
	APN2 = [<<"another">>, <<"apn">>],
	application:set_env( ergw, apns, #{APN1 => APN1_values, APN2 => value2} ),
	URL = proplists:get_value( api_root, Config ),
	Gun = ergw_test_lib:gun_open( inet ),

	{200, APN_values} = ergw_test_lib:gun_request( Gun, get, URL ++ "/apns/an.apn", empty  ),

	gun:close( Gun ),
	APN1_values = APN_values.

get_apn_default() -> [{doc, "HTTP/2 GET OAM API, default APN name"}].
get_apn_default( Config ) ->
	Default_value = #{'Idle-Timeout' => 200000},
	application:set_env( ergw, apns, #{'_' => Default_value} ),
	URL = proplists:get_value( api_root, Config ),
	Gun = ergw_test_lib:gun_open( inet ),

	{200, APN_values} = ergw_test_lib:gun_request( Gun, get, URL ++ "/apns/$DEFAULT$", empty  ),

	gun:close( Gun ),
	Default_value = APN_values.

get_apn_not_exist() -> [{doc, "HTTP/2 GET OAM API, specific APN that does not exist"}].
get_apn_not_exist( Config ) ->
	application:unset_env( ergw, apns ),
	URL = proplists:get_value( api_root, Config ),
	Gun = ergw_test_lib:gun_open( inet ),

	{404, _} = ergw_test_lib:gun_request( Gun, get, URL ++ "/apns/an.apn", empty  ),

	gun:close( Gun ).

get_names_exist() -> [{doc, "HTTP/2 GET OAM API when APN names exist"}].
get_names_exist( Config ) ->
	APN1 = [<<"an">>, <<"apn">>],
	APN2 = [<<"another">>, <<"apn">>],
	application:set_env( ergw, apns, #{APN1 => value1, APN2 => value2, '_' => default} ),
	URL = proplists:get_value( api_root, Config ),
	Gun = ergw_test_lib:gun_open( inet ),

	{200, APNs} = ergw_test_lib:gun_request( Gun, get, URL ++ "/apns", empty  ),

	gun:close( Gun ),
	[<<"$DEFAULT$">>, <<"an.apn">>, <<"another.apn">>] = lists:sort( APNs ).

get_no_names() -> [{doc, "HTTP/2 GET OAM API when no APN names"}].
get_no_names( Config ) ->
	application:unset_env( ergw, apns ),
	URL = proplists:get_value( api_root, Config ),
	Gun = ergw_test_lib:gun_open( inet ),

	{200, Body} = ergw_test_lib:gun_request( Gun, get, URL ++ "/apns", empty  ),

	gun:close( Gun ),
	[] = Body.

%%====================================================================
%% Internal functions
%%====================================================================
