%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(smc_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").

-define(match(Guard, Expr),
	((fun () ->
		  case (Expr) of
		      Guard -> ok;
		      V -> ct:pal("MISMATCH(~s:~b, ~s)~nExpected: ~p~nActual:   ~p~n",
				  [?FILE, ?LINE, ??Expr, ??Guard, V]),
			   error(badmatch)
		  end
	  end)())).

%%%===================================================================
%%% API
%%%===================================================================

all() ->
    [pgw, pgw_proxy, ggsn, ggsn_proxy, saegw_s11, tdf].

init_per_suite(Config) ->
    logger:set_primary_config(level, debug),
    Config.

end_per_suite(_Config) ->
    ok.

init_per_testcase(_Case, Config) ->
    clear_app_env(),
    Config.

end_per_testcase(_Case, _Config) ->
    [application:stop(App) || App <- [ergw_core, ergw_aaa, ergw_cluster, ergw]],
    ok.

pgw() ->
    [{doc, "Test the PGW function"}].
pgw(Config)  ->
    Dir  = ?config(data_dir, Config),
    application:load(ergw),
    CfgSet = #{type => json, file => filename:join(Dir, "pgw.json")},
    application:set_env(ergw, config, CfgSet),
    {ok, Started} = application:ensure_all_started(ergw),
    ct:pal("Started: ~p", [Started]),

    ergw:wait_till_running(),

    #{rules := Rules} = ergw_charging:rulebase(),
    ct:pal("Rules: ~p", [Rules]),
    ?match(
       #{<<"OnlineRedirection">> :=
	     #{'Flow-Information' :=
		   [#{'Flow-Description' :=
			  [<<"permit out ip from any to assigned">>],
		      'Flow-Direction' := [1]},
		    #{'Flow-Description' :=
			  [<<"permit out ip from any to assigned">>],
		      'Flow-Direction' := [2]}],
	       'Metering-Method' := [2],
	       'Offline' := [0],
	       'Online' := [0],
	       'Precedence' := [500],
	       'Rating-Group' := [3224],
	       'Redirect-Information' :=
		   [#{'Redirect-Address-Type' := [2],
		      'Redirect-Server-Address' :=
			  [<<"https://portal">>],
		      'Redirect-Support' := [1]}]}
	}, Rules),
    ok.

pgw_proxy() ->
    [{doc, "Test the PGW proxy function"}].
pgw_proxy(Config)  ->
    Dir  = ?config(data_dir, Config),
    application:load(ergw),
    CfgSet = #{type => json, file => filename:join(Dir, "pgw_proxy.json")},
    application:set_env(ergw, config, CfgSet),
    application:ensure_all_started(ergw),

    ergw:wait_till_running(),
    ok.

ggsn() ->
    [{doc, "Test the GGSN function"}].
ggsn(Config)  ->
    Dir  = ?config(data_dir, Config),
    application:load(ergw),
    CfgSet = #{type => json, file => filename:join(Dir, "ggsn.json")},
    application:set_env(ergw, config, CfgSet),
    application:ensure_all_started(ergw),

    ergw:wait_till_running(),
    ok.

ggsn_proxy() ->
    [{doc, "Test the GGSN proxy function"}].
ggsn_proxy(Config)  ->
    Dir  = ?config(data_dir, Config),
    application:load(ergw),
    CfgSet = #{type => json, file => filename:join(Dir, "ggsn_proxy.json")},
    application:set_env(ergw, config, CfgSet),
    application:ensure_all_started(ergw),

    ergw:wait_till_running(),
    ok.

saegw_s11() ->
    [{doc, "Test the SAE-GW function"}].
saegw_s11(Config)  ->
    Dir  = ?config(data_dir, Config),
    application:load(ergw),
    CfgSet = #{type => json, file => filename:join(Dir, "saegw_s11.json")},
    application:set_env(ergw, config, CfgSet),
    application:ensure_all_started(ergw),

    ergw:wait_till_running(),
    ok.

tdf() ->
    [{doc, "Test the TDF function"}].
tdf(Config)  ->
    Dir  = ?config(data_dir, Config),
    application:load(ergw),
    CfgSet = #{type => json, file => filename:join(Dir, "tdf.json")},
    application:set_env(ergw, config, CfgSet),
    application:ensure_all_started(ergw),

    ergw:wait_till_running(),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

clear_app_env() ->
    [[application:unset_env(App, Par) ||
	 {Par, _} <- application:get_all_env(App)] ||
	App <- [ergw_core, ergw_aaa, ergw_cluster]].
