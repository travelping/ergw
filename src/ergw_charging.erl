%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_charging).

-export([validate_options/1,
	 is_charging_event/2,
	 is_enabled/1,
	 rulebase/0]).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

-define(DefaultChargingOpts, [{rulebase, []}, {online, []}, {offline, []}]).
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

validate_options({Key, Opts})
  when is_atom(Key), ?is_opts(Opts) ->
    {Key, ergw_config:validate_options(fun validate_charging_options/2, Opts, ?DefaultChargingOpts, map)}.

%% validate_rule_def('Service-Identifier', Value) ->
%% validate_rule_def('Rating-Group', Value) ->
%% validate_rule_def('Flow-Information', Value) ->
%% validate_rule_def('Default-Bearer-Indication', Value) ->
%% validate_rule_def('TDF-Application-Identifier', Value) ->
%% validate_rule_def('Flow-Status', Value) ->
%% validate_rule_def('QoS-Information', Value) ->
%% validate_rule_def('PS-to-CS-Session-Continuity', Value) ->
%% validate_rule_def('Reporting-Level', Value) ->
%% validate_rule_def('Online', Value) ->
%% validate_rule_def('Offline', Value) ->
%% validate_rule_def('Max-PLR-DL', Value) ->
%% validate_rule_def('Max-PLR-UL', Value) ->
%% validate_rule_def('Metering-Method', Value) ->
%% validate_rule_def('Precedence', Value) ->
%% validate_rule_def('AF-Charging-Identifier', Value) ->
%% validate_rule_def('Flows', Value) ->
%% validate_rule_def('Monitoring-Key', Value) ->
%% validate_rule_def('Redirect-Information', Value) ->
%% validate_rule_def('Mute-Notification', Value) ->
%% validate_rule_def('AF-Signalling-Protocol', Value) ->
%% validate_rule_def('Sponsor-Identity', Value) ->
%% validate_rule_def('Application-Service-Provider-Identity', Value) ->
%% validate_rule_def('Required-Access-Info', Value) ->
%% validate_rule_def('Sharing-Key-DL', Value) ->
%% validate_rule_def('Sharing-Key-UL', Value) ->
%% validate_rule_def('Traffic-Steering-Policy-Identifier-DL', Value) ->
%% validate_rule_def('Traffic-Steering-Policy-Identifier-UL', Value) ->
%% validate_rule_def('Content-Version', Value) ->

validate_rule_def(Key, Value)
  when is_atom(Key) andalso
       is_list(Value) andalso length(Value) /= 0 ->
    Value;
validate_rule_def(Key, Value) ->
    throw({error, {options, {rule, {Key, Value}}}}).

validate_rulebase(Key, [Id | _] = RuleBaseDef)
  when is_binary(Key) andalso is_binary(Id) ->
    case lists:usort(RuleBaseDef) of
	S when length(S) /= length(RuleBaseDef) ->
	    throw({error, {options, {rulebase, {Key, RuleBaseDef}}}});
	_ ->
	    ok
    end,

    lists:foreach(fun(RId) when is_binary(RId) ->
			  ok;
		     (RId) ->
			  throw({error, {options, {rule, {Key, RId}}}})
		  end, RuleBaseDef),
    RuleBaseDef;
validate_rulebase(Key, Rule)
  when is_binary(Key) andalso ?non_empty_opts(Rule) ->
    ergw_config:check_unique_keys(Key, Rule),
    ergw_config:validate_options(fun validate_rule_def/2,
				 Rule, ?DefaultRuleDef, map);
validate_rulebase(Key, Rule) ->
    throw({error, {options, {rulebase, {Key, Rule}}}}).

validate_online_charging_options(Key, Opts) ->
    throw({error, {options, {{online, charging}, {Key, Opts}}}}).

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
    throw({error, {options, {{offline, charging, triggers}, {Key, Opts}}}}).

validate_offline_charging_options(enable, Opt) when is_boolean(Opt) ->
    Opt;
validate_offline_charging_options(triggers, Opts) ->
    ergw_config:validate_options(fun validate_offline_charging_triggers/2,
				 Opts, ?DefaultOfflineChargingTriggers, map);
validate_offline_charging_options(Key, Opts) ->
    throw({error, {options, {{offline, charging}, {Key, Opts}}}}).

validate_charging_options(rulebase, RuleBase) ->
    ergw_config:check_unique_keys(rulebase, RuleBase),
    ergw_config:validate_options(fun validate_rulebase/2,
				 RuleBase, ?DefaultRulebase, map);
validate_charging_options(online, Opts) ->
    ergw_config:validate_options(fun validate_online_charging_options/2,
				 Opts, ?DefaultOnlineChargingOpts, map);
validate_charging_options(offline, Opts) ->
    ergw_config:validate_options(fun validate_offline_charging_options/2,
				 Opts, ?DefaultOfflineChargingOpts, map);
validate_charging_options(Key, Opts) ->
    throw({error, {options, {charging, {Key, Opts}}}}).

%%%===================================================================
%%% API
%%%===================================================================

config() ->
    %% TODO: use APN, VPLMN, HPLMN and Charging Characteristics
    %%       to select config
    case application:get_env(ergw, charging) of
	{ok, #{default := Cfg}} -> Cfg;
	_ -> #{}
    end.

is_charging_event(offline, Evs) ->
    Filter =
	maps:get(triggers,
		 maps:get(offline, config(), #{}), #{}),
    is_offline_charging_event(Evs, Filter);
is_charging_event(online, _) ->
    true.

is_enabled(Type = offline) ->
    maps:get(enable, maps:get(Type, config(), #{}), true).

rulebase() ->
    maps:get(rulebase, config(), #{}).

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
