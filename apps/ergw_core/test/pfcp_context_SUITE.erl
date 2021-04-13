%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pfcp_context_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("ergw_test_lib.hrl").

%%%===================================================================
%%% Common Test callbacks
%%%===================================================================

all() ->
    [localtime_BDST_before_BDST_midnight,
     localtime_BDST_before_UTC_midnight,
     localtime_BDST_after_midnight,
     localtime_BST_before_BST_midnight,
     localtime_BST_before_UTC_midnight,
     localtime_BST_after_midnight].

suite() ->
    [{timetrap, {seconds, 30}}].

init_per_suite(Config) ->
    application:ensure_all_started(zoneinfo),
    Config.

end_per_suite(_Config) ->
    application:stop(zoneinfo),
    ok.

%%%===================================================================
%%% Test cases
%%%===================================================================

localtime_BDST_before_BDST_midnight() ->
    [{doc, "Check that local time to UTC conversion in Tariff Time calculation works"}].
localtime_BDST_before_BDST_midnight(_Config) ->
    %% 2021-10-30T22:58:17Z is 2021-10-30 23:58:17 BDST
    Now = {{2021, 10, 30}, {22, 58, 17}},
    Location = "Europe/London",

    URR = ergw_pfcp_context:apply_charging_tariff_time(
	    #{'Local-Tariff-Time' => {0, 0}, 'Location' => Location}, Now, #{}),
    ?match(#{monitoring_time := #monitoring_time{}}, URR),
    ct:pal("Time: ~p", [monitoring_time(URR)]),
    ?match({{2021, 10, 30}, {23, 0, 0}}, monitoring_time(URR)),
    ok.

localtime_BDST_before_UTC_midnight() ->
    [{doc, "Check that local time to UTC conversion in Tariff Time calculation works"}].
localtime_BDST_before_UTC_midnight(_Config) ->
    %% 2021-10-30T23:58:17Z is 2021-10-30 00:58:17 BDST,
    %% next tariff time is midnight next day in BST
    Now = {{2021, 10, 30}, {23, 58, 17}},
    Location = "Europe/London",

    URR = ergw_pfcp_context:apply_charging_tariff_time(
	    #{'Local-Tariff-Time' => {0, 0}, 'Location' => Location}, Now, #{}),
    ?match(#{monitoring_time := #monitoring_time{}}, URR),
    ct:pal("Time: ~p", [monitoring_time(URR)]),
    ?match({{2021, 11, 1}, {0, 0, 0}}, monitoring_time(URR)),
    ok.

localtime_BDST_after_midnight() ->
    [{doc, "Check that local time to UTC conversion in Tariff Time calculation works"}].
localtime_BDST_after_midnight(_Config) ->
    %% 2021-10-31T00:58:17Z is 2021-10-31 01:58:17 BDST
    %% next tariff time is midnight next day in BST
    Now = {{2021, 10, 31}, {0, 58, 17}},
    Location = "Europe/London",

    URR = ergw_pfcp_context:apply_charging_tariff_time(
	    #{'Local-Tariff-Time' => {0, 0}, 'Location' => Location}, Now, #{}),
    ?match(#{monitoring_time := #monitoring_time{}}, URR),
    ct:pal("Time: ~p", [monitoring_time(URR)]),
    ?match({{2021, 11, 01}, {0, 0, 0}}, monitoring_time(URR)),
    ok.

localtime_BST_before_BST_midnight() ->
    [{doc, "Check that local time to UTC conversion in Tariff Time calculation works"}].
localtime_BST_before_BST_midnight(_Config) ->
    %% 2021-03-27T22:58:17Z is 2021-03-27 22:58:17 BST
    Now = {{2021, 03, 27}, {22, 58, 17}},
    Location = "Europe/London",

    URR = ergw_pfcp_context:apply_charging_tariff_time(
	    #{'Local-Tariff-Time' => {0, 0}, 'Location' => Location}, Now, #{}),
    ?match(#{monitoring_time := #monitoring_time{}}, URR),
    ct:pal("Time: ~p", [monitoring_time(URR)]),
    ?match({{2021, 03, 28}, {0, 0, 0}}, monitoring_time(URR)),
    ok.

localtime_BST_before_UTC_midnight() ->
    [{doc, "Check that local time to UTC conversion in Tariff Time calculation works"}].
localtime_BST_before_UTC_midnight(_Config) ->
    %% 2021-03-27T23:58:17Z is 2021-03-27 23:58:17 BST
    Now = {{2021, 03, 27}, {23, 58, 17}},
    Location = "Europe/London",

    URR = ergw_pfcp_context:apply_charging_tariff_time(
	    #{'Local-Tariff-Time' => {0, 0}, 'Location' => Location}, Now, #{}),
    ?match(#{monitoring_time := #monitoring_time{}}, URR),
    ct:pal("Time: ~p", [monitoring_time(URR)]),
    ?match({{2021, 03, 28}, {0, 0, 0}}, monitoring_time(URR)),
    ok.

localtime_BST_after_midnight() ->
    [{doc, "Check that local time to UTC conversion in Tariff Time calculation works"}].
localtime_BST_after_midnight(_Config) ->
    %% 2021-03-28T00:58:17Z is 2021-03-28 00:58:17 BST
    %% next tariff time is midnight next day in BDST
    Now = {{2021, 03, 28}, {00, 58, 17}},
    Location = "Europe/London",

    URR = ergw_pfcp_context:apply_charging_tariff_time(
	    #{'Local-Tariff-Time' => {0, 0}, 'Location' => Location}, Now, #{}),
    ?match(#{monitoring_time := #monitoring_time{}}, URR),
    ct:pal("Time: ~p", [monitoring_time(URR)]),
    ?match({{2021, 03, 28}, {23, 0, 0}}, monitoring_time(URR)),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

monitoring_time(#{monitoring_time := #monitoring_time{time = SNTP}}) ->
    ergw_gsn_lib:sntp_time_to_datetime(SNTP);
monitoring_time(_) ->
    0.
