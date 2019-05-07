%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_http_api).

%% API
-export([init/1, validate_options/1]).

init(undefined) ->
    lager:debug("HTTP API will not be started because of lack of configuration~n"),
    ok;
init(Opts) when is_map(Opts) ->
    lager:debug("HTTP API listener options: ~p", [Opts]),
    %% HTTP API options should be already validated in the ergw_config,
    %% so it should be safe to run with it
    start_http_listener(Opts).

start_http_listener(#{ip := IP, port := Port, acceptors_num := AcceptorsNum}) ->
    INet = get_inet(IP),
    Dispatch = cowboy_router:compile(
		 [{'_',
		   [
		    %% Public API
		    {"/api/v1/version", http_api_handler, []},
		    {"/api/v1/status", http_api_handler, []},
		    {"/api/v1/status/accept-new", http_api_handler, []},
		    {"/api/v1/status/accept-new/:value", http_api_handler, []},
		    {"/api/v1/contexts/:count", http_api_handler, []},
		    {"/metrics", http_api_handler, []},
		    {"/metrics/[...]", http_api_handler, []},
		    %% serves static files for swagger UI
		    {"/api/v1/spec/ui", swagger_ui_handler, []},
		    {"/api/v1/spec/ui/[...]", cowboy_static, {priv_dir, ergw, "static"}}]}
		 ]),
    TransOpts = #{socket_opts => [{port, Port}, {ip, IP}, INet],
		  num_acceptors => AcceptorsNum},
    ProtoOpts = #{env => #{dispatch => Dispatch}},
    cowboy:start_clear(ergw_http_listener, TransOpts, ProtoOpts).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(Defaults, [{ip, {127, 0, 0, 1}},
		   {port, 8000},
		   {acceptors_num, 100}]).

validate_options(Values) ->
    ergw_config:validate_options(fun validate_option/2, Values, ?Defaults, map).

validate_option(port, Port)
  when is_integer(Port) ->
    Port;
validate_option(acceptors_num, Acceptors)
  when is_integer(Acceptors) ->
    Acceptors;
validate_option(ip, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Value;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

get_inet({_, _, _, _}) ->
    inet;
get_inet({_, _, _, _, _, _, _, _}) ->
    inet6.
