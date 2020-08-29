%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module( ergw_oam_handler_SUITE ).

-export( [documentation/0, documentation/1] ).

%% Common test callbacks
-export( [all/0, init_per_suite/1, end_per_suite/1] ).


all() -> [documentation].

init_per_suite( Config ) ->
	inets:start(),
	{ok, _} = application:ensure_all_started( cowboy ),
	Options = #{ip => {127,0,0,1}, port => 0},
	{ok, _Pid} = ergw_http_api:init( Options ),
	Port = ranch:get_port( ergw_http_listener ),
	[{port, Port} | Config].

end_per_suite( _Config ) ->
	cowboy:stop_listener( ergw_http_listener ),
	application:stop( cowboy ),
	inets:stop().

%% Test cases

%% Not testing ergw_oam_handler.erl, but where else?
documentation() -> [{doc, "Test that OAM API documentation is available via Swagger UI"}].
documentation( Config ) ->
	Port = erlang:integer_to_list( proplists:get_value(port, Config) ),
	{ok, Result} = httpc:request( "http://127.0.0.1:" ++ Port ++ "/api/v1/spec/ui"  ),

	{{_, 200, _}, _, Body} = Result,
	"specs/oam.yaml" ++ _ = string:find( Body, "specs/oam.yaml" ).