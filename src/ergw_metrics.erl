%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% Metrics for Create Session (and the v1 equivalent Create PDP Context).

-module( ergw_metrics ).

-export( [create_all/0, pdp_context_create_request/0, pdp_context_create_response/1, session_create_request/0, session_create_response/1] ).


create_all() ->
	exometer:re_register( pdp_context_create_path(request), counter, [] ),
	[exometer:re_register( pdp_context_create_path(response, X), counter, [] ) || X <- response_causes()],
	exometer:re_register( session_create_path(request), counter, [] ),
	[exometer:re_register( session_create_path(response, X), counter, [] ) || X <- response_causes()],
	ok.

pdp_context_create_request() ->
	exometer:update( pdp_context_create_path(request), 1 ).

pdp_context_create_response( Cause ) ->
	update( lists:member(Cause, response_causes()), pdp_context_create_path(response, Cause) ).

session_create_request() ->
	exometer:update( session_create_path(request), 1 ).

session_create_response( Cause ) ->
	update( lists:member(Cause, response_causes()),session_create_path(response, Cause) ).

%%====================================================================
%% Internal functions
%%====================================================================

response_causes() -> [request_accepted, rejected, mandatory_ie_missing, system_failure, missing_or_unknown_apn].


pdp_context_create_path( request ) -> [pdp_context, create, request].

pdp_context_create_path( response, Cause ) -> [pdp_context, create, response, Cause].


session_create_path( request ) -> [session, create, request].

session_create_path( response, Cause ) -> [session, create, response, Cause].


update( true, Path ) -> exometer:update( Path, 1 );
update( false, Path ) -> exometer:update_or_create( Path, 1, counter, [] ).
