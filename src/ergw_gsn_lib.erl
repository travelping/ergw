%% Copyright 2017,2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gsn_lib).

-compile({parse_transform, cut}).

-export([create_sgi_session/3, create_tdf_session/3,
	 usage_report_to_charging_events/3,
	 process_online_charging_events/4,
	 process_offline_charging_events/4,
	 process_offline_charging_events/5,
	 pfcp_to_context_event/1,
	 pcc_ctx_to_credit_request/1,
	 modify_sgi_session/5,
	 delete_sgi_session/3,
	 query_usage_report/2, query_usage_report/3,
	 choose_context_ip/3,
	 ip_pdu/3]).
-export([%%update_pcc_rules/2,
	 gx_events_to_pcc_ctx/4,
	 gy_events_to_pcc_ctx/3,
	 gy_events_to_pcc_rules/2,
	 gy_credit_report/1,
	 gy_credit_request/2,
	 gy_credit_request/3,
	 pcc_events_to_charging_rule_report/1]).
-export([pcc_ctx_has_rules/1]).

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
	    lager:warning("PFCP: Session Deletion failed with ~p",
			  [lager:pr(_Other, ?MODULE)]),
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

ctx_update_dp_seid(#{f_seid := #f_seid{seid = DP}},
		   #pfcp_ctx{seid = SEID} = PCtx) ->
    PCtx#pfcp_ctx{seid = SEID#seid{dp = DP}};
ctx_update_dp_seid(_, PCtx) ->
    PCtx.

%% use additional information from the Context to prefre V4 or V6....
choose_context_ip(IP4, _IP6, _Context)
  when is_binary(IP4) ->
    IP4;
choose_context_ip(_IP4, IP6, _Context)
  when is_binary(IP6) ->
    IP6.

session_establishment_request(PCC, PCtx0, Ctx) ->
    {ok, CntlNode, _} = ergw_sx_socket:id(),

    {SxRules, SxErrors, PCtx} = build_sx_rules(PCC, #{}, PCtx0, Ctx),
    lager:info("SxRules: ~p~n", [SxRules]),
    lager:info("SxErrors: ~p~n", [SxErrors]),
    lager:info("CtxPending: ~p~n", [Ctx]),

    IEs = update_m_rec(ergw_pfcp:f_seid(PCtx, CntlNode), SxRules),
    lager:info("IEs: ~p~n", [IEs]),

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

pcc_rules_to_credits(_K, #{'Rating-Group' := [RatingGroup], 'Online' := [1]},
			    Granted, Acc) ->
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
	    [RatingGroup] = maps:get('Rating-Group', V, [undefined]),
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

credits_to_pcc_rules(K, #{'Rating-Group' := [RatingGroup], 'Online' := [1]} = V,
			  Pools, {Rules, Removed}) ->
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
    lager:error("Invalid Tariff-Time \"~p\"", [Time]),
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

%% build_sx_rules/5
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
    Update2 = maps:fold(fun build_sx_monitor_rule/3, Update1, Monitors),
    Update3 = build_sx_charging_rule(PCC, PolicyRules, Update2),
    Update4 = maps:fold(fun build_sx_usage_rule/3, Update3, GrantedCredits),
    maps:fold(fun build_sx_rule/3, Update4, PolicyRules).

build_sx_ctx_rule(#sx_upd{
		     pctx =
			 #pfcp_ctx{cp_port = #gtp_port{ip = CpIP} = CpPort,
				   cp_tei = CpTEI} = PCtx0,
		     sctx = #context{
			       local_data_endp = LocalDataEndp,
			       ms_v6 = {{_,_,_,_,_,_,_,_},_}}
		    } = Update) ->
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
      pctx = ergw_pfcp:pfcp_rules_add(
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

build_sx_offline_charging_rule(_Name,
			       #{'Rating-Group' := [RatingGroup],
				 'Offline' := [1]} = Definition,
			       #pcc_ctx{acct_interim_interval = AcctInterimInterval,
					offline_charging_profile = OCPcfg},
			       #sx_upd{pctx = PCtx0} = Update) ->
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

    {UrrId, PCtx} = ergw_pfcp:get_urr_id(ChargingKey, [RatingGroup], ChargingKey, PCtx0),
    URR0 = #{urr_id => #urr_id{id = UrrId},
	     measurement_method => MM,
	     reporting_triggers => #reporting_triggers{periodic_reporting = 1},
	     measurement_period => #measurement_period{period = AcctInterimInterval}
	    },

    OCP = maps:get('Default', OCPcfg, #{}),
    URR = apply_charging_profile(URR0, OCP),

    lager:warning("Offline URR: ~p", [URR]),
    Update#sx_upd{
      pctx = ergw_pfcp:pfcp_rules_add(
	       [{urr, ChargingKey, URR}], PCtx)};

build_sx_offline_charging_rule(Name, #{'Offline' := [1]}, _PCC, Update) ->
    %% Offline without Rating-Group ???
    sx_rule_error({system_error, Name}, Update);
build_sx_offline_charging_rule(_Name, _Definition, _PCC, Update) ->
    Update.

build_sx_online_charging_rule(_Name,
			       #{'Rating-Group' := [RatingGroup], 'Online' := [1]},
			      _PCC, #sx_upd{pctx = PCtx} = Update) ->
    ChargingKey = {online, RatingGroup},
    Update#sx_upd{
      pctx = ergw_pfcp:pfcp_rules_add(
	       [{urr, ChargingKey, needed}], PCtx)};
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
      pctx = ergw_pfcp:pfcp_rules_add(
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
      pctx = ergw_pfcp:pfcp_rules_add(
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
      pctx = ergw_pfcp:pfcp_rules_add(
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
      pctx = ergw_pfcp:pfcp_rules_add(
	       [{pdr, RuleName, PDR},
		{far, RuleName, FAR}], PCtx)};

%% ===========================================================================

build_sx_rule(_Direction, Name, _Definition, _FlowInfo, _URRs, Update) ->
    sx_rule_error({system_error, Name}, Update).

get_rule_urrs(#{'Rating-Group' := [RatingGroup]}, #sx_upd{pctx = PCtx}) ->
    ergw_pfcp:get_urr_group(RatingGroup, PCtx) ++
	ergw_pfcp:get_urr_group('IP-CAN', PCtx);
get_rule_urrs(_Definition, _Update) ->
    [].

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

%% build_sx_usage_rule/4
build_sx_usage_rule(time, #{'CC-Time' := [Time]}, _,
		    #{measurement_method := MM,
		      reporting_triggers := RT} = URR) ->
    URR#{measurement_method => MM#measurement_method{durat = 1},
	 reporting_triggers => RT#reporting_triggers{time_quota = 1},
	 time_quota => #time_quota{quota = Time}};

build_sx_usage_rule(time_quota_threshold,
		    #{'CC-Time' := [Time]}, #{'Time-Quota-Threshold' := [TimeThreshold]},
		    #{reporting_triggers := RT} = URR)
  when Time > TimeThreshold ->
    URR#{reporting_triggers => RT#reporting_triggers{time_threshold = 1},
	 time_threshold => #time_threshold{threshold = Time - TimeThreshold}};

build_sx_usage_rule(total_octets, #{'CC-Total-Octets' := [Volume]}, _,
		    #{measurement_method := MM,
		      reporting_triggers := RT} = URR) ->
    maps:update_with(volume_quota, fun(V) -> V#volume_quota{total = Volume} end,
		     #volume_quota{total = Volume},
		     URR#{measurement_method => MM#measurement_method{volum = 1},
			  reporting_triggers => RT#reporting_triggers{volume_quota = 1}});
build_sx_usage_rule(input_octets, #{'CC-Input-Octets' := [Volume]}, _,
		    #{measurement_method := MM,
		      reporting_triggers := RT} = URR) ->
    maps:update_with(volume_quota, fun(V) -> V#volume_quota{uplink = Volume} end,
		     #volume_quota{uplink = Volume},
		     URR#{measurement_method => MM#measurement_method{volum = 1},
			  reporting_triggers => RT#reporting_triggers{volume_quota = 1}});
build_sx_usage_rule(output_octets, #{'CC-Output-Octets' := [Volume]}, _,
		    #{measurement_method := MM,
		      reporting_triggers := RT} = URR) ->
    maps:update_with(volume_quota, fun(V) -> V#volume_quota{downlink = Volume} end,
		     #volume_quota{downlink = Volume},
		     URR#{measurement_method => MM#measurement_method{volum = 1},
			  reporting_triggers => RT#reporting_triggers{volume_quota = 1}});

build_sx_usage_rule(total_quota_threshold,
		    #{'CC-Total-Octets' := [Volume]},
		    #{'Volume-Quota-Threshold' := [Threshold]},
		    #{reporting_triggers := RT} = URR)
  when Volume > Threshold ->
    VolumeThreshold = Volume - Threshold,
    maps:update_with(volume_threshold, fun(V) -> V#volume_threshold{total = VolumeThreshold} end,
		     #volume_threshold{total = VolumeThreshold},
		     URR#{reporting_triggers => RT#reporting_triggers{volume_threshold = 1}});
build_sx_usage_rule(input_quota_threshold,
		    #{'CC-Input-Octets' := [Volume]},
		    #{'Volume-Quota-Threshold' := [Threshold]},
		    #{reporting_triggers := RT} = URR)
  when Volume > Threshold ->
    VolumeThreshold = Volume - Threshold,
    maps:update_with(volume_threshold, fun(V) -> V#volume_threshold{uplink = VolumeThreshold} end,
		     #volume_threshold{uplink = VolumeThreshold},
		     URR#{reporting_triggers => RT#reporting_triggers{volume_threshold = 1}});
build_sx_usage_rule(output_quota_threshold,
		    #{'CC-Output-Octets' := [Volume]},
		    #{'Volume-Quota-Threshold' := [Threshold]},
		    #{reporting_triggers := RT} = URR)
  when Volume > Threshold ->
    VolumeThreshold = Volume - Threshold,
    maps:update_with(volume_threshold, fun(V) -> V#volume_threshold{downlink = VolumeThreshold} end,
		     #volume_threshold{downlink = VolumeThreshold},
		     URR#{reporting_triggers => RT#reporting_triggers{volume_threshold = 1}});

build_sx_usage_rule(monitoring_time, #{'Tariff-Time-Change' := [TTC]}, _, URR) ->
    Time = seconds_to_sntp_time(
	     calendar:datetime_to_gregorian_seconds(TTC) - ?SECONDS_FROM_0_TO_1970),   %% 1970
    URR#{monitoring_time => #monitoring_time{time = Time}};

build_sx_usage_rule(Type, _, _, URR) ->
    lager:warning("build_sx_usage_rule: not handling ~p", [Type]),
    URR.

pfcp_to_context_event([], M) ->
    M;
pfcp_to_context_event([{ChargingKey, Ev}|T], M) ->
    pfcp_to_context_event(T,
			  maps:update_with(Ev, [ChargingKey|_], [ChargingKey], M)).

%% pfcp_to_context_event/1
pfcp_to_context_event(Evs) ->
    pfcp_to_context_event(Evs, #{}).

handle_validity_time(ChargingKey, #{'Validity-Time' := {abs, AbsTime}}, PCtx, _) ->
    ergw_pfcp:set_timer(AbsTime, {ChargingKey, validity_time}, PCtx);
handle_validity_time(_, _, PCtx, _) ->
    PCtx.

%% build_sx_usage_rule/2
build_sx_usage_rule(_K, #{'Rating-Group' := [RatingGroup],
			  'Granted-Service-Unit' := [GSU],
			  'Update-Time-Stamp' := UpdateTS} = GCU,
		    #sx_upd{pctx = PCtx0} = Update) ->
    ChargingKey = {online, RatingGroup},
    {UrrId, PCtx1} = ergw_pfcp:get_urr_id(ChargingKey, [RatingGroup], ChargingKey, PCtx0),
    PCtx = handle_validity_time(ChargingKey, GCU, PCtx1, Update),

    URR0 = #{urr_id => #urr_id{id = UrrId},
	     measurement_method => #measurement_method{},
	     reporting_triggers => #reporting_triggers{},
	     'Update-Time-Stamp' => UpdateTS},
    URR = lists:foldl(build_sx_usage_rule(_, GSU, GCU, _), URR0,
		      [time, time_quota_threshold,
		       total_octets, input_octets, output_octets,
		       total_quota_threshold, input_quota_threshold, output_quota_threshold,
		       monitoring_time]),

    lager:warning("URR: ~p", [URR]),
    Update#sx_upd{
      pctx = ergw_pfcp:pfcp_rules_add(
	       [{urr, ChargingKey, URR}], PCtx)};
build_sx_usage_rule(_, _, Update) ->
    Update.

build_sx_monitor_rule(Service, {'IP-CAN', periodic, Time} = _Definition,
		      #sx_upd{monitors = Monitors0, pctx = PCtx0} = Update) ->
    lager:info("Sx Monitor Rule: ~p", [_Definition]),

    RuleName = {monitor, 'IP-CAN', Service},
    {UrrId, PCtx} = ergw_pfcp:get_urr_id(RuleName, ['IP-CAN'], RuleName, PCtx0),

    URR = [#urr_id{id = UrrId},
	   #measurement_method{volum = 1, durat = 1},
	   #reporting_triggers{periodic_reporting = 1},
	   #measurement_period{period = Time}],

    lager:warning("URR: ~p", [URR]),
    Monitors1 = update_m_key('IP-CAN', UrrId, Monitors0),
    Monitors = Monitors1#{{urr, UrrId}  => Service},
    Update#sx_upd{
      pctx = ergw_pfcp:pfcp_rules_add(
	       [{urr, RuleName, URR}], PCtx),
      monitors = Monitors};

build_sx_monitor_rule(Service, Definition, Update) ->
    lager:error("Monitor URR: ~p:~p", [Service, Definition]),
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

create_sgi_session(Candidates, PCC, Ctx0)
  when is_record(PCC, pcc_ctx) ->
    PCtx = ergw_sx_node:select_sx_node(Candidates, Ctx0),
    Ctx = ergw_pfcp:assign_data_teid(PCtx, Ctx0),
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

    lager:info("SxRules: ~p~n", [SxRules]),
    lager:info("SxErrors: ~p~n", [SxErrors]),
    lager:info("PCtx: ~p~n", [PCtx]),
    session_modification_request(PCtx, SxRules, Ctx).

create_tdf_session(Node, PCC, Ctx)
  when is_record(PCC, pcc_ctx), is_record(Ctx, tdf_ctx) ->
    PCtx = ergw_sx_node:attach(Node, Ctx),
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

init_sdc_from_session(Now, SessionOpts) ->
    Keys = ['Charging-Rule-Base-Name', 'QoS-Information',
	    '3GPP-User-Location-Info', '3GPP-RAT-Type',
	    '3GPP-SGSN-Address', '3GPP-SGSN-IPv6-Address'],
    SDC =
	maps:fold(fun(K, V, M) when K == '3GPP-User-Location-Info';
				    K == '3GPP-RAT-Type' ->
			  M#{K => [ergw_aaa_diameter:'3gpp_from_session'(K, V)]};
		     (K, V, M) when K == '3GPP-SGSN-Address';
				    K == '3GPP-SGSN-IPv6-Address' ->
			  M#{'SGSN-Address' => [V]};
		     (K, V, M) -> M#{K => [V]}
		 end,
		 #{}, maps:with(Keys, SessionOpts)),
    SDC#{'Change-Time' =>
	     [calendar:system_time_to_universal_time(Now + erlang:time_offset(), native)]}.

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
    optional_if_unset('Change-Condition', ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TIME_LIMIT', SDC);
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

cev_to_rf('Charge-Event', {_, 'qos-change'}, SDC) ->
    SDC#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_QOS_CHANGE'};
cev_to_rf('Charge-Event', {_, 'sgsn-sgw-change'}, SDC) ->
    SDC#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_SERVING_NODE_CHANGE'};
cev_to_rf('Charge-Event', {_, 'sgsn-sgw-plmn-id-change'}, SDC) ->
    SDC#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_SERVING_NODE_PLMN_CHANGE'};
cev_to_rf('Charge-Event', {_, 'user-location-info-change'}, SDC) ->
    SDC#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_USER_LOCATION_CHANGE'};
cev_to_rf('Charge-Event', {_, 'rat-change'}, SDC) ->
    SDC#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_RAT_CHANGE'};
cev_to_rf('Charge-Event', {_, 'ms-time-zone-change'}, SDC) ->
    SDC#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_UE_TIMEZONE_CHANGE'};
cev_to_rf('Charge-Event', {_, 'cgi-sai-change'}, SDC) ->
    SDC#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_CGI_SAI_CHANGE'};
cev_to_rf('Charge-Event', {_, 'rai-change'}, SDC) ->
    SDC#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_RAI_CHANGE'};
cev_to_rf('Charge-Event', {_, 'ecgi-change'}, SDC) ->
    SDC#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_ECGI_CHANGE'};
cev_to_rf('Charge-Event', {_, 'tai-change'}, SDC) ->
    SDC#{'Change-Condition' => ?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TAI_CHANGE'};

cev_to_rf('Rating-Group' = Key, RatingGroup, SDC) ->
    SDC#{Key => [RatingGroup]};
cev_to_rf(_, #start_time{time = TS}, SDC) ->
    SDC#{'Time-First-Usage' =>
	     [calendar:gregorian_seconds_to_datetime(sntp_time_to_seconds(TS)
						     + ?SECONDS_FROM_0_TO_1970)]};
cev_to_rf(_, #end_time{time = TS}, SDC) ->
    SDC#{'Time-Last-Usage' =>
	     [calendar:gregorian_seconds_to_datetime(sntp_time_to_seconds(TS)
						     + ?SECONDS_FROM_0_TO_1970)]};
cev_to_rf(usage_report_trigger, #usage_report_trigger{} = Trigger, SDC) ->
    cev_to_rf_change_condition(record_info(fields, usage_report_trigger),
			       tl(tuple_to_list(Trigger)), SDC);
cev_to_rf(_, #volume_measurement{uplink = UL, downlink = DL}, SDC) ->
    SDC#{'Accounting-Input-Octets'  => opt_int(UL),
	 'Accounting-Output-Octets' => opt_int(DL)};
cev_to_rf(_, #duration_measurement{duration = Duration}, SDC) ->
    SDC#{'Time-Usage' => opt_int(Duration)};
cev_to_rf(_, _, SDC) ->
    SDC.

%% charging_event_to_rf/2
charging_event_to_rf(#{usage_report_trigger :=
			   #usage_report_trigger{perio = Periodic}} = URR, SDCInit, Reason0) ->
    Reason = if Periodic == 1 -> cdr_closure;
		true          -> Reason0
	     end,
    SDC = maps:fold(fun cev_to_rf/3, SDCInit, URR),
    {SDC, Reason}.

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
  when is_integer(RatingGroup), is_map(Report) ->
    setelement(2, Ev, [Report#{'Rating-Group' => RatingGroup,
			       'Charge-Event' => ChargeEv} | Off]);
%% usage_report_to_charging_events({monitor, Level, Service}, Report,
%% 				ChargeEv, {_, _, Mon} = Ev)
%%   when is_map(Report) ->
%%     Ev;
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


process_offline_charging_events(Reason, Ev, Now, Session)
  when is_list(Ev) ->
    process_offline_charging_events(Reason, Ev, Now, ergw_aaa_session:get(Session), Session).

process_offline_charging_events(Reason0, Ev, Now, SessionOpts, Session)
  when is_list(Ev) ->
    SDCInit = init_sdc_from_session(Now, SessionOpts),
    {Update, Reason} = lists:mapfoldl(charging_event_to_rf(_, SDCInit, _), Reason0, Ev),

    SOpts = #{now => Now, async => true, 'gy_event' => Reason},
    Request = #{'service_data' => Update},
    case Reason of
	{terminate, _} ->
	    ergw_aaa_session:invoke(Session, Request, {rf, 'Terminate'}, SOpts);
	_ when length(Update) /= 0 ->
	    ergw_aaa_session:invoke(Session, Request, {rf, 'Update'}, SOpts);
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
pcc_rules_to_credit_request(_K, #{'Rating-Group' := [RatingGroup], 'Online' := [1]}, Acc) ->
    RG = empty,
    maps:update_with(RatingGroup, fun(V) -> V end, RG, Acc);
pcc_rules_to_credit_request(_K, V, Acc) ->
    lager:warning("No Rating Group: ~p", [V]),
    Acc.

%% pcc_ctx_to_credit_request/1
pcc_ctx_to_credit_request(#pcc_ctx{rules = Rules}) ->
    lager:debug("Rules: ~p", [Rules]),
    CreditReq = maps:fold(fun pcc_rules_to_credit_request/3, #{}, Rules),
    lager:debug("CreditReq: ~p", [CreditReq]),
    CreditReq.

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
    lager:warning("unhandled T-PDU: ~p", [Data]),
    ok.

%% IPv6 Router Solicitation
icmpv6(TC, FlowLabel, _SrcAddr, ?'IPv6 All Routers LL',
       <<?'ICMPv6 Router Solicitation':8, _Code:8, _CSum:16, _/binary>>,
       #context{local_data_endp = LocalDataEndp, remote_data_teid = RemoteDataTEID,
		ms_v6 = MSv6, dns_v6 = DNSv6}, PCtx) ->
    {Prefix, PLen} = ergw_inet:ipv6_interface_id(MSv6, ?NULL_INTERFACE_ID),

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
    lager:warning("unhandeld ICMPv6 from ~p to ~p: ~p", [_SrcAddr, _DstAddr, _PayLoad]),
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
