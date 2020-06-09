%% Copyright 2017-2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_pfcp_context).

-compile({parse_transform, do}).
-compile({parse_transform, cut}).

-export([create_session/5,
	 modify_session/5,
	 delete_session/2,
	 session_liveness_check/1,
	 usage_report_to_charging_events/3,
	 query_usage_report/1, query_usage_report/2
	]).
-export([select_upf/1, select_upf/3, reselect_upf/4]).
-export([send_g_pdu/3]).
-export([register_ctx_ids/3, unregister_ctx_ids/3]).
-export([update_dp_seid/2, make_request_bearer/3, update_bearer/3]).

-ifdef(TEST).
-export([apply_charging_tariff_time/3]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include("ergw_core_config.hrl").
-include("include/ergw.hrl").

-record(sx_upd, {now, errors = [], monitors = #{}, pctx = #pfcp_ctx{}, left, right}).

-define(SECONDS_PER_DAY, 86400).

-define(ZERO_IPv6, {0,0,0,0,0,0,0,0}).
-define(UE_INTERFACE_ID, {0,0,0,0,0,0,0,1}).

%%%===================================================================
%%% PFCP Sx/N6 API
%%%===================================================================

%% create_session/5
create_session(Handler, PCC, PCtx, Bearer, Ctx)
  when is_record(PCC, pcc_ctx) ->
    session_establishment_request(Handler, PCC, PCtx, Bearer, Ctx).

%% modify_session/5
modify_session(PCC, URRActions, Opts, #{left := Left, right := Right} = _Bearer, PCtx0)
  when is_record(PCC, pcc_ctx), is_record(PCtx0, pfcp_ctx) ->
    {SxRules0, SxErrors, PCtx} = build_sx_rules(PCC, Opts, PCtx0, Left, Right),
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
    session_modification_request(PCtx, SxRules).

%% delete_session/2
delete_session(Reason, PCtx)
  when Reason /= upf_failure ->
    ergw_pfcp:cancel_timers(PCtx),
    Req = #pfcp{version = v1, type = session_deletion_request, ie = []},
    case ergw_sx_node:call(PCtx, Req) of
	#pfcp{type = session_deletion_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} = IEs} ->
	    maps:get(usage_report_sdr, IEs, undefined);

	_Other ->
	    ?LOG(warning, "PFCP: Session Deletion failed with ~p",
			  [_Other]),
	    undefined
    end;
delete_session(_Reason, PCtx) ->
    ergw_pfcp:cancel_timers(PCtx),
    undefined.

session_liveness_check(#pfcp_ctx{} = PCtx) ->
    Req = #pfcp{version = v1, type = session_modification_request, ie = []},
    case ergw_sx_node:call(PCtx, Req) of
	#pfcp{type = session_modification_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}}} ->
	    ok;
	_ ->
	    {error, ?CTX_ERR(?FATAL, system_failure)}
    end.

build_query_usage_report(Type, PCtx) ->
    maps:fold(fun(K, {URRType, V}, A)
		    when Type =:= URRType, is_integer(V) ->
		      [#query_urr{group = [#urr_id{id = K}]} | A];
		 (_, _, A) -> A
	      end, [], ergw_pfcp:get_urr_ids(PCtx)).

%% query_usage_report/1
query_usage_report(PCtx) ->
    query_usage_report(online, PCtx).

%% query_usage_report/2
query_usage_report(Type, PCtx)
  when is_record(PCtx, pfcp_ctx) andalso
       (Type == offline orelse Type == online) ->
    IEs = build_query_usage_report(Type, PCtx),
    session_modification_request(PCtx, IEs);

query_usage_report(ChargingKeys, PCtx)
  when is_record(PCtx, pfcp_ctx) ->
    IEs = [#query_urr{group = [#urr_id{id = Id}]} ||
	   Id <- ergw_pfcp:get_urr_ids(ChargingKeys, PCtx), is_integer(Id)],
    session_modification_request(PCtx, IEs).

%%%===================================================================
%%% Helper functions
%%%===================================================================

get_rating_group(Key, M) when is_map(M) ->
    hd(maps:get(Key, M, maps:get('Rating-Group', M, [undefined]))).

update_dp_seid(#{f_seid := #f_seid{seid = DP}}, #pfcp_ctx{seid = SEID} = PCtx) ->
    PCtx#pfcp_ctx{seid = SEID#seid{dp = DP}};
update_dp_seid(_, PCtx) ->
    PCtx.

%% update_bearer/2
update_bearer(#f_teid{teid = TEID, ipv4 = IP}, #bearer{local = #fq_teid{ip = v4}} = Bearer) ->
    Bearer#bearer{local = #fq_teid{ip =  ergw_inet:bin2ip(IP), teid = TEID}};
update_bearer(#f_teid{teid = TEID, ipv6 = IP}, #bearer{local = #fq_teid{ip = v6}} = Bearer) ->
    Bearer#bearer{local = #fq_teid{ip = ergw_inet:bin2ip(IP), teid = TEID}};
update_bearer(_, Bearer) ->
    Bearer.

update_bearer_f(#created_pdr{group = #{pdr_id := #pdr_id{id = PdrId}, f_teid := FqTEID}},
		{BearerMap, PCtx0}) ->
    Key = ergw_pfcp:get_bearer_key_by_pdr(PdrId, PCtx0),
    Bearer = maps:update_with(Key, update_bearer(FqTEID, _), BearerMap),
    PCtx = ergw_pfcp:update_teids(PdrId, FqTEID, PCtx0),
    {Bearer, PCtx};
update_bearer_f(_, Acc) ->
    Acc.

%% update_bearer/3
update_bearer(#{created_pdr := #created_pdr{} = PDR}, Bearer, PCtx) ->
    update_bearer_f(PDR, {Bearer, PCtx});
update_bearer(#{created_pdr := PDRs}, Bearer, PCtx) when is_list(PDRs) ->
    lists:foldl(fun update_bearer_f/2, {Bearer, PCtx}, PDRs);
update_bearer(_, Bearer, PCtx) ->
    {Bearer, PCtx}.

%% session_info/3
session_info(_, #tp_created_nat_binding{
		   group =
		       #{bbf_nat_port_block := #bbf_nat_port_block{block = Block},
			 bbf_nat_outside_address := #bbf_nat_outside_address{ipv4 = IP},
			 bbf_nat_external_port_range :=
			     #bbf_nat_external_port_range{ranges = [{Start, End}|_]}}},
	     Info) ->
    Info#{'NAT-Pool-Id' => Block,
	  'NAT-IP-Address' => IP,
	  'NAT-Port-Start' => Start,
	  'NAT-Port-End' => End};
session_info(_, #tp_created_nat_binding{
		   group =
		       #{bbf_nat_port_block := #bbf_nat_port_block{block = Block},
			 bbf_nat_outside_address := #bbf_nat_outside_address{ipv4 = IP}}},
	     Info) ->
    Info#{'NAT-Pool-Id' => Block,
	  'NAT-IP-Address' => IP};
session_info(_, _, Info) ->
    Info.

%% session_info/1
session_info(RespIEs) ->
    maps:fold(fun session_info/3, #{}, RespIEs).

%% session_establishment_request/5
session_establishment_request(Handler, PCC, PCtx0,
			      #{left := Left, right := Right} = Bearer0, Ctx) ->
    register_ctx_ids(Handler, Bearer0, PCtx0),
    {ok, CntlNode, _, _} = ergw_sx_socket:id(),

    PCtx1 = pctx_update_from_ctx(PCtx0, Ctx),
    {SxRules, SxErrors, PCtx2} = build_sx_rules(PCC, #{}, PCtx1, Left, Right),
    ?LOG(debug, "SxRules: ~p~n", [SxRules]),
    ?LOG(debug, "SxErrors: ~p~n", [SxErrors]),
    ?LOG(debug, "CtxPending: ~p~n", [Ctx]),

    IEs0 = pfcp_pctx_update(PCtx2, PCtx0, SxRules),
    IEs1 = update_m_rec(ergw_pfcp:f_seid(PCtx2, CntlNode), IEs0),
    IEs = pfcp_user_id(Ctx, IEs1),
    ?LOG(debug, "IEs: ~p~n", [IEs]),

    Req = #pfcp{version = v1, type = session_establishment_request, ie = IEs},
    case ergw_sx_node:call(PCtx2, Req) of
	#pfcp{version = v1, type = session_establishment_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'},
		     f_seid := #f_seid{}} = RespIEs} ->
	    SessionInfo = session_info(RespIEs),
	    {Bearer, PCtx} = update_bearer(RespIEs, Bearer0, PCtx2),
	    register_ctx_ids(Handler, Bearer, PCtx),
	    {ok, {update_dp_seid(RespIEs, PCtx), Bearer, SessionInfo}};
	_ ->
	    {error, ?CTX_ERR(?FATAL, system_failure)}
    end.

%% session_modification_request/2
session_modification_request(PCtx, ReqIEs)
  when ?is_non_empty_opts(ReqIEs) ->
    Req = #pfcp{version = v1, type = session_modification_request, ie = ReqIEs},
    case ergw_sx_node:call(PCtx, Req) of
	#pfcp{type = session_modification_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} = RespIEs} ->
	    SessionInfo = session_info(RespIEs),
	    UsageReport = maps:get(usage_report_smr, RespIEs, undefined),
	    {ok, {PCtx, UsageReport, SessionInfo}};
	_ ->
	    {error, ?CTX_ERR(?FATAL, system_failure)}
    end;
session_modification_request(PCtx, _ReqIEs) ->
    %% nothing to do
    {ok, {PCtx, undefined, #{}}}.

%%%===================================================================
%%% PCC to Sx translation functions
%%%===================================================================

%% convert PCC rule state into Sx rule states

sx_rule_error(Error, #sx_upd{errors = Errors} = Update) ->
    Update#sx_upd{errors = [Error | Errors]}.

apply_charging_tariff_time(#{'Local-Tariff-Time' := {H, M}, 'Location' := Location}, Now, URR)
  when is_integer(H), H >= 0, H < 24,
       is_integer(M), M >= 0, M < 60 ->
    {LocalDate, _} = LocalNow =
	localtime:to_local_time(
	  localtime:from_universal_time(Now, Location)),
    TT0 = {LocalDate, {H, M, 0}},
    TT =
	if TT0 < LocalNow ->
		calendar:gregorian_seconds_to_datetime(
		  calendar:datetime_to_gregorian_seconds(TT0) + ?SECONDS_PER_DAY);
	   true ->
		TT0
	end,
    case localtime:from_local_time(TT, Location) of
	[] ->
	    ?LOG(error, "can't calculate UTC from Tariff-Time \"~p\" at location ~s",
		 [TT, Location]),
	    URR;
	TTList ->
	    UniTT = localtime:to_universal_time(hd(TTList)),
	    TCTime = ergw_gsn_lib:gregorian_seconds_to_sntp_time(
		       calendar:datetime_to_gregorian_seconds(UniTT)),
	    case URR of
		#{monitoring_time := #monitoring_time{time = OldTCTime}}
		  when TCTime > OldTCTime ->
		    %% don't update URR when new time is after existing time
		    URR;
		_ ->
		    URR#{monitoring_time => #monitoring_time{time = TCTime}}
	    end
    end;
apply_charging_tariff_time(Time, _Now, URR) ->
    ?LOG(error, "Invalid Tariff-Time \"~p\"", [Time]),
    URR.

apply_charging_profile('Tariff-Time', Value, Now, URR)
  when is_map(Value) ->
    apply_charging_tariff_time(Value, Now, URR);
apply_charging_profile('Tariff-Time', Value, Now, URR)
  when is_list(Value) ->
    lists:foldl(apply_charging_tariff_time(_, Now, _), URR, Value);
apply_charging_profile(_K, _V, _Now, URR) ->
    URR.

apply_charging_profile(OCP, Now, URR) ->
    maps:fold(apply_charging_profile(_, _, Now, _), URR, OCP).

%% build_sx_rules/5
build_sx_rules(PCC, Opts, PCtx0, Left, Right) ->
    PCtx2 = ergw_pfcp:reset_ctx(PCtx0),
    Init = #sx_upd{now = calendar:universal_time(), pctx = PCtx2, left = Left, right = Right},
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

%% install special SLAAC and RA rule (only for tunnels for the moment)
build_sx_ctx_rule(#sx_upd{
		     pctx = #pfcp_ctx{cp_bearer = CpBearer} = PCtx0,
		     left = LeftBearer, right = RightBearer
		    } = Update)
  when not is_record(LeftBearer#bearer.remote, ue_ip),
       RightBearer#bearer.local#ue_ip.v6 /= undefined ->
    {PdrId, PCtx1} = ergw_pfcp:get_id(pdr, ipv6_mcast_pdr, PCtx0),
    {FarId, PCtx2} = ergw_pfcp:get_id(far, dp_to_cp_far, PCtx1),
    {LeftBearerReq, PCtx} = make_request_bearer(PdrId, LeftBearer, PCtx2),

    PDI = #pdi{
	     group =
		 [#sdf_filter{
		     flow_description =
			 <<"permit out 58 from ff00::/8 to assigned">>}
		 | ergw_pfcp:traffic_endpoint(LeftBearerReq, [])]
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
	      group = ergw_pfcp:traffic_forward(CpBearer, [])
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
			       #sx_upd{now = Now, pctx = PCtx0} = Update) ->
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
    URR = apply_charging_profile(OCP, Now, URR1),

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

pdr(PdrId, Precedence, Side, Src, Dst, FilterInfo, FarId, URRs) ->
    SxFilter = build_sx_filter(FilterInfo),
    Group =
	[#pdr_id{id = PdrId},
	 #precedence{precedence = Precedence},
	 #pdi{group = pdi(Side, Src, Dst, SxFilter)},
	 #far_id{id = FarId}] ++
	[#urr_id{id = X} || X <- URRs],
    ergw_pfcp:outer_header_removal(Src, Group).

pdi(Side, Src, #bearer{local = UeIP} = Dst, Group)
  when is_record(UeIP, ue_ip) ->
    %% gtp endpoint with UE IP for bearer binding verification
    [ergw_pfcp:ue_ip_address(Side, Dst)
    | ergw_pfcp:traffic_endpoint(Src, Group)];
pdi(_Side, Src, _Dst, Group) ->
    ergw_pfcp:traffic_endpoint(Src, Group).

make_request_bearer(PdrId, #bearer{local = #fq_teid{teid = {upf, Id}} = FqTEID} = Bearer, PCtx0) ->
    {ChId, PCtx} = ergw_pfcp:get_chid(PdrId, Id, PCtx0),
    {Bearer#bearer{local = FqTEID#fq_teid{teid = {upf, ChId}}}, PCtx};
make_request_bearer(_PdrId, Bearer, PCtx) ->
    {Bearer, PCtx}.
%% s(L) -> lists:sort(L).

%% The spec compliante FAR would set Destination Interface
%% to Access. However, VPP can not deal with that right now.
%%
%% far(FarId, [#{'Redirect-Support' :=        [1],   %% ENABLED
%%	      'Redirect-Address-Type' :=   [2],   %% URL
%%	      'Redirect-Server-Address' := [URL]}],
%%     Src, _Dst) ->
%%     RedirInfo = #redirect_information{type = 'URL', address = to_binary(URL)},
%%     [#far_id{id = FarId},
%%      #apply_action{forw = 1},
%%      #forwarding_parameters{
%%	group = ergw_pfcp:traffic_forward(Src, [RedirInfo])
%%        }
%%     ];
far(FarId, [#{'Redirect-Support' :=        [1],   %% ENABLED
	      'Redirect-Address-Type' :=   [2],   %% URL
	      'Redirect-Server-Address' := [URL]}],
    _Src, Dst) ->
    RedirInfo = #redirect_information{type = 'URL', address = to_binary(URL)},
    [#far_id{id = FarId},
     #apply_action{forw = 1},
     #forwarding_parameters{
	group = ergw_pfcp:traffic_forward(Dst, [RedirInfo])
       }];
far(FarId, _RedirInfo, _Src, #bearer{remote = undefined}) ->
    [#far_id{id = FarId},
     #apply_action{drop = 1}];
far(FarId, _RedirInfo, _Src, Dst) ->
    [#far_id{id = FarId},
     #apply_action{forw = 1},
     #forwarding_parameters{
	group = ergw_pfcp:traffic_forward(Dst, [])
       }].

%% build_sx_rule/6
build_sx_rule(Direction, Name, Definition, FilterInfo, URRs,
	      #sx_upd{left = LeftBearer, right = RightBearer} = Update) ->
    build_sx_rule(Direction, Name, Definition, FilterInfo, URRs, LeftBearer, RightBearer, Update).

%% build_sx_rule/8
build_sx_rule(Direction = downlink, Name, Definition, FilterInfo, URRs,
	      LeftBearer, RightBearer, #sx_upd{pctx = PCtx0} = Update)
  when LeftBearer#bearer.remote /= undefined ->
    [Precedence] = maps:get('Precedence', Definition, [1000]),
    RuleName = {Direction, Name},
    {PdrId, PCtx1} = ergw_pfcp:get_id(pdr, RuleName, PCtx0),
    {FarId, PCtx2} = ergw_pfcp:get_id(far, RuleName, PCtx1),
    {RightBearerReq, PCtx} = make_request_bearer(PdrId, RightBearer, PCtx2),

    PDR = pdr(PdrId, Precedence, dst, RightBearerReq, LeftBearer, FilterInfo, FarId, URRs),
    FAR = far(FarId, undefined, RightBearer, LeftBearer),

    Update#sx_upd{
      pctx = ergw_pfcp_rules:add(
	       [{pdr, RuleName, PDR},
		{far, RuleName, FAR}], PCtx)};

build_sx_rule(Direction = uplink, Name, Definition, FilterInfo, URRs,
	      LeftBearer, RightBearer, #sx_upd{pctx = PCtx0} = Update) ->
    [Precedence] = maps:get('Precedence', Definition, [1000]),
    RuleName = {Direction, Name},
    {PdrId, PCtx1} = ergw_pfcp:get_id(pdr, RuleName, PCtx0),
    {FarId, PCtx2} = ergw_pfcp:get_id(far, RuleName, PCtx1),
    {LeftBearerReq, PCtx} = make_request_bearer(PdrId, LeftBearer, PCtx2),

    PDR = pdr(PdrId, Precedence, src, LeftBearerReq, RightBearer, FilterInfo, FarId, URRs),

    RedirInfo = maps:get('Redirect-Information', Definition, undefined),
    FAR = far(FarId, RedirInfo, LeftBearer, RightBearer),

    Update#sx_upd{
      pctx = ergw_pfcp_rules:add(
	       [{pdr, RuleName, PDR},
		{far, RuleName, FAR}], PCtx)};

build_sx_rule(_Direction, Name, _Definition, _FilterInfo, _URRs,
	      _LeftBearer, _RightBearer, Update) ->
    sx_rule_error({system_error, Name}, Update).

%% ===========================================================================

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
    Time = ergw_gsn_lib:datetime_to_sntp_time(TTC),
    URR#{monitoring_time => #monitoring_time{time = Time}};

build_sx_usage_rule_4(Type, _, _, URR) ->
    ?LOG(warning, "build_sx_usage_rule_4: not handling ~p", [Type]),
    URR.

pctx_update_from_ctx(PCtx, #context{idle_timeout = IdleTimeout})
  when is_integer(IdleTimeout) ->
    %% UP timer is measured in seconds
    PCtx#pfcp_ctx{up_inactivity_timer = IdleTimeout div 1000};
pctx_update_from_ctx(PCtx, _) ->
    %% if idle_timeout /= integer, it is not set
    PCtx#pfcp_ctx{up_inactivity_timer = undefined}.

pfcp_pctx_update(#pfcp_ctx{up_inactivity_timer = UPiTnew} = PCtx,
		 #pfcp_ctx{up_inactivity_timer = UPiTold}, IEs)
  when UPiTold /= UPiTnew ->
    update_m_rec(ergw_pfcp:up_inactivity_timer(PCtx), IEs);
pfcp_pctx_update(_, _, IEs) ->
    IEs.

pfcp_user_id(#context{imsi = IMSI, imei = IMEI, msisdn = MSISDN}, IEs) ->
    IEs#{user_id => #user_id{imsi = IMSI, imei = IMEI, msisdn = MSISDN}};
pfcp_user_id(_, IEs) ->
    %% TDF contexts do not have user id information
    IEs.

handle_validity_time(_ChargingKey,
		     #{'Update-Time-Stamp' := BaseTime, 'Validity-Time' := {BaseTime, Time}},
		     URR0, #pfcp_ctx{features = #up_function_features{vtime = 1}} = PCtx) ->
    URR = maps:update_with(reporting_triggers,
			   fun(T) -> T#reporting_triggers{quota_validity_time = 1} end,
			   URR0#{quota_validity_time => #quota_validity_time{time = Time}}),
    {URR, PCtx};
handle_validity_time(ChargingKey, #{'Validity-Time' := {BaseTime, Time}}, URR, PCtx) ->
    AbsTime = erlang:convert_time_unit(BaseTime, native, millisecond) + Time * 1000,
    {URR, ergw_pfcp:set_timer(AbsTime, {ChargingKey, validity_time}, PCtx)};
handle_validity_time(_, _, URR, PCtx) ->
    {URR, PCtx}.

%% build_sx_usage_rule/3
build_sx_usage_rule(_K, #{'Rating-Group' := [RatingGroup],
			  'Granted-Service-Unit' := [GSU],
			  'Update-Time-Stamp' := UpdateTS} = GCU,
		    #sx_upd{pctx = PCtx0} = Update) ->
    ChargingKey = {online, RatingGroup},
    {UrrId, PCtx1} = ergw_pfcp:get_urr_id(ChargingKey, [RatingGroup], ChargingKey, PCtx0),

    URR0 = #{urr_id => #urr_id{id = UrrId},
	     measurement_method => #measurement_method{},
	     reporting_triggers => #reporting_triggers{},
	     'Update-Time-Stamp' => UpdateTS},

    {URR1, PCtx2} = handle_validity_time(ChargingKey, GCU, URR0, PCtx1),

%%% FIXME: triggering a report on Online RGs also triggers a Gy report.
%%%        linking them to the Offline for interim reporting will result
%%%        Gy reports without a Gy specific trigger.
%%% Note:  unlinking them breaks including Service Data Containers in ACRs when
%%%        one of the conditions in "IP-CAN bearer modification" are meet
%%%        see 3GPP TS 32.251, Sect. 5.2.3.4.1 and Table  5.2.3.4.1.1.

    %% {URR1, PCtx} =
    %%         case ergw_pfcp:get_urr_ids([{offline, RatingGroup}], PCtx2) of
    %%             [undefined] ->
    %%                 %% if this is an online only rule, do nothing
    %%                 {URR0, PCtx2};
    %%             [OffId] when is_integer(OffId)->
    %%                 %% if the same rule is use for offline and online reporting add a link
    %%                 build_sx_linked_rule(URR0, PCtx2)
    %%         end,
    {URR2, PCtx} = {URR1, PCtx2},

%%% FIXME - End

    URR = lists:foldl(build_sx_usage_rule_4(_, GSU, GCU, _), URR2,
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

make_pctx_bearer_key(_, #bearer{local = FqTEID}, PCtx, Keys)
  when is_record(FqTEID, fq_teid), is_integer(FqTEID#fq_teid.teid) ->
    [ergw_pfcp:ctx_teid_key(PCtx, FqTEID)|Keys];
make_pctx_bearer_key(_, _, _, Keys) ->
    Keys.

make_pctx_keys(Bearer, #pfcp_ctx{seid = #seid{cp = SEID}} = PCtx) ->
    maps:fold(make_pctx_bearer_key(_, _, PCtx, _), [#seid_key{seid = SEID}], Bearer).

register_ctx_ids(Handler, Bearer, PCtx) ->
    Keys = make_pctx_keys(Bearer, PCtx),
    gtp_context_reg:register(Keys, Handler, self()).

unregister_ctx_ids(Handler, Bearer, PCtx) ->
    Keys = make_pctx_keys(Bearer, PCtx),
    gtp_context_reg:unregister(Keys, Handler, self()).

%% ===========================================================================
%% Usage Report to Charging Event translation
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

%%%===================================================================
%%% UPF selection
%%%===================================================================

%% select/2
select(_, []) -> undefined;
select(first, L) -> hd(L);
select(random, L) when is_list(L) ->
    lists:nth(rand:uniform(length(L)), L).

%% select_upf/1
select_upf(Candidates) ->
    do([error_m ||
	   Available = ergw_sx_node_reg:available(),
	   Pid <- select_upf_with(fun(_, {Pid, _}) -> {ok, Pid} end, Candidates, Available),
	   ergw_sx_node:attach(Pid)
       ]).

%% select_upf_with/3
select_upf_with(_, [], _) ->
    {error, ?CTX_ERR(?FATAL, no_resources_available)};
select_upf_with(Fun, Candidates, Available) ->
    case ergw_node_selection:snaptr_candidate(Candidates) of
	{{Node, _, _}, Next} when is_map_key(Node, Available) ->
	    case Fun(Node, maps:get(Node, Available)) of
		{ok, _} = Result ->
		    Result;
		_ ->
		    select_upf_with(Fun, Next, Available)
	    end;
	{_, Next} ->
	    select_upf_with(Fun, Next, Available)
    end.

select_ip_pool(Version, HasVersions, Pools) ->
    case lists:member(Version, HasVersions) of
	true  -> select(random, Pools);
	false -> undefined
    end.

apn_filter(vrfs, V, F) ->
    F#{vrf => V};
apn_filter(ip_pools, V, F) ->
    F#{ip_pools => [[X] || X <- V]};
apn_filter(nat_port_blocks, V, F) ->
    F#{nat_port_blocks => [[X] || X <- V]};
apn_filter(_, _, F) ->
    F.

%% select_upf/3
select_upf(Candidates, Session0, APNOpts) ->
    Select = maps:get(upf_selection, APNOpts, ['3gpp']),
    select_upf(Candidates, Session0, APNOpts, Select).

%% select_upf/4
select_upf(_Candidates, _Session, _APNOpts, []) ->
    {error, ?CTX_ERR(?FATAL, no_resources_available)};
select_upf(Candidates, Session, APNOpts, ['3gpp'|_]) ->
    select_upf_3gpp(Candidates, Session, APNOpts);
select_upf(Candidates, Session, APNOpts, [API|Next]) ->
    case (catch API:upf_selection(Session)) of
	{ok, UPF} ->
	    select_upf_api_result(UPF, Session, APNOpts);
	{error, Error} ->
	    {error, ?CTX_ERR(?FATAL, Error)};
	skip ->
	    select_upf(Candidates, Session, APNOpts, Next);
	Other ->
	    ?LOG(error, #{what => "UPF selection", api => API, error => Other}),
	    {error, ?CTX_ERR(?FATAL, no_resources_available)}
    end.

select_upf_api_result(UPF, Session0, APNOpts) when is_binary(UPF) ->
    Available = ergw_sx_node_reg:available(),
    case Available of
	%% TODO: this NodePools/NodeCaps thing can be cleaned,
	%%       NodePools is contained within NodeCaps
	#{UPF := {Pid, {_, NodePools} = NodeCaps}} ->
	    Wanted = maps:fold(fun apn_filter/3, #{}, APNOpts),
	    case common_caps_n(Wanted, NodePools) of
		[] ->
		    {error, ?CTX_ERR(?FATAL, no_resources_available)};
		Pools ->
		    #{ip_pools := IPpools, ip_versions := IPvs,
		      nat_port_blocks := NATblocks, vrf := VRF} = select(random, Pools),
		    PoolV4 = select_ip_pool(v4, IPvs, IPpools),
		    PoolV6 = select_ip_pool(v6, IPvs, IPpools),
		    NAT = select(random, NATblocks),

		    Session1 = Session0#{'Framed-Pool' => PoolV4, 'Framed-IPv6-Pool' => PoolV6},
		    Session2 = case maps:is_key(nat_port_blocks, Wanted) of
				   true  -> Session1#{'NAT-Pool-Id' => NAT};
				   false -> Session1
			       end,
		    Session = init_session_ue_ifid(APNOpts, Session2),
		    Node = {UPF, Pid, NodeCaps, NodePools},
		    UPinfo = {api, Node, VRF, PoolV4, NAT, PoolV6},
		    {ok, {UPinfo, Session}}
	    end;
	_ ->
	    {error, ?CTX_ERR(?FATAL, no_resources_available)}
    end;
select_upf_api_result(_UPF, _Session, _APNOpts) ->
    {error, ?CTX_ERR(?FATAL, no_resources_available)}.

session_set_pool(Pool, Value, Session) when is_binary(Value) ->
    maps:put(Pool, Value, Session);
session_set_pool(_, _, Session) ->
    Session.

session_set_maybe(true, Key, Value, Session) ->
    maps:put(Key, Value, Session);
session_set_maybe(_, _, _, Session) ->
    Session.

%% select_upf_3gpp/3
select_upf_3gpp(Candidates, Session0, APNOpts) ->
    Wanted = maps:fold(fun apn_filter/3, #{}, APNOpts),
    do([error_m ||
	   {_, _, _, Pools} = Node <- select_by_caps(Wanted, undefined, Candidates),

	   #{ip_pools := IPpools, ip_versions := IPvs,
	     nat_port_blocks := NATblocks, vrf := VRF} = select(random, Pools),
	   PoolV4 = select_ip_pool(v4, IPvs, IPpools),
	   PoolV6 = select_ip_pool(v6, IPvs, IPpools),
	   NAT = select(random, NATblocks),

	   Session1 = session_set_pool('Framed-Pool', PoolV4, Session0),
	   Session2 = session_set_pool('Framed-IPv6-Pool', PoolV6, Session1),
	   Session3 = session_set_maybe(maps:is_key(nat_port_blocks, Wanted),
					 'NAT-Pool-Id', NAT, Session2),
	   Session = init_session_ue_ifid(APNOpts, Session3),
	   UPinfo = {Node, VRF, PoolV4, NAT, PoolV6},

	   return({UPinfo, Session})
       ]).

filter([]) -> #{};
filter([{_, undefined}|T]) -> filter(T);
filter([{Ver, IP}|T]) when Ver == v4; Ver == v6 ->
    maps:update_with(ip_versions, fun([X]) -> [[Ver|X]] end, [[Ver]],
		     maps:update_with(ip_pools, fun([X]) -> [lists:usort([IP|X])] end, [[IP]], filter(T)));
filter([{nat, NAT}|T]) ->
    maps:put(nat_port_blocks, [[NAT]], filter(T)).

%% reselect_upf/4
reselect_upf(_Candidates, Session, _APNOpts, {api, {_, Pid, NodeCaps, NodePools}, VRF0, PoolV4, NATBlock, PoolV6}) ->
    NAT = maps:get('NAT-Pool-Id', Session, undefined),
    IP4 = maps:get('Framed-Pool', Session, undefined),
    IP6 = maps:get('Framed-IPv6-Pool', Session, undefined),

    do([error_m ||
	   VRF <-
	       if (IP4 /= PoolV4 orelse IP6 /= PoolV6 orelse
		   NATBlock /= NAT) ->
		       Wanted = filter([{v4, IP4}, {v6, IP6}, {nat, NAT}]),
		       case common_caps_n(Wanted, NodePools) of
			   [] ->
			       fail(?CTX_ERR(?FATAL, no_resources_available));
			   Pools ->
			       #{vrf := VRF1} = select(random, Pools),
			       return(VRF1)
		       end;
		  true ->
		       return(VRF0)
	       end,
	   {PCtx, _} <- ergw_sx_node:attach(Pid),
	   return({PCtx, NodeCaps, #bearer{interface = 'SGi-LAN', vrf = VRF}})
       ]);
reselect_upf(Candidates, Session, _APNOpts, {{NodeName, _, _, _} = Node0, VRF0, PoolV4, NATBlock, PoolV6}) ->
    NAT = maps:get('NAT-Pool-Id', Session, undefined),
    IP4 = maps:get('Framed-Pool', Session, undefined),
    IP6 = maps:get('Framed-IPv6-Pool', Session, undefined),

    do([error_m ||
	   {{_, Pid, NodeCaps, _}, VRF} <-
	       if (IP4 /= PoolV4 orelse IP6 /= PoolV6 orelse
		   NATBlock /= NAT) ->
		       Wanted = filter([{v4, IP4}, {v6, IP6}, {nat, NAT}]),
		       do([error_m ||
			      {_, _, _, Pools} = Node1 <- select_by_caps(Wanted, NodeName, Candidates),
			      #{vrf := VRF1} = select(random, Pools),
			      return({Node1, VRF1})
			  ]);
		  true ->
		       return({Node0, VRF0})
	       end,
	   {PCtx, _} <- ergw_sx_node:attach(Pid),
	   return({PCtx, NodeCaps, #bearer{interface = 'SGi-LAN', vrf = VRF}})
       ]).

common_caps_f_pred(Has, Want)
  when is_binary(Has), is_list(Want) ->
    lists:member(Has, Want);
common_caps_f_pred(Has, WantAny)
  when is_list(Has), is_list(WantAny) ->
    fun Pred([]) -> false;
	Pred([WantAll|T]) -> Pred(T) orelse WantAll -- Has =:= []
    end(WantAny);
common_caps_f_pred(_, _) ->
    false.

common_caps_f_walk(_, none) ->
    true;
common_caps_f_walk(Pool, {K, V, Next})
  when is_map_key(K, Pool) ->
    case common_caps_f_pred(maps:get(K, Pool), V) of
	true  -> common_caps_f_walk(Pool, maps:next(Next));
	false -> false
    end;
common_caps_f_walk(_, _) ->
    false.

common_caps_f(Wanted, Pool) ->
    common_caps_f_walk(Pool, maps:next(maps:iterator(Wanted))).

common_caps_n(Wanted, NodePools) ->
    lists:filter(common_caps_f(Wanted, _), NodePools).

common_caps_n(_, [], _) ->
    [];
common_caps_n(Wanted, [{Node, _, _, _, _} = UPF|Next], Available)
  when is_map_key(Node, Available) ->
    {_, {_, NodePools}} = maps:get(Node, Available),
    case common_caps_n(Wanted, NodePools) of
	[] -> common_caps_n(Wanted, Next, Available);
	_  -> [UPF|common_caps_n(Wanted, Next, Available)]
    end;
common_caps_n(Wanted, [_|Next], Available) ->
    common_caps_n(Wanted, Next, Available).

%% select_by_caps/3
select_by_caps(Wanted, Preferred, Candidates) ->
    Available = ergw_sx_node_reg:available(),
    Eligible = common_caps_n(Wanted, Candidates, Available),

    case lists:keymember(Preferred, 1, Eligible) of
	true when is_map_key(Preferred, Available) ->
	    Node = maps:get(Preferred, Available),
	    filter_by_caps_f(Preferred, Wanted, Node);
	_ ->
	    %% Note: common_caps/5 filters all **Available** nodes by capabilities first,
	    %%       select_upf_with/3 can therefor simply take the node with the highest precedence.
	    select_upf_with(filter_by_caps_f(_, Wanted, _), Eligible, Available)
    end.

%% filter_by_caps_f/2
filter_by_caps_f(NodeName, Wanted, {Pid, {_, NodePools} = NodeCaps}) ->
    SPools = common_caps_n(Wanted, NodePools),
    {ok, {NodeName, Pid, NodeCaps, SPools}}.

%%%===================================================================

init_session_ue_ifid(APNOpts, #{'3GPP-PDP-Type' := Type} = Session)
  when Type =:= 'IPv6'; Type =:= 'IPv4v6' ->
    ReqIPv6 = maps:get('Requested-IPv6-Prefix', Session, {?ZERO_IPv6, 64}),
    IfId = ue_interface_id(ReqIPv6, APNOpts),
    Session#{'Framed-Interface-Id' => IfId};
init_session_ue_ifid(_, Session) ->
    Session.

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

%%%===================================================================
%%% T-PDU functions
%%%===================================================================

send_g_pdu(PCtx, #bearer{vrf = VRF,
			 local = #fq_teid{ip = SrcIP},
			 remote = #fq_teid{ip = DstIP, teid = TEID}}, Data) ->
    GTP = #gtp{version =v1, type = g_pdu, tei = TEID, ie = Data},
    PayLoad = gtp_packet:encode(GTP),
    UDP = ergw_inet:make_udp(
	    ergw_inet:ip2bin(SrcIP), ergw_inet:ip2bin(DstIP),
	    ?GTP1u_PORT, ?GTP1u_PORT, PayLoad),
    ergw_sx_node:send(PCtx, 'Access', VRF, UDP),
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
