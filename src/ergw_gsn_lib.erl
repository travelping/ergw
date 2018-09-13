%% Copyright 2017,2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gsn_lib).

-compile({parse_transform, cut}).

-export([create_sgi_session/3,
	 usage_report_to_credit_report/2,
	 usage_report_to_monitoring_report/2,
	 pcc_rules_to_credit_request/1,
	 modify_sgi_session/3,
	 delete_sgi_session/2,
	 query_usage_report/1, query_usage_report/2,
	 choose_context_ip/3,
	 ip_pdu/2]).
-export([update_pcc_rules/2, session_events/3]).
-export([find_sx_by_id/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include("include/ergw.hrl").

-record(sx_ids, {cnt = #{}, idmap = #{}}).
-record(sx_upd, {errors = [], rules = #{}, monitors = #{}, ids = #sx_ids{}, context}).

%%%===================================================================
%%% Sx DP API
%%%===================================================================

delete_sgi_session(normal, #context{dp_seid = SEID} = Ctx) ->
    Req = #pfcp{version = v1, type = session_deletion_request, seid = SEID, ie = []},
    case ergw_sx_node:call(Ctx, Req) of
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

query_usage_report(#context{dp_seid = SEID, sx_ids = #sx_ids{idmap = #{urr := URRs}}} = Ctx) ->
    lager:error("Q URRs: ~p", [URRs]),
    IEs = maps:fold(fun(K, V, A) when is_integer(V) ->
			    [#query_urr{group = [#urr_id{id = K}]} | A];
		       (_, _, A) -> A
		    end, [], URRs),
    Req = #pfcp{version = v1, type = session_modification_request,
		seid = SEID, ie = IEs},
    ergw_sx_node:call(Ctx, Req);
query_usage_report(_) ->
    undefined.

query_usage_report(RatingGroup, #context{dp_seid = SEID,
					 sx_ids = #sx_ids{idmap = #{urr := URRs}}} = Ctx) ->
    lager:error("Q URRs: ~p", [URRs]),
    case URRs of
	#{RatingGroup := Id} ->
	    IEs = [#query_urr{group = [#urr_id{id = Id}]}],
	    Req = #pfcp{version = v1, type = session_modification_request,
			seid = SEID, ie = IEs},
	    ergw_sx_node:call(Ctx, Req);
	_ ->
	    undefined
    end.

%%%===================================================================
%%% Helper functions
%%%===================================================================

create_ipv6_mcast_pdr(PdrId, FarId,
		      #context{
			 data_port = #gtp_port{ip = IP} = DataPort,
			 local_data_tei = LocalTEI,
			 ms_v6 = IPv6},
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
			  ergw_pfcp:network_instance(DataPort),
			  ergw_pfcp:f_teid(LocalTEI, IP),
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
		    #context{cp_port = #gtp_port{ip = CpIP} = CpPort, cp_tei = CpTEI},
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

sx_id(Type, Name, #context{sx_ids = SxIds0} = Ctx) ->
    SxIds1 = if is_record(SxIds0, sx_ids) -> SxIds0;
		true -> #sx_ids{}
	     end,
    {Id, SxIds} = sx_id(Type, Name, SxIds1),
    {Id, Ctx#context{sx_ids = SxIds}};
sx_id(Type, Name, #sx_upd{ids = Ids0} = Upd) ->
    {Id, Ids} = sx_id(Type, Name, Ids0),
    {Id, Upd#sx_upd{ids = Ids}};
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

find_sx_id(Type, Name, #sx_upd{ids = Ids0}) ->
    find_sx_id(Type, Name, Ids0);
find_sx_id(Type, Name, #sx_ids{idmap = IdMap}) ->
    Key = {Type, Name},
    maps:find(Key, IdMap).

find_sx_by_id(Type, Id, #sx_ids{idmap = IdMap}) ->
    TypeId = maps:get(Type, IdMap, #{}),
    maps:find(Id, TypeId).

build_sx_rules(SessionOpts, Opts, #context{sx_ids = SxIds0, sx_rules = OldSxRules} = Ctx) ->
    Monitors = maps:get(monitoring, SessionOpts, #{}),
    PolicyRules = maps:get(rules, SessionOpts, #{}),
    Credits = maps:get('Multiple-Services-Credit-Control', SessionOpts, []),
    SxIds1 = if is_record(SxIds0, sx_ids) -> SxIds0;
		true -> #sx_ids{}
	     end,

    Update0 = #sx_upd{ids = SxIds1, context = Ctx},
    Update1 = maps:fold(fun build_sx_monitor_rule/3, Update0, Monitors),
    Update2 = maps:fold(build_sx_offline_charging_rule(_, _, SessionOpts, _), Update1, PolicyRules),
    Update3 = lists:foldl(fun build_sx_usage_rule/2, Update2, Credits),
    Update4 = maps:fold(fun build_sx_rule/3, Update3, PolicyRules),
    #sx_upd{errors = Errors, rules = NewSxRules, ids = SxIds2} =
	Update4,

    SxRuleReq = update_sx_rules(OldSxRules, NewSxRules, Opts),

    %% TODO:
    %% remove unused SxIds

    {SxRuleReq, Errors, Ctx#context{sx_ids = SxIds2, sx_rules = NewSxRules}}.

build_sx_offline_charging_rule(_Name,
			       #{'Rating-Group' := [RatingGroup],
				 'Offline' := [1]} = Definition,
			       SessionOpts, #sx_upd{rules = Rules} = Update0) ->
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

    {UrrId, Update} = sx_id(urr, ChargingKey, Update0),
    URR = #{urr_id => #urr_id{id = UrrId},
	    measurement_method => MM,
	    reporting_triggers => #reporting_triggers{periodic_reporting = 1},
	    measurement_period =>
		#measurement_period{
		   period = maps:get('Acct-Interim-Interval', SessionOpts, 600)}
	   },

    lager:warning("Offline URR: ~p", [URR]),
    Update#sx_upd{rules = Rules#{{urr, ChargingKey} => URR}};

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
		 rules = Rules,
		 context = #context{
			      data_port = DataPort,
			      remote_data_teid = PeerTEID} = Ctx
		} = Update0)
  when PeerTEID /= undefined ->
    [Precedence] = maps:get('Precedence', Definition, [1000]),
    RuleName = {Direction, Name},
    {PdrId, Update1} = sx_id(pdr, RuleName, Update0),
    {FarId, Update2} = sx_id(far, RuleName, Update1),
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
		   ergw_pfcp:network_instance(DataPort),
		   ergw_pfcp:outer_header_creation(PeerTEID)
		  ]
	     }
	  ],
    Update2#sx_upd{
      rules =
	  Rules#{
		 {pdr, RuleName} => pfcp_packet:ies_to_map(PDR),
		 {far, RuleName} => pfcp_packet:ies_to_map(FAR)
		}
     };
build_sx_rule(Direction = uplink, Name, Definition, FilterInfo, URRs,
	      #sx_upd{rules = Rules,
		 context = #context{
			      data_port = #gtp_port{ip = IP} = DataPort,
			      local_data_tei = LocalTEI} = Ctx
		     } = Update0) ->
    [Precedence] = maps:get('Precedence', Definition, [1000]),
    RuleName = {Direction, Name},
    {PdrId, Update1} = sx_id(pdr, RuleName, Update0),
    {FarId, Update2} = sx_id(far, RuleName, Update1),
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'Access'},
		  ergw_pfcp:network_instance(DataPort),
		  ergw_pfcp:f_teid(LocalTEI, IP),
		  ergw_pfcp:ue_ip_address(src, Ctx)] ++
		 build_sx_filter(FilterInfo)
	    },
    PDR = [#pdr_id{id = PdrId},
	   #precedence{precedence = Precedence},
	   PDI,
	   ergw_pfcp:outer_header_removal(IP),
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
    Update2#sx_upd{
      rules =
	  Rules#{
		 {pdr, RuleName} => pfcp_packet:ies_to_map(PDR),
		 {far, RuleName} => pfcp_packet:ies_to_map(FAR)
		}
     };

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
    %% Time = calendar:datetime_to_gregorian_seconds(TTC) - 62167219200,   %% 1970
    %% Time = calendar:datetime_to_gregorian_seconds(TTC) - 59958230400,   %% 1900
    Time = seconds_to_sntp_time(
	     calendar:datetime_to_gregorian_seconds(TTC) - 62167219200),   %% 1970
    URR#{monitoring_time => #monitoring_time{time = Time}};

build_sx_usage_rule(Type, _, _, URR) ->
    lager:warning("build_sx_usage_rule: not handling ~p", [Type]),
    URR.

build_sx_usage_rule(#{'Result-Code' := [2001],
		      'Rating-Group' := [ChargingKey],
		      'Granted-Service-Unit' := [GSU]} = GCU,
		    #sx_upd{rules = Rules} = Update0) ->
    {UrrId, Update} = sx_id(urr, ChargingKey, Update0),
    URR0 = #{urr_id => #urr_id{id = UrrId},
	     measurement_method => #measurement_method{},
	     reporting_triggers => #reporting_triggers{}},
    URR = lists:foldl(build_sx_usage_rule(_, GSU, GCU, _), URR0,
		      [time, time_quota_threshold,
		       total_octets, input_octets, output_octets,
		       total_quota_threshold, input_quota_threshold, output_quota_threshold,
		       monitoring_time]),

    lager:warning("URR: ~p", [URR]),
    Update#sx_upd{rules = Rules#{{urr, ChargingKey} => URR}};
build_sx_usage_rule(Definition, Update) ->
    lager:error("URR: ~p", [Definition]),
    sx_rule_error({system_error, Definition}, Update).

build_sx_monitor_rule(Service, {'IP-CAN', periodic, Time} = _Definition,
		      #sx_upd{rules = Rules, monitors = Monitors0} = Update0) ->
    lager:info("Sx Monitor Rule: ~p", [_Definition]),

    RuleName = {monitor, 'IP-CAN', Service},
    {UrrId, Update} = sx_id(urr, RuleName, Update0),

    URR = pfcp_packet:ies_to_map(
	    [#urr_id{id = UrrId},
	     #measurement_method{volum = 1, durat = 1},
	     #reporting_triggers{periodic_reporting = 1},
	     #measurement_period{period = Time}]),

    lager:warning("URR: ~p", [URR]),
    Monitors1 = update_m_key('IP-CAN', UrrId, Monitors0),
    Monitors = Monitors1#{{urr, UrrId}  => Service},
    Update#sx_upd{rules = Rules#{{urr, RuleName} => URR}, monitors = Monitors};

build_sx_monitor_rule(Service, Definition, Update) ->
    lager:error("Monitor URR: ~p:~p", [Service, Definition]),
    sx_rule_error({system_error, Definition}, Update).

update_sx_usage_rules(Update, #{context := Ctx} = State) ->
    Init = #sx_upd{ids = Ctx#context.sx_ids, context = Ctx},
    #sx_upd{errors = Errors, rules = Rules, ids = SxIds} =
	lists:foldl(fun build_sx_usage_rule/2, Init, Update),

    lager:info("Sx Modify: ~p, (~p)", [maps:values(Rules), Errors]),

    case maps:values(Rules) of
	[] ->
	    ok;
	RulesList when is_list(RulesList) ->
	    URRs = [#update_urr{group = V} || V <- RulesList],
	    lager:info("Sx Modify: ~p", [URRs]),

	    IEs = [#update_urr{group = V} || V <- maps:values(Rules)],
	    Req = #pfcp{version = v1, type = session_modification_request,
			seid = Ctx#context.dp_seid, ie = IEs},
	    R = ergw_sx_node:call(Ctx, Req),
	    lager:warning("R: ~p", [R]),
	    ok
    end,
    State#{context => Ctx#context{sx_ids = SxIds}}.

update_m_key(Key, Value, Map) ->
    maps:update_with(Key, [Value | _], [Value], Map).

update_m_rec(Record, Map) when is_tuple(Record) ->
    maps:update_with(element(1, Record), [Record | _], [Record], Map).

put_rec(Record, Map) when is_tuple(Record) ->
    maps:put(element(1, Record), Record, Map).

update_sx_rules(Old, New, Opts) ->
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
    Ctx1 = ergw_sx_node:select_sx_node(Candidates, Ctx0),
    Ctx2 = ergw_pfcp:assign_data_teid(Ctx1, control),
    SEID = ergw_sx_socket:seid(),
    {ok, #node{node = _Node, ip = IP}, _} = ergw_sx_socket:id(),

    {CPinFarId, Ctx3} = sx_id(far, dp_to_cp_far, Ctx2),
    {IPv6MCastPdrId, Ctx4} = sx_id(pdr, ipv6_mcast_pdr, Ctx3),

    {SxRules0, SxErrors, Ctx} = build_sx_rules(SessionOpts, #{}, Ctx4),
    lager:info("SxRules: ~p~n", [SxRules0]),
    lager:info("SxErrors: ~p~n", [SxErrors]),
    lager:info("CtxPending: ~p~n", [Ctx]),

    SxRules1 = create_dp_to_cp_far(access, CPinFarId, Ctx, SxRules0),
    SxRules2 = create_ipv6_mcast_pdr(IPv6MCastPdrId, CPinFarId, Ctx, SxRules1),
    IEs = update_m_rec(ergw_pfcp:f_seid(SEID, IP), SxRules2),

    lager:info("IEs: ~p~n", [IEs]),

    Req = #pfcp{version = v1, type = session_establishment_request, seid = 0, ie = IEs},
    case ergw_sx_node:call(Ctx, Req) of
	#pfcp{version = v1, type = session_establishment_response,
	      %% seid = SEID, TODO: fix DP
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'},
		     f_seid := #f_seid{seid = DataPathSEID}} = _RespIEs} ->
	    Ctx#context{cp_seid = SEID, dp_seid = DataPathSEID};
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, Ctx))
    end.

modify_sgi_session(SessionOpts, Opts, #context{dp_seid = SEID} = Ctx) ->
    {SxRules0, SxErrors, CtxPending} = build_sx_rules(SessionOpts, Opts, Ctx),

    %% TODO: at the moment, modify_sgi_session is only used to change TEIDs,
    SxRules = maps:without([update_urr], SxRules0),

    lager:info("SxRules: ~p~n", [SxRules]),
    lager:info("SxErrors: ~p~n", [SxErrors]),
    lager:info("CtxPending: ~p~n", [CtxPending]),

    Req = #pfcp{version = v1, type = session_modification_request, seid = SEID, ie = SxRules},
    case ergw_sx_node:call(CtxPending, Req) of
	#pfcp{version = v1, type = session_modification_response,
	      %% seid = SEID, TODO: fix DP
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} = _RespIEs} ->
	    CtxPending;
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, CtxPending))
    end.


opt_int(X) when is_integer(X) -> [X];
opt_int(_) -> [].

opt_int(K, X, M) when is_integer(X) -> M#{K => X};
opt_int(_, _, M) -> M.

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

usage_report_to_credit_report(#{urr_id := #urr_id{id = Id},
				usage_report_trigger := Trigger} = URR) ->
    Report0 = trigger_to_reason(Trigger, #{}),
    Report1 = tariff_change_usage(URR, Report0),
    Report2 = credit_report_volume(maps:get(volume_measurement, URR, undefined), Report1),
    Report = credit_report_duration(maps:get(duration_measurement, URR, undefined), Report2),
    {Id, Report}.

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

usage_report_to_credit_report({Id, Report}, UrrMap, R) ->
    lager:warning("usage_report_to_credit_report: ~p, ~p", [Id, UrrMap]),
    case UrrMap of
	#{Id := ChargingKey} when is_integer(ChargingKey) ->
	    [{ChargingKey, Report} | R];
	_ ->
	    R
    end.

usage_report_to_credit_report(URR, #context{sx_ids = #sx_ids{idmap = IdMap}}) ->
    CR = map_usage_report(fun usage_report_to_credit_report/1, URR),
    lists:foldl(usage_report_to_credit_report(_, maps:get(urr, IdMap, #{}), _), [], CR).

monitor_report_volume(#volume_measurement{uplink = UL, downlink = DL}, Report0) ->
    Report = opt_int('InOctets', UL, Report0),
    opt_int('OutOctets', DL, Report);
monitor_report_volume(_, Report) ->
    Report.

monitor_report_duration(#duration_measurement{duration = Duration}, Report) ->
    opt_int('Session-Time', Duration, Report);
monitor_report_duration(_, Report) ->
    Report.

usage_report_to_monitor_report(#{urr_id := #urr_id{id = Id}} = URR) ->
    Report0 = monitor_report_volume(maps:get(volume_measurement, URR, undefined), #{}),
    Report = monitor_report_duration(maps:get(duration_measurement, URR, undefined), Report0),
    {Id, Report}.

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

usage_report_to_monitoring_report(URR, #context{sx_ids = #sx_ids{idmap = IdMap}}) ->
    CR = map_usage_report(fun usage_report_to_monitor_report/1, URR),
    CR1 = maps:fold(usage_report_to_monitor_report(_, _, maps:from_list(CR), _), #{}, IdMap),
    lager:warning("Monitoring Report ~p", [lager:pr(CR1, ?MODULE)]),
    CR1.

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
       #context{data_port = #gtp_port{ip = DpGtpIP, vrf = VRF},
		remote_data_teid = #fq_teid{ip = GtpIP, teid = TEID},
		ms_v6 = MSv6, dns_v6 = DNSv6} = Context) ->
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
    GTP = #gtp{version =v1, type = g_pdu, tei = TEID, ie = ICMPv6},
    PayLoad = gtp_packet:encode(GTP),
    UDP = ergw_inet:make_udp(
	    ergw_inet:ip2bin(DpGtpIP), ergw_inet:ip2bin(GtpIP),
	    ?GTP1u_PORT, ?GTP1u_PORT, PayLoad),
    ergw_sx_node:send(Context, 'Access', VRF, UDP),
    ok;

icmpv6(_TC, _FlowLabel, _SrcAddr, _DstAddr, _PayLoad, _Context) ->
    lager:warning("unhandeld ICMPv6 from ~p to ~p: ~p", [_SrcAddr, _DstAddr, _PayLoad]),
    ok.
