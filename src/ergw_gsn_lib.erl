%% Copyright 2017-2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gsn_lib).

-compile({parse_transform, cut}).

-export([seconds_to_sntp_time/1,
	 gregorian_seconds_to_sntp_time/1,
	 datetime_to_sntp_time/1,
	 sntp_time_to_seconds/1
	 %% sntp_time_to_gregorian_seconds/1
	 %% sntp_time_to_datetime/1
	]).
-export([
	 process_online_charging_events/4,
	 process_offline_charging_events/4,
	 process_offline_charging_events/5,
	 process_accounting_monitor_events/4,
	 secondary_rat_usage_data_report_to_rf/2,
	 pfcp_to_context_event/1,
	 pcc_ctx_to_credit_request/1,
	 choose_ip_by_tunnel/4,
	 ip_pdu/3
	]).
-export([%%update_pcc_rules/2,
	 session_events_to_pcc_ctx/2,
	 gx_events_to_pcc_ctx/4,
	 gy_events_to_pcc_ctx/3,
	 gy_credit_report/1,
	 gy_credit_request/2,
	 gy_credit_request/3,
	 pcc_events_to_charging_rule_report/1]).
-export([pcc_ctx_has_rules/1]).
-export([apn/2, apn_opts/2, select_vrf/2,
	 allocate_ips/7, release_context_ips/1]).
-export([tunnel/2,
	 bearer/2,
	 init_tunnel/4,
	 init_bearer/2,
	 assign_tunnel_teid/3,
	 reassign_tunnel_teid/1,
	 assign_local_data_teid/5,
	 set_bearer_vrf/3,
	 set_ue_ip/4,
	 set_ue_ip/5
	]).

-include_lib("kernel/include/logger.hrl").
-include_lib("parse_trans/include/exprecs.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_3gpp.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include("include/ergw.hrl").

-export_records([context, tdf_ctx, tunnel, bearer, fq_teid]).

-define(SECONDS_PER_DAY, 86400).
-define(DAYS_FROM_0_TO_1970, 719528).
-define(SECONDS_FROM_0_TO_1970, (?DAYS_FROM_0_TO_1970*?SECONDS_PER_DAY)).

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

-define(ZERO_IPv4, {0,0,0,0}).
-define(ZERO_IPv6, {0,0,0,0,0,0,0,0}).
-define(UE_INTERFACE_ID, {0,0,0,0,0,0,0,1}).

-define(APNOpts, ['MS-Primary-DNS-Server', 'MS-Secondary-DNS-Server',
		  'MS-Primary-NBNS-Server', 'MS-Secondary-NBNS-Server',
		  'DNS-Server-IPv6-Address', '3GPP-IPv6-DNS-Servers']).

%%%===================================================================
%%% Helper functions
%%%===================================================================

seconds_to_sntp_time(Sec) ->
    if Sec >= 2085978496 ->
	    Sec - 2085978496;
       true ->
	    Sec + 2208988800
    end.

gregorian_seconds_to_sntp_time(Sec) ->
    seconds_to_sntp_time(Sec - ?SECONDS_FROM_0_TO_1970).

datetime_to_sntp_time(DateTime) ->
    gregorian_seconds_to_sntp_time(calendar:datetime_to_gregorian_seconds(DateTime)).

sntp_time_to_seconds(SNTP) ->
    if SNTP >= 2208988800 ->
	    SNTP - 2208988800;
       true ->
	    SNTP + 2085978496
    end.

sntp_time_to_gregorian_seconds(SNTP) ->
    ergw_gsn_lib:sntp_time_to_seconds(SNTP) + ?SECONDS_FROM_0_TO_1970.

sntp_time_to_datetime(SNTP) ->
    calendar:gregorian_seconds_to_datetime(sntp_time_to_gregorian_seconds(SNTP)).

get_rating_group(Key, M) when is_map(M) ->
    hd(maps:get(Key, M, maps:get('Rating-Group', M, [undefined]))).

%% choose_ip_by_tunnel/4
choose_ip_by_tunnel(#tunnel{local = FqTEID}, IP4, IP6, Ctx) ->
    choose_ip_by_tunnel_f(FqTEID, IP4, IP6, Ctx).

%% use additional information from the context or config to prefer V4 or V6....
choose_ip_by_tunnel_f(#fq_teid{ip = LocalIP}, IP4, _IP6, _)
  when is_binary(IP4), byte_size(IP4) =:= 4, ?IS_IPv4(LocalIP) ->
    IP4;
choose_ip_by_tunnel_f(#fq_teid{ip = LocalIP}, _IP4, IP6, _)
  when is_binary(IP6), byte_size(IP6) =:= 16, ?IS_IPv6(LocalIP) ->
    IP6;
choose_ip_by_tunnel_f(_, _IP4, _IP6, Ctx) ->
    %% IP version mismatch, broken peer GSN or misconfiguration
    throw(?CTX_ERR(?FATAL, system_failure, Ctx)).


%%%===================================================================
%%% PCC context helper
%%%===================================================================

pcc_ctx_has_rules(#pcc_ctx{rules = Rules}) ->
    maps:size(Rules) /= 0.

pfcp_to_context_event([], M) ->
    M;
pfcp_to_context_event([{ChargingKey, Ev}|T], M) ->
    pfcp_to_context_event(T,
			  maps:update_with(Ev, [ChargingKey|_], [ChargingKey], M)).

%% pfcp_to_context_event/1
pfcp_to_context_event(Evs) ->
    pfcp_to_context_event(Evs, #{}).

%%%===================================================================
%%% PCC to Sx translation functions
%%%===================================================================

-record(pcc_upd, {errors = [], rules = #{}}).

session_events_to_pcc_ctx(Evs, PCC) ->
    lists:foldl(fun session_events_to_pcc_ctx_2/2, PCC, Evs).

session_events_to_pcc_ctx_2({set, {Service, {Type, Level, Interval, Opts}}},
			    #pcc_ctx{monitors = Monitors} = PCC) ->
    Definition = {Type, Interval, Opts},
    PCC#pcc_ctx{monitors =
		    maps:update_with(Level, maps:put(Service, Definition, _),
				     #{Service => Definition}, Monitors)};
session_events_to_pcc_ctx_2(Ev, PCC) ->
    ?LOG(warning, "unhandled Session Event ~p", [Ev]),
    PCC.

%% convert Gx like Install/Remove interactions in PCC rule states

%% gx_events_to_pcc_ctx/4
gx_events_to_pcc_ctx(Evs, Filter, RuleBase,
		     #pcc_ctx{rules = Rules0, credits = GrantedCredits} = PCC) ->
    #pcc_upd{errors = Errors, rules = Rules} =
	lists:foldl(update_pcc_rules(_, Filter, RuleBase, _), #pcc_upd{rules = Rules0}, Evs),
    Credits = maps:fold(pcc_rules_to_credits(_, _, GrantedCredits, _), #{}, Rules),
    {PCC#pcc_ctx{rules = Rules, credits = Credits}, Errors}.

update_pcc_rules({pcc, install, Ev}, Filter, RuleBase, Update)
  when Filter == install; Filter == '_' ->
    lists:foldl(install_pcc_rules(_, RuleBase, _), Update, Ev);
update_pcc_rules({pcc, remove, Ev}, Filter, _RuleBase, Update)
  when Filter == remove; Filter == '_' ->
    lists:foldl(fun remove_pcc_rules/2, Update, Ev);
update_pcc_rules(_, _, _, Update) ->
    Update.

pcc_rules_to_credits(_K, #{'Online' := [1]} = Definition, Granted, Acc) ->
    RatingGroup = get_rating_group('Online-Rating-Group', Definition),
    RG = maps:get(RatingGroup, Granted, empty),
    maps:update_with(RatingGroup, fun(V) -> V end, RG, Acc);
pcc_rules_to_credits(_K, _V, _Granted, Acc) ->
    Acc.

split_pcc_rule(Rule) ->
    maps:fold(fun(K, V, {Action, Opts})
		    when K =:= 'Charging-Rule-Name';
			 K =:= 'Charging-Rule-Base-Name';
			 K =:= 'Charging-Rule-Definition' ->
		      {Action#{K => V}, Opts};
		 (K, V, {Action, Opts}) ->
		      {Action, Opts#{K => V}}
	      end, {#{}, #{}}, Rule).

pcc_upd_error(Error, #pcc_upd{errors = Errs} = Updates) ->
    Updates #pcc_upd{errors = [Error|Errs]}.

update_pcc_rule(Name, Rule, Opts, #pcc_upd{rules = Rules0} = Update) ->
    UpdRule = maps:merge(Opts, Rule),
    Rules = maps:update_with(Name, maps:merge(_, UpdRule), UpdRule, Rules0),
    Update#pcc_upd{rules = Rules}.

install_preconf_rule(Name, IsRuleBase, Opts, RuleBase, Update) ->
    case RuleBase of
	#{Name := Rules} when IsRuleBase andalso is_list(Rules) ->
	    UpdOpts = Opts#{'Charging-Rule-Base-Name' => Name},
	    lists:foldl(install_preconf_rule(_, false, UpdOpts, RuleBase, _), Update, Rules);
	#{Name := Rule} when (not IsRuleBase) andalso is_map(Rule) ->
	    update_pcc_rule(Name, Rule, Opts, Update);
	_ when IsRuleBase ->
	    pcc_upd_error({not_found, {rulebase, Name}}, Update);
	_ ->
	    pcc_upd_error({not_found, {rule, Name}}, Update)
    end.

install_pcc_rules(Install, RuleBase, Update) ->
    {Rules, Opts} = split_pcc_rule(Install),
    maps:fold(install_pcc_rule(_, _, Opts, RuleBase, _), Update, Rules).

install_pcc_rule('Charging-Rule-Name', V, Opts, RuleBase, Update) ->
    lists:foldl(install_preconf_rule(_, false, Opts, RuleBase, _), Update, V);
install_pcc_rule('Charging-Rule-Base-Name', V, Opts, RuleBase, Update) ->
    lists:foldl(install_preconf_rule(_, true, Opts, RuleBase, _), Update, V);
install_pcc_rule('Charging-Rule-Definition', V, Opts, _RuleBase, Update) ->
    lists:foldl(fun(#{'Charging-Rule-Name' := Name} = Rule, Upd) ->
			update_pcc_rule(Name, Rule, Opts, Upd)
		end, Update, V).

remove_pcc_rules(Install, Update) ->
    {Rules, Opts} = split_pcc_rule(Install),
    maps:fold(remove_pcc_rules(_, _, Opts, _), Update, Rules).

remove_pcc_rule(Name, true, _Opts, #pcc_upd{rules = Rules0} = Update) ->
    Rules =
	maps:filter(fun(_K, #{'Charging-Rule-Base-Name' := BaseName}) ->
			    BaseName /= Name;
		       (_K, _V) -> true
		    end, Rules0),
    Update#pcc_upd{rules = Rules};
remove_pcc_rule(Name, false, _Opts, #pcc_upd{rules = Rules} = Update) ->
    case Rules of
	#{Name := _} ->
	    Update#pcc_upd{rules = maps:remove(Name, Rules)};
	_ ->
	    pcc_upd_error({not_found, {rule, Name}}, Update)
    end.
remove_pcc_rules('Charging-Rule-Name', V, Opts, Update) ->
    lists:foldl(remove_pcc_rule(_, false, Opts, _), Update, V);
remove_pcc_rules('Charging-Rule-Base-Name', V, Opts, Update) ->
    lists:foldl(remove_pcc_rule(_, true, Opts, _), Update, V).

gy_events_to_credits(Now, #{'Rating-Group' := [RatingGroup],
			    'Result-Code' := [2001],
			    'Validity-Time' := [Time]
			   } = C0, Credits)
  when is_integer(Time) ->
    AbsTime = erlang:convert_time_unit(Now, native, millisecond) + Time * 1000,
    C = C0#{'Update-Time-Stamp' => Now, 'Validity-Time' => {abs, AbsTime}},
    Credits#{RatingGroup => C};
gy_events_to_credits(Now, #{'Rating-Group' := [RatingGroup],
			    'Result-Code' := [2001]
			   } = C0, Credits) ->
    C = C0#{'Update-Time-Stamp' => Now},
    Credits#{RatingGroup => C};
gy_events_to_credits(_, #{'Rating-Group' := [RatingGroup]}, Credits) ->
    maps:remove(RatingGroup, Credits).

credits_to_pcc_rules(K, #{'Online' := [1]} = V, Pools, {Rules, Removed}) ->
    RatingGroup = get_rating_group('Online-Rating-Group', V),
    case is_map_key(RatingGroup, Pools) of
	true ->
	    {maps:put(K, V, Rules), Removed};
	false ->
	    {Rules, [{no_credits, K} | Removed]}
    end;
credits_to_pcc_rules(K, V, _, {Rules, Removed}) ->
    {maps:put(K, V, Rules), Removed}.

%% gy_events_to_pcc_ctx/3
gy_events_to_pcc_ctx(Now, Evs, #pcc_ctx{rules = Rules0, credits = Credits0} = PCC) ->
    Upd = proplists:get_value(update_credits, Evs, []),
    Credits = lists:foldl(gy_events_to_credits(Now, _, _), Credits0, Upd),
    {Rules, Removed} = maps:fold(credits_to_pcc_rules(_, _, Credits, _), {#{}, []}, Rules0),
    {PCC#pcc_ctx{rules = Rules, credits = Credits}, Removed}.




opt_int(X) when is_integer(X) -> [X];
opt_int(_) -> [].

%% ===========================================================================
%% Gy Support - Online Charging
%% ===========================================================================

credit_report_volume(#volume_measurement{total = Total, uplink = UL, downlink = DL}, Report) ->
    Report#{'CC-Total-Octets' => opt_int(Total),
	    'CC-Input-Octets' => opt_int(UL),
	    'CC-Output-Octets' => opt_int(DL)};
credit_report_volume(_, Report) ->
    Report.

credit_report_duration(#duration_measurement{duration = Duration}, Report) ->
    Report#{'CC-Time' => opt_int(Duration)};
credit_report_duration(_, Report) ->
    Report.

trigger_to_reason(#usage_report_trigger{volqu = 1}, Report) ->
    Report#{'Reporting-Reason' =>
		[?'DIAMETER_3GPP_CHARGING_REPORTING-REASON_QUOTA_EXHAUSTED']};
trigger_to_reason(#usage_report_trigger{timqu = 1}, Report) ->
    Report#{'Reporting-Reason' =>
		[?'DIAMETER_3GPP_CHARGING_REPORTING-REASON_QUOTA_EXHAUSTED']};
trigger_to_reason(#usage_report_trigger{volth = 1}, Report) ->
    Report#{'Reporting-Reason' =>
		[?'DIAMETER_3GPP_CHARGING_REPORTING-REASON_THRESHOLD']};
trigger_to_reason(#usage_report_trigger{timth = 1}, Report) ->
    Report#{'Reporting-Reason' =>
		[?'DIAMETER_3GPP_CHARGING_REPORTING-REASON_THRESHOLD']};
trigger_to_reason(#usage_report_trigger{termr = 1}, Report) ->
    Report#{'Reporting-Reason' =>
		[?'DIAMETER_3GPP_CHARGING_REPORTING-REASON_FINAL']};
trigger_to_reason(_, Report) ->
   Report.

charge_event_to_reason(#{'Charge-Event' := validity_time}, Report) ->
    Report#{'Reporting-Reason' =>
		[?'DIAMETER_3GPP_CHARGING_REPORTING-REASON_VALIDITY_TIME']};
charge_event_to_reason(_, Report) ->
    Report.

tariff_change_usage(#{usage_information := #usage_information{bef = 1}}, Report) ->
    Report#{'Tariff-Change-Usage' =>
		[?'DIAMETER_3GPP_CHARGING_TARIFF-CHANGE-USAGE_UNIT_BEFORE_TARIFF_CHANGE']};
tariff_change_usage(#{usage_information := #usage_information{aft = 1}}, Report) ->
    Report#{'Tariff-Change-Usage' =>
		[?'DIAMETER_3GPP_CHARGING_TARIFF-CHANGE-USAGE_UNIT_AFTER_TARIFF_CHANGE']};
tariff_change_usage(_, Report) ->
    Report.

%% charging_event_to_gy/1
charging_event_to_gy(#{'Rating-Group' := ChargingKey,
		       usage_report_trigger := Trigger} = URR) ->
    Report0 = trigger_to_reason(Trigger, #{}),
    Report1 = charge_event_to_reason(URR, Report0),
    Report2 = tariff_change_usage(URR, Report1),
    Report3 = credit_report_volume(maps:get(volume_measurement, URR, undefined), Report2),
    Report = credit_report_duration(maps:get(duration_measurement, URR, undefined), Report3),
    {ChargingKey, Report}.

%% ===========================================================================
%% Gx Support - Charging-Rule-Report
%% ===========================================================================

pcc_events_to_charging_rule_report({not_found, {rulebase, Name}}, AVPs) ->
    Report =
	#{'Charging-Rule-Base-Name' => [Name],
	  'PCC-Rule-Status'    => [?'DIAMETER_GX_PCC-RULE-STATUS_INACTIVE'],
	  'Rule-Failure-Code'  => [?'DIAMETER_GX_RULE-FAILURE-CODE_RATING_GROUP_ERROR']
	 },
    repeated('Charging-Rule-Report', Report, AVPs);
pcc_events_to_charging_rule_report({not_found, {rule, Name}}, AVPs) ->
    Report =
	#{'Charging-Rule-Name' => [Name],
	  'PCC-Rule-Status'    => [?'DIAMETER_GX_PCC-RULE-STATUS_INACTIVE'],
	  'Rule-Failure-Code'  => [?'DIAMETER_GX_RULE-FAILURE-CODE_RATING_GROUP_ERROR']
	 },
    repeated('Charging-Rule-Report', Report, AVPs);
pcc_events_to_charging_rule_report(_Ev, AVPs) ->
    AVPs.

pcc_events_to_charging_rule_report(Events) ->
    lists:foldl(fun pcc_events_to_charging_rule_report/2, #{}, Events).

%% ===========================================================================
%% Rf Support - Offline Charging
%% ===========================================================================

assign([Key], Fun, Avps) ->
    Fun(Key, Avps);
assign([Key | Next], Fun, Avps) ->
    [V] = maps:get(Key, Avps, [#{}]),
    Avps#{Key => [assign(Next, Fun, V)]}.

repeated(Keys, Value, Avps) when is_list(Keys) ->
    assign(Keys, repeated(_, Value, _), Avps);
repeated(Key, Value, Avps)
  when is_atom(Key) ->
    maps:update_with(Key, fun(V) -> [Value|V] end, [Value], Avps).

optional_if_unset(K, V, M) ->
    maps:update_with(K, fun(L) -> L end, [V], M).

%% Service-Data-Container :: = < AVP Header: 2040>
%%   [ AF-Correlation-Information ]
%%   [ Charging-Rule-Base-Name ]
%%   [ Accounting-Input-Octets ]
%%   [ Accounting-Output-Octets ]
%%   [ Local-Sequence-Number ]
%%   [ QoS-Information ]
%%   [ Rating-Group ]
%%   [ Change-Time ]
%%   [ Service-Identifier ]
%%   [ Service-Specific-Info ]
%%   [ ADC-Rule-Base-Name ]
%%   [ SGSN-Address ]
%%   [ Time-First-Usage ]
%%   [ Time-Last-Usage ]
%%   [ Time-Usage ]
%% * [ Change-Condition]
%%   [ 3GPP-User-Location-Info ]
%%   [ 3GPP2-BSID ]
%%   [ UWAN-User-Location-Info ]
%%   [ TWAN-User-Location-Info ]
%%   [ Sponsor-Identity ]
%%   [ Application-Service-Provider-Identity ]
%% * [ Presence-Reporting-Area-Information]
%%   [ Presence-Reporting-Area-Status ]
%%   [ User-CSG-Information ]
%%   [ 3GPP-RAT-Type ]
%%   [ Related-Change-Condition-Information ]
%%   [ Serving-PLMN-Rate-Control ]
%%   [ APN-Rate-Control ]
%%   [ 3GPP-PS-Data-Off-Status ]
%%   [ Traffic-Steering-Policy-Identifier-DL ]
%%   [ Traffic-Steering-Policy-Identifier-UL ]

init_cev_from_session(Now, SessionOpts) ->
    Keys = ['Charging-Rule-Base-Name', 'QoS-Information',
	    '3GPP-User-Location-Info', '3GPP-RAT-Type',
	    '3GPP-Charging-Id',
	    '3GPP-SGSN-Address', '3GPP-SGSN-IPv6-Address'],
    Init = #{'Change-Time' =>
		 [calendar:system_time_to_universal_time(Now + erlang:time_offset(), native)]},
    Container =
	maps:fold(fun(K, V, M) when K == '3GPP-User-Location-Info';
				    K == '3GPP-RAT-Type';
				    K == '3GPP-Charging-Id' ->
			  M#{K => [ergw_aaa_diameter:'3gpp_from_session'(K, V)]};
		     (K, V, M) when K == '3GPP-SGSN-Address';
				    K == '3GPP-SGSN-IPv6-Address' ->
			  M#{'SGSN-Address' => [V]};
		     (K, V, M) -> M#{K => [V]}
		  end,
		  Init, maps:with(Keys, SessionOpts)),

    TDVKeys = ['Charging-Rule-Base-Name', 'QoS-Information',
	       '3GPP-User-Location-Info', '3GPP-RAT-Type',
	       '3GPP-Charging-Id'],
    TDV = maps:with(TDVKeys, Container),

    SDCKeys = ['Charging-Rule-Base-Name', 'QoS-Information',
	       '3GPP-User-Location-Info', '3GPP-RAT-Type',
	       '3GPP-SGSN-Address', '3GPP-SGSN-IPv6-Address'],
    SDC = maps:with(SDCKeys, Container),

    {SDC, TDV}.

cev_to_rf_cc_kv(immer, SDC) ->
    %% Immediate Reporting means something has triggered a Report Request,
    %% the triggering function has to make sure to fill in the
    %% Change-Condition
    SDC;
cev_to_rf_cc_kv(droth, SDC) ->
    %% Drop-Threshold, similar enough to Volume Limit
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_VOLUME_LIMIT', SDC);
cev_to_rf_cc_kv(stopt, SDC) ->
    %% best match for Stop-Of-Trigger seems to be Service Idled Out
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_SERVICE_IDLED_OUT', SDC);
cev_to_rf_cc_kv(start, SDC) ->
    %% Start-Of-Traffic should not trigger a chargable event....
    %%    maybe a container opening
    SDC;
cev_to_rf_cc_kv(quhti, SDC) ->
    %% Quota Holding Time
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TIME_LIMIT', SDC);
cev_to_rf_cc_kv(timth, SDC) ->
    %% Time Threshold ->
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TIME_LIMIT', SDC);
cev_to_rf_cc_kv(volth, SDC) ->
    %% Volume Threshold ->
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_VOLUME_LIMIT', SDC);
cev_to_rf_cc_kv(perio, SDC) ->
    %% Periodic Reporting
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TIME_LIMIT', SDC);
cev_to_rf_cc_kv(macar, SDC) ->
    %% MAC Addresses Reporting
    SDC;
cev_to_rf_cc_kv(envcl, SDC) ->
    %% Envelope Closure
    SDC;
cev_to_rf_cc_kv(monit, SDC) ->
    %% Monitoring Time
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TARIFF_TIME_CHANGE', SDC);
cev_to_rf_cc_kv(termr, SDC) ->
    %% Termination Report -> Normal Release
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_NORMAL_RELEASE', SDC);
cev_to_rf_cc_kv(liusa, SDC) ->
    %% Linked Usage Reporting -> TBD, not used for now
    SDC;
cev_to_rf_cc_kv(timqu, SDC) ->
    %% Time Quota -> Time Limit
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TIME_LIMIT', SDC);
cev_to_rf_cc_kv(volqu, SDC) ->
    %% Volume Quota ->
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_VOLUME_LIMIT', SDC);
cev_to_rf_cc_kv(_, SDC) ->
    SDC.

cev_to_rf_change_condition([], _, SDC) ->
    SDC;
cev_to_rf_change_condition([K|Fields], [1|Values], SDC) ->
    cev_to_rf_change_condition(Fields, Values, cev_to_rf_cc_kv(K, SDC));
cev_to_rf_change_condition([_|Fields], [_|Values], SDC) ->
    cev_to_rf_change_condition(Fields, Values, SDC).

cev_to_rf('Charge-Event', {_, 'qos-change'}, _, C) ->
    C#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_QOS_CHANGE'};
cev_to_rf('Charge-Event', {_, 'sgsn-sgw-change'}, _, C) ->
    C#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_SERVING_NODE_CHANGE'};
cev_to_rf('Charge-Event', {_, 'sgsn-sgw-plmn-id-change'}, _, C) ->
    C#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_SERVING_NODE_PLMN_CHANGE'};
cev_to_rf('Charge-Event', {_, 'user-location-info-change'}, _, C) ->
    C#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_USER_LOCATION_CHANGE'};
cev_to_rf('Charge-Event', {_, 'rat-change'}, _, C) ->
    C#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_RAT_CHANGE'};
cev_to_rf('Charge-Event', {_, 'ms-time-zone-change'}, _, C) ->
    C#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_UE_TIMEZONE_CHANGE'};
cev_to_rf('Charge-Event', {_, 'cgi-sai-change'}, _, C) ->
    C#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_CGI_SAI_CHANGE'};
cev_to_rf('Charge-Event', {_, 'rai-change'}, _, C) ->
    C#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_RAI_CHANGE'};
cev_to_rf('Charge-Event', {_, 'ecgi-change'}, _, C) ->
    C#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_ECGI_CHANGE'};
cev_to_rf('Charge-Event', {_, 'tai-change'}, _, C) ->
    C#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TAI_CHANGE'};

cev_to_rf('Rating-Group' = Key, RatingGroup, service_data, C) ->
    C#{Key => [RatingGroup]};
cev_to_rf(_, #time_of_first_packet{time = TS}, service_data, C) ->
    C#{'Time-First-Usage' => [sntp_time_to_datetime(TS)]};
cev_to_rf(_, #time_of_last_packet{time = TS}, service_data, C) ->
    C#{'Time-Last-Usage' => [sntp_time_to_datetime(TS)]};
cev_to_rf(_, #end_time{time = TS}, _, C) ->
    C#{'Change-Time' => [sntp_time_to_datetime(TS)]};
cev_to_rf(usage_report_trigger, #usage_report_trigger{} = Trigger, _, C) ->
    cev_to_rf_change_condition(record_info(fields, usage_report_trigger),
			       tl(tuple_to_list(Trigger)), C);
cev_to_rf(_, #volume_measurement{uplink = UL, downlink = DL}, _, C) ->
    C#{'Accounting-Input-Octets'  => opt_int(UL),
	 'Accounting-Output-Octets' => opt_int(DL)};
cev_to_rf(_, #duration_measurement{duration = Duration}, service_data, C) ->
    C#{'Time-Usage' => opt_int(Duration)};
cev_to_rf(_K, _V, _, C) ->
    C.

cev_reason({cdr_closure, time}, C) ->
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TIME_LIMIT', C);
cev_reason({terminate, _}, C) ->
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_NORMAL_RELEASE', C);
cev_reason(_, C) ->
    C.

secondary_rat_usage_data_report_to_rf(ChargingId,
				      #v2_secondary_rat_usage_data_report{
					 rat_type = RAT, ebi = _EBI,
					 start_time = Start, end_time = End,
					 dl = DL, ul = UL}) ->
    #{'Secondary-RAT-Type' => [binary:encode_unsigned(RAT)],
      'RAN-Start-Timestamp' => [sntp_time_to_datetime(Start)],
      'RAN-End-Timestamp' => [sntp_time_to_datetime(End)],
      'Accounting-Input-Octets' => [UL],
      'Accounting-Output-Octets' => [DL],
      '3GPP-Charging-Id' => [ChargingId]}.

%% find_offline_charging_reason/2
update_offline_charging_event(Ev, ChargeEv) when is_atom(ChargeEv) ->
    update_offline_charging_event(Ev, {ChargeEv, ChargeEv});
update_offline_charging_event(_, {terminate, _} = ChargeEv) ->
    ChargeEv;
update_offline_charging_event([], ChargeEv) ->
    ChargeEv;
update_offline_charging_event([#{'Rating-Group' := RG,
				 usage_report_trigger :=
				     #usage_report_trigger{perio = 1}}|T], _)
  when not is_integer(RG) ->
    update_offline_charging_event(T, {cdr_closure, time});
update_offline_charging_event([_|T], ChargeEv) ->
    update_offline_charging_event(T, ChargeEv).

%% charging_event_to_rf/3
charging_event_to_rf(#{'Rating-Group' := RG} = URR, {Init, _}, Reason, {SDCs, TDVs})
  when is_integer(RG) ->
    SDC0 = maps:fold(cev_to_rf(_, _, service_data, _), Init, URR),
    SDC = cev_reason(Reason, SDC0),
    {[SDC|SDCs], TDVs};
charging_event_to_rf(URR, {_, Init}, Reason, {SDCs, TDVs}) ->
    TDV0 = maps:fold(cev_to_rf(_, _, traffic_data, _), Init, URR),
    TDV = cev_reason(Reason, TDV0),
    {SDCs, [TDV|TDVs]}.

%% process_online_charging_events/4
process_online_charging_events(Reason, Request, Session, ReqOpts)
  when is_map(Request) ->
    Used = maps:get(used_credits, Request, #{}),
    Needed = maps:get(credits, Request, #{}),
    case Reason of
	{terminate, Cause} ->
	    TermReq = Request#{'Termination-Cause' => Cause},
	    ergw_aaa_session:invoke(Session, TermReq, {gy, 'CCR-Terminate'}, ReqOpts);
	_ when map_size(Used) /= 0;
	       map_size(Needed) /= 0 ->
	    ergw_aaa_session:invoke(Session, Request, {gy, 'CCR-Update'}, ReqOpts);
	_ ->
	    SOpts = ergw_aaa_session:get(Session),
	    {ok, SOpts, []}
    end.


process_offline_charging_events(ChargeEv, Ev, Now, Session)
  when is_list(Ev) ->
    process_offline_charging_events(ChargeEv, Ev, Now, ergw_aaa_session:get(Session), Session).

process_offline_charging_events(ChargeEv0, Ev, Now, SessionOpts, Session)
  when is_list(Ev) ->
    {Reason, _} = ChargeEv = update_offline_charging_event(Ev, ChargeEv0),
    Init = init_cev_from_session(Now, SessionOpts),
    {SDCs, TDVs} = lists:foldl(charging_event_to_rf(_, Init, ChargeEv, _), {[], []}, Ev),

    SOpts = #{now => Now, async => true, 'gy_event' => Reason},
    Request = #{'service_data' => SDCs, 'traffic_data' => TDVs},
    case Reason of
	terminate ->
	    ergw_aaa_session:invoke(Session, Request, {rf, 'Terminate'}, SOpts);
	_ when length(SDCs) /= 0; length(TDVs) /= 0 ->
	    ergw_aaa_session:invoke(Session, Request, {rf, 'Update'}, SOpts);
	_ ->
	    ok
    end.

accounting_session_time(Now, #{'Session-Start' := Start} = Update) ->
    %% round Start and Now to full seconds, before calculating the duration
    Duration =
	erlang:convert_time_unit(Now, native, second) -
	erlang:convert_time_unit(Start, native, second),
    Update#{'Acct-Session-Time' => Duration};
accounting_session_time(_, Update) ->
    Update.

monitor_event_to_accounting(Now, #{'Level'      := 'IP-CAN',
				   'Service-Id' := {accounting, _, _}} = Report, Update0) ->
    Update = accounting_session_time(Now, Update0),
    maps:fold(
      fun(_, #volume_measurement{uplink = In, downlink = Out}, Upd0) ->
	      Upd = maps:update_with('InOctets', In + _, In, Upd0),
	      maps:update_with('OutOctets', Out + _, Out, Upd);
	 (_, #tp_packet_measurement{uplink = In, downlink = Out}, Upd0) ->
	      Upd = maps:update_with('InPackets', In + _, In, Upd0),
	      maps:update_with('OutPackets', Out + _, Out, Upd);
	 (_, _, Upd) ->
	      Upd
      end, Update, Report);
monitor_event_to_accounting(_Now, _Ev, Update) ->
    Update.

process_accounting_monitor_events(Reason, Ev, Now, Session)
  when is_list(Ev) ->
    Keys = ['InPackets', 'OutPackets',
	    'InOctets',  'OutOctets',
	    'Session-Start'],
    Update0 = maps:with(Keys, ergw_aaa_session:get(Session)),
    Update1 = lists:foldl(monitor_event_to_accounting(Now, _, _), Update0, Ev),
    SOpts = #{now => Now, async => true},

    case Reason of
	{terminate, Cause} ->
	    Update2 = Update1#{'Termination-Cause' => Cause},
	    Update3 = maps:remove('Session-Start', Update2),
	    Update = accounting_session_time(Now, Update3),
	    ergw_aaa_session:invoke(Session, Update, stop, SOpts);
	_ when Update0 /= Update1 ->
	    Update = maps:remove('Session-Start', Update1),
	    ergw_aaa_session:invoke(Session, Update, interim, SOpts);
	_ ->
	    ok
    end.

%% gy_credit_report/1
gy_credit_report(Ev) ->
    Used = lists:map(fun charging_event_to_gy/1, Ev),
    #{used_credits => Used}.

make_gy_credit_request(Ev, Add, CreditsNeeded) ->
    Used = lists:map(fun charging_event_to_gy/1, Ev),
    Needed = lists:foldl(
	       fun ({RG, _}, Crds)
		     when is_map_key(RG, CreditsNeeded) ->
		       Crds#{RG => empty};
		   (_, Crds) ->
		       Crds
	       end, Add, Used),
    #{used_credits => Used, credits => Needed}.

%% gy_credit_request/2
gy_credit_request(Ev, #pcc_ctx{credits = CreditsNeeded}) ->
    make_gy_credit_request(Ev, #{}, CreditsNeeded).

%% gy_credit_request/3
gy_credit_request(Ev, #pcc_ctx{credits = CreditsOld},
		  #pcc_ctx{credits = CreditsNeeded}) ->
    Add = maps:without(maps:keys(CreditsOld), CreditsNeeded),
    make_gy_credit_request(Ev, Add, CreditsNeeded).

%% ===========================================================================

%% 3GPP TS 23.203, Sect. 6.1.2 Reporting:
%%
%% NOTE 1: Reporting usage information to the online charging function
%%         is distinct from credit management. Hence multiple PCC/ADC
%%         rules may share the same charging key for which one credit
%%         is assigned whereas reporting may be at higher granularity
%%         if serviced identifier level reporting is used.
%%
%% also see RFC 4006, https://tools.ietf.org/html/rfc4006#section-5.1.2
%%
pcc_rules_to_credit_request(_K, #{'Online' := [1]} = Definition, Acc) ->
    case get_rating_group('Online-Rating-Group', Definition) of
	RatingGroup when is_integer(RatingGroup) ->
	    RG = empty,
	    maps:update_with(RatingGroup, fun(V) -> V end, RG, Acc);
	_ ->
	    ?LOG(warning, "Online Charging requested, but no Rating Group: ~p", [Definition]),
	    Acc
    end;
pcc_rules_to_credit_request(_K, _V, Acc) ->
    Acc.

%% pcc_ctx_to_credit_request/1
pcc_ctx_to_credit_request(#pcc_ctx{rules = Rules}) ->
    ?LOG(debug, "Rules: ~p", [Rules]),
    CreditReq = maps:fold(fun pcc_rules_to_credit_request/3, #{}, Rules),
    ?LOG(debug, "CreditReq: ~p", [CreditReq]),
    CreditReq.

%%%===================================================================
%%% VRF selection
%%%===================================================================

apn(APN) ->
    apn(APN, application:get_env(ergw, apns, #{})).

apn([H|_] = APN0, APNs) when is_binary(H) ->
    APN = gtp_c_lib:normalize_labels(APN0),
    {NI, OI} = ergw_node_selection:split_apn(APN),
    FqAPN = NI ++ OI,
    case APNs of
	#{FqAPN := A} -> A;
	#{NI :=    A} -> A;
	#{'_' :=   A} -> A;
	_ -> false
    end;
apn(_, _) ->
    false.

apn_opts(APN, Ctx) ->
    case apn(APN) of
	false -> throw(?CTX_ERR(?FATAL, missing_or_unknown_apn, Ctx));
	Other -> Other
    end.

%% select/2
select(_, []) -> undefined;
select(first, L) -> hd(L);
select(random, L) when is_list(L) ->
    lists:nth(rand:uniform(length(L)), L).

%% select/3
select(Method, L1, L2) when is_map(L2) ->
    select(Method, L1, maps:keys(L2));
select(Method, L1, L2) when is_list(L1), is_list(L2) ->
    {L,_} = lists:partition(fun(A) -> lists:member(A, L2) end, L1),
    select(Method, L).

%% select_vrf/2
select_vrf({AvaVRFs, _AvaPools}, APN) ->
    select(random, maps:get(vrfs, apn(APN)), AvaVRFs).

%%%===================================================================

normalize_ipv4({IP, PLen} = Addr)
  when ?IS_IPv4(IP), is_integer(PLen), PLen > 0, PLen =< 32 ->
    Addr;
normalize_ipv4(IP) when ?IS_IPv4(IP) ->
    {IP, 32};
normalize_ipv4(undefined) ->
    undefined.

normalize_ipv6({?ZERO_IPv6, 0}) ->
    {?ZERO_IPv6, 64};
normalize_ipv6({IP, PLen} = Addr)
  when ?IS_IPv6(IP), is_integer(PLen), PLen > 0, PLen =< 128 ->
    Addr;
normalize_ipv6(IP) when ?IS_IPv6(IP) ->
    {IP, 64};
normalize_ipv6(undefined) ->
    undefined.

init_session_ue_ifid(APNOpts, #{'3GPP-PDP-Type' := Type} = Session)
  when Type =:= 'IPv6'; Type =:= 'IPv4v6' ->
    ReqIPv6 = maps:get('Requested-IPv6-Prefix', Session, {?ZERO_IPv6, 64}),
    IfId = ue_interface_id(ReqIPv6, APNOpts),
    Session#{'Framed-Interface-Id' => IfId};
init_session_ue_ifid(_, Session) ->
    Session.

request_alloc({ReqIPv4, PrefixLen}, #{'Framed-Pool' := Pool} = Opts)
  when ?IS_IPv4(ReqIPv4) ->
    Request = case ReqIPv4 of
		  ?ZERO_IPv4 -> ipv4;
		  _          -> ReqIPv4
	      end,
    {Pool, Request, PrefixLen, Opts};
request_alloc({ReqIPv6, PrefixLen}, #{'Framed-Pool' := Pool} = Opts)
  when ?IS_IPv6(ReqIPv6) ->
    Request = case ReqIPv6 of
		  ?ZERO_IPv6 -> ipv6;
		  _          -> ReqIPv6
	      end,
    {Pool, Request, PrefixLen, Opts};
request_alloc(_ReqIP, _Opts) ->
    skip.

request_ip_alloc(ReqIPs, Opts,# tunnel{local = #fq_teid{teid = TEI}}) ->
    Req = [request_alloc(IP, Opts) || IP <- ReqIPs],
    ergw_ip_pool:send_request(TEI, Req).

ip_alloc_result(skip, Acc) ->
    Acc;
ip_alloc_result({error, empty}, {UeIP, _}) ->
    throw(?CTX_ERR(?FATAL, all_dynamic_addresses_are_occupied, UeIP));
ip_alloc_result({error, taken}, {UeIP, _}) ->
    throw(?CTX_ERR(?FATAL, system_error, UeIP));
ip_alloc_result({error, undefined}, Acc) ->
    %% pool not defined
    Acc;
ip_alloc_result({error, Result}, Acc) ->
    ?LOG(error, "IP alloc failed with ~p", [Result]),
    Acc;
ip_alloc_result(AI, {UeIP, Opts0}) ->
    case ergw_ip_pool:ip(AI) of
	{IP, _} when ?IS_IPv4(IP) ->
	    Opts1 = maps:merge(Opts0, ergw_ip_pool:opts(AI)),
	    Opts = maps:put('Framed-IP-Address', IP, Opts1),
	    {UeIP#ue_ip{v4 = AI}, Opts};
	{IP, _} = IPv6 when ?IS_IPv6(IP) ->
	    Opts1 = maps:merge(Opts0, ergw_ip_pool:opts(AI)),
	    Opts = Opts1#{'Framed-IPv6-Prefix' => ergw_inet:ipv6_prefix(IPv6)},
	    {UeIP#ue_ip{v6 = AI}, Opts}
    end.

wait_ip_alloc_results(ReqIds, Opts0) ->
    IPOpts = ['Framed-IP-Address', 'Framed-IPv6-Prefix', 'Framed-Interface-Id'],
    Opts = maps:without(IPOpts, Opts0),
    lists:foldl(fun ip_alloc_result/2, {#ue_ip{}, Opts}, ergw_ip_pool:wait_response(ReqIds)).

ue_interface_id({{_,_,_,_,A,B,C,D} = ReqIP, _}, _) when ReqIP =/= ?ZERO_IPv6 ->
    {0,0,0,0,A,B,C,D};
ue_interface_id(_ReqIP, #{ipv6_ue_interface_id := default}) ->
    ?UE_INTERFACE_ID;
ue_interface_id(_, #{ipv6_ue_interface_id := random}) ->
    E = rand:uniform(65536) - 1,
    F = rand:uniform(65536) - 1,
    G = rand:uniform(65536) - 1,
    H = rand:uniform(65534),
    {0,0,0,0,E,F,G,H};
ue_interface_id(_, #{ipv6_ue_interface_id := IfId})
  when is_tuple(IfId) ->
    IfId.

session_ipv4_alloc(#{'Framed-IP-Address' := {255,255,255,255}}, ReqMSv4) ->
    ReqMSv4;
session_ipv4_alloc(#{'Framed-IP-Address' := {255,255,255,254}}, _ReqMSv4) ->
    {0,0,0,0};
session_ipv4_alloc(#{'Framed-IP-Address' := {_,_,_,_} = IPv4}, _ReqMSv4) ->
    IPv4;
session_ipv4_alloc(_SessionOpts, ReqMSv4) ->
    ReqMSv4.

session_ipv6_alloc(#{'Framed-IPv6-Prefix' := {{_,_,_,_,_,_,_,_}, _} = IPv6}, _ReqMSv6) ->
    IPv6;
session_ipv6_alloc(_SessionOpts, ReqMSv6) ->
    ReqMSv6.

session_ip_alloc('IPv4', _, _, _, {'IPv6', _, _}) ->
    {'IPv4', undefined, undefined};
session_ip_alloc('IPv6', _, _, _, {'IPv4', _, _}) ->
    {'IPv6', undefined, undefined};

session_ip_alloc('IPv4', _, SessionOpts, _, {'IPv4v6', ReqMSv4, _}) ->
    MSv4 = session_ipv4_alloc(SessionOpts, ReqMSv4),
    {'IPv4v6', MSv4, undefined};

session_ip_alloc('IPv6', _, SessionOpts, _, {'IPv4v6', _, ReqMSv6}) ->
    MSv6 = session_ipv6_alloc(SessionOpts, ReqMSv6),
    {'IPv4v6', undefined, MSv6};

session_ip_alloc('IPv4v6', 'IPv4', SessionOpts, false, {'IPv4v6', ReqMSv4, _}) ->
    MSv4 = session_ipv4_alloc(SessionOpts, ReqMSv4),
    {'IPv4v6', MSv4, undefined};

session_ip_alloc('IPv4v6', 'IPv6', SessionOpts, false, {'IPv4v6', _, ReqMSv6}) ->
    MSv6 = session_ipv6_alloc(SessionOpts, ReqMSv6),
    {'IPv4v6', undefined, MSv6};

session_ip_alloc(_, _, SessionOpts, _, {PDNType, ReqMSv4, ReqMSv6}) ->
    MSv4 = session_ipv4_alloc(SessionOpts, ReqMSv4),
    MSv6 = session_ipv6_alloc(SessionOpts, ReqMSv6),
    {PDNType, MSv4, MSv6}.

%% allocate_ips/4
allocate_ips(ReqIPs, SOpts0, Tunnel, Context) ->
    ReqIds = request_ip_alloc(ReqIPs, SOpts0, Tunnel),
    try
	{UeIP, SOpts} = wait_ip_alloc_results(ReqIds, SOpts0),
	{UeIP, SOpts, Context#context{ms_ip = UeIP}}
    catch
	throw:#ctx_err{context = CtxUeIP} = CtxErr ->
	    ErrCtx = Context#context{ms_ip = CtxUeIP},
	    throw(CtxErr#ctx_err{context = ErrCtx})
    end.

allocate_ips_result(ReqPDNType, BearerType, #ue_ip{v4 = MSv4, v6 = MSv6}, Context) ->
    allocate_ips_result(ReqPDNType, BearerType, ergw_ip_pool:ip(MSv4),
			ergw_ip_pool:ip(MSv6), Context).

allocate_ips_result('Non-IP', _, _, _, _) -> {request_accepted, 'Non-IP'};
allocate_ips_result('IPv4', _, IPv4, _, _) when IPv4 /= undefined ->
    {request_accepted, 'IPv4'};
allocate_ips_result('IPv6', _, _, IPv6, _) when IPv6 /= undefined ->
    {request_accepted, 'IPv6'};
allocate_ips_result('IPv4v6', _, IPv4, IPv6, _)
  when IPv4 /= undefined, IPv6 /= undefined ->
    {request_accepted, 'IPv4v6'};
allocate_ips_result('IPv4v6', 'IPv4', IPv4, undefined, _) when IPv4 /= undefined ->
    {new_pdn_type_due_to_network_preference, 'IPv4'};
allocate_ips_result('IPv4v6', _, IPv4, undefined, _) when IPv4 /= undefined ->
    {'new_pdn_type_due_to_single_address_bearer_only', 'IPv4'};
allocate_ips_result('IPv4v6', 'IPv6', undefined, IPv6, _) when IPv6 /= undefined ->
    {new_pdn_type_due_to_network_preference, 'IPv6'};
allocate_ips_result('IPv4v6', _, undefined, IPv6, _) when IPv6 /= undefined ->
    {'new_pdn_type_due_to_single_address_bearer_only', 'IPv6'};
allocate_ips_result(_, _, _, _, Context) ->
    throw(?CTX_ERR(?FATAL, preferred_pdn_type_not_supported, Context)).

%% allocate_ips/7
allocate_ips(AllocInfo,
	     #{bearer_type := BearerType, prefered_bearer_type := PrefBearer} = APNOpts,
	     SOpts0, DualAddressBearerFlag, Tunnel, Bearer, Context0) ->
    {ReqPDNType, ReqMSv4, ReqMSv6} =
	session_ip_alloc(BearerType, PrefBearer, SOpts0, DualAddressBearerFlag, AllocInfo),

    SOpts1 = maps:merge(SOpts0, maps:with(?APNOpts, APNOpts)),
    SOpts2 = init_session_ue_ifid(APNOpts, SOpts1),

    ReqIPs = [normalize_ipv4(ReqMSv4), normalize_ipv6(ReqMSv6)],
    {UeIP, SOpts3, Context} = allocate_ips(ReqIPs, SOpts2, Tunnel, Context0),

    {Result, PDNType} = allocate_ips_result(ReqPDNType, BearerType, UeIP, Context),
    SOpts = init_session_ue_ifid(APNOpts, SOpts3),

    DNS = if PDNType =:= 'IPv6' orelse PDNType =:= 'IPv4v6' ->
		  maps:get('DNS-Server-IPv6-Address', SOpts, []) ++          %% RFC 6911
		      maps:get('3GPP-IPv6-DNS-Servers', SOpts, []);          %% 3GPP
	     true ->
		  []
	  end,
    {Result, SOpts, Bearer#bearer{local = UeIP}, Context#context{pdn_type = PDNType, dns_v6 = DNS}}.

%% release_context_ips/1
release_context_ips(#context{ms_ip = #ue_ip{v4 = MSv4, v6 = MSv6}} = Context) ->
    ergw_ip_pool:release([MSv4, MSv6]),
    unset_ue_ip(Context#context{ms_ip = undefined});
release_context_ips(#context{ms_ip = _IP} = Context) ->
    Context.

%%%===================================================================
%%% T-PDU functions
%%%===================================================================

-define('ICMPv6', 58).

-define('IPv6 All Nodes LL',   <<255,2,0,0,0,0,0,0,0,0,0,0,0,0,0,1>>).
-define('IPv6 All Routers LL', <<255,2,0,0,0,0,0,0,0,0,0,0,0,0,0,2>>).
-define('ICMPv6 Router Solicitation',  133).
-define('ICMPv6 Router Advertisement', 134).

-define(NULL_INTERFACE_ID, {0,0,0,0,0,0,0,0}).
-define('Our LL IP', <<254,128,0,0,0,0,0,0,0,0,0,0,0,0,0,2>>).

-define('RA Prefix Information', 3).
-define('RDNSS', 25).

%% ICMPv6
ip_pdu(<<6:4, TC:8, FlowLabel:20, Length:16, ?ICMPv6:8,
	     _HopLimit:8, SrcAddr:16/bytes, DstAddr:16/bytes,
	     PayLoad:Length/bytes, _/binary>>, Context, PCtx) ->
    icmpv6(TC, FlowLabel, SrcAddr, DstAddr, PayLoad, Context, PCtx);
ip_pdu(Data, _Context, _PCtx) ->
    ?LOG(warning, "unhandled T-PDU: ~p", [Data]),
    ok.

%% IPv6 Router Solicitation
icmpv6(TC, FlowLabel, _SrcAddr, ?'IPv6 All Routers LL',
       <<?'ICMPv6 Router Solicitation':8, _Code:8, _CSum:16, _/binary>>,
       #context{left = Bearer, right = #bearer{local = #ue_ip{v6 = MSv6}},
		dns_v6 = DNSv6}, PCtx) ->
    IPv6 = ergw_ip_pool:ip(MSv6),
    {Prefix, PLen} = ergw_inet:ipv6_interface_id(IPv6, ?NULL_INTERFACE_ID),

    OnLink = 1,
    AutoAddrCnf = 1,
    ValidLifeTime = 2592000,
    PreferredLifeTime = 604800,
    PrefixInformation = <<?'RA Prefix Information':8, 4:8,
			  PLen:8, OnLink:1, AutoAddrCnf:1, 0:6,
			  ValidLifeTime:32, PreferredLifeTime:32, 0:32,
			  (ergw_inet:ip2bin(Prefix))/binary>>,

    DNSCnt = length(DNSv6),
    DNSSrvOpt =
	if (DNSCnt /= 0) ->
		<<?'RDNSS', (1 + DNSCnt * 2):8, 0:16, 16#ffffffff:32,
		  << <<(ergw_inet:ip2bin(DNS))/binary>> || DNS <- DNSv6 >>/binary >>;
	   true ->
		<<>>
	end,

    TTL = 255,
    Managed = 0,
    OtherCnf = 0,
    LifeTime = 1800,
    ReachableTime = 0,
    RetransTime = 0,
    RAOpts = <<TTL:8, Managed:1, OtherCnf:1, 0:6, LifeTime:16,
	       ReachableTime:32, RetransTime:32,
	       PrefixInformation/binary,
	       DNSSrvOpt/binary>>,

    NwSrc = ?'Our LL IP',
    NwDst = ?'IPv6 All Nodes LL',
    ICMPLength = 4 + size(RAOpts),

    CSum = ergw_inet:ip_csum(<<NwSrc:16/bytes-unit:8, NwDst:16/bytes-unit:8,
				  ICMPLength:32, 0:24, ?ICMPv6:8,
				  ?'ICMPv6 Router Advertisement':8, 0:8, 0:16,
				  RAOpts/binary>>),
    ICMPv6 = <<6:4, TC:8, FlowLabel:20, ICMPLength:16, ?ICMPv6:8, TTL:8,
	       NwSrc:16/bytes, NwDst:16/bytes,
	       ?'ICMPv6 Router Advertisement':8, 0:8, CSum:16, RAOpts/binary>>,
    ergw_pfcp_context:send_g_pdu(PCtx, Bearer, ICMPv6);

icmpv6(_TC, _FlowLabel, _SrcAddr, _DstAddr, _PayLoad, _Context, _PCtx) ->
    ?LOG(warning, "unhandeld ICMPv6 from ~p to ~p: ~p", [_SrcAddr, _DstAddr, _PayLoad]),
    ok.

%%%===================================================================
%%% Bearer helpers
%%%===================================================================

update_field_with(Field, Rec, Fun) ->
    '#set-'([{Field, Fun('#get-'(Field, Rec))}], Rec).
    %% {Get, Set} = '#lens-'(Field, element(1, Rec)),
    %% Set(Fun(Get(Rec)), Rec).

context_field(tunnel, left)  -> left_tnl;
context_field(tunnel, right) -> right_tnl;
context_field(bearer, left)  -> left;
context_field(bearer, right) -> right.

%% tunnel/2
tunnel(CtxSide, Ctx) ->
    '#get-'(context_field(tunnel, CtxSide), Ctx).

%% init_tunnel/4
init_tunnel(Interface, #gtp_socket_info{vrf = VRF}, Socket, Version) ->
    #tunnel{interface = Interface, vrf = VRF, socket = Socket, version = Version}.

%% assign_tunnel_teid/3
assign_tunnel_teid(TunnelSide, #gtp_socket_info{vrf = VRF} = Info, Tunnel) ->
    '#set-'([{TunnelSide, assign_tunnel_teid_f(Info, Tunnel)}], Tunnel#tunnel{vrf = VRF}).

%% assign_tunnel_teid_f/2
assign_tunnel_teid_f(#gtp_socket_info{ip = IP}, #tunnel{socket = Socket}) ->
    {ok, TEI} = ergw_tei_mngr:alloc_tei(Socket),
    #fq_teid{ip = IP, teid = TEI}.

%% assign_tunnel_teid/1
reassign_tunnel_teid(Tunnel) ->
    update_field_with(
      local, Tunnel, reassign_tunnel_teid_f(Tunnel, _)).

%% reassign_tunnel_teid_f/2
reassign_tunnel_teid_f(#tunnel{socket = Socket}, FqTEID) ->
    {ok, TEI} = ergw_tei_mngr:alloc_tei(Socket),
    FqTEID#fq_teid{teid = TEI}.

%% init_bearer/2
init_bearer(Interface, #vrf{name = VRF}) ->
    #bearer{interface = Interface, vrf = VRF}.

%% bearer/2
bearer(CtxSide, Ctx) ->
    '#get-'(context_field(bearer, CtxSide), Ctx).

%% assign_local_data_teid/5
assign_local_data_teid(PCtx, NodeCaps, Tunnel, Bearer, Ctx)
  when is_record(Bearer, bearer) ->
    assign_local_data_teid_f(PCtx, NodeCaps, Tunnel, Bearer, Ctx).

%% assign_local_data_teid_f/5
assign_local_data_teid_f(PCtx, {VRFs, _} = _NodeCaps,
			 #tunnel{vrf = VRF} = Tunnel, Bearer, Ctx) ->
    #vrf{name = Name, ipv4 = IP4, ipv6 = IP6} = maps:get(VRF, VRFs),
    IP = choose_ip_by_tunnel(Tunnel, IP4, IP6, Ctx),
    {ok, DataTEI} = ergw_tei_mngr:alloc_tei(PCtx),
    FqTEID = #fq_teid{
		     ip = ergw_inet:bin2ip(IP),
		     teid = DataTEI},
    Bearer#bearer{vrf = Name, local = FqTEID}.

%% update_ue_ip/5
update_ue_ip(CtxSide, BearerSide, VRF, Fun, Ctx) ->
    update_field_with(
      context_field(bearer, CtxSide), Ctx,
      fun(Bearer) ->
	      update_field_with(BearerSide, Bearer#bearer{vrf = VRF}, Fun)
      end).

%% set_bearer_vrf/3,
set_bearer_vrf(CtxSide, VRF, Ctx) ->
    update_field_with(
      context_field(bearer, CtxSide), Ctx,
      fun(Bearer) -> Bearer#bearer{vrf = VRF} end).

%% set_ue_ip/4
set_ue_ip(CtxSide, BearerSide, UeIP, Ctx) when is_record(UeIP, ue_ip) ->
    update_field_with(context_field(bearer, CtxSide), Ctx, '#set-'([{BearerSide, UeIP}], _)).

%% set_ue_ip/5
set_ue_ip(CtxSide, BearerSide, #vrf{name = VRF}, UeIP, Ctx) ->
    update_ue_ip(CtxSide, BearerSide, VRF, fun(_) -> UeIP end, Ctx);
set_ue_ip(CtxSide, BearerSide, VRF, UeIP, Ctx) when is_binary(VRF) ->
    update_ue_ip(CtxSide, BearerSide, VRF, fun(_) -> UeIP end, Ctx).

%% unset_ue_ip/1
unset_ue_ip(Ctx) ->
    unset_ue_ip(right, local, Ctx).

%% unset_ue_ip/3
unset_ue_ip(CtxSide, BearerSide, Ctx) ->
    update_ue_ip(CtxSide, BearerSide, undefined, fun(_) -> undefined end, Ctx).
