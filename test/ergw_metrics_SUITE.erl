%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module( ergw_metrics_SUITE ).

%% Tests
-export( [create_all/1, pdp_context_create_request/1, pdp_context_create_response/1, session_create_request/1, session_create_response/1] ).

%% Callbacks
-export( [all/0, init_per_suite/1, end_per_suite/1] ).

all() -> [create_all, pdp_context_create_request, pdp_context_create_response, session_create_request, session_create_response].

init_per_suite( Config ) ->
	exometer:start(),
	ergw_metrics:create_all(), % Do before all tests, if random order.
	Config.

end_per_suite( _Config ) ->
	application:stop( exometer_core ).

%% Tests
create_all( _Config ) ->
	%% ergw_metrics:create_all/0 is done in init_per_suite/1
	Es = exometer:find_entries( "" ),
	1 = erlang:length( metric_find(session, request, Es) ),
	6 = erlang:length( metric_find(session, response, Es) ),
	1 = erlang:length( metric_find(pdp_context, request, Es) ),
	6 = erlang:length( metric_find(pdp_context, response, Es) ).

pdp_context_create_request( _Config ) ->
	{Before_request, Before_response_ok, Before_response_error} = three_values( pdp_context ),

	ergw_metrics:pdp_context_create_request(),

	{After_request, After_response_ok, After_response_error} = three_values( pdp_context ),
	1 = After_request - Before_request,
	0 = After_response_ok - Before_response_ok,
	0 = After_response_error - Before_response_error.

pdp_context_create_response( _Config ) ->
	{Before_request, Before_response_ok, Before_response_error} = three_values( pdp_context ),

	ergw_metrics:pdp_context_create_response( metric( exist ) ),
	ergw_metrics:pdp_context_create_response( metric( exist ) ),
	ergw_metrics:pdp_context_create_response( metric( does_not_exist ) ),

	{After_request, After_response_ok, After_response_error} = three_values( pdp_context ),
	0 = After_request - Before_request,
	2 = After_response_ok - Before_response_ok,
	1 = After_response_error - Before_response_error.

session_create_request( _Config ) ->
	{Before_request, Before_response_ok, Before_response_error} = three_values( session ),

	ergw_metrics:session_create_request(),

	{After_request, After_response_ok, After_response_error} = three_values( session ),
	1 = After_request - Before_request,
	0 = After_response_ok - Before_response_ok,
	0 = After_response_error - Before_response_error.

session_create_response( _Config ) ->
	{Before_request, Before_response_ok, Before_response_error} = three_values( session ),

	ergw_metrics:session_create_response( metric( exist ) ),
	ergw_metrics:session_create_response( metric( exist ) ),
	ergw_metrics:session_create_response( metric( does_not_exist ) ),

	{After_request, After_response_ok, After_response_error} = three_values( session ),
	0 = After_request - Before_request,
	2 = After_response_ok - Before_response_ok,
	1 = After_response_error - Before_response_error.

%%====================================================================
%% Internal functions
%%====================================================================


get_value( {error, not_found} ) -> 0;
get_value( {ok, Vs} ) -> proplists:get_value( value, Vs );
get_value( Path ) -> get_value( exometer:get_value(Path) ).


metric( exist ) -> request_accepted;
metric( _ ) -> asdqwe.


metric_find( Command, Action, Metrics ) ->
	[X || {[C, create, A |_], counter, enabled}=X <- Metrics, C =:= Command, A =:= Action].
	
path( Command, Action ) -> [Command, create, Action].

path( Command, Action, Result ) -> [Command, create, Action, Result].


three_values( Command ) ->
	Request = get_value( path(Command, request) ),
	Response_ok = get_value( path(Command, response, metric( exist )) ),
	Response_error = get_value( path(Command, response, metric( does_not_exist )) ),
	{Request, Response_ok, Response_error}.
