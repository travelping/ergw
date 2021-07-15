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
    [load, avps, avp_filters, http_api].

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

avps() ->
    [{doc, "Test the AVP filter conversion"}].
avps(Config)  ->
    DataDir  = ?config(data_dir, Config),

    Cfg = read_json(DataDir, "avps.json"),
    ct:pal("Cfg: ~p", [Cfg]),
    ?match(#{aaa :=
		 #{handlers :=
		       #{ergw_aaa_static :=
			     #{answers :=
				   #{<<"AVP Test">> :=
					 #{avps :=
					       #{'Multiple-Services-Credit-Control' :=
						     [_]}}}}}}
	    }, Cfg),
    #{aaa :=
	  #{handlers :=
		#{ergw_aaa_static :=
		      #{answers :=
			    #{<<"AVP Test">> :=
				  #{avps :=
					#{'Multiple-Services-Credit-Control' := [MSCC]}}}}}}} = Cfg,
    ct:pal("MSCC: ~p~n", [MSCC]),
    ?match(
       #{'Rating-Group' := <<"1000">>,
	 avp1 := [{127,0,0,1}],
	 avp10 := [1.0],
	 avp2 := [{0,0,0,0,0,0,0,1}],
	 avp3 := [1],
	 avp4 := [1],
	 avp5 := [<<"1">>],
	 avp6 := [<<"1">>],
	 avp7 := [<<"1.00000000000000000000e+00">>],
	 avp8 := [1.0],
	 avp9 := [1.0]}, MSCC),
    ok.

avp_filters() ->
    [{doc, "Test the AVP filter conversion"}].
avp_filters(Config)  ->
    DataDir  = ?config(data_dir, Config),

    Cfg = read_json(DataDir, "avp_filters.json"),
    ?match(#{aaa := #{handlers := #{ergw_aaa_nasreq := #{avp_filter := [_|_]}}}}, Cfg),
    ct:pal("Cfg: ~p", [Cfg]),
    #{aaa := #{handlers := #{ergw_aaa_nasreq := #{avp_filter := Filters}}}} = Cfg,
    ct:pal("Filters: ~p", [lists:sort(Filters)]),
    ?match(
       [['Multiple-Services-Credit-Control',[#{'Rating-Group' := <<"1000">>}]],
	[avp1,avp2],
	[avp1,[#{avp2 := 1}]],
	[avp1,[#{avp2 := 1}]],
	[avp1,[#{avp2 := 1}]],
	[avp1,[#{avp2 := 1.0}]],
	[avp1,[#{avp2 := 1.0}]],
	[avp1,[#{avp2 := 1.0}]],
	[avp1,[#{avp2 := 1}],avp3],
	[avp1,[#{avp2 := {127,0,0,1}}]],
	[avp1,[#{avp2 := {0,0,0,0,0,0,0,1}}]],
	[avp1,[#{avp2 := <<"1">>}]],
	[avp1,[#{avp2 := <<"1">>}]],
	[avp1,[#{avp2 := <<"1.00000000000000000000e+00">>}]]],
       lists:sort(Filters)),
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

%% this function bypassed the schema validation and lets us try
%% config translation on incomplete configs
read_json(Dir, File) ->
    {ok, Bin} = file:read_file(filename:join(Dir, File)),
    Config = jsx:decode(Bin, [return_maps, {labels, binary}]),
    ergw_config:coerce_config(Config).

set(Keys, Value, Config) ->
    ergw_config:set(Keys, Value, Config).
