%% Copyright 2017,2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gsn_lib).

-compile({parse_transform, cut}).

-export([create_sgi_session/4, create_tdf_session/4,
	 usage_report_to_charging_events/3,
	 process_online_charging_events/4,
	 process_offline_charging_events/4,
	 process_offline_charging_events/5,
	 process_accounting_monitor_events/4,
	 secondary_rat_usage_data_report_to_rf/2,
	 pfcp_to_context_event/1,
	 pcc_ctx_to_credit_request/1,
	 modify_sgi_session/5,
	 delete_sgi_session/3,
	 query_usage_report/2, query_usage_report/3,
	 choose_context_ip/3,
	 ip_pdu/3]).
-export([%%update_pcc_rules/2,
	 session_events_to_pcc_ctx/2,
	 gx_events_to_pcc_ctx/4,
	 gy_events_to_pcc_ctx/3,
	 gy_events_to_pcc_rules/2,
	 gy_credit_report/1,
	 gy_credit_request/2,
	 gy_credit_request/3,
	 pcc_events_to_charging_rule_report/1]).
-export([session_to_pco/2, pco_requested_opts/2]).
-export([pcc_ctx_has_rules/1]).
-export([apn/2, select_vrf/2,
	 init_session_ip_opts/3,
	 allocate_ips/6, release_context_ips/1]).

-export([select_upf/2, reselect_upf/4]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_3gpp.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include("include/ergw.hrl").

-record(sx_upd, {now, errors = [], monitors = #{}, pctx = #pfcp_ctx{}, sctx}).

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
%%% Sx DP API
%%%===================================================================

delete_sgi_session(Reason, Ctx, PCtx)
  when Reason /= upf_failure ->
    Req = #pfcp{version = v1, type = session_deletion_request, ie = []},
    case ergw_sx_node:call(PCtx, Req, Ctx) of
	#pfcp{type = session_deletion_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} = IEs} ->
	    maps:get(usage_report_sdr, IEs, undefined);

	_Other ->
	    ?LOG(warning, "PFCP: Session Deletion failed with ~p",
			  [_Other]),
	    undefined
    end;
delete_sgi_session(_Reason, _Context, _PCtx) ->
    undefined.

build_query_usage_report(Type, PCtx) ->
    maps:fold(fun(K, {URRType, V}, A)
		    when Type =:= URRType, is_integer(V) ->
		      [#query_urr{group = [#urr_id{id = K}]} | A];
		 (_, _, A) -> A
	      end, [], ergw_pfcp:get_urr_ids(PCtx)).

%% query_usage_report/2
query_usage_report(Ctx, PCtx) ->
    query_usage_report(online, Ctx, PCtx).

%% query_usage_report/3
query_usage_report(Type, Ctx, PCtx)
  when is_record(PCtx, pfcp_ctx) andalso
       (Type == offline orelse Type == online) ->
    IEs = build_query_usage_report(Type, PCtx),
    session_modification_request(PCtx, IEs, Ctx);

query_usage_report(ChargingKeys, Ctx, PCtx)
  when is_record(PCtx, pfcp_ctx) ->
    IEs = [#query_urr{group = [#urr_id{id = Id}]} ||
	   Id <- ergw_pfcp:get_urr_ids(ChargingKeys, PCtx), is_integer(Id)],
    session_modification_request(PCtx, IEs, Ctx).

%%%===================================================================
%%% Helper functions
%%%===================================================================

get_rating_group(Key, M) when is_map(M) ->
    hd(maps:get(Key, M, maps:get('Rating-Group', M, [undefined]))).

ctx_update_dp_seid(#{f_seid := #f_seid{seid = DP}},
		   #pfcp_ctx{seid = SEID} = PCtx) ->
    PCtx#pfcp_ctx{seid = SEID#seid{dp = DP}};
ctx_update_dp_seid(_, PCtx) ->
    PCtx.

%% use additional information from the Context to prefre V4 or V6....
choose_context_ip(IP4, _IP6, #context{control_port = #gtp_port{ip = LocalIP}})
  when is_binary(IP4), byte_size(IP4) =:= 4, ?IS_IPv4(LocalIP) ->
    IP4;
choose_context_ip(_IP4, IP6, #context{control_port = #gtp_port{ip = LocalIP}})
  when is_binary(IP6), byte_size(IP6) =:= 16, ?IS_IPv6(LocalIP) ->
    IP6;
choose_context_ip(_IP4, _IP6, Context) ->
    %% IP version mismatch, broken peer GSN or misconfiguration
    throw(?CTX_ERR(?FATAL, system_failure, Context)).

session_establishment_request(PCC, PCtx0, Ctx) ->
    {ok, CntlNode, _} = ergw_sx_socket:id(),

    PCtx1 = pctx_update_from_ctx(PCtx0, Ctx),
    {SxRules, SxErrors, PCtx} = build_sx_rules(PCC, #{}, PCtx1, Ctx),
    ?LOG(debug, "SxRules: ~p~n", [SxRules]),
    ?LOG(debug, "SxErrors: ~p~n", [SxErrors]),
    ?LOG(debug, "CtxPending: ~p~n", [Ctx]),

    IEs0 = pfcp_pctx_update(PCtx, PCtx0, SxRules),
    IEs = update_m_rec(ergw_pfcp:f_seid(PCtx, CntlNode), IEs0),
    ?LOG(debug, "IEs: ~p~n", [IEs]),

    Req = #pfcp{version = v1, type = session_establishment_request, ie = IEs},
    case ergw_sx_node:call(PCtx, Req, Ctx) of
	#pfcp{version = v1, type = session_establishment_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'},
		     f_seid := #f_seid{}} = RespIEs} ->
	    {Ctx, ctx_update_dp_seid(RespIEs, PCtx)};
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, Ctx))
    end.

session_modification_request(PCtx, ReqIEs, Ctx)
  when (is_list(ReqIEs) andalso length(ReqIEs) /= 0) orelse
       (is_map(ReqIEs) andalso map_size(ReqIEs) /= 0) ->
    Req = #pfcp{version = v1, type = session_modification_request, ie = ReqIEs},
    case ergw_sx_node:call(PCtx, Req, Ctx) of
	#pfcp{type = session_modification_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} = RespIEs} ->
	    UsageReport = maps:get(usage_report_smr, RespIEs, undefined),
	    {PCtx, UsageReport};
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, Ctx))
    end;
session_modification_request(PCtx, _ReqIEs, _Ctx) ->
    %% nothing to do
    {PCtx, undefined}.

%%%===================================================================
%%% PCC context helper
%%%===================================================================

pcc_ctx_has_rules(#pcc_ctx{rules = Rules}) ->
    maps:size(Rules) /= 0.

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

%% convert Gy Multiple-Services-Credit-Control interactions in PCC rule states

gy_events_to_rating_group_map(Evs)
  when is_list(Evs) ->
    lists:foldl(
      fun({update_credits, E}, M) ->
	      EvsM = gy_events_to_rating_group_map_1(E),
	      maps:merge(M, EvsM);
	 (_, M) ->
	      M
      end, #{}, Evs).

gy_events_to_rating_group_map_1(Evs)
  when is_list(Evs) ->
    lists:foldl(
      fun(#{'Rating-Group' := [RatingGroup]} = V, M) -> M#{RatingGroup => V};
	 (_, M) -> M end, #{}, Evs);
gy_events_to_rating_group_map_1(Evs)
  when is_map(Evs) ->
    Evs.

%% gy_events_to_pcc_rules/4
gy_events_to_pcc_rules(K, V, EvsMap, {Removals, Rules}) ->
    case maps:get('Online', V, [0]) of
	[0] -> {Removals, Rules#{K => V}};
	[1] ->
	    RatingGroup = get_rating_group('Online-Rating-Group', V),
	    case maps:get(RatingGroup, EvsMap, undefined) of
		#{'Result-Code' := [2001]} ->
		    {Removals, Rules#{K => V}};
		_ ->
		    {[{K, V} | Removals], Rules}
	    end
    end.

%% gy_events_to_pcc_rules/2
gy_events_to_pcc_rules(Evs, Rules0) ->
    EvsMap = gy_events_to_rating_group_map(Evs),
    maps:fold(gy_events_to_pcc_rules(_, _, EvsMap, _), {[], #{}}, Rules0).

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


%% convert PCC rule state into Sx rule states

sx_rule_error(Error, #sx_upd{errors = Errors} = Update) ->
    Update#sx_upd{errors = [Error | Errors]}.

apply_charing_tariff_time({H, M}, URR)
  when is_integer(H), H >= 0, H < 24,
       is_integer(M), M >= 0, M < 60 ->
    {Date, _} = Now = calendar:universal_time(),
    NowSecs = calendar:datetime_to_gregorian_seconds(Now),
    TCSecs =
	case calendar:datetime_to_gregorian_seconds({Date, {H, M, 0}}) of
	    T when T > NowSecs ->
		T;
	    T when T =< NowSecs ->
		T + ?SECONDS_PER_DAY
	end,
    TCTime = seconds_to_sntp_time(TCSecs - ?SECONDS_FROM_0_TO_1970),   %% 1970
    case URR of
	#{monitoring_time := #monitoring_time{time = OldTCTime}}
	  when TCTime > OldTCTime ->
	    %% don't update URR when new time is after existing time
	    URR;
	_ ->
	    URR#{monitoring_time => #monitoring_time{time = TCTime}}
    end;
apply_charing_tariff_time(Time, URR) ->
    ?LOG(error, "Invalid Tariff-Time \"~p\"", [Time]),
    URR.

apply_charging_profile('Tariff-Time', Value, URR)
  when is_tuple(Value) ->
    apply_charing_tariff_time(Value, URR);
apply_charging_profile('Tariff-Time', Value, URR)
  when is_list(Value) ->
    lists:foldl(fun apply_charing_tariff_time/2, URR, Value);
apply_charging_profile(_K, _V, URR) ->
    URR.

apply_charging_profile(URR, OCP) ->
    maps:fold(fun apply_charging_profile/3, URR, OCP).

%% build_sx_rules/4
build_sx_rules(PCC, Opts, PCtx0, SCtx) ->
    PCtx2 = ergw_pfcp:reset_ctx(PCtx0),

    Init = #sx_upd{now = erlang:monotonic_time(millisecond),
		   pctx = PCtx2, sctx = SCtx},
    #sx_upd{errors = Errors, pctx = NewPCtx0} =
	build_sx_rules_3(PCC, Opts, Init),
    NewPCtx = ergw_pfcp:apply_timers(PCtx0, NewPCtx0),

    SxRuleReq = ergw_pfcp:update_pfcp_rules(PCtx0, NewPCtx, Opts),

    %% TODO:
    %% remove unused SxIds

    {SxRuleReq, Errors, NewPCtx}.

build_sx_rules_3(#pcc_ctx{monitors = Monitors, rules = PolicyRules,
			  credits = GrantedCredits} = PCC, _Opts, Update0) ->
    Update1 = build_sx_ctx_rule(Update0),
    Update2 = build_ipcan_rule(Update1),
    Update3 = maps:fold(fun build_sx_monitor_rule/3, Update2, Monitors),
    Update4 = build_sx_charging_rule(PCC, PolicyRules, Update3),
    Update5 = maps:fold(fun build_sx_usage_rule/3, Update4, GrantedCredits),
    maps:fold(fun build_sx_rule/3, Update5, PolicyRules).

build_sx_ctx_rule(#sx_upd{
		     pctx =
			 #pfcp_ctx{cp_port = #gtp_port{ip = CpIP} = CpPort,
				   cp_tei = CpTEI} = PCtx0,
		     sctx = #context{
			       local_data_endp = LocalDataEndp,
			       ms_v6 = MSv6}
		    } = Update)
  when MSv6 /= undefined ->
    {PdrId, PCtx1} = ergw_pfcp:get_id(pdr, ipv6_mcast_pdr, PCtx0),
    {FarId, PCtx} = ergw_pfcp:get_id(far, dp_to_cp_far, PCtx1),

    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'Access'},
		  ergw_pfcp:network_instance(LocalDataEndp),
		  ergw_pfcp:f_teid(LocalDataEndp),
		  #sdf_filter{
		     flow_description =
			 <<"permit out 58 from ff00::/8 to assigned">>}]
	    },
    PDR = [#pdr_id{id = PdrId},
	   #precedence{precedence = 100},
	   PDI,
	   #far_id{id = FarId}
	   %% TBD: #urr_id{id = 1}
	  ],
    FAR = [#far_id{id = FarId},
	   #apply_action{forw = 1},
	   #forwarding_parameters{
	      group =
		  [#destination_interface{interface = 'CP-function'},
		   ergw_pfcp:network_instance(CpPort),
		   ergw_pfcp:outer_header_creation(#fq_teid{ip = CpIP, teid = CpTEI})
		  ]
	     }
	  ],
    Update#sx_upd{
      pctx = ergw_pfcp_rules:add(
	       [{pdr, ipv6_mcast_pdr, PDR},
		{far, dp_to_cp_far, FAR}], PCtx)};
build_sx_ctx_rule(Update) ->
    Update.

build_sx_charging_rule(PCC, PolicyRules, Update) ->
    maps:fold(
      fun(Name, Definition, Upd0) ->
	      Upd = build_sx_offline_charging_rule(Name, Definition, PCC, Upd0),
	      build_sx_online_charging_rule(Name, Definition, PCC, Upd)
      end, Update, PolicyRules).

%% TBD: handle offline charging config, only link URR if trigger closes CDR...
build_sx_linked_rule(URR, PCtx) ->
    build_sx_linked_offline_rule(ergw_charging:is_enabled(offline), URR, PCtx).

build_sx_linked_offline_rule(true, URR0, PCtx0) ->
    RuleName = {offline, 'IP-CAN'},
    {LinkedUrrId, PCtx} =
	ergw_pfcp:get_urr_id(RuleName, ['IP-CAN'], RuleName, PCtx0),
    URR = maps:update_with(reporting_triggers,
			   fun(T) -> T#reporting_triggers{linked_usage_reporting = 1} end,
			   URR0#{linked_urr_id => #linked_urr_id{id = LinkedUrrId}}),
    {URR, PCtx};
build_sx_linked_offline_rule(_, URR, PCtx) ->
    {URR, PCtx}.

build_sx_offline_charging_rule(Name,
			       #{'Offline' := [1]} = Definition,
			       #pcc_ctx{offline_charging_profile = OCPcfg},
			       #sx_upd{pctx = PCtx0} = Update) ->
    RatingGroup =
	case get_rating_group('Offline-Rating-Group', Definition) of
	    RG when is_integer(RG) -> RG;
	    _ ->
		%% Offline without Rating-Group ???
		sx_rule_error({system_error, Name}, Update)
	end,
    ChargingKey = {offline, RatingGroup},
    MM = case maps:get('Metering-Method', Definition,
		       [?'DIAMETER_3GPP_CHARGING_METERING-METHOD_DURATION_VOLUME']) of
	     [?'DIAMETER_3GPP_CHARGING_METERING-METHOD_DURATION'] ->
		 #measurement_method{durat = 1};
	     [?'DIAMETER_3GPP_CHARGING_METERING-METHOD_VOLUME'] ->
		 #measurement_method{volum = 1};
	     [?'DIAMETER_3GPP_CHARGING_METERING-METHOD_DURATION_VOLUME'] ->
		 #measurement_method{volum = 1, durat = 1}
	 end,

    {UrrId, PCtx1} = ergw_pfcp:get_urr_id(ChargingKey, [RatingGroup], ChargingKey, PCtx0),
    URR0 = #{urr_id => #urr_id{id = UrrId},
	     measurement_method => MM,
	     reporting_triggers => #reporting_triggers{}},
    {URR1, PCtx} = build_sx_linked_rule(URR0, PCtx1),

    OCP = maps:get('Default', OCPcfg, #{}),
    URR = apply_charging_profile(URR1, OCP),

    ?LOG(debug, "Offline URR: ~p", [URR]),
    Update#sx_upd{
      pctx = ergw_pfcp_rules:add(urr, ChargingKey, URR, PCtx)};

build_sx_offline_charging_rule(_Name, _Definition, _PCC, Update) ->
    Update.

build_sx_online_charging_rule(Name, #{'Online' := [1]} = Definition,
			      _PCC, #sx_upd{pctx = PCtx} = Update) ->
    RatingGroup =
	case get_rating_group('Online-Rating-Group', Definition) of
	    RG when is_integer(RG) -> RG;
	    _ ->
		%% Online without Rating-Group ???
		sx_rule_error({system_error, Name}, Update)
	end,
    ChargingKey = {online, RatingGroup},
    Update#sx_upd{
      pctx = ergw_pfcp_rules:add(urr, ChargingKey, needed, PCtx)};
build_sx_online_charging_rule(_Name, _Definition, _PCC, Update) ->
    Update.

%% no need to split into dl and ul direction, URR contain DL, UL and Total
%% build_sx_rule/3
build_sx_rule(Name, #{'Flow-Information' := FlowInfo,
		      'Metering-Method' := [_MeterM]} = Definition,
	      #sx_upd{} = Update) ->
    %% we need PDR+FAR (and PDI) for UL and DL, URR is universal for both

    {DL, UL} = lists:foldl(
		 fun(#{'Flow-Direction' :=
			   [?'DIAMETER_3GPP_CHARGING_FLOW-DIRECTION_DOWNLINK']} = R, {D, U}) ->
			 {[R | D], U};
		    (#{'Flow-Direction' :=
			   [?'DIAMETER_3GPP_CHARGING_FLOW-DIRECTION_UPLINK']} = R, {D, U}) ->
			 {D, [R | U]};
		    (#{'Flow-Direction' :=
			   [?'DIAMETER_3GPP_CHARGING_FLOW-DIRECTION_BIDIRECTIONAL']} = R, {D, U}) ->
			 {[R | D], [R | U]};
		    (_, A) ->
			 A
		 end, {[], []}, FlowInfo),
    build_sx_rule(Name, Definition, DL, UL, Update);

build_sx_rule(Name, #{'TDF-Application-Identifier' := [AppId],
		      'Metering-Method' := [_MeterM]} = Definition,
	      #sx_upd{} = Update) ->
    build_sx_rule(Name, Definition, AppId, AppId, Update);

build_sx_rule(Name, _Definition, Update) ->
    sx_rule_error({system_error, Name}, Update).

%% build_sx_rule/5
build_sx_rule(Name, Definition, DL, UL, Update0) ->
    URRs = get_rule_urrs(Definition, Update0),
    Update = build_sx_rule(downlink, Name, Definition, DL, URRs, Update0),
    build_sx_rule(uplink, Name, Definition, UL, URRs, Update).

build_sx_filter(FlowInfo)
  when is_list(FlowInfo) ->
    [#sdf_filter{flow_description = FD} || #{'Flow-Description' := [FD]} <- FlowInfo];
build_sx_filter(AppId)
  when is_binary(AppId) ->
    [#application_id{id = AppId}];
build_sx_filter(_) ->
    [].

to_binary(List) when is_list(List) ->
    list_to_binary(List);
to_binary(Bin) when is_binary(Bin) ->
    Bin.

build_sx_redirect([#{'Redirect-Support' :=        [1],   %% ENABLED
		     'Redirect-Address-Type' :=   [2],   %% URL
		     'Redirect-Server-Address' := [URL]}]) ->
    [#redirect_information{type = 'URL', address = to_binary(URL)}];
build_sx_redirect(_) ->
    [].

%% The spec compliante FAR would set Destination Interface
%% to Access. However, VPP can not deal with that right now.
%%
%% build_sx_sgi_fwd_far(FarId,
%%		     [#{'Redirect-Support' :=        [1],   %% ENABLED
%%			'Redirect-Address-Type' :=   [2],   %% URL
%%			'Redirect-Server-Address' := [URL]}],
%%		     #context{local_data_endp = LocalDataEndp}) ->
%%     [#far_id{id = FarId},
%%      #apply_action{forw = 1},
%%      #forwarding_parameters{
%%	group =
%%	    [#destination_interface{interface = 'Access'},
%%	     ergw_pfcp:network_instance(LocalDataEndp),
%%	     #redirect_information{type = 'URL', address = to_binary(URL)}]
%%        }];
build_sx_sgi_fwd_far(FarId,
		     [#{'Redirect-Support' :=        [1],   %% ENABLED
			'Redirect-Address-Type' :=   [2],   %% URL
			'Redirect-Server-Address' := [URL]}],
		     Ctx) ->
    [#far_id{id = FarId},
     #apply_action{forw = 1},
     #forwarding_parameters{
	group =
	    [#destination_interface{interface = 'SGi-LAN'},
	     ergw_pfcp:network_instance(Ctx),
	     #redirect_information{type = 'URL', address = to_binary(URL)}]
       }];
build_sx_sgi_fwd_far(FarId, _RedirInfo, Ctx) ->
    [#far_id{id = FarId},
     #apply_action{forw = 1},
     #forwarding_parameters{
	group =
	    [#destination_interface{interface = 'SGi-LAN'},
	     ergw_pfcp:network_instance(Ctx)]
       }].

%% build_sx_rule/6
build_sx_rule(Direction = downlink, Name, Definition, FilterInfo, URRs,
	      #sx_upd{
		 pctx = PCtx0,
		 sctx = #context{local_data_endp = LocalDataEndp,
				 remote_data_teid = PeerTEID} = Ctx
		} = Update)
  when PeerTEID /= undefined ->
    [Precedence] = maps:get('Precedence', Definition, [1000]),
    RuleName = {Direction, Name},
    {PdrId, PCtx1} = ergw_pfcp:get_id(pdr, RuleName, PCtx0),
    {FarId, PCtx} = ergw_pfcp:get_id(far, RuleName, PCtx1),
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'SGi-LAN'},
		  ergw_pfcp:network_instance(Ctx),
		  ergw_pfcp:ue_ip_address(dst, Ctx)] ++
		 build_sx_filter(FilterInfo)
	     },
    PDR = [#pdr_id{id = PdrId},
	   #precedence{precedence = Precedence},
	   PDI,
	   #far_id{id = FarId}] ++
	[#urr_id{id = X} || X <- URRs],
    FAR = [#far_id{id = FarId},
	   #apply_action{forw = 1},
	   #forwarding_parameters{
	      group =
		  [#destination_interface{interface = 'Access'},
		   ergw_pfcp:network_instance(LocalDataEndp),
		   ergw_pfcp:outer_header_creation(PeerTEID)
		  ]
	     }
	  ],
    Update#sx_upd{
      pctx = ergw_pfcp_rules:add(
	       [{pdr, RuleName, PDR},
		{far, RuleName, FAR}], PCtx)};

build_sx_rule(Direction = uplink, Name, Definition, FilterInfo, URRs,
	      #sx_upd{pctx = PCtx0,
		      sctx = #context{local_data_endp = LocalDataEndp} = Ctx
		     } = Update) ->
    [Precedence] = maps:get('Precedence', Definition, [1000]),
    RuleName = {Direction, Name},
    {PdrId, PCtx1} = ergw_pfcp:get_id(pdr, RuleName, PCtx0),
    {FarId, PCtx} = ergw_pfcp:get_id(far, RuleName, PCtx1),
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'Access'},
		  ergw_pfcp:network_instance(LocalDataEndp),
		  ergw_pfcp:f_teid(LocalDataEndp),
		  ergw_pfcp:ue_ip_address(src, Ctx)] ++
		 build_sx_filter(FilterInfo)
	    },
    PDR = [#pdr_id{id = PdrId},
	   #precedence{precedence = Precedence},
	   PDI,
	   ergw_pfcp:outer_header_removal(LocalDataEndp),
	   #far_id{id = FarId}] ++
	[#urr_id{id = X} || X <- URRs],

    RedirInfo = maps:get('Redirect-Information', Definition, undefined),
    FAR = build_sx_sgi_fwd_far(FarId, RedirInfo, Ctx),


    %% FAR = [#far_id{id = FarId},
    %% 	    #apply_action{forw = 1},
    %% 	    #forwarding_parameters{
    %% 	       group =
    %% 		   [#destination_interface{interface = 'SGi-LAN'},
    %% 		    %% #redirect_information{type = 'URL',
    %% 		    %% 			  address = <<"http://www.heise.de/">>},
    %% 		    ergw_pfcp:network_instance(Ctx)]
    %% 	       ++ build_sx_redirect(maps:get('Redirect-Information', Definition, undefined))
    %% 	      }
    %% 	  ],

    Update#sx_upd{
      pctx = ergw_pfcp_rules:add(
	       [{pdr, RuleName, PDR},
		{far, RuleName, FAR}], PCtx)};

%% ===========================================================================

build_sx_rule(Direction = downlink, Name, Definition, FilterInfo, URRs,
	      #sx_upd{pctx = PCtx0,
		      sctx = #tdf_ctx{in_vrf = InVrf, out_vrf = OutVrf} = SCtx
		     } = Update) ->
    [Precedence] = maps:get('Precedence', Definition, [1000]),
    RuleName = {Direction, Name},
    {PdrId, PCtx1} = ergw_pfcp:get_id(pdr, RuleName, PCtx0),
    {FarId, PCtx} = ergw_pfcp:get_id(far, RuleName, PCtx1),
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'SGi-LAN'},
		  ergw_pfcp:network_instance(OutVrf),
		  ergw_pfcp:ue_ip_address(dst, SCtx)] ++
		 build_sx_filter(FilterInfo)
	     },
    PDR = [#pdr_id{id = PdrId},
	   #precedence{precedence = Precedence},
	   PDI,
	   #far_id{id = FarId}] ++
	[#urr_id{id = X} || X <- URRs],
    FAR = [#far_id{id = FarId},
	   #apply_action{forw = 1},
	   #forwarding_parameters{
	      group =
		  [#destination_interface{interface = 'Access'},
		   ergw_pfcp:network_instance(InVrf)
		  ]
	     }
	  ],
    Update#sx_upd{
      pctx = ergw_pfcp_rules:add(
	       [{pdr, RuleName, PDR},
		{far, RuleName, FAR}], PCtx)};

build_sx_rule(Direction = uplink, Name, Definition, FilterInfo, URRs,
	      #sx_upd{pctx = PCtx0,
		      sctx = #tdf_ctx{in_vrf = InVrf, out_vrf = OutVrf} = SCtx
		     } = Update) ->
    [Precedence] = maps:get('Precedence', Definition, [1000]),
    RuleName = {Direction, Name},
    {PdrId, PCtx1} = ergw_pfcp:get_id(pdr, RuleName, PCtx0),
    {FarId, PCtx} = ergw_pfcp:get_id(far, RuleName, PCtx1),
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'Access'},
		  ergw_pfcp:network_instance(InVrf),
		  ergw_pfcp:ue_ip_address(src, SCtx)] ++
		 build_sx_filter(FilterInfo)
	    },
    PDR = [#pdr_id{id = PdrId},
	   #precedence{precedence = Precedence},
	   PDI,
	   #far_id{id = FarId}] ++
	[#urr_id{id = X} || X <- URRs],
    FAR = [#far_id{id = FarId},
	    #apply_action{forw = 1},
	    #forwarding_parameters{
	       group =
		   [#destination_interface{interface = 'SGi-LAN'},
		    ergw_pfcp:network_instance(OutVrf)
		   ]
	       ++ build_sx_redirect(maps:get('Redirect-Information', Definition, undefined))
	      }
	  ],
    Update#sx_upd{
      pctx = ergw_pfcp_rules:add(
	       [{pdr, RuleName, PDR},
		{far, RuleName, FAR}], PCtx)};

%% ===========================================================================

build_sx_rule(_Direction, Name, _Definition, _FlowInfo, _URRs, Update) ->
    sx_rule_error({system_error, Name}, Update).

get_rule_urrs(D, #sx_upd{pctx = PCtx}) ->
    RGs =
	lists:foldl(
	  fun({K, RG}, Acc) ->
		  case maps:get(K, D, undefined) of
		      [1] -> ergw_pfcp:get_urr_group(get_rating_group(RG, D), PCtx) ++ Acc;
		      _   -> Acc
		  end
	  end, ergw_pfcp:get_urr_group('IP-CAN', PCtx),
	  [{'Online',  'Online-Rating-Group'},
	   {'Offline', 'Offline-Rating-Group'}]),
    lists:usort(RGs).

%% 'Granted-Service-Unit' => [#{'CC-Time' => [14400],'CC-Total-Octets' => [10485760]}],
%% 'Rating-Group' => [3000],'Result-Code' => ?'DIAMETER_BASE_RESULT-CODE_SUCCESS',
%% 'Time-Quota-Threshold' => [1440],
%% 'Validity-Time' => [600],
%% 'Volume-Quota-Threshold' => [921600]}],

seconds_to_sntp_time(Sec) ->
    if Sec >= 2085978496 ->
	    Sec - 2085978496;
       true ->
	    Sec + 2208988800
    end.

sntp_time_to_seconds(SNTP) ->
    if SNTP >= 2208988800 ->
	    SNTP - 2208988800;
       true ->
	    SNTP + 2085978496
    end.

%% build_sx_usage_rule_4/4
build_sx_usage_rule_4(time, #{'CC-Time' := [Time]}, _,
		    #{measurement_method := MM,
		      reporting_triggers := RT} = URR) ->
    URR#{measurement_method => MM#measurement_method{durat = 1},
	 reporting_triggers => RT#reporting_triggers{time_quota = 1},
	 time_quota => #time_quota{quota = Time}};

build_sx_usage_rule_4(time_quota_threshold,
		    #{'CC-Time' := [Time]}, #{'Time-Quota-Threshold' := [TimeThreshold]},
		    #{reporting_triggers := RT} = URR)
  when Time > TimeThreshold ->
    URR#{reporting_triggers => RT#reporting_triggers{time_threshold = 1},
	 time_threshold => #time_threshold{threshold = Time - TimeThreshold}};

build_sx_usage_rule_4(total_octets, #{'CC-Total-Octets' := [Volume]}, _,
		    #{measurement_method := MM,
		      reporting_triggers := RT} = URR) ->
    maps:update_with(volume_quota, fun(V) -> V#volume_quota{total = Volume} end,
		     #volume_quota{total = Volume},
		     URR#{measurement_method => MM#measurement_method{volum = 1},
			  reporting_triggers => RT#reporting_triggers{volume_quota = 1}});
build_sx_usage_rule_4(input_octets, #{'CC-Input-Octets' := [Volume]}, _,
		    #{measurement_method := MM,
		      reporting_triggers := RT} = URR) ->
    maps:update_with(volume_quota, fun(V) -> V#volume_quota{uplink = Volume} end,
		     #volume_quota{uplink = Volume},
		     URR#{measurement_method => MM#measurement_method{volum = 1},
			  reporting_triggers => RT#reporting_triggers{volume_quota = 1}});
build_sx_usage_rule_4(output_octets, #{'CC-Output-Octets' := [Volume]}, _,
		    #{measurement_method := MM,
		      reporting_triggers := RT} = URR) ->
    maps:update_with(volume_quota, fun(V) -> V#volume_quota{downlink = Volume} end,
		     #volume_quota{downlink = Volume},
		     URR#{measurement_method => MM#measurement_method{volum = 1},
			  reporting_triggers => RT#reporting_triggers{volume_quota = 1}});

build_sx_usage_rule_4(total_quota_threshold,
		    #{'CC-Total-Octets' := [Volume]},
		    #{'Volume-Quota-Threshold' := [Threshold]},
		    #{reporting_triggers := RT} = URR)
  when Volume > Threshold ->
    VolumeThreshold = Volume - Threshold,
    maps:update_with(volume_threshold, fun(V) -> V#volume_threshold{total = VolumeThreshold} end,
		     #volume_threshold{total = VolumeThreshold},
		     URR#{reporting_triggers => RT#reporting_triggers{volume_threshold = 1}});
build_sx_usage_rule_4(input_quota_threshold,
		    #{'CC-Input-Octets' := [Volume]},
		    #{'Volume-Quota-Threshold' := [Threshold]},
		    #{reporting_triggers := RT} = URR)
  when Volume > Threshold ->
    VolumeThreshold = Volume - Threshold,
    maps:update_with(volume_threshold, fun(V) -> V#volume_threshold{uplink = VolumeThreshold} end,
		     #volume_threshold{uplink = VolumeThreshold},
		     URR#{reporting_triggers => RT#reporting_triggers{volume_threshold = 1}});
build_sx_usage_rule_4(output_quota_threshold,
		    #{'CC-Output-Octets' := [Volume]},
		    #{'Volume-Quota-Threshold' := [Threshold]},
		    #{reporting_triggers := RT} = URR)
  when Volume > Threshold ->
    VolumeThreshold = Volume - Threshold,
    maps:update_with(volume_threshold, fun(V) -> V#volume_threshold{downlink = VolumeThreshold} end,
		     #volume_threshold{downlink = VolumeThreshold},
		     URR#{reporting_triggers => RT#reporting_triggers{volume_threshold = 1}});

build_sx_usage_rule_4(monitoring_time, #{'Tariff-Time-Change' := [TTC]}, _, URR) ->
    Time = seconds_to_sntp_time(
	     calendar:datetime_to_gregorian_seconds(TTC) - ?SECONDS_FROM_0_TO_1970),   %% 1970
    URR#{monitoring_time => #monitoring_time{time = Time}};

build_sx_usage_rule_4(Type, _, _, URR) ->
    ?LOG(warning, "build_sx_usage_rule_4: not handling ~p", [Type]),
    URR.

pfcp_to_context_event([], M) ->
    M;
pfcp_to_context_event([{ChargingKey, Ev}|T], M) ->
    pfcp_to_context_event(T,
			  maps:update_with(Ev, [ChargingKey|_], [ChargingKey], M)).

%% pfcp_to_context_event/1
pfcp_to_context_event(Evs) ->
    pfcp_to_context_event(Evs, #{}).

pctx_update_from_ctx(PCtx, #context{'Idle-Timeout' = IdleTimeout})
  when is_integer(IdleTimeout) ->
    %% UP timer is measured in seconds
    PCtx#pfcp_ctx{up_inactivity_timer = IdleTimeout div 1000};
pctx_update_from_ctx(PCtx, _) ->
    %% if 'Idle-Timeout' /= integer, it is not set
    PCtx#pfcp_ctx{up_inactivity_timer = undefined}.

pfcp_pctx_update(#pfcp_ctx{up_inactivity_timer = UPiTnew} = PCtx,
		 #pfcp_ctx{up_inactivity_timer = UPiTold}, IEs)
  when UPiTold /= UPiTnew ->
    update_m_rec(ergw_pfcp:up_inactivity_timer(PCtx), IEs);
pfcp_pctx_update(_, _, IEs) ->
    IEs.

handle_validity_time(ChargingKey, #{'Validity-Time' := {abs, AbsTime}}, PCtx, _) ->
    ergw_pfcp:set_timer(AbsTime, {ChargingKey, validity_time}, PCtx);
handle_validity_time(_, _, PCtx, _) ->
    PCtx.

%% build_sx_usage_rule/3
build_sx_usage_rule(_K, #{'Rating-Group' := [RatingGroup],
			  'Granted-Service-Unit' := [GSU],
			  'Update-Time-Stamp' := UpdateTS} = GCU,
		    #sx_upd{pctx = PCtx0} = Update) ->
    ChargingKey = {online, RatingGroup},
    {UrrId, PCtx1} = ergw_pfcp:get_urr_id(ChargingKey, [RatingGroup], ChargingKey, PCtx0),
    PCtx2 = handle_validity_time(ChargingKey, GCU, PCtx1, Update),

    URR0 = #{urr_id => #urr_id{id = UrrId},
	     measurement_method => #measurement_method{},
	     reporting_triggers => #reporting_triggers{},
	     'Update-Time-Stamp' => UpdateTS},
    {URR1, PCtx} =
	case ergw_pfcp:get_urr_ids([{offline, RatingGroup}], PCtx2) of
	    [undefined] ->
		%% if this is an online only rule, do nothing
		{URR0, PCtx2};
	    [OffId] when is_integer(OffId)->
		%% if the same rule is use for offline and online reporting add a link
		build_sx_linked_rule(URR0, PCtx2)
	end,
    URR = lists:foldl(build_sx_usage_rule_4(_, GSU, GCU, _), URR1,
		      [time, time_quota_threshold,
		       total_octets, input_octets, output_octets,
		       total_quota_threshold, input_quota_threshold, output_quota_threshold,
		       monitoring_time]),

    ?LOG(debug, "URR: ~p", [URR]),
    Update#sx_upd{
      pctx = ergw_pfcp_rules:add(urr, ChargingKey, URR, PCtx)};
build_sx_usage_rule(_, _, Update) ->
    Update.

build_ipcan_rule(Update) ->
    build_ipcan_rule(ergw_charging:is_enabled(offline), Update).

%% build IP-CAN rule for offline charging
build_ipcan_rule(true, #sx_upd{pctx = PCtx0} = Update) ->
    RuleName = {offline, 'IP-CAN'},
    %% TBD: Offline Charging Rules at the IP-CAL level need to be seperated
    %%      by Charging-Id (maps to ARP/QCI combi)
    {UrrId, PCtx} = ergw_pfcp:get_urr_id(RuleName, ['IP-CAN'], RuleName, PCtx0),

    URR = [#urr_id{id = UrrId},
	   #measurement_method{volum = 1, durat = 1},
	   #reporting_triggers{}],

    ?LOG(debug, "URR: ~p", [URR]),
    Update#sx_upd{pctx = ergw_pfcp_rules:add(urr, RuleName, URR, PCtx)};
build_ipcan_rule(_, Update) ->
    Update.

build_sx_monitor_rule(Level, Monitors, Update) ->
    maps:fold(build_sx_monitor_rule(Level, _, _, _), Update, Monitors).

%% TBD: merging offline rules with identical timeout.... maybe
build_sx_monitor_rule('IP-CAN', Service, {periodic, Time, _Opts} = _Definition,
		      #sx_upd{monitors = Monitors0, pctx = PCtx0} = Update) ->
    ?LOG(debug, "Sx Monitor Rule: ~p", [_Definition]),

    RuleName = {monitor, 'IP-CAN', Service},
    {UrrId, PCtx} = ergw_pfcp:get_urr_id(RuleName, ['IP-CAN'], RuleName, PCtx0),

    URR = [#urr_id{id = UrrId},
	   #measurement_method{volum = 1, durat = 1},
	   #reporting_triggers{periodic_reporting = 1},
	   #measurement_period{period = Time}],

    ?LOG(debug, "URR: ~p", [URR]),
    Monitors1 = update_m_key('IP-CAN', UrrId, Monitors0),
    Monitors = Monitors1#{{urr, UrrId}  => Service},
    Update#sx_upd{
      pctx = ergw_pfcp_rules:add(urr, RuleName, URR, PCtx),
      monitors = Monitors};

build_sx_monitor_rule('Offline', Service, {periodic, Time, _Opts} = Definition,
		      #sx_upd{monitors = Monitors0, pctx = PCtx0} = Update) ->
    ?LOG(debug, "Sx Offline Monitor URR: ~p:~p", [Service, Definition]),

    RuleName = {offline, 'IP-CAN'},
    %% TBD: Offline Charging Rules at the IP-CAL level need to be seperated
    %%      by Charging-Id (maps to ARP/QCI combi)
    {UrrId, PCtx1} = ergw_pfcp:get_urr_id(RuleName, ['IP-CAN'], RuleName, PCtx0),

    URR = [#urr_id{id = UrrId},
	   #measurement_method{volum = 1, durat = 1},
	   #reporting_triggers{periodic_reporting = 1},
	   #measurement_period{period = Time}],
    ?LOG(debug, "URR: ~p", [URR]),
    URRUpd =
	fun (X0) ->
		X = X0#{measurement_period => #measurement_period{period = Time}},
		maps:update_with(
		  reporting_triggers,
		  fun (T) -> T#reporting_triggers{periodic_reporting = 1} end, X)
	end,
    PCtx = ergw_pfcp_rules:update_with(urr, RuleName, URRUpd, URR, PCtx1),

    Monitors1 = update_m_key('Offline', UrrId, Monitors0),
    Monitors = Monitors1#{{urr, UrrId}  => Service},
    Update#sx_upd{pctx = PCtx, monitors = Monitors};

build_sx_monitor_rule(Level, Service, Definition, Update) ->
    ?LOG(error, "Sx Monitor URR: ~p:~p:~p", [Level, Service, Definition]),
    sx_rule_error({system_error, Definition}, Update).

update_m_key(Key, Value, Map) ->
    maps:update_with(Key, [Value | _], [Value], Map).

update_m_rec(Record, Map) when is_tuple(Record) ->
    maps:update_with(element(1, Record), [Record | _], [Record], Map).

register_ctx_ids(Handler, #pfcp_ctx{seid = #seid{cp = SEID}}) ->
    Keys = [{seid, SEID}],
    gtp_context_reg:register(Keys, Handler, self()).

register_ctx_ids(Handler,
		 #context{local_data_endp = LocalDataEndp},
		 #pfcp_ctx{seid = #seid{cp = SEID}} = PCtx) ->
    Keys = [{seid, SEID} |
	    [ergw_pfcp:ctx_teid_key(PCtx, #fq_teid{ip = LocalDataEndp#gtp_endp.ip,
						   teid = LocalDataEndp#gtp_endp.teid}) ||
		is_record(LocalDataEndp, gtp_endp)]],
    gtp_context_reg:register(Keys, Handler, self()).

create_sgi_session(PCtx, NodeCaps, PCC, Ctx0)
  when is_record(PCC, pcc_ctx) ->
    Ctx = ergw_pfcp:assign_data_teid(PCtx, NodeCaps, Ctx0),
    register_ctx_ids(gtp_context, Ctx, PCtx),
    session_establishment_request(PCC, PCtx, Ctx).

modify_sgi_session(PCC, URRActions, Opts, Ctx, PCtx0)
  when is_record(PCC, pcc_ctx), is_record(PCtx0, pfcp_ctx) ->
    {SxRules0, SxErrors, PCtx} = build_sx_rules(PCC, Opts, PCtx0, Ctx),
    SxRules =
	lists:foldl(
	  fun({offline, _}, SxR) ->
		  SxR#{query_urr => build_query_usage_report(offline, PCtx)};
	     (_, SxR) ->
		  SxR
	  end, SxRules0, URRActions),

    ?LOG(debug, "SxRules: ~p~n", [SxRules]),
    ?LOG(debug, "SxErrors: ~p~n", [SxErrors]),
    ?LOG(debug, "PCtx: ~p~n", [PCtx]),
    session_modification_request(PCtx, SxRules, Ctx).

create_tdf_session(PCtx, _NodeCaps, PCC, Ctx)
  when is_record(PCC, pcc_ctx), is_record(Ctx, tdf_ctx) ->
    register_ctx_ids(tdf, PCtx),
    session_establishment_request(PCC, PCtx, Ctx).

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
    C#{'Time-First-Usage' =>
	     [calendar:gregorian_seconds_to_datetime(sntp_time_to_seconds(TS)
						     + ?SECONDS_FROM_0_TO_1970)]};
cev_to_rf(_, #time_of_last_packet{time = TS}, service_data, C) ->
    C#{'Time-Last-Usage' =>
	     [calendar:gregorian_seconds_to_datetime(sntp_time_to_seconds(TS)
						     + ?SECONDS_FROM_0_TO_1970)]};
cev_to_rf(_, #end_time{time = TS}, _, C) ->
    C#{'Change-Time' =>
	     [calendar:gregorian_seconds_to_datetime(sntp_time_to_seconds(TS)
						     + ?SECONDS_FROM_0_TO_1970)]};
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
      'RAN-Start-Timestamp' =>
	  [calendar:gregorian_seconds_to_datetime(sntp_time_to_seconds(Start)
						  + ?SECONDS_FROM_0_TO_1970)],
      'RAN-End-Timestamp' =>
	  [calendar:gregorian_seconds_to_datetime(sntp_time_to_seconds(End)
						  + ?SECONDS_FROM_0_TO_1970)],
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

fold_usage_report_1(Fun, #usage_report_smr{group = UR}, Acc) ->
    Fun(UR, Acc);
fold_usage_report_1(Fun, #usage_report_sdr{group = UR}, Acc) ->
    Fun(UR, Acc);
fold_usage_report_1(Fun, #usage_report_srr{group = UR}, Acc) ->
    Fun(UR, Acc).

foldl_usage_report(_Fun, Acc, []) ->
    Acc;
foldl_usage_report(Fun, Acc, [H|T]) ->
    foldl_usage_report(Fun, fold_usage_report_1(Fun, H, Acc), T);
foldl_usage_report(Fun, Acc, URR) when is_tuple(URR) ->
    fold_usage_report_1(Fun, URR, Acc);
foldl_usage_report(_Fun, Acc, undefined) ->
    Acc.

init_charging_events() ->
    {[], [], []}.

%% usage_report_to_charging_events/4
usage_report_to_charging_events({online, RatingGroup}, Report,
				ChargeEv, {On, _, _} = Ev)
  when is_integer(RatingGroup), is_map(Report) ->
    setelement(1, Ev, [Report#{'Rating-Group' => RatingGroup,
			       'Charge-Event' => ChargeEv} | On]);
usage_report_to_charging_events({offline, RatingGroup}, Report,
				ChargeEv, {_, Off, _} = Ev)
  when is_map(Report) ->
    setelement(2, Ev, [Report#{'Rating-Group' => RatingGroup,
			       'Charge-Event' => ChargeEv} | Off]);
usage_report_to_charging_events({monitor, Level, Service} = _K,
				Report, ChargeEv, {_, _, Mon} = Ev)
  when is_map(Report) ->
    setelement(3, Ev, [Report#{'Service-Id' => Service,
			       'Level' => Level,
			       'Charge-Event' => ChargeEv} | Mon]);
usage_report_to_charging_events(_K, _V, _ChargeEv, Ev) ->
    Ev.

%% usage_report_to_charging_events/3
usage_report_to_charging_events(URR, ChargeEv, PCtx)
  when is_record(PCtx, pfcp_ctx) ->
    UrrIds = ergw_pfcp:get_urr_ids(PCtx),
    foldl_usage_report(
      fun (#{urr_id := #urr_id{id = Id}} = Report, Ev) ->
	      usage_report_to_charging_events(maps:get(Id, UrrIds, undefined), Report, ChargeEv, Ev)
      end,
      init_charging_events(), URR).

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

apn_opts(APN, Context) ->
    case apn(APN) of
	false -> throw(?CTX_ERR(?FATAL, missing_or_unknown_apn, Context));
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

%% select_upf/2
select_upf(Candidates, #context{apn = APN} = Ctx) ->
    Opts = apn_opts(APN, Ctx),
    {Pid, NodeCaps, VRF, Pools} =
	select_by_caps(Candidates, Opts, [], Ctx),

    %% TBD: smarter v4/v6 pool select
    Pool = select(random, Pools),

    {{Pid, NodeCaps, Opts}, Ctx#context{vrf = VRF, ipv4_pool = Pool, ipv6_pool = Pool}}.

%% reselect_upf/4
reselect_upf(Candidates, SOpts, Ctx, UPinfo0) ->
    IP4 = maps:get('Framed-Pool', SOpts, Ctx#context.ipv4_pool),
    IP6 = maps:get('Framed-IPv6-Pool', SOpts, Ctx#context.ipv6_pool),
    reselect_upf_(Candidates, Ctx, Ctx#context{ipv4_pool = IP4, ipv6_pool = IP6}, UPinfo0).

reselect_upf_(_, Ctx, Ctx, {Pid, NodeCaps, APNOpts}) ->
    {ok, PCtx, _} = ergw_sx_node:attach(Pid, Ctx),
    {PCtx, NodeCaps, APNOpts, Ctx};

reselect_upf_(Candidates, _, #context{ipv4_pool = IP4, ipv6_pool = IP6} = Ctx, {_, _, Opts}) ->
    Pools = ordsets:from_list([IP4 || is_binary(IP4)] ++ [IP6 || is_binary(IP6)]),
    {Pid, NodeCaps, VRF, _} =
	select_by_caps(Candidates, Opts, Pools, Ctx),
    {ok, PCtx, _} = ergw_sx_node:attach(Pid, Ctx),
    {PCtx, NodeCaps, Opts, Ctx#context{vrf = VRF}}.

%% common_caps/3
common_caps({WVRFs, WPools}, {HVRFs, HPools}, true) ->
    VRFs = maps:with(WVRFs, HVRFs),
    Pools = ordsets:intersection(WPools, HPools),
    {maps:size(VRFs) /= 0 andalso length(Pools) /=0, VRFs, Pools};
common_caps({WVRFs, WPools}, {HVRFs, HPools}, false) ->
    VRFs = maps:with(WVRFs, HVRFs),
    {maps:size(VRFs) /= 0 andalso ordsets:is_subset(WPools, HPools), VRFs, WPools}.

%% common_caps/5
common_caps(_, [], _Available, _AnyPool, Candidates) ->
    Candidates;
common_caps(Wanted, [{Node, _, _, _, _} = UPF|Next], Available, AnyPool, Candidates)
  when is_map_key(Node, Available) ->
    {_, NodeCaps} = maps:get(Node, Available),
    case common_caps(Wanted, NodeCaps, AnyPool) of
	{true, _, _} ->
	    [UPF|common_caps(Wanted, Next, Available, AnyPool,Candidates)];
	{false, _, _} ->
	    common_caps(Wanted, Next, Available, AnyPool, Candidates)
    end;
common_caps(Wanted, [_|Next], Available, AnyPool, Candidates) ->
    common_caps(Wanted, Next, Available, AnyPool, Candidates).

select_by_caps(Candidates, #{vrfs := VRFs, ip_pools := Pools}, [], Context) ->
    Wanted = {VRFs, ordsets:from_list(Pools)},
    filter_by_caps(Candidates, Wanted, true, Context);

select_by_caps(Candidates, #{vrfs := VRFs, ip_pools := Pools}, WantPools, Context) ->
    ordsets:is_subset(WantPools, Pools) orelse
	    %% pool not available
	throw(?CTX_ERR(?FATAL, no_resources_available, Context)),

    Wanted = {VRFs, WantPools},
    filter_by_caps(Candidates, Wanted, false, Context).

filter_by_caps(Candidates, Wanted, AnyPool, Context) ->
    Available = ergw_sx_node_reg:available(),
    Eligible = common_caps(Wanted, Candidates, Available, AnyPool, []),
    length(Eligible) /= 0 orelse
	throw(?CTX_ERR(?FATAL, no_resources_available, Context)),
    {{Node, _, _}, _} = ergw_node_selection:snaptr_candidate(Eligible),
    {Pid, NodeCaps} = maps:get(Node, Available),
    {_, SVRFs, SPools} = common_caps(Wanted, NodeCaps, AnyPool),
    VRF = maps:get(select(random, maps:keys(SVRFs)), SVRFs),
    {Pid, NodeCaps, VRF, SPools}.

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

init_session_pool(#context{ipv4_pool = undefined, ipv6_pool = undefined}, Session) ->
    Session;
init_session_pool(#context{ipv4_pool = IPv4Pool, ipv6_pool = undefined}, Session) ->
    Session#{'Framed-Pool' => IPv4Pool};
init_session_pool(#context{ipv4_pool = undefined, ipv6_pool = IPv6Pool}, Session) ->
    Session#{'Framed-IPv6-Pool' => IPv6Pool};
init_session_pool(#context{ipv4_pool = IPv4Pool, ipv6_pool = IPv6Pool}, Session) ->
    Session#{'Framed-Pool' => IPv4Pool, 'Framed-IPv6-Pool' => IPv6Pool}.

init_session_ue_ifid({_, _, APNOpts}, #{'3GPP-PDP-Type' := Type} = Session)
  when Type =:= 'IPv6'; Type =:= 'IPv4v6' ->
    ReqIPv6 = maps:get('Requested-IPv6-Prefix', Session, {?ZERO_IPv6, 64}),
    IfId = ue_interface_id(ReqIPv6, APNOpts),
    Session#{'Framed-Interface-Id' => IfId};
init_session_ue_ifid(_UPinfo, Session) ->
    Session.

init_session_ip_opts(UPinfo, Context, Session0) ->
    Session = init_session_pool(Context, Session0),
    init_session_ue_ifid(UPinfo, Session).

request_alloc({ReqIPv4, PrefixLen}, Opts, #context{ipv4_pool = Pool})
  when ?IS_IPv4(ReqIPv4) ->
    Request = case ReqIPv4 of
		  ?ZERO_IPv4 -> ipv4;
		  _          -> ReqIPv4
	      end,
    {Pool, Request, PrefixLen, Opts};
request_alloc({ReqIPv6, PrefixLen}, Opts, #context{ipv6_pool = Pool})
  when ?IS_IPv6(ReqIPv6) ->
    Request = case ReqIPv6 of
		  ?ZERO_IPv6 -> ipv6;
		  _          -> ReqIPv6
	      end,
    {Pool, Request, PrefixLen, Opts};
request_alloc(_ReqIP, _Opts, _Context) ->
    skip.

request_ip_alloc(ReqIPs, Opts, #context{local_control_tei = TEI} = Context) ->
    Req = [request_alloc(IP, Opts, Context) || IP <- ReqIPs],
    ergw_ip_pool:send_request(TEI, Req).

ip_alloc_result(skip, Acc) ->
    Acc;
ip_alloc_result({error, empty}, {Context, _}) ->
    throw(?CTX_ERR(?FATAL, all_dynamic_addresses_are_occupied, Context));
ip_alloc_result({error, taken}, {Context, _}) ->
    throw(?CTX_ERR(?FATAL, system_error, Context));
ip_alloc_result({error, undefined}, Acc) ->
    %% pool not defined
    Acc;
ip_alloc_result({error, Result}, Acc) ->
    ?LOG(error, "IP alloc failed with ~p", [Result]),
    Acc;
ip_alloc_result(AI, {Context, Opts0}) ->
    case ergw_ip_pool:ip(AI) of
	{IP, _} when ?IS_IPv4(IP) ->
	    Opts1 = maps:merge(Opts0, ergw_ip_pool:opts(AI)),
	    Opts = maps:put('Framed-IP-Address', IP, Opts1),
	    {Context#context{ms_v4 = AI}, Opts};
	{IP, _} = IPv6 when ?IS_IPv6(IP) ->
	    Opts1 = maps:merge(Opts0, ergw_ip_pool:opts(AI)),
	    Opts = Opts1#{'Framed-IPv6-Prefix' => ergw_inet:ipv6_prefix(IPv6),
			  'Framed-Interface-Id' => ergw_inet:ipv6_interface_id(IPv6)},
	    {Context#context{ms_v6 = AI}, Opts}
    end.

wait_ip_alloc_results(ReqIds, Opts0, Context) ->
    IPOpts = ['Framed-IP-Address', 'Framed-IPv6-Prefix', 'Framed-Interface-Id'],
    Opts = maps:without(IPOpts, Opts0),
    lists:foldl(fun ip_alloc_result/2, {Context, Opts}, ergw_ip_pool:wait_response(ReqIds)).

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

allocate_ips_result(ReqPDNType, Bearer, #context{ms_v4 = MSv4, ms_v6 = MSv6} = Context) ->
    allocate_ips_result(ReqPDNType, Bearer, ergw_ip_pool:ip(MSv4),
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

%% allocate_ips/6
allocate_ips(AllocInfo,
	     #{bearer_type := Bearer, prefered_bearer_type := PrefBearer} = APNOpts,
	     SOpts0, DualAddressBearerFlag, PCOReqOpts, Context0) ->
    {ReqPDNType, ReqMSv4, ReqMSv6} =
	session_ip_alloc(Bearer, PrefBearer, SOpts0, DualAddressBearerFlag, AllocInfo),

    SOpts1 = maps:merge(SOpts0, maps:with(?APNOpts, APNOpts)),

    ReqIPs = [normalize_ipv4(ReqMSv4),
	      normalize_ipv6(ReqMSv6)],
    ReqIds = request_ip_alloc(ReqIPs, PCOReqOpts, Context0),
    {Context, SOpts2} = wait_ip_alloc_results(ReqIds, SOpts1, Context0),

    {Result, PDNType} = allocate_ips_result(ReqPDNType, Bearer, Context),
    SOpts = maps:put('3GPP-PDP-Type', PDNType, SOpts2),

    DNS = if PDNType =:= 'IPv6' orelse PDNType =:= 'IPv4v6' ->
		  maps:get('DNS-Server-IPv6-Address', SOpts, []) ++          %% RFC 6911
		      maps:get('3GPP-IPv6-DNS-Servers', SOpts, []);          %% 3GPP
	     true ->
		  []
	  end,
    {Result, SOpts, Context#context{pdn_type = PDNType, dns_v6 = DNS}}.

%% release_context_ips/1
release_context_ips(#context{ms_v4 = MSv4, ms_v6 = MSv6} = Context) ->
    ergw_ip_pool:release([MSv4, MSv6]),
    Context#context{ms_v4 = undefined, ms_v6 = undefined}.

%%%===================================================================
%%% Protocol Configuation Options
%%%===================================================================

pco_ppp_ipcp_requested_opts({ms_dns1, <<0,0,0,0>>}, Opts) ->
    Opts#{'MS-Primary-DNS-Server' => true};
pco_ppp_ipcp_requested_opts({ms_dns2, <<0,0,0,0>>}, Opts) ->
    Opts#{'MS-Secondary-DNS-Server' => true};
pco_ppp_ipcp_requested_opts({ms_wins1, <<0,0,0,0>>}, Opts) ->
    Opts#{'MS-Primary-NBNS-Server' => true};
pco_ppp_ipcp_requested_opts({ms_wins2, <<0,0,0,0>>}, Opts) ->
    Opts#{'MS-Secondary-NBNS-Server' => true};
pco_ppp_ipcp_requested_opts(_, Opts) ->
    Opts.

pco_ppp_requested_opts({ipcp,'CP-Configure-Request', _Id, CpReqOpts}, Opts) ->
    lists:foldr(fun pco_ppp_ipcp_requested_opts/2, Opts, CpReqOpts);
pco_ppp_requested_opts({?'PCO-DNS-Server-IPv4-Address', <<>>}, Opts) ->
    Opts#{'MS-Primary-DNS-Server' => true,
	  'MS-Secondary-DNS-Server' => true};
pco_ppp_requested_opts({?'PCO-DNS-Server-IPv6-Address', <<>>}, Opts) ->
    Opts#{'DNS-Server-IPv6-Address' => true};
pco_ppp_requested_opts({?'PCO-P-CSCF-IPv4-Address', <<>>}, Opts) ->
    Opts#{'SIP-Servers-IPv4-Address-List' => true};
pco_ppp_requested_opts({?'PCO-P-CSCF-IPv6-Address', <<>>}, Opts) ->
    Opts#{'SIP-Servers-IPv6-Address-List' => true};
pco_ppp_requested_opts(_, Opts) ->
    Opts.

pco_requested_opts({0, Requested}, SOpts) ->
    Init = maps:with(['Framed-Interface-Id'], SOpts),
    lists:foldr(fun pco_ppp_requested_opts/2, Init, Requested);
pco_requested_opts(_, _) ->
    [].

session_to_ppp_ipcp_conf_resp(Verdict, Opt, IPCP) ->
    maps:update_with(Verdict, fun(O) -> [Opt|O] end, [Opt], IPCP).

session_to_ppp_ipcp_conf(#{'MS-Primary-DNS-Server' := DNS}, {ms_dns1, <<0,0,0,0>>}, IPCP) ->
    session_to_ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_dns1, ergw_inet:ip2bin(DNS)}, IPCP);
session_to_ppp_ipcp_conf(#{'MS-Secondary-DNS-Server' := DNS}, {ms_dns2, <<0,0,0,0>>}, IPCP) ->
    session_to_ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_dns2, ergw_inet:ip2bin(DNS)}, IPCP);
session_to_ppp_ipcp_conf(#{'MS-Primary-NBNS-Server' := DNS}, {ms_wins1, <<0,0,0,0>>}, IPCP) ->
    session_to_ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_wins1, ergw_inet:ip2bin(DNS)}, IPCP);
session_to_ppp_ipcp_conf(#{'MS-Secondary-NBNS-Server' := DNS}, {ms_wins2, <<0,0,0,0>>}, IPCP) ->
    session_to_ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_wins2, ergw_inet:ip2bin(DNS)}, IPCP);

session_to_ppp_ipcp_conf(_SessionOpts, Opt, IPCP) ->
    session_to_ppp_ipcp_conf_resp('CP-Configure-Reject', Opt, IPCP).

session_to_ppp_pco(SessionOpts, {pap, 'PAP-Authentication-Request', Id, _Username, _Password}, Opts) ->
    [{pap, 'PAP-Authenticate-Ack', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
session_to_ppp_pco(SessionOpts, {chap, 'CHAP-Response', Id, _Value, _Name}, Opts) ->
    [{chap, 'CHAP-Success', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
session_to_ppp_pco(SessionOpts, {ipcp,'CP-Configure-Request', Id, CpReqOpts}, Opts) ->
    CpRespOpts = lists:foldr(session_to_ppp_ipcp_conf(SessionOpts, _, _), #{}, CpReqOpts),
    maps:fold(fun(K, V, O) -> [{ipcp, K, Id, V} | O] end, Opts, CpRespOpts);

session_to_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv6-Address', <<>>}, Opts) ->
    [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
     || DNS <- maps:get('DNS-Server-IPv6-Address', SessionOpts, [])]
	++ [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
	    || DNS <- maps:get('3GPP-IPv6-DNS-Servers', SessionOpts, [])]
	++ Opts;
session_to_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv4-Address', <<>>}, Opts) ->
    lists:foldr(fun(Key, O) ->
			case maps:find(Key, SessionOpts) of
			    {ok, DNS} ->
				[{?'PCO-DNS-Server-IPv4-Address', ergw_inet:ip2bin(DNS)} | O];
			    _ ->
				O
			end
		end, Opts, ['MS-Secondary-DNS-Server', 'MS-Primary-DNS-Server']);
session_to_ppp_pco(SessionOpts, {?'PCO-P-CSCF-IPv4-Address', <<>>}, Opts) ->
    [{?'PCO-P-CSCF-IPv4-Address', ergw_inet:ip2bin(IP)}
     || IP <- maps:get('SIP-Servers-IPv4-Address-List', SessionOpts, [])]
	++ Opts;
session_to_ppp_pco(SessionOpts, {?'PCO-P-CSCF-IPv6-Address', <<>>}, Opts) ->
    [{?'PCO-P-CSCF-IPv6-Address', ergw_inet:ip2bin(IP)}
     || IP <- maps:get('SIP-Servers-IPv6-Address-List', SessionOpts, [])]
	++ Opts;
session_to_ppp_pco(_SessionOpts, PPPReqOpt, Opts) ->
    ?LOG(debug, "Apply PPP Opt: ~p", [PPPReqOpt]),
    Opts.

session_to_pco(SessionOpts, {0, Requested}) ->
    case lists:foldr(session_to_ppp_pco(SessionOpts, _, _), [], Requested) of
	[] -> undefined;
	Opts -> {0, Opts}
    end;
session_to_pco(_, _) ->
    undefined.

%%%===================================================================
%%% T-PDU functions
%%%===================================================================

send_g_pdu(PCtx, #gtp_endp{vrf = VRF, ip = SrcIP}, #fq_teid{ip = DstIP, teid = TEID}, Data) ->
    GTP = #gtp{version =v1, type = g_pdu, tei = TEID, ie = Data},
    PayLoad = gtp_packet:encode(GTP),
    UDP = ergw_inet:make_udp(
	    ergw_inet:ip2bin(SrcIP), ergw_inet:ip2bin(DstIP),
	    ?GTP1u_PORT, ?GTP1u_PORT, PayLoad),
    ergw_sx_node:send(PCtx, 'Access', VRF, UDP),
    ok.

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
       #context{local_data_endp = LocalDataEndp, remote_data_teid = RemoteDataTEID,
		ms_v6 = MSv6, dns_v6 = DNSv6}, PCtx) ->
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
    send_g_pdu(PCtx, LocalDataEndp, RemoteDataTEID, ICMPv6);

icmpv6(_TC, _FlowLabel, _SrcAddr, _DstAddr, _PayLoad, _Context, _PCtx) ->
    ?LOG(warning, "unhandeld ICMPv6 from ~p to ~p: ~p", [_SrcAddr, _DstAddr, _PayLoad]),
    ok.

%%
%%
%% Translating PCC Rules and Charging Information to PDRs, FARs and URRs
%% =====================================================================
%%
%% 1. translate current rules to PFCP
%% 2. calculate difference between new and old PFCP
%% 3. translate PFCP difference into rules
%%
%% It would be possible to tranalte GX events (Charging-Rule-Install/Remove)
%% directly into PFCP changes. But this a optimization for the future.
%%
%% URRs are special:
%% * quotas are consumed by the UPF, so simply resending them might not work
%% * updated quotas could be indentical to old values, yet the update needs to
%%   send to the UPF
%%
%% Online charing and rejected Rating-Groups (Result-Code != 2001)
%%
%% If Gy rejects a RG, the resulting PCC rules need to be removed (and reported
%% as such)
%%
%% Details:
%%
%% * every active PCC-Rule can have online, offline or no URR
%%
