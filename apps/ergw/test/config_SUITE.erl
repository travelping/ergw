%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(config_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

-define(match(Guard, Expr),
	((fun () ->
		  case (Expr) of
		      Guard -> ok;
		      V -> ct:pal("MISMATCH(~s:~b, ~s)~nExpected: ~p~nActual:   ~s~n",
				   [?FILE, ?LINE, ??Expr, ??Guard,
				    smc_test_lib:pretty_print(V)]),
			    error(badmatch)
		  end
	  end)())).

-define(bad(Fun), ?match({'EXIT', {badarg, _}}, (catch Fun))).
-define(ok(Fun), ?match(#{}, (catch Fun))).

%%%===================================================================
%%% API
%%%===================================================================

all() ->
    [load, http_api].

init_per_testcase(_Case, Config) ->
    smc_test_lib:clear_app_env(),
    Config.

end_per_testcase(_Case, _Config) ->
    smc_test_lib:clear_app_env(),
    ok.

load() ->
    [{doc, "Test the config load function"}].
load(Config)  ->
    DataDir  = ?config(data_dir, Config),

    application:load(ergw),

    load(DataDir, "ggsn", json),
    load(DataDir, "ggsn_proxy", json),
    load(DataDir, "pgw", json),
    load(DataDir, "pgw_proxy", json),
    load(DataDir, "saegw_s11", json),
    load(DataDir, "tdf", json),
    ok.

load(Dir, File, Type) ->
    FileName = filename:join(Dir, io_lib:format("~s.~s", [File, Type])),
    Cfg = #{file => FileName, type => Type},
    ct:pal("Cfg: ~p~n", [Cfg]),
    application:set_env(ergw, config, Cfg),

    Config = ergw_config:load(),
    ?match({ok, #{handlers := _}}, Config),
    ok.

http_api() ->
    [{doc, "Test HTTP API config"}].
http_api(_Config) ->
    API = [{enabled, false}],
    ValF = fun ergw_http_api:validate_options/1,

    ?ok(ValF(API)),
    ?ok(ValF(ValF(API))),

    ?bad(ValF([])),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

read_json(Dir, File) ->
    {ok, Bin} = file:read_file(filename:join(Dir, File)),
    Config = jsx:decode(Bin, [return_maps, {labels, binary}]),
    ergw_config:coerce_config(Config).

set(Keys, Value, Config) ->
    ergw_config:set(Keys, Value, Config).
