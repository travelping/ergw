%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_http_api).

%% API
-export([init/1, validate_options/1]).

-include_lib("kernel/include/logger.hrl").

init(undefined) ->
    ?LOG(debug, "HTTP API will not be started because of lack of configuration~n"),
    ok;
init(Opts) when is_map(Opts) ->
    ?LOG(debug, "HTTP API listener options: ~p", [Opts]),
    %% HTTP API options should be already validated in the ergw_config,
    %% so it should be safe to run with it
    start_http_listener(Opts).

start_http_listener(Opts) ->
    Dispatch = cowboy_router:compile(
		 [{'_',
		   [
		    %% Public API
		    {"/api/v1/version", http_api_handler, []},
		    {"/api/v1/status", http_api_handler, []},
		    {"/api/v1/status/accept-new", http_api_handler, []},
		    {"/api/v1/status/accept-new/:value", http_api_handler, []},
		    {"/api/v1/contexts/:count", http_api_handler, []},
		    {"/metrics/[:registry]", prometheus_cowboy2_handler, []},
		    %% 5G SBI APIs
		    {"/sbi/nbsf-management/v1/pcfBindings", sbi_nbsf_handler, []},
		    % Swagger
		    {"/api-docs", cowboy_swagger_redirect_handler, {priv_file, cowboy_swagger, "swagger/index.html"}},
		    {"/api-docs/swagger.json", cowboy_swagger_json_handler, #{}},
		    {"/api-docs/[...]", cowboy_static, {priv_dir, cowboy_swagger, "swagger", [{mimetypes, cow_mimetypes, all}]}}
		   ]
		 }]),
    ok = trails_store(Dispatch),
    SocketOpts = [get_inet(Opts) | maps:to_list(maps:with([port, ip, ipv6_v6only], Opts))],
    TransOpts0 = maps:with([num_acceptors], Opts),
    TransOpts = TransOpts0#{socket_opts => SocketOpts,
			    logger => logger},
    ProtoOpts =
	#{env =>
	      #{
		dispatch => Dispatch,
		logger => logger,
		metrics_callback => fun prometheus_cowboy2_instrumenter:observe/1,
		stream_handlers => [cowboy_metrics_h, cowboy_stream_h]
	       }},
    cowboy:start_clear(ergw_http_listener, TransOpts, ProtoOpts).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(Defaults, [{ip, {127, 0, 0, 1}},
		   {port, 8000},
		   {num_acceptors, 100}]).

validate_options(Values) ->
    ergw_config:validate_options(fun validate_option/1, Values, ?Defaults, map).

validate_option({port, Port} = Opt)
  when is_integer(Port), Port >= 0, Port =< 65535 ->
    Opt;
validate_option({acceptors_num, Acceptors})
  when is_integer(Acceptors) ->
    ?LOG(warning, "HTTP config option 'acceptors_num' is depreciated, "
	 "please use 'num_acceptors'."),
    {num_acceptors, Acceptors};
validate_option({num_acceptors, Acceptors} = Opt)
  when is_integer(Acceptors) ->
    Opt;
validate_option({ip, Value} = Opt)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Opt;
validate_option({ipv6_v6only, Value} = Opt) when is_boolean(Value) ->
    Opt;
validate_option(Opt) ->
    throw({error, {options, Opt}}).

get_inet(#{ip := {_, _, _, _}}) ->
    inet;
get_inet(#{ip := {_, _, _, _, _, _, _, _}}) ->
    inet6.

trails_store(Dispatch) ->
    try
        [{_, _, Modules}] = Dispatch,
        trails:store(trails:trails(collect_trails(Modules, [])))
    catch Class:Exception ->
        ?LOG(error, "Trails Call: [~p:~p/0] catched ~p:~p~n", [?MODULE, ?FUNCTION_NAME, Class, Exception])
    end.

collect_trails([], Acc) ->
    Acc;
collect_trails([{_, _, Module, _} | T], Acc) ->
    case erlang:function_exported(Module, trails, 0) of
        true ->
            collect_trails(T, [Module | Acc]);
        _ ->
            collect_trails(T, Acc)
    end.
