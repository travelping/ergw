%% Copyright 2017,2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gsn_lib).

-compile({parse_transform, cut}).

-export([create_sgi_session/3,
	 usage_report_to_monitoring_report/2,
	 usage_report_to_charging_events/2,
	 process_online_charging_events/4,
	 process_offline_charging_events/4,
	 process_offline_charging_events/5,
	 pcc_rules_to_credit_request/1,
	 modify_sgi_session/4,
	 delete_sgi_session/2,
	 query_usage_report/1, query_usage_report/2,
	 trigger_offline_usage_report/2,
	 choose_context_ip/3,
	 ip_pdu/2]).
-export([update_pcc_rules/2, session_events/3]).
-export([find_sx_by_id/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include("include/ergw.hrl").

-record(sx_ids, {cnt = #{}, idmap = #{}}).
-record(sx_upd, {errors = [], monitors = #{}, pctx = #pfcp_ctx{}, sctx}).

-define(SECONDS_PER_DAY, 86400).
-define(DAYS_FROM_0_TO_1970, 719528).
-define(SECONDS_FROM_0_TO_1970, (?DAYS_FROM_0_TO_1970*?SECONDS_PER_DAY)).

%%%===================================================================
%%% Sx DP API
%%%===================================================================

delete_sgi_session(normal, #context{pfcp_ctx = PCtx} = Ctx) ->
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
delete_sgi_session(_Reason, _Context) ->
    undefined.

build_query_usage_report(Type, #context{
				  pfcp_ctx =
				      #pfcp_ctx{
					 sx_ids = #sx_ids{idmap = #{urr := URRs}}}}) ->
    maps:fold(fun(K, {offline, V}, A)
		    when Type =:= offline, is_integer(V) ->
		      [#query_urr{group = [#urr_id{id = K}]} | A];
		 (K, V, A)
		    when Type =:= online andalso is_integer(V) ->
		      [#query_urr{group = [#urr_id{id = K}]} | A];
		 (_, _, A) -> A
	      end, [], URRs);
build_query_usage_report(_Type, _Context) ->
    [].

query_usage_report(#context{
		      pfcp_ctx =
			  #pfcp_ctx{
			     sx_ids = #sx_ids{idmap = #{urr := URRs}}
			    } = PCtx} = Ctx) ->
    lager:error("Q URRs: ~p", [URRs]),
    IEs = build_query_usage_report(online, Ctx),
    Req = #pfcp{version = v1, type = session_modification_request, ie = IEs},
    ergw_sx_node:call(PCtx, Req, Ctx);
query_usage_report(_) ->
    undefined.

query_usage_report(RatingGroup, #context{
				   pfcp_ctx =
				       #pfcp_ctx{
					  sx_ids = #sx_ids{idmap = #{urr := URRs}}
					 } = PCtx} = Ctx) ->
    lager:error("Q URRs: ~p", [URRs]),
    case URRs of
	#{RatingGroup := Id} ->
	    IEs = [#query_urr{group = [#urr_id{id = Id}]}],
	    Req = #pfcp{version = v1, type = session_modification_request, ie = IEs},
	    ergw_sx_node:call(PCtx, Req, Ctx);
	_ ->
	    undefined
    end.

trigger_offline_usage_report(#context{pfcp_ctx = PCtx} = Ctx, Cb) ->
    IEs = build_query_usage_report(offline, Ctx),
    Req = #pfcp{version = v1, type = session_modification_request, ie = IEs},
    ergw_sx_node:call_async(PCtx, Req, Cb);
trigger_offline_usage_report(_, _) ->
    undefined.

%%%===================================================================
%%% Helper functions
%%%===================================================================

ctx_update_dp_seid(#{f_seid := #f_seid{seid = DP}},
		   #pfcp_ctx{seid = SEID} = PCtx) ->
    PCtx#pfcp_ctx{seid = SEID#seid{dp = DP}};
ctx_update_dp_seid(_, PCtx) ->
    PCtx.

create_ipv6_mcast_pdr(PdrId, FarId,
		      #context{local_data_endp = LocalDataEndp, ms_v6 = IPv6},
		      Rules)
  when IPv6 /= undefined ->
    PDR =
	pfcp_packet:ies_to_map(
	  #create_pdr{
	     group =
		 [#pdr_id{id = PdrId},
		  #precedence{precedence = 100},
		  #pdi{
		     group =
			 [#source_interface{interface = 'Access'},
			  ergw_pfcp:network_instance(LocalDataEndp),
			  ergw_pfcp:f_teid(LocalDataEndp),
			  #sdf_filter{
			     flow_description =
				 <<"permit out 58 from ff00::/8 to assigned">>}
			 ]},
		  #far_id{id = FarId},
		  #urr_id{id = 1}]
	    }),
    update_m_rec(PDR, Rules);
create_ipv6_mcast_pdr(_, _, _, Rules) ->
    Rules.

create_dp_to_cp_far(access, FarId,
		    #pfcp_ctx{cp_port = #gtp_port{ip = CpIP} = CpPort, cp_tei = CpTEI},
		    Rules) ->
    FAR =
	pfcp_packet:ies_to_map(
	  #create_far{
	     group =
		 [#far_id{id = FarId},
		  #apply_action{forw = 1},
		  #forwarding_parameters{
		     group =
			 [#destination_interface{interface = 'CP-function'},
			  ergw_pfcp:network_instance(CpPort),
			  ergw_pfcp:outer_header_creation(#fq_teid{ip = CpIP, teid = CpTEI})
			 ]
		    }
		 ]
	    }),
    update_m_rec(FAR, Rules).

%% use additional information from the Context to prefre V4 or V6....
choose_context_ip(IP4, _IP6, _Context)
  when is_binary(IP4) ->
    IP4;
choose_context_ip(_IP4, IP6, _Context)
  when is_binary(IP6) ->
    IP6.

%%%===================================================================
%%% Session Trigger functions
%%%===================================================================

session_events(_Session, [], State) ->
    State;
%% session_events(Session, [{Action, _} = H|_],  State)
%%   when Action =:= add; Action =:= del; Action =:= set ->
%%     erlang:error(badarg, [Session, H,  State]);
session_events(Session, [{update_credits, Update} | T], State0) ->
    lager:info("Session credit Update: ~p", [Update]),
    State = update_sx_usage_rules(Update, State0),
    session_events(Session, T, State);
session_events(Session, [stop | T], State) ->
    self() ! stop_from_session,
    session_events(Session, T, State);
session_events(Session, [H | T], State) ->
    lager:error("unhandled session event: ~p", [H]),
    session_events(Session, T, State).

%%%===================================================================
%%% PCC to Sx translation functions
%%%===================================================================

-record(pcc_upd, {errors = [], rules = #{}}).

%% convert Gx like Install/Remove interactions in PCC rule states

update_pcc_rules(CRUpdate, Rules) when is_map(CRUpdate) ->
    Update = update_pcc_rules(fun remove_pcc_rule/3,
			      maps:get('Charging-Rule-Remove', CRUpdate, []),
			      #pcc_upd{rules = Rules}),
    update_pcc_rules(fun install_pcc_rule/3,
		     maps:get('Charging-Rule-Install', CRUpdate, []),
		     Update).

update_pcc_rules(Fun, Update, Rules) ->
    lists:foldl(maps:fold(Fun, _, _), Update, Rules).

pcc_rule_error(Error, #pcc_upd{errors = Errors} = Update) ->
    Update#pcc_upd{errors = [Error | Errors]}.

remove_pcc_rule('Charging-Rule-Name', Names, #pcc_upd{} = Update) ->
    lists:foldl(
      fun(Name, #pcc_upd{rules = Rules} = Upd) ->
	      case maps:is_key(Name, Rules) of
		  true ->
		      Update#pcc_upd{rules = maps:without([Name], Rules)};
		  _ ->
		      pcc_rule_error({unknown_rule_name, Name}, Upd)
	      end
      end, Update, Names);
remove_pcc_rule(_K, _V, #pcc_upd{} = Update) ->
    Update.

install_pcc_rule('Charging-Rule-Definition', Definitions, #pcc_upd{} = Update)
  when is_list(Definitions) ->
    lists:foldl(fun install_pcc_rule_def/2, Update, Definitions);
install_pcc_rule(_K, _V, #pcc_upd{} = Update) ->
    Update.

install_pcc_rule_def(#{'Charging-Rule-Name' := Name} = UpdRule,
		     #pcc_upd{rules = Rules} = Update) ->
    case maps:get(Name, Rules, #{}) of
	OldRule when is_map(OldRule) ->
	    Update#pcc_upd{rules = Rules#{Name => maps:merge(OldRule, UpdRule)}};
	_ ->
	    pcc_rule_error({unknown_rule_name, Name}, Update)
    end.

%% convert PCC rule state into Sx rule states

sx_rule_error(Error, #sx_upd{errors = Errors} = Update) ->
    Update#sx_upd{errors = [Error | Errors]}.

sx_rule_add(Key, Rule, #pfcp_ctx{sx_rules = Rules} = PCtx) ->
    PCtx#pfcp_ctx{sx_rules = Rules#{Key => Rule}}.

sx_rules_add(Add, #pfcp_ctx{sx_rules = Rules} = PCtx) ->
    PCtx#pfcp_ctx{sx_rules = maps:merge(Add, Rules)}.

sx_id(Type, Name, Record, Field) ->
    F0 = element(Field, Record),
    {Id, F1} = sx_id(Type, Name, F0),
    {Id, setelement(Field, Record, F1)}.

sx_id(Type, Name, Upd) when is_record(Upd, sx_upd) ->
    sx_id(Type, Name, Upd, #sx_upd.pctx);
sx_id(Type, Name, PCtx) when is_record(PCtx, pfcp_ctx) ->
    sx_id(Type, Name, PCtx, #pfcp_ctx.sx_ids);

sx_id(Type, Name, undefined) ->
    sx_id(Type, Name, #sx_ids{});
sx_id(Type, Name, #sx_ids{cnt = Cnt, idmap = IdMap0} = State) ->
    Key = {Type, Name},
    case IdMap0 of
	#{Key := Id} ->
	    {Id, State};
	_ ->
	    Id = maps:get(Type, Cnt, 1),
	    IdMap = maps:update_with(Type, fun(X) -> X#{Id => Name} end,
				     #{Id => Name}, IdMap0),
	    {Id, State#sx_ids{cnt = Cnt#{Type => Id + 1},
			      idmap = IdMap#{Key => Id}}}
    end.

find_sx_id(Type, Name, #sx_upd{pctx = PCtx}) ->
    find_sx_id(Type, Name, PCtx);
find_sx_id(Type, Name, #pfcp_ctx{sx_ids = Ids}) ->
    find_sx_id(Type, Name, Ids);
find_sx_id(Type, Name, #sx_ids{idmap = IdMap}) ->
    Key = {Type, Name},
    maps:find(Key, IdMap).

find_sx_by_id(Type, Id, #sx_ids{idmap = IdMap}) ->
    TypeId = maps:get(Type, IdMap, #{}),
    maps:find(Id, TypeId).

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

build_sx_rules(SessionOpts, Opts, PCtx, SCtx) ->
    InitPCtx = PCtx#pfcp_ctx{sx_rules = #{}},
    Init = #sx_upd{pctx = InitPCtx, sctx = SCtx},
    #sx_upd{errors = Errors, pctx = NewPCtx} =
	build_sx_rules_3(SessionOpts, Opts, Init),

    SxRuleReq = update_sx_rules(PCtx, NewPCtx, Opts),

    %% TODO:
    %% remove unused SxIds

    {SxRuleReq, Errors, NewPCtx}.

build_sx_rules_3(SessionOpts, _Opts, Update0) ->
    Monitors = maps:get(monitoring, SessionOpts, #{}),
    PolicyRules = maps:get(rules, SessionOpts, #{}),
    Credits = maps:get('Multiple-Services-Credit-Control', SessionOpts, []),

    Update1 = maps:fold(fun build_sx_monitor_rule/3, Update0, Monitors),
    Update2 = maps:fold(build_sx_offline_charging_rule(_, _, SessionOpts, _), Update1, PolicyRules),
    Update3 = lists:foldl(fun build_sx_usage_rule/2, Update2, Credits),
    maps:fold(fun build_sx_rule/3, Update3, PolicyRules).

build_sx_offline_charging_rule(_Name,
			       #{'Rating-Group' := [RatingGroup],
				 'Offline' := [1]} = Definition,
			       SessionOpts, #sx_upd{pctx = PCtx0} = Update) ->
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

    {UrrId, PCtx} = sx_id(urr, ChargingKey, PCtx0),
    URR0 = #{urr_id => #urr_id{id = UrrId},
	    measurement_method => MM,
	    reporting_triggers => #reporting_triggers{periodic_reporting = 1},
	    measurement_period =>
		#measurement_period{
		   period = maps:get('Acct-Interim-Interval', SessionOpts, 600)}
	   },

    OCPcfg = maps:get('Offline-Charging-Profile', SessionOpts, #{}),
    OCP = maps:get('Default', OCPcfg, #{}),
    URR = apply_charging_profile(URR0, OCP),

    lager:warning("Offline URR: ~p", [URR]),
    Update#sx_upd{pctx = sx_rule_add({urr, ChargingKey}, URR, PCtx)};

build_sx_offline_charging_rule(Name, #{'Offline' := [1]}, _SessionOpts, Update) ->
    %% Offline without Rating-Group ???
    sx_rule_error({system_error, Name}, Update);
build_sx_offline_charging_rule(_Name, _Definition, _SessionOpts, Update) ->
    Update.

%% no need to split into dl and ul direction, URR contain DL, UL and Total
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
    URRs = collect_urrs(Name, Definition, Update0),
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

build_sx_rule(Direction = downlink, Name, Definition, FilterInfo, URRs,
	      #sx_upd{
		 pctx = PCtx0,
		 sctx = #context{local_data_endp = LocalDataEndp,
				 remote_data_teid = PeerTEID} = Ctx
		} = Update)
  when PeerTEID /= undefined ->
    [Precedence] = maps:get('Precedence', Definition, [1000]),
    RuleName = {Direction, Name},
    {PdrId, PCtx1} = sx_id(pdr, RuleName, PCtx0),
    {FarId, PCtx} = sx_id(far, RuleName, PCtx1),
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
      pctx = sx_rules_add(
	       #{{pdr, RuleName} => pfcp_packet:ies_to_map(PDR),
		 {far, RuleName} => pfcp_packet:ies_to_map(FAR)}, PCtx)};

build_sx_rule(Direction = uplink, Name, Definition, FilterInfo, URRs,
	      #sx_upd{pctx = PCtx0,
		      sctx = #context{local_data_endp = LocalDataEndp} = Ctx
		     } = Update) ->
    [Precedence] = maps:get('Precedence', Definition, [1000]),
    RuleName = {Direction, Name},
    {PdrId, PCtx1} = sx_id(pdr, RuleName, PCtx0),
    {FarId, PCtx} = sx_id(far, RuleName, PCtx1),
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
    FAR = [#far_id{id = FarId},
	    #apply_action{forw = 1},
	    #forwarding_parameters{
	       group =
		   [#destination_interface{interface = 'SGi-LAN'},
		    ergw_pfcp:network_instance(Ctx)]
	      }
	  ],
    Update#sx_upd{
      pctx = sx_rules_add(
	       #{{pdr, RuleName} => pfcp_packet:ies_to_map(PDR),
		 {far, RuleName} => pfcp_packet:ies_to_map(FAR)}, PCtx)};

build_sx_rule(_Direction, Name, _Definition, _FlowInfo, _URRs, Update) ->
    sx_rule_error({system_error, Name}, Update).

get_sx_ids(_Type, [], _Update, URRs) ->
    URRs;
get_sx_ids(Type, [H|T], Update, URRs0) ->
    URRs =
	case find_sx_id(urr, H, Update) of
	    {ok, UrrId} ->
		[UrrId | URRs0];
	    _ ->
		URRs0
	end,
    get_sx_ids(Type, T, Update, URRs).

collect_urrs(_Name, #{'Rating-Group' := [RatingGroup]},
	     #sx_upd{monitors = Monitors} = Update) ->
    URRs = maps:get('IP-CAN', Monitors, []),
    get_sx_ids(urr, [RatingGroup, {offline, RatingGroup}], Update, URRs);
collect_urrs(Name, _Definition, Update) ->
    lager:error("URR: ~p, ~p", [Name, _Definition]),
    {[], sx_rule_error({system_error, Name}, Update)}.

%% 'Granted-Service-Unit' => [#{'CC-Time' => [14400],'CC-Total-Octets' => [10485760]}],
%% 'Rating-Group' => [3000],'Result-Code' => [?'DIAMETER_BASE_RESULT-CODE_SUCCESS'],
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

-ifdef(OTP_RELEASE).
%% OTP 21 or higher
system_time_to_universal_time(Time, TimeUnit) ->
    calendar:system_time_to_universal_time(Time, TimeUnit).

-else.
%% from Erlang R21:

system_time_to_universal_time(Time, TimeUnit) ->
    Secs = erlang:convert_time_unit(Time, TimeUnit, second),
    calendar:gregorian_seconds_to_datetime(Secs + ?SECONDS_FROM_0_TO_1970).
-endif.

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

build_sx_usage_rule(#{'Result-Code' := [2001],
		      'Rating-Group' := [ChargingKey],
		      'Granted-Service-Unit' := [GSU]} = GCU,
		    #sx_upd{pctx = PCtx0} = Update) ->
    {UrrId, PCtx} = sx_id(urr, ChargingKey, PCtx0),
    URR0 = #{urr_id => #urr_id{id = UrrId},
	     measurement_method => #measurement_method{},
	     reporting_triggers => #reporting_triggers{}},
    URR = lists:foldl(build_sx_usage_rule(_, GSU, GCU, _), URR0,
		      [time, time_quota_threshold,
		       total_octets, input_octets, output_octets,
		       total_quota_threshold, input_quota_threshold, output_quota_threshold,
		       monitoring_time]),

    lager:warning("URR: ~p", [URR]),
    Update#sx_upd{pctx = sx_rule_add({urr, ChargingKey}, URR, PCtx)};
build_sx_usage_rule(Definition, Update) ->
    lager:error("URR: ~p", [Definition]),
    sx_rule_error({system_error, Definition}, Update).

build_sx_monitor_rule(Service, {'IP-CAN', periodic, Time} = _Definition,
		      #sx_upd{monitors = Monitors0, pctx = PCtx0} = Update) ->
    lager:info("Sx Monitor Rule: ~p", [_Definition]),

    RuleName = {monitor, 'IP-CAN', Service},
    {UrrId, PCtx} = sx_id(urr, RuleName, PCtx0),

    URR = pfcp_packet:ies_to_map(
	    [#urr_id{id = UrrId},
	     #measurement_method{volum = 1, durat = 1},
	     #reporting_triggers{periodic_reporting = 1},
	     #measurement_period{period = Time}]),

    lager:warning("URR: ~p", [URR]),
    Monitors1 = update_m_key('IP-CAN', UrrId, Monitors0),
    Monitors = Monitors1#{{urr, UrrId}  => Service},
    Update#sx_upd{pctx = sx_rule_add({urr, RuleName}, URR, PCtx), monitors = Monitors};

build_sx_monitor_rule(Service, Definition, Update) ->
    lager:error("Monitor URR: ~p:~p", [Service, Definition]),
    sx_rule_error({system_error, Definition}, Update).

update_sx_usage_rules(Update, #{context := #context{pfcp_ctx = PCtx0} = Ctx} = State) ->
    Init = #sx_upd{pctx = PCtx0, sctx = Ctx},
    #sx_upd{errors = Errors, pctx = PCtx} =
	lists:foldl(fun build_sx_usage_rule/2, Init, Update),
    #pfcp_ctx{sx_rules = Rules} = PCtx,

    lager:info("Sx Modify: ~p, (~p)", [maps:values(Rules), Errors]),

    case maps:values(Rules) of
	[] ->
	    ok;
	RulesList when is_list(RulesList) ->
	    URRs = [#update_urr{group = V} || V <- RulesList],
	    lager:info("Sx Modify: ~p", [URRs]),

	    IEs = [#update_urr{group = V} || V <- maps:values(Rules)],
	    Req = #pfcp{version = v1, type = session_modification_request, ie = IEs},
	    R = ergw_sx_node:call(PCtx, Req, Ctx),
	    lager:warning("R: ~p", [R]),
	    ok
    end,
    State#{context => Ctx#context{pfcp_ctx = PCtx}}.

update_m_key(Key, Value, Map) ->
    maps:update_with(Key, [Value | _], [Value], Map).

update_m_rec(Record, Map) when is_tuple(Record) ->
    maps:update_with(element(1, Record), [Record | _], [Record], Map).

put_rec(Record, Map) when is_tuple(Record) ->
    maps:put(element(1, Record), Record, Map).

update_sx_rules(#pfcp_ctx{sx_rules = Old}, #pfcp_ctx{sx_rules = New}, Opts) ->
    lager:debug("Update Sx Rules Old: ~p", [lager:pr(Old, ?MODULE)]),
    lager:debug("Update Sx Rules New: ~p", [lager:pr(New, ?MODULE)]),
    Del = maps:fold(fun del_sx_rules/3, #{}, maps:without(maps:keys(New), Old)),
    maps:fold(upd_sx_rules(_, _, Old, _, Opts), Del, New).

del_sx_rules({pdr, _}, #{pdr_id := Id}, Acc) ->
    update_m_rec(#remove_pdr{group = [Id]}, Acc);
del_sx_rules({far, _}, #{far_id := Id}, Acc) ->
    update_m_rec(#remove_far{group = [Id]}, Acc);
del_sx_rules({urr, _}, #{urr_id := Id}, Acc) ->
    update_m_rec(#remove_urr{group = [Id]}, Acc).

upd_sx_rules({Type, _} = K, V, Old, Acc, Opts) ->
    upd_sx_rules_1(Type, V, maps:get(K, Old, undefined), Acc, Opts).

upd_sx_rules_1(pdr, V, undefined, Acc, _Opts) ->
    update_m_rec(#create_pdr{group = V}, Acc);
upd_sx_rules_1(far, V, undefined, Acc, _Opts) ->
    update_m_rec(#create_far{group = V}, Acc);
upd_sx_rules_1(urr, V, undefined, Acc, _Opts) ->
    update_m_rec(#create_urr{group = V}, Acc);

upd_sx_rules_1(_Type, V, V, Acc, _Opts) ->
    Acc;

upd_sx_rules_1(pdr, V, OldV, Acc, Opts) ->
    update_m_rec(#update_pdr{group = update_sx_pdr(V, OldV, Opts)}, Acc);
upd_sx_rules_1(far, V, OldV, Acc, Opts) ->
    update_m_rec(#update_far{group = update_sx_far(V, OldV, Opts)}, Acc);
upd_sx_rules_1(urr, V, _OldV, Acc, _Opts) ->
    update_m_rec(#update_urr{group = V}, Acc).

update_sx_simplify(New, Old)
  when is_map(Old), New =/= Old ->
    Added = maps:without(maps:keys(Old), New),
    maps:fold(fun(K, V, A) ->
		      case maps:get(K, New) of
			  V -> A;
			  NewV -> maps:put(K, NewV, A)
		      end
	      end, Added, Old);
update_sx_simplify(New, _Old) ->
    New.

%% TODO: predefined rules (activate/deactivate)
update_sx_pdr(#{pdr_id := Id} = New, Old, _Opts) ->
    Update = update_sx_simplify(New, Old),
    put_rec(Id, Update).

update_sx_far(#{far_id := Id} = New, Old, Opts) ->
    lager:debug("Update Sx Far Old: ~p", [lager:pr(Old, ?MODULE)]),
    lager:debug("Update Sx Far New: ~p", [lager:pr(New, ?MODULE)]),
    Update = update_sx_simplify(New, Old),
    lager:debug("Update Sx Far Update: ~p", [lager:pr(Update, ?MODULE)]),
    maps:fold(update_sx_far(_, _, Old, _, Opts), #{}, put_rec(Id, Update)).

update_sx_far(_, #forwarding_parameters{
		    group =
			#{destination_interface :=
			      #destination_interface{interface = Interface}} = New},
	      #{forwarding_parameters := #forwarding_parameters{group = Old}},
	      Far, Opts) ->
    lager:debug("Update Sx Forward Old: ~p", [lager:pr(Old, ?MODULE)]),
    lager:debug("Update Sx Forward P0: ~p", [lager:pr(New, ?MODULE)]),

    SendEM = maps:get(send_end_marker, Opts, false),
    Update0 = update_sx_simplify(New, Old),
    lager:debug("Update Sx Forward Update: ~p", [lager:pr(Update0, ?MODULE)]),
    Update =
	case Update0 of
	    #{outer_header_creation := _}
	      when SendEM andalso (Interface == 'Access' orelse Interface == 'Core')->
		put_rec(#sxsmreq_flags{sndem = 1}, Update0);
	    _ ->
		Update0
	end,
    put_rec(#update_forwarding_parameters{group = Update}, Far);
update_sx_far(_, #duplicating_parameters{group = P}, _Old, Far, _Opts) ->
    put_rec(#update_duplicating_parameters{group = P}, Far);
update_sx_far(K, V, _Old, Far, _Opts) ->
    lager:debug("Update Sx Far: ~p, ~p", [K, lager:pr(V, ?MODULE)]),
    Far#{K => V}.

create_sgi_session(Candidates, SessionOpts, Ctx0) ->
    PCtx0 = ergw_sx_node:select_sx_node(Candidates, Ctx0),
    Ctx = ergw_pfcp:assign_data_teid(PCtx0, Ctx0),
    {ok, #node{node = _Node, ip = IP}, _} = ergw_sx_socket:id(),

    {CPinFarId, PCtx1} = sx_id(far, dp_to_cp_far, PCtx0),
    {IPv6MCastPdrId, PCtx2} = sx_id(pdr, ipv6_mcast_pdr, PCtx1),

    {SxRules0, SxErrors, PCtx} = build_sx_rules(SessionOpts, #{}, PCtx2, Ctx),
    lager:info("SxRules: ~p~n", [SxRules0]),
    lager:info("SxErrors: ~p~n", [SxErrors]),
    lager:info("CtxPending: ~p~n", [Ctx]),

    SxRules1 = create_dp_to_cp_far(access, CPinFarId, PCtx, SxRules0),
    SxRules2 = create_ipv6_mcast_pdr(IPv6MCastPdrId, CPinFarId, Ctx, SxRules1),
    IEs = update_m_rec(ergw_pfcp:f_seid(PCtx, IP), SxRules2),

    lager:info("IEs: ~p~n", [IEs]),

    Req = #pfcp{version = v1, type = session_establishment_request, ie = IEs},
    case ergw_sx_node:call(PCtx, Req, Ctx) of
	#pfcp{version = v1, type = session_establishment_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'},
		     f_seid := #f_seid{}} = RespIEs} ->
	    Ctx#context{pfcp_ctx = ctx_update_dp_seid(RespIEs, PCtx)};
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, Ctx))
    end.

modify_sgi_report_urrs(Response, URRActions) ->
    lists:map(
	  fun({offline, {M,F,A}}) ->
		  (catch erlang:apply(M, F, A ++ [Response]));
	     (_) ->
		  ok
	  end, URRActions).

modify_sgi_session(SessionOpts, URRActions, Opts, #context{pfcp_ctx = PCtx0} = Ctx) ->
    {SxRules0, SxErrors, PCtx} = build_sx_rules(SessionOpts, Opts, PCtx0, Ctx),
    SxRules1 =
	lists:foldl(
	  fun({offline, _}, SxR) ->
		  SxR#{query_urr => build_query_usage_report(offline, Ctx)};
	     (_, SxR) ->
		  SxR
	  end, SxRules0, URRActions),

    %% TODO: at the moment, modify_sgi_session is only used to change TEIDs,
    SxRules = maps:without([update_urr], SxRules1),

    lager:info("SxRules: ~p~n", [SxRules]),
    lager:info("SxErrors: ~p~n", [SxErrors]),
    lager:info("PCtx: ~p~n", [PCtx]),

    Req = #pfcp{version = v1, type = session_modification_request, ie = SxRules},
    case ergw_sx_node:call(PCtx, Req, Ctx) of
	#pfcp{version = v1, type = session_modification_response,
	      ie = #{
		     pfcp_cause :=
			 #pfcp_cause{cause = 'Request accepted'}} = RespIEs} = Response ->
	    modify_sgi_report_urrs(Response, URRActions),
	    Ctx#context{pfcp_ctx = ctx_update_dp_seid(RespIEs, PCtx)};
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, Ctx))
    end.


opt_int(X) when is_integer(X) -> [X];
opt_int(_) -> [].

opt_int(K, X, M) when is_integer(X) -> M#{K => X};
opt_int(_, _, M) -> M.

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
    Report1 = tariff_change_usage(URR, Report0),
    Report2 = credit_report_volume(maps:get(volume_measurement, URR, undefined), Report1),
    Report = credit_report_duration(maps:get(duration_measurement, URR, undefined), Report2),
    {ChargingKey, Report}.

%% ===========================================================================
%% Rf Support - Offline Charging
%% ===========================================================================

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
	     [system_time_to_universal_time(Now + erlang:time_offset(), native)]}.

-ifdef (TBD).

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

%% TBD: Change Condition
cev_to_rf_change_condition([], _, SDC) ->
    SDC;
cev_to_rf_change_condition([immer|Fields], [1|Values], SDC) ->
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([droth|Fields], [1|Values], SDC) ->
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([stopt|Fields], [1|Values], SDC) ->
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([start|Fields], [1|Values], SDC) ->
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([quhti|Fields], [1|Values], SDC) ->
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([timth|Fields], [1|Values], SDC) ->
    %% Time Threshold ->
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([volth|Fields], [1|Values], SDC) ->
    %% Volume Threshold ->
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([perio|Fields], [1|Values], SDC) ->
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([macar|Fields], [1|Values], SDC) ->
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([envcl|Fields], [1|Values], SDC) ->
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([monit|Fields], [1|Values], SDC) ->
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([termr|Fields], [1|Values], SDC) ->
    %% Normal Release
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([liusa|Fields], [1|Values], SDC) ->
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([timqu|Fields], [1|Values], SDC) ->
    %% Time Quota -> Time Limit
    repeated('Change-Condition', 0, SDC);
cev_to_rf_change_condition([volqu|Fields], [1|Values], SDC) ->
    %% Volume Quota ->
    repeated('Change-Condition', 0, SDC);

cev_to_rf_change_condition([_|Fields], [_|Values], SDC) ->
    cev_to_rf_change_condition(Fields, Values, SDC).

-endif.

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
%% cev_to_rf(usage_report_trigger, #usage_report_trigger{} = Trigger, SDC) ->
%%     cev_to_rf_change_condition(record_info(fields, usage_report_trigger),
%% 			       tl(tuple_to_list(Trigger)), SDC);
cev_to_rf(_, #volume_measurement{uplink = UL, downlink = DL}, SDC) ->
    SDC#{'Accounting-Input-Octets'  => opt_int(UL),
	 'Accounting-Output-Octets' => opt_int(DL)};
cev_to_rf(_, #duration_measurement{duration = Duration}, SDC) ->
    SDC#{'Time-Usage' => opt_int(Duration)};
cev_to_rf(_, _, SDC) ->
    SDC.

%% charging_event_to_rf/2
charging_event_to_rf(#{'Rating-Group' := ChargingKey,
		       usage_report_trigger :=
			   #usage_report_trigger{perio = Periodic}} = URR, SDCInit, Reason0) ->
    Reason = if Periodic == 1 -> cdr_closure;
		true          -> Reason0
	     end,
    SDC = maps:fold(fun cev_to_rf/3, SDCInit, URR),
    {SDC, Reason}.

%% ===========================================================================

map_usage_report_1(Fun, #usage_report_smr{group = UR}) ->
    Fun(UR);
map_usage_report_1(Fun, #usage_report_sdr{group = UR}) ->
    Fun(UR);
map_usage_report_1(Fun, #usage_report_srr{group = UR}) ->
    Fun(UR).

map_usage_report(_Fun, []) ->
    [];
map_usage_report(Fun, [H|T]) ->
    [map_usage_report_1(Fun, H) | map_usage_report(Fun, T)];
map_usage_report(Fun, URR) when is_tuple(URR) ->
    [map_usage_report_1(Fun, URR)];
map_usage_report(_Fun, undefined) ->
    [].

monitor_report_volume(#volume_measurement{uplink = UL, downlink = DL}, Report0) ->
    Report = opt_int('InOctets', UL, Report0),
    opt_int('OutOctets', DL, Report);
monitor_report_volume(_, Report) ->
    Report.

monitor_report_duration(#duration_measurement{duration = Duration}, Report) ->
    opt_int('Session-Time', Duration, Report);
monitor_report_duration(_, Report) ->
    Report.

%% usage_report_to_monitor_report/1
usage_report_to_monitor_report(#{urr_id := #urr_id{id = Id}} = URR) ->
    Report0 = monitor_report_volume(maps:get(volume_measurement, URR, undefined), #{}),
    Report = monitor_report_duration(maps:get(duration_measurement, URR, undefined), Report0),
    {Id, Report}.

%% usage_report_to_monitor_report/4
usage_report_to_monitor_report({urr, {monitor, Level, Service}}, Id, CR, Report) ->
    case CR of
	#{Id := R} ->
	    maps:update_with(Level, maps:put(Service, R, _), #{Service => R}, Report);
	_ ->
	    Report
    end;
usage_report_to_monitor_report({urr, {offline, RatingGroup}}, Id, CR, Report) ->
    case CR of
	#{Id := R} ->
	    maps:update_with(offline, maps:put(RatingGroup, R, _), #{RatingGroup => R}, Report);
	_ ->
	    Report
    end;
usage_report_to_monitor_report(_, _, _, Report) ->
    Report.

%% usage_report_to_monitor_report/2
usage_report_to_monitoring_report(URR, #context{
					  pfcp_ctx =
					      #pfcp_ctx{
						 sx_ids = #sx_ids{idmap = IdMap}}}) ->
    CR = map_usage_report(fun usage_report_to_monitor_report/1, URR),
    CR1 = maps:fold(usage_report_to_monitor_report(_, _, maps:from_list(CR), _), #{}, IdMap),
    lager:warning("Monitoring Report ~p", [lager:pr(CR1, ?MODULE)]),
    CR1.


%% ===========================================================================

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

%% usage_report_to_charging_events/3
usage_report_to_charging_events(RatingGroup, Report, {On, _, _} = Ev)
  when is_integer(RatingGroup), is_map(Report) ->
    setelement(1, Ev, [Report#{'Rating-Group' => RatingGroup} | On]);
usage_report_to_charging_events({offline, RatingGroup}, Report, {_, Off, _} = Ev)
  when is_integer(RatingGroup), is_map(Report) ->
    setelement(2, Ev, [Report#{'Rating-Group' => RatingGroup} | Off]);
%% usage_report_to_charging_events({monitor, Level, Service}, Report, {_, _, Mon} = Ev)
%%   when is_map(Report) ->
%%     Ev;
usage_report_to_charging_events(_K, _V, Ev) ->
    Ev.

%% usage_report_to_charging_events/2
usage_report_to_charging_events(URR, #context{
					pfcp_ctx =
					    #pfcp_ctx{
					       sx_ids = #sx_ids{idmap = IdMap}}}) ->
    UrrIds = maps:get(urr, IdMap, #{}),
    foldl_usage_report(
      fun (#{urr_id := #urr_id{id = Id}} = Report, Ev) ->
	      case UrrIds of
		  #{Id := Key} ->
		      usage_report_to_charging_events(Key, Report, Ev);
		  _ ->
		      Ev
	      end
      end,
      init_charging_events(), URR).

process_online_charging_events(Reason, Ev, Now, Session) when is_list(Ev) ->
    SOpts = #{now => Now, async => true},

    Update = lists:map(fun charging_event_to_gy/1, Ev),

    case Reason of
	{terminate, Cause} ->
	    Request = #{'Termination-Cause' => Cause,
			used_credits => Update},
	    ergw_aaa_session:invoke(Session, Request, {gy, 'CCR-Terminate'}, SOpts);
	_ when length(Update) /= 0 ->
	    Request = #{'used_credits' => Update},
	    ergw_aaa_session:invoke(Session, Request, {gy, 'CCR-Update'}, SOpts);
	_ ->
	    ok
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
pcc_rules_to_credit_request(_K, #{'Rating-Group' := [RatingGroup]}, Acc) ->
    RG = empty,
    maps:update_with(RatingGroup, fun(V) -> V end, RG, Acc);
pcc_rules_to_credit_request(_K, V, Acc) ->
    lager:warning("No Rating Group: ~p", [V]),
    Acc.

pcc_rules_to_credit_request(Rules) when is_map(Rules) ->
    lager:debug("Rules: ~p", [Rules]),
    CreditReq = maps:fold(fun pcc_rules_to_credit_request/3, #{}, Rules),
    lager:debug("CreditReq: ~p", [CreditReq]),
    CreditReq;
pcc_rules_to_credit_request(_Rules) ->
    lager:error("Rules: ~p", [_Rules]),
    #{}.

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
	     PayLoad:Length/bytes, _/binary>>, Context) ->
    icmpv6(TC, FlowLabel, SrcAddr, DstAddr, PayLoad, Context);
ip_pdu(Data, _Context) ->
    lager:warning("unhandled T-PDU: ~p", [Data]),
    ok.

%% IPv6 Router Solicitation
icmpv6(TC, FlowLabel, _SrcAddr, ?'IPv6 All Routers LL',
       <<?'ICMPv6 Router Solicitation':8, _Code:8, _CSum:16, _/binary>>,
       #context{local_data_endp = LocalDataEndp, remote_data_teid = RemoteDataTEID,
		pfcp_ctx = PCtx, ms_v6 = MSv6, dns_v6 = DNSv6} = Context) ->
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

icmpv6(_TC, _FlowLabel, _SrcAddr, _DstAddr, _PayLoad, _Context) ->
    lager:warning("unhandeld ICMPv6 from ~p to ~p: ~p", [_SrcAddr, _DstAddr, _PayLoad]),
    ok.
