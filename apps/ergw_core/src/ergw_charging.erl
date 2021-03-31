%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_charging).

-export([validate_profile/2, validate_rule/2, validate_rulebase/2,
	 add_profile/2, add_rule/2, add_rulebase/2,
	 reporting_triggers/0,
	 is_charging_event/2,
	 is_enabled/1,
	 rulebase/0]).

-include("ergw_core_config.hrl").

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(DefaultProfile, [{online, []}, {offline, []}]).
-define(DefaultRulebase, []).
-define(DefaultRuleDef, []).
-define(DefaultOnlineChargingOpts, []).
-define(DefaultOfflineChargingOpts, [{enable, true}, {triggers, []}]).
-define(DefaultOfflineChargingTriggers,
	[{'cgi-sai-change',		'container'},
	 {'ecgi-change',		'container'},
	 {'max-cond-change',		'cdr'},
	 {'ms-time-zone-change',	'cdr'},
	 {'qos-change',			'container'},
	 {'rai-change',			'container'},
	 {'rat-change',			'cdr'},
	 {'sgsn-sgw-change',		'cdr'},
	 {'sgsn-sgw-plmn-id-change',	'cdr'},
	 {'tai-change',			'container'},
	 {'tariff-switch-change',	'container'},
	 {'user-location-info-change',	'container'}]).

validate_profile(_Name, Opts)
  when ?is_opts(Opts) ->
    ergw_core_config:validate_options(fun validate_charging_options/2, Opts, ?DefaultProfile);
validate_profile(Name, Opts) ->
    erlang:error(badarg, [Name, Opts]).

%% validate_rule_def('Service-Identifier', [Value] = V)
%%   when is_integer(Value) ->
%%     V;
validate_rule_def('Rating-Group', [Value] = V)
  when is_integer(Value), Value >= 0 ->
    V;
validate_rule_def('Online-Rating-Group', [Value] = V)
  when is_integer(Value), Value >= 0 ->
    V;
validate_rule_def('Offline-Rating-Group', [Value] = V)
  when is_integer(Value), Value >= 0 ->
    V;
validate_rule_def('Flow-Information', Value)
  when length(Value) /= 0 ->
    Value;
%% validate_rule_def('Default-Bearer-Indication', [Value] = V) ->
%%     V;
validate_rule_def('TDF-Application-Identifier', [Value] = V)
  when is_binary(Value) ->
    V;
%% validate_rule_def('Flow-Status', [Value] = V) ->
%%     V;
%% validate_rule_def('QoS-Information', [Value] = V) ->
%%     V;
%% validate_rule_def('PS-to-CS-Session-Continuity', [Value] = V) ->
%%     V;
%% validate_rule_def('Reporting-Level', [Value] = V) ->
%%     V;
validate_rule_def('Online', [Value] = V)
  when Value =:= 0; Value =:= 1 ->
    V;
validate_rule_def('Offline', [Value] = V)
  when Value =:= 0; Value =:= 1 ->
    V;
%% validate_rule_def('Max-PLR-DL', [Value] = V) ->
%%     V;
%% validate_rule_def('Max-PLR-UL', [Value] = V) ->
%%     V;
validate_rule_def('Metering-Method', [Value] = V)
  when Value =:= 0; Value =:= 1; Value =:= 2; Value =:= 3 ->
    V;
validate_rule_def('Precedence', [Value] = V)
  when is_integer(Value), Value >= 0 ->
    V;
%% validate_rule_def('AF-Charging-Identifier', [Value] = V) ->
%%     V;
%% validate_rule_def('Flows', [Value] = V) ->
%%     V;
%% validate_rule_def('Monitoring-Key', [Value] = V) ->
%%     V;
validate_rule_def('Redirect-Information', Value = V)
  when is_list(Value), length(Value) /= 0, length(Value) =< 2 ->
    V;
%% validate_rule_def('Mute-Notification', [Value] = V) ->
%%     V;
%% validate_rule_def('AF-Signalling-Protocol', [Value] = V) ->
%%     V;
%% validate_rule_def('Sponsor-Identity', [Value] = V) ->
%%     V;
%% validate_rule_def('Application-Service-Provider-Identity', [Value] = V) ->
%%     V;
%% validate_rule_def('Required-Access-Info', [Value] = V) ->
%%     V;
%% validate_rule_def('Sharing-Key-DL', [Value] = V) ->
%%     V;
%% validate_rule_def('Sharing-Key-UL', [Value] = V) ->
%%     V;
%% validate_rule_def('Traffic-Steering-Policy-Identifier-DL', [Value] = V) ->
%%     V;
%% validate_rule_def('Traffic-Steering-Policy-Identifier-UL', [Value] = V) ->
%%     V;
%% validate_rule_def('Content-Version', [Value] = V) ->
%%     V;
validate_rule_def(AVP, Value) ->
    %% only known AVP are supported for now
    erlang:error(badarg, [AVP, Value]).

validate_rule(Key, Opts)
  when is_binary(Key), ?is_non_empty_opts(Opts) ->
    %% 3GPP TS 29.212 Charging-Rule-Definition AVP in Erlang terms
    ergw_core_config:validate_options(fun validate_rule_def/2, Opts, []);
validate_rule(Key, Opts) ->
    erlang:error(badarg, [Key, Opts]).

validate_rulebase(Key, RuleBaseDef)
  when is_binary(Key), is_list(RuleBaseDef) ->
    S = lists:usort([X || X <- RuleBaseDef, is_binary(X)]),
    if length(S) /= length(RuleBaseDef) ->
	    erlang:error(badarg, [Key, RuleBaseDef]);
       true ->
	    ok
    end,
    RuleBaseDef;
validate_rulebase(Key, RuleBase) ->
    erlang:error(badarg, [Key, RuleBase]).

validate_online_charging_options(Key, Opts) ->
    erlang:error(badarg, [{online, charging}, {Key, Opts}]).

validate_offline_charging_triggers(Key, Opt)
  when (Opt == 'cdr' orelse Opt == 'off') andalso
       (Key == 'max-cond-change' orelse
	Key == 'ms-time-zone-change' orelse
	Key == 'rat-change' orelse
	Key == 'sgsn-sgw-change' orelse
	Key == 'sgsn-sgw-plmn-id-change') ->
    Opt;
validate_offline_charging_triggers(Key, Opt)
  when (Opt == 'container' orelse Opt == 'off') andalso
       (Key == 'cgi-sai-change' orelse
	Key == 'ecgi-change' orelse
	Key == 'qos-change' orelse
	Key == 'rai-change' orelse
	Key == 'rat-change' orelse
	Key == 'sgsn-sgw-change' orelse
	Key == 'sgsn-sgw-plmn-id-change' orelse
	Key == 'tai-change' orelse
	Key == 'tariff-switch-change' orelse
	Key == 'user-location-info-change') ->
    Opt;
validate_offline_charging_triggers(Key, Opts) ->
    erlang:error(badarg, [{offline, charging, triggers}, {Key, Opts}]).

validate_offline_charging_options(enable, Opt) when is_boolean(Opt) ->
    Opt;
validate_offline_charging_options(triggers, Opts) ->
    ergw_core_config:validate_options(fun validate_offline_charging_triggers/2,
				 Opts, ?DefaultOfflineChargingTriggers);
validate_offline_charging_options(Key, Opts) ->
    erlang:error(badarg, [{offline, charging}, {Key, Opts}]).

validate_charging_options(online, Opts) ->
    ergw_core_config:validate_options(fun validate_online_charging_options/2,
				 Opts, ?DefaultOnlineChargingOpts);
validate_charging_options(offline, Opts) ->
    ergw_core_config:validate_options(fun validate_offline_charging_options/2,
				 Opts, ?DefaultOfflineChargingOpts);
validate_charging_options(Key, Opts) ->
    erlang:error(badarg, [charging, {Key, Opts}]).

%%%===================================================================
%%% API
%%%===================================================================

add_profile(Name, Opts0) ->
    Opts = validate_profile(Name, Opts0),
    {ok, Profiles} = ergw_core_config:get([charging_profile], #{}),
    ergw_core_config:put(charging_profile, maps:put(Name, Opts, Profiles)).

add_rule(Name, Opts0) ->
    Opts = validate_rule(Name, Opts0),
    {ok, Rules} = ergw_core_config:get([charging_rule], #{}),
    ergw_core_config:put(charging_rule, maps:put(Name, Opts, Rules)).

add_rulebase(Name, Opts0) ->
    Opts = validate_rulebase(Name, Opts0),
    {ok, RBs} = ergw_core_config:get([charging_rulebase], #{}),
    ergw_core_config:put(charging_rulebase, maps:put(Name, Opts, RBs)).

%% TODO: use APN, VPLMN, HPLMN and Charging Characteristics
%%       to select config
get_profile() ->
    case ergw_core_config:get([charging_profile, default], []) of
	{ok, Opts0} when is_map(Opts0) ->
	    Opts0;
	undefined ->
	    Opts = validate_profile(default, []),
	    ergw_core_config:put(charging_profile, #{default => Opts}),
	    Opts
    end.

reporting_triggers() ->
    Triggers =
	maps:get(triggers,
		 maps:get(offline, get_profile(), #{}), #{}),
    maps:map(
      fun(_Key, Cond) -> Cond /= 'off' end, Triggers).

is_charging_event(offline, Evs) ->
    Filter =
	maps:get(triggers,
		 maps:get(offline, get_profile(), #{}), #{}),
    is_offline_charging_event(Evs, Filter);
is_charging_event(online, _) ->
    true.

is_enabled(Type = offline) ->
    maps:get(enable, maps:get(Type, get_profile(), #{}), true).

rulebase() ->
    {ok, Rules} = ergw_core_config:get([charging_rule], #{}),
    {ok, RuleBase} = ergw_core_config:get([charging_rulebase], #{}),
    #{rules => Rules, rulebase => RuleBase}.

%%%===================================================================
%%% Helper functions
%%%===================================================================

%% use the numeric ordering from 3GPP TS 32.299,
%% sect. 7.2.37 Change-Condition AVP
ev_highest_prio(Evs) ->
    PrioM =
	#{
	  'qos-change' =>                       2,
	  'sgsn-sgw-change' =>                  5,
	  'sgsn-sgw-plmn-id-change' =>          6,
	  'user-location-info-change' =>        7,
	  'rat-change' =>                       8,
	  'ms-time-zone-change' =>              9,
	  'tariff-switch-change' =>             10,
	  'max-cond-change' =>                  13,
	  'cgi-sai-change' =>                   14,
	  'rai-change' =>                       15,
	  'ecgi-change' =>                      16,
	  'tai-change' =>                       17
	 },
    {_, H} = lists:min([{maps:get(Ev, PrioM, 255), Ev} || Ev <- Evs]),
    H.

assign_ev(Key, Ev, M) ->
    maps:update_with(Key, fun(L) -> [Ev|L] end, [Ev], M).

is_offline_charging_event(Evs, Filter)
  when is_map(Filter) ->
    Em = lists:foldl(
	   fun(Ev, M) -> assign_ev(maps:get(Ev, Filter, off), Ev, M) end,
	   #{}, Evs),
    case Em of
	#{cdr := CdrEvs} when CdrEvs /= [] ->
	    {cdr_closure, ev_highest_prio(CdrEvs)};
	#{container := CCEvs} when CCEvs /= [] ->
	    {container_closure, ev_highest_prio(CCEvs)};
	_ ->
	    false
    end.
