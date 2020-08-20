%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% Operation and Maintenance (OAM) support is provided for 
%% 'Idle-Timeout' at the moment.
-module(ergw_oam_handler).

-export([init/2,
	 allowed_methods/2,
	 api_v1alpha_routes/0,
	 malformed_request/2,
	 content_types_provided/2,
	 content_types_accepted/2,
	 to_json/2]).

-ifdef(TEST). % Defined by 'rebar3 ct'
-export([
	api_v1alpha_status/0,
	api_v1alpha_update/0,
	get_apn_par/1
]).
-endif.

-include("include/ergw.hrl").

-define( API_V1ALPHA_STATUS, <<"/oam/management/api/v1alpha/status">> ).
-define( API_V1ALPHA_UPDATE, <<"/oam/management/api/v1alpha/update">> ).


api_v1alpha_routes() ->
	Status = {api_v1alpha_status(), ?MODULE, []},
	Update = {api_v1alpha_update(), ?MODULE, []},
	[Status, Update].

init(Req0, State) ->
    case cowboy_req:version(Req0) of
	'HTTP/2' ->
	    {cowboy_rest, Req0, State};
	_ ->
	    ProblemDetails =
		#{title  => <<"HTTP/2 is mandatory.">>,
		  status => 400,
		  cause  => <<"UNSUPPORTED_HTTP_VERSION">>
		 },
	    Req = problem(400, ProblemDetails, Req0),
	    {ok, Req, done}
    end.

% Post and Put will peform the same action
allowed_methods(Req, State) ->
    %% GET, POST and PUT methods are suppported
    {[<<"GET">>, <<"POST">>, <<"PUT">>], Req, State}.

% should we fetch body for post and store in state for malform checks
malformed_request(Req0, State) ->
    case cowboy_req:method(Req0) of
	<<"GET">> ->
	    check_malformed_request_status(Req0);
	_ ->
	    {false, Req0, State}
    end.

content_types_provided(Req, State) ->
    {[{<<"application/json">>, to_json}], Req, State}.

content_types_accepted(Req, State) ->
    {[{'*', to_json}], Req, State}.

%% Sample Req0 for Method = "GET": "?ergwPars=Idle-Timeout"
to_json(Req0, State0) ->
    Path = cowboy_req:path(Req0),
    Method = cowboy_req:method(Req0),
    handle_json_request(Method, Path, Req0, State0).
	

%%%===================================================================
%%% Internal functions
%%%===================================================================

api_v1alpha_status() -> binary:bin_to_list( ?API_V1ALPHA_STATUS ).
api_v1alpha_update() -> binary:bin_to_list( ?API_V1ALPHA_UPDATE ).


problem(Code, Details, Req) ->
    cowboy_req:reply(
	  Code, #{<<"content-type">> => "application/problem+json"}, jsx:encode(Details), Req).

check_malformed_request_status(Req0) ->
	try Match = [{'ergwPars', [fun qs_idleT/2]}],
		  Q = cowboy_req:match_qs(Match, Req0),
		  {false, Req0, Q}
	catch
		exit:{request_error, {match_qs, Error}, Title} ->
			Param =
		maps:fold(
		  fun(Field, {Fun, Code, V}, Acc) ->
			  [#{param => Field,
			     reason => iolist_to_binary(Fun(format_error, {Code, V}))} | Acc]
		  end, [], Error),
	    ErrorDetails =
		    #{title  => Title,
		      status => 400,
		      cause  => <<"INVALID_QUERY_PARAM">>,
		      invalidParams => Param
		     },
	    ErrorReq = problem(400, ErrorDetails, Req0),
	    {stop, ErrorReq, done}		
	end.


%% The get HTTP request will get the apn names and their 'Idle-Timeout' values
%% JSON Response body (sample): "{\"Idle-Timeout\":{\"apn1\":\"288000\",\"apn2\":\"288000\"}}"
handle_json_request(<<"GET">>, ?API_V1ALPHA_STATUS, Req, _State0) ->
	Qs = cowboy_req:qs(Req),
	Qs_str = binary_to_list(Qs),
	["ergwPars", ParStr] = string:split(Qs_str, "="),
	Par = list_to_atom(ParStr),
	Map = get_apn_par(Par),
	Response = jsx:encode(#{Par => Map}),
	{Response, Req, done};

%% The post HTTP request will set the 'Idle-Timeout' values for all APN
%% JSON Request body (sample): "{\"ergwPars\":{\"Idle-Timeout\":100000}}"
%% JSON Response body (sample): "{\"Idle-Timeout\":{\"apn1\":\"100000\",\"apn2\":\"100000\"}}"
handle_json_request(<<"POST">>, ?API_V1ALPHA_UPDATE, Req, State) ->
	update(Req, State);

%% The Req qs for the put command (update) command is as for the post command
handle_json_request(<<"PUT">>, ?API_V1ALPHA_UPDATE, Req, State) ->
	update(Req, State).

update(Req0, State) ->
	{ok, Data0, Req1} = cowboy_req:read_body(Req0),
	Data = jsx:decode(Data0, [return_maps]),
	ParsVal = set_pars(Data),
	Response = jsx:encode(#{'Idle-Timeout' => ParsVal}),
	Req2 = cowboy_req:set_resp_body(Response, Req1),
	{true, Req2, State}.

get_apn_par('Idle-Timeout') ->
	{ok, APNs0} = application:get_env(ergw, apns),	
	APNs = maps:keys(APNs0),
    get_timeouts(APNs, APNs0, #{}).

get_timeouts([], _APNs, Map) ->
    Map;
get_timeouts([APN | Rest], APNs, Map0) ->
	#{'Idle-Timeout' := IdleTimeout} = maps:get(APN, APNs),
	APNBin = list_to_binary(APN),
	ITBin = list_to_binary(integer_to_list(IdleTimeout)),
	Map = maps:put(APNBin, ITBin, Map0),
	get_timeouts(Rest, APNs, Map).
	
set_pars(#{<<"ergwPars">> := Pars}) ->
	set_pars_1(Pars).
	
set_pars_1(#{<<"Idle-Timeout">> := Value}) ->
	Key = list_to_atom(binary_to_list(<<"Idle-Timeout">>)),
	{ok, APNs0} = application:get_env(ergw, apns),
	Upd = fun(_APN, Val_map) -> maps:put(Key, Value, Val_map) end,
	APNs = maps:map(Upd, APNs0),
	ok = application:set_env(ergw, apns, APNs),
	get_apn_par('Idle-Timeout').

qs_idleT(_, <<"Idle-Timeout">> = Val) ->
	{ok, binary_to_list(Val)};
qs_idleT(format_error, {einval, V}) ->
	io_lib:format("The value ~p is for 'Idle-timeout  is invalid.", [V]);
qs_idleT(_,_) ->
	{error, einval}.
