%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(config_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

%%%===================================================================
%%% API
%%%===================================================================

all() ->
    [load].

init_per_testcase(_Case, Config) ->
    clear_app_env(),
    Config.

end_per_testcase(_Case, _Config) ->
    ok.

laod() ->
    [{doc, "Test the config load function"}].
load(Config)  ->
    DataDir  = ?config(data_dir, Config),

    application:load(ergw),

    load(DataDir, "ggsn.json"),
    load(DataDir, "ggsn_proxy.json"),
    load(DataDir, "pgw.json"),
    load(DataDir, "pgw_proxy.json"),
    load(DataDir, "sae_s11.json"),
    load(DataDir, "tdf.json"),
    ok.

load(Dir, File) ->
    application:set_env(ergw, config, filename:join(Dir, File)),
    %% ?match({ok, #{handlers := _}}, ergw_config:load()).
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

clear_app_env() ->
    [[application:unset_env(App, Par) ||
	 {Par, _} <- application:get_all_env(App)] ||
	App <- [ergw_core, ergw_aaa, ergw_cluster]].
