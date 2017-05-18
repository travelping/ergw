%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_http_api).

-export([init/0]).
-export([validate_options/2]).

-define(DEFAULT_PORT,	8000).
-define(DEFAULT_IP,     {127, 0, 0, 1}).
-define(ACCEPTORS_NUM,  100).

init() ->
    HttpConfig = application:get_env(ergw, http_api),
    case HttpConfig of
        undefined ->
            lager:debug("HTTP API will not be started because of lack of configuration~n"),
            ok;
        {ok, HttpOpts0} ->
            lager:debug("HTTP API listener options: ~p", [HttpOpts0]),
            % HTTP API options should be already validated in the ergw_config,
            % so it should be safe to run with it
            start_http_listener(HttpOpts0)
    end.

start_http_listener(HttpOpts) ->
    Port = get_config_option(HttpOpts, port, ?DEFAULT_PORT),
    Ip = get_config_option(HttpOpts, ip, ?DEFAULT_IP),
    Inet = get_inet(Ip),
    AcceptorsNum = get_config_option(HttpOpts, acceptors_num, ?ACCEPTORS_NUM),
    Dispatch = cowboy_router:compile([{'_',
                                       [{"/api/v1/version", http_api_handler, []},
                                        {"/api/v1/status", http_api_handler, []},
                                        {"/api/v1/status/accept-new", http_api_handler, []},
                                        {"/api/v1/status/accept-new/:value", http_api_handler, []}]
                                      }]),
    cowboy:start_clear(ergw_http_listener, AcceptorsNum, [{port, Port}, {ip, Ip}, Inet], #{
                                                           env => #{dispatch => Dispatch}
                                                          }).

get_config_option(List, Key, DefaultVal) ->
    case lists:keyfind(Key, 1, List) of
        false ->
            DefaultVal;
        {_, Value} ->
            Value
    end.

validate_options(port, Port) when is_integer(Port) ->
    Port;
validate_options(acceptors_num, Acceptors) when is_integer(Acceptors) ->
    Acceptors;
validate_options(ip, {_, _, _, _} = Ip) ->
    Ip;
validate_options(ip, {_, _, _, _, _, _, _, _} = Ip) ->
    Ip;
validate_options(OptName, OptValue) ->
    throw({error, {options, {OptName, OptValue}}}).

get_inet({_, _, _, _}) ->
    inet4;
get_inet({_, _, _, _, _, _, _, _}) ->
    inet6.
