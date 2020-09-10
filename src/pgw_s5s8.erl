%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8).

-behaviour(gtp_api).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([validate_options/1, init/2, request_spec/3,
	 handle_pdu/4, handle_sx_report/3,
	 handle_request/5, handle_response/5,
	 handle_event/4, terminate/3]).

%% shared API's
-export([init_session/3, init_session_from_gtp_req/4]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define(GTP_v1_Interface, ggsn_gn).
-define(T3, 10 * 1000).
-define(N3, 5).

%%====================================================================
%% API
%%====================================================================

-define('Cause',					{v2_cause, 0}).
-define('Recovery',					{v2_recovery, 0}).
-define('IMSI',						{v2_international_mobile_subscriber_identity, 0}).
-define('MSISDN',					{v2_msisdn, 0}).
-define('PDN Address Allocation',			{v2_pdn_address_allocation, 0}).
-define('RAT Type',					{v2_rat_type, 0}).
-define('Sender F-TEID for Control Plane',		{v2_fully_qualified_tunnel_endpoint_identifier, 0}).
-define('Access Point Name',				{v2_access_point_name, 0}).
-define('Bearer Contexts to be created',		{v2_bearer_context, 0}).
-define('Bearer Contexts to be modified',		{v2_bearer_context, 0}).
-define('Protocol Configuration Options',		{v2_protocol_configuration_options, 0}).
-define('ME Identity',					{v2_mobile_equipment_identity, 0}).
-define('APN-AMBR',					{v2_aggregate_maximum_bit_rate, 0}).
-define('Bearer Level QoS',				{v2_bearer_level_quality_of_service, 0}).
-define('EPS Bearer ID',                                {v2_eps_bearer_id, 0}).
-define('SGW-U node name',                              {v2_fully_qualified_domain_name, 0}).
-define('Secondary RAT Usage Data Report',              {v2_secondary_rat_usage_data_report, 0}).

-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).

-define(ABORT_CTX_REQUEST(Context, Request, Type, Cause),
	begin
	    AbortReply = response(Type, Context, [#v2_cause{v2_cause = Cause}], Request),
	    throw(?CTX_ERR(?FATAL, AbortReply, Context))
	end).

-define(CAUSE_OK(Cause), (Cause =:= request_accepted orelse
			  Cause =:= request_accepted_partially orelse
			  Cause =:= new_pdp_type_due_to_network_preference orelse
			  Cause =:= new_pdp_type_due_to_single_address_bearer_only)).

request_spec(v1, Type, Cause) ->
    ?GTP_v1_Interface:request_spec(v1, Type, Cause);
request_spec(v2, _Type, Cause)
  when Cause /= undefined andalso not ?CAUSE_OK(Cause) ->
    [];
request_spec(v2, create_session_request, _) ->
    [{?'RAT Type',						mandatory},
     {?'Sender F-TEID for Control Plane',			mandatory},
     {?'Access Point Name',					mandatory},
     {?'APN-AMBR' ,						mandatory},
     {?'Bearer Contexts to be created',				mandatory}];
request_spec(v2, delete_session_request, _) ->
    [];
request_spec(v2, modify_bearer_request, _) ->
    [];
request_spec(v2, modify_bearer_command, _) ->
    [{?'APN-AMBR' ,						mandatory},
     {?'Bearer Contexts to be modified',			mandatory}];
request_spec(v2, resume_notification, _) ->
    [{?'IMSI',							mandatory}];
request_spec(v2, _, _) ->
    [].

validate_options(Options) ->
    ?LOG(debug, "GGSN S5/S8 Options: ~p", [Options]),
    gtp_context:validate_options(fun validate_option/2, Options, []).

validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

init(_Opts, Data) ->
    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),
    SessionOpts = ergw_aaa_session:get(Session),
    OCPcfg = maps:get('Offline-Charging-Profile', SessionOpts, #{}),
    PCC = #pcc_ctx{offline_charging_profile = OCPcfg},
    {ok, run, Data#{'Version' => v2, 'Session' => Session, pcc => PCC}}.

handle_event(Type, Content, State, #{'Version' := v1} = Data) ->
    ?GTP_v1_Interface:handle_event(Type, Content, State, Data);

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event({call, From}, delete_context, run, Data) ->
    delete_context(From, administrative, Data);
handle_event({call, From}, delete_context, shutdown, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, ok}}]};
handle_event({call, _From}, delete_context, _State, _Data) ->
    {keep_state_and_data, [postpone]};

handle_event({call, From}, terminate_context, _State, Data) ->
    close_pdn_context(normal, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, Path}, _State,
	     #{context := #context{path = Path}} = Data) ->
    close_pdn_context(normal, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, _Path}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

handle_event(cast, {defered_usage_report, URRActions, UsageReport}, _State,
	    #{pfcp := PCtx, 'Session' := Session}) ->
    Now = erlang:monotonic_time(),
    case proplists:get_value(offline, URRActions) of
	{ChargeEv, OldS} ->
	    {_Online, Offline, _} =
		ergw_gsn_lib:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),
	    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, OldS, Session);
	_ ->
	    ok
    end,
    keep_state_and_data;

handle_event(cast, delete_context, run, Data) ->
    delete_context(undefined, administrative, Data);
handle_event(cast, delete_context, _State, _Data) ->
    keep_state_and_data;

handle_event(cast, {packet_in, _GtpPort, _IP, _Port, _Msg}, _State, _Data) ->
    ?LOG(warning, "packet_in not handled (yet): ~p", [_Msg]),
    keep_state_and_data;

handle_event(info, {'DOWN', _MonitorRef, Type, Pid, _Info}, _State,
	    #{pfcp := #pfcp_ctx{node = Pid}} = Data)
  when Type == process; Type == pfcp ->
    close_pdn_context(upf_failure, Data),
    {next_state, shutdown, Data};

handle_event(info, #aaa_request{procedure = {_, 'ASR'}} = Request, run, Data) ->
    ergw_aaa_session:response(Request, ok, #{}, #{}),
    delete_context(undefined, administrative, Data);
handle_event(info, #aaa_request{procedure = {_, 'ASR'}} = Request, _State, _Data) ->
    ergw_aaa_session:response(Request, ok, #{}, #{}),
    keep_state_and_data;

handle_event(info, #aaa_request{procedure = {gx, 'RAR'},
				events = Events} = Request,
	     run,
	     #{context := Context, pfcp := PCtx0,
	       'Session' := Session, pcc := PCC0} = Data) ->
%%% 1. update PCC
%%%    a) calculate PCC rules to be removed
%%%    b) calculate PCC rules to be installed
%%% 2. figure out which Rating-Groups are new or which ones have to be removed
%%%    based on updated PCC rules
%%% 3. remove PCC rules and unsused Rating-Group URRs from UPF
%%% 4. on Gy:
%%%     - report removed URRs/RGs
%%%     - request credits for new URRs/RGs
%%% 5. apply granted quotas to PCC rules, remove PCC rules without quotas
%%% 6. install new PCC rules which have granted quota
%%% 7. report remove and not installed (lack of quota) PCC rules on Gx

    Now = erlang:monotonic_time(),
    ReqOps = #{now => Now},

    RuleBase = ergw_charging:rulebase(),

%%% step 1a:
    {PCC1, _} =
	ergw_gsn_lib:gx_events_to_pcc_ctx(Events, remove, RuleBase, PCC0),
%%% step 1b:
    {PCC2, PCCErrors2} =
	ergw_gsn_lib:gx_events_to_pcc_ctx(Events, install, RuleBase, PCC1),

%%% step 2
%%% step 3:
    {PCtx1, UsageReport} =
	ergw_gsn_lib:modify_sgi_session(PCC1, [], #{}, Context, PCtx0),

%%% step 4:
    ChargeEv = {online, 'RAR'},   %% made up value, not use anywhere...
    {Online, Offline, Monitor} =
	ergw_gsn_lib:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx1),

    ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),
    GyReqServices = ergw_gsn_lib:gy_credit_request(Online, PCC0, PCC2),
    {ok, _, GyEvs} =
	ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOps),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),

%%% step 5:
    {PCC4, PCCErrors4} = ergw_gsn_lib:gy_events_to_pcc_ctx(Now, GyEvs, PCC2),

%%% step 6:
    {PCtx, _} =
	ergw_gsn_lib:modify_sgi_session(PCC4, [], #{}, Context, PCtx1),

%%% step 7:
    %% TODO Charging-Rule-Report for successfully installed/removed rules

    GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(PCCErrors2 ++ PCCErrors4),
    ergw_aaa_session:response(Request, ok, GxReport, #{}),
    {keep_state, Data#{pfcp := PCtx, pcc := PCC4}};

handle_event(info, #aaa_request{procedure = {gy, 'RAR'},
				events = Events} = Request,
	     run, Data) ->
    ergw_aaa_session:response(Request, ok, #{}, #{}),
    Now = erlang:monotonic_time(),

    %% Triggered CCR.....
    ChargingKeys =
	case proplists:get_value(report_rating_group, Events) of
	    RatingGroups when is_list(RatingGroups) ->
		[{online, RG} || RG <- RatingGroups];
	    _ ->
		undefined
	end,
    triggered_charging_event(interim, Now, ChargingKeys, Data),
    keep_state_and_data;

handle_event(info, #aaa_request{procedure = {_, 'RAR'}} = Request, _State, _Data) ->
    ergw_aaa_session:response(Request, {error, unknown_session}, #{}, #{}),
    keep_state_and_data;

handle_event(info, {pfcp_timer, #{validity_time := ChargingKeys}}, _State, Data) ->
    Now = erlang:monotonic_time(),
    triggered_charging_event(validity_time, Now, ChargingKeys, Data),
    keep_state_and_data;

handle_event(info, _Info, _State, _Data) ->
    keep_state_and_data;

handle_event({timeout, context_idle}, stop_session, _state, Data) ->
    delete_context(undefined, normal, Data);

handle_event(internal, {session, stop, _Session}, run, Data) ->
    delete_context(undefined, normal, Data);
handle_event(internal, {session, stop, _Session}, _, _) ->
    keep_state_and_data;

handle_event(internal, {session, {update_credits, _} = CreditEv, _}, _State,
	     #{context := Context, pfcp := PCtx0, pcc := PCC0} = Data) ->
    Now = erlang:monotonic_time(),

    {PCC, _PCCErrors} = ergw_gsn_lib:gy_events_to_pcc_ctx(Now, [CreditEv], PCC0),
    {PCtx, _} =
	ergw_gsn_lib:modify_sgi_session(PCC, [], #{}, Context, PCtx0),

    {keep_state, Data#{pfcp := PCtx, pcc := PCC}};

handle_event(internal, {session, Ev, _}, _State, _Data) ->
    ?LOG(error, "unhandled session event: ~p", [Ev]),
    keep_state_and_data;

handle_event(cast, Ev, _State, _Data)
  when is_tuple(Ev), element(1, Ev) =:= '$' ->
    %% late async events, just ignore them...
    ?LOG(debug, "late event: ~p", [Ev]),
    keep_state_and_data.

handle_pdu(ReqKey, #gtp{ie = PDU} = Msg, _State,
	   #{context := Context, pfcp := PCtx} = Data) ->
    ?LOG(debug, "GTP-U PGW: ~p, ~p", [ReqKey, gtp_c_lib:fmt_gtp(Msg)]),

    ergw_gsn_lib:ip_pdu(PDU, Context, PCtx),
    {keep_state, Data}.

handle_sx_report(#pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{erir = 1}}},
	    _State, Data) ->
    close_pdn_context(normal, Data),
    {shutdown, Data};

%% User Plane Inactivity Timer expired
handle_sx_report(#pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{upir = 1}}},
		 _State, Data) ->
    close_pdn_context(normal, Data),
    {shutdown, Data};

handle_sx_report(Report, State, Data) ->
    ?GTP_v1_Interface:handle_sx_report(Report, State, Data).

defered_usage_report(Server, URRActions, Report) ->
    gen_statem:cast(Server, {defered_usage_report, URRActions, Report}).

%% API Message Matrix:
%%
%% SGSN/MME/ TWAN/ePDG to PGW (S4/S11, S5/S8, S2a, S2b)
%%
%%   Create Session Request/Response
%%   Delete Session Request/Response
%%
%% SGSN/MME/ePDG to PGW (S4/S11, S5/S8, S2b)
%%
%%   Modify Bearer Request/Response
%%
%% SGSN/MME to PGW (S4/S11, S5/S8)
%%
%%   Change Notification Request/Response
%%   Resume Notification/Acknowledge

handle_request(ReqKey, #gtp{version = v1} = Msg, Resent, State, Data) ->
    ?GTP_v1_Interface:handle_request(ReqKey, Msg, Resent, State, Data#{'Version' => v1});
handle_request(ReqKey, #gtp{version = v2} = Msg, Resent, State, #{'Version' := v1} = Data) ->
    handle_request(ReqKey, Msg, Resent, State, Data#{'Version' => v2});

handle_request(_ReqKey, _Msg, true, _State, _Data) ->
    %% resent request
    keep_state_and_data;

handle_request(ReqKey,
	       #gtp{type = create_session_request,
		    ie = #{?'Sender F-TEID for Control Plane' := FqCntlTEID,
			   ?'Access Point Name' := #v2_access_point_name{apn = APN},
			   ?'Bearer Contexts to be created' :=
			       #v2_bearer_context{
				  group = #{
				    ?'EPS Bearer ID'     := EBI,
				    {v2_fully_qualified_tunnel_endpoint_identifier, 2} :=
					%% S5/S8 SGW GTP-U Interface
					#v2_fully_qualified_tunnel_endpoint_identifier{interface_type = ?'S5/S8-U SGW'} =
					FqDataTEID
				   }}
			  } = IEs} = Request,
	       _Resent, _State,
	       #{context := Context0, aaa_opts := AAAopts, node_selection := NodeSelect,
		 'Session' := Session, pcc := PCC0} = Data) ->

    APN_FQDN = ergw_node_selection:apn_to_fqdn(APN),
    Services = [{"x-3gpp-upf", "x-sxb"}],
    SGWuNode =
	case IEs of
	    #{?'SGW-U node name' := #v2_fully_qualified_domain_name{fqdn = SGWuFQDN}} ->
		SGWuFQDN;
	    _ -> []
	end,
    Candidates = ergw_node_selection:topology_select(APN_FQDN, SGWuNode, Services, NodeSelect),
    SxConnectId = ergw_sx_node:request_connect(Candidates, NodeSelect, 1000),

    Context1 = update_context_tunnel_ids(FqCntlTEID, FqDataTEID, Context0),
    Context2 = update_context_from_gtp_req(Request, Context1),
    ContextPreAuth = gtp_path:bind(Request, false, Context2),

    gtp_context:terminate_colliding_context(ContextPreAuth),

    PAA = maps:get(?'PDN Address Allocation', IEs, undefined),
    DAF = proplists:get_bool('DAF', gtp_v2_c:get_indication_flags(IEs)),

    SessionOpts0 = init_session(IEs, ContextPreAuth, AAAopts),
    SessionOpts1 = init_session_from_gtp_req(IEs, AAAopts, ContextPreAuth, SessionOpts0),
    %% SessionOpts = init_session_qos(ReqQoSProfile, SessionOpts1),

    ergw_sx_node:wait_connect(SxConnectId),
    {UPinfo0, ContextUP} = ergw_gsn_lib:select_upf(Candidates, ContextPreAuth),

    SessionOpts  = ergw_gsn_lib:init_session_ip_opts(UPinfo0, ContextUP, SessionOpts1),

    {ok, ActiveSessionOpts0, AuthSEvs} =
	authenticate(ContextUP, Session, SessionOpts, Request),

    {PendingPCtx, NodeCaps, APNOpts, ContextVRF} =
	ergw_gsn_lib:reselect_upf(Candidates, ActiveSessionOpts0, ContextUP, UPinfo0),

    {Result, ActiveSessionOpts1, ContextPending1} =
	allocate_ips(APNOpts, ActiveSessionOpts0, PAA, DAF, ContextVRF),
    {ContextPending, ActiveSessionOpts} = 
	add_apn_timeout(APNOpts, ActiveSessionOpts1, ContextPending1),
    ergw_aaa_session:set(Session, ActiveSessionOpts),

    Now = erlang:monotonic_time(),
    SOpts = #{now => Now},

    GxOpts = #{'Event-Trigger' => ?'DIAMETER_GX_EVENT-TRIGGER_UE_IP_ADDRESS_ALLOCATE',
	       'Bearer-Operation' => ?'DIAMETER_GX_BEARER-OPERATION_ESTABLISHMENT'},

    {ok, _, GxEvents} =
	ccr_initial(ContextPending, Session, gx, GxOpts, SOpts, Request),

    RuleBase = ergw_charging:rulebase(),
    {PCC1, PCCErrors1} =
	ergw_gsn_lib:gx_events_to_pcc_ctx(GxEvents, '_', RuleBase, PCC0),

    case ergw_gsn_lib:pcc_ctx_has_rules(PCC1) of
	false ->
	    ?ABORT_CTX_REQUEST(ContextPending, Request, create_session_response,
			       user_authentication_failed);
	true ->
	    ok
    end,

    %% TBD............
    CreditsAdd = ergw_gsn_lib:pcc_ctx_to_credit_request(PCC1),
    GyReqServices = #{credits => CreditsAdd},

    {ok, GySessionOpts, GyEvs} =
	ccr_initial(ContextPending, Session, gy, GyReqServices, SOpts, Request),
    ?LOG(debug, "GySessionOpts: ~p", [GySessionOpts]),
    ?LOG(debug, "Initial GyEvs: ~p", [GyEvs]),

    ergw_aaa_session:invoke(Session, #{}, start, SOpts),
    {_, _, RfSEvs} = ergw_aaa_session:invoke(Session, #{}, {rf, 'Initial'}, SOpts),

    {PCC2, PCCErrors2} = ergw_gsn_lib:gy_events_to_pcc_ctx(Now, GyEvs, PCC1),
    PCC3 = ergw_gsn_lib:session_events_to_pcc_ctx(AuthSEvs, PCC2),
    PCC4 = ergw_gsn_lib:session_events_to_pcc_ctx(RfSEvs, PCC3),

    {Context, PCtx} =
	ergw_gsn_lib:create_sgi_session(PendingPCtx, NodeCaps, PCC4, ContextPending),
    gtp_context:remote_context_register_new(Context),

    GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(PCCErrors1 ++ PCCErrors2),
    if map_size(GxReport) /= 0 ->
	    ergw_aaa_session:invoke(Session, GxReport,
				    {gx, 'CCR-Update'}, SOpts#{async => true});
       true ->
	    ok
    end,

    ResponseIEs = create_session_response(Result, ActiveSessionOpts, IEs, EBI, Context),
    Response = response(create_session_response, Context, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = context_idle_action([], Context),
    {keep_state, Data#{context => Context, pfcp => PCtx, pcc => PCC4}, Actions};

handle_request(ReqKey,
	       #gtp{type = modify_bearer_request,
		    ie = #{?'Bearer Contexts to be modified' :=
			       #v2_bearer_context{
				  group = #{
				    ?'EPS Bearer ID' := EBI,
				    {v2_fully_qualified_tunnel_endpoint_identifier, 1} :=
					%% S5/S8 SGW GTP-U Interface
					#v2_fully_qualified_tunnel_endpoint_identifier{interface_type = ?'S5/S8-U SGW'} =
					FqDataTEID
				   }}
			  } = IEs} = Request,
	       _Resent, _State,
	       #{context := OldContext, pfcp := PCtx, 'Session' := Session} = Data0) ->

    process_secondary_rat_usage_data_reports(IEs, OldContext, Session),

    FqCntlTEID = maps:get(?'Sender F-TEID for Control Plane', IEs, undefined),

    Context0 = update_context_tunnel_ids(FqCntlTEID, FqDataTEID, OldContext),
    Context1 = update_context_from_gtp_req(Request, Context0),
    Context = gtp_path:bind(Request, false, Context1),
    URRActions = update_session_from_gtp_req(IEs, Session, Context),

    Data1 = if Context /= OldContext ->
		     gtp_context:remote_context_update(OldContext, Context),
		     apply_context_change(Context, OldContext, URRActions, Data0);
		true ->
		     trigger_defered_usage_report(URRActions, PCtx),
		     Data0
	     end,

    ResponseIEs0 =
	if FqCntlTEID /= undefined ->
		%% take the presens of the FQ-TEID element as SGW change indication
		%%
		%% 3GPP TS 29.274, Sect. 7.2.7 Modify Bearer Request says that we should
		%% consider the content as well, but in practice that is not stable enough
		%% in the presense of middle boxes between the SGW and the PGW
		%%
		[EBI,				%% Linked EPS Bearer ID
		 #v2_apn_restriction{restriction_type_value = 0},
		 context_charging_id(Context) |
		 [#v2_msisdn{msisdn = Context#context.msisdn} || Context#context.msisdn /= undefined]];
	   true ->
		[]
	end,

    ResponseIEs = [#v2_cause{v2_cause = request_accepted},
		   #v2_bearer_context{
		      group=[#v2_cause{v2_cause = request_accepted},
			     context_charging_id(Context),
			     EBI]} |
		   ResponseIEs0],
    Response = response(modify_bearer_response, Context, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = context_idle_action([], Context),
    {keep_state, Data1, Actions};

handle_request(ReqKey,
	       #gtp{type = modify_bearer_request, ie = IEs} = Request,
	       _Resent, _State,
	       #{context := OldContext, pfcp := PCtx,
		 'Session' := Session} = Data) ->
    process_secondary_rat_usage_data_reports(IEs, OldContext, Session),

    Context = update_context_from_gtp_req(Request, OldContext),
    URRActions = update_session_from_gtp_req(IEs, Session, Context),
    trigger_defered_usage_report(URRActions, PCtx),

    ResponseIEs = [#v2_cause{v2_cause = request_accepted}],
    Response = response(modify_bearer_response, Context, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = context_idle_action([], Context),
    {keep_state, Data#{context => Context}, Actions};

handle_request(#request{gtp_port = GtpPort, ip = SrcIP, port = SrcPort} = ReqKey,
	       #gtp{type = modify_bearer_command,
		    seq_no = SeqNo,
		    ie = #{?'APN-AMBR' := AMBR,
			   ?'Bearer Contexts to be modified' :=
			       #v2_bearer_context{
				   group = #{?'EPS Bearer ID' := EBI} = Bearer}} = IEs},
	       _Resent, _State,
	       #{context := Context, pfcp := PCtx, 'Session' := Session}) ->
    URRActions = update_session_from_gtp_req(IEs, Session, Context),
    trigger_defered_usage_report(URRActions, PCtx),

    Type = update_bearer_request,
    RequestIEs0 = [AMBR,
		   #v2_bearer_context{
		      group = copy_ies_to_response(Bearer, [EBI], [?'Bearer Level QoS'])}],
    RequestIEs = gtp_v2_c:build_recovery(Type, Context, false, RequestIEs0),
    Msg = msg(Context, Type, RequestIEs),
    send_request(GtpPort, SrcIP, SrcPort, ?T3, ?N3, Msg#gtp{seq_no = SeqNo}, ReqKey),

    Actions = context_idle_action([], Context),
    {keep_state_and_data, Actions};

handle_request(ReqKey,
	       #gtp{type = change_notification_request, ie = IEs} = Request,
	       _Resent, _State,
	       #{context := OldContext, pfcp := PCtx,
		 'Session' := Session} = Data) ->
    process_secondary_rat_usage_data_reports(IEs, OldContext, Session),

    Context = update_context_from_gtp_req(Request, OldContext),
    URRActions = update_session_from_gtp_req(IEs, Session, Context),
    trigger_defered_usage_report(URRActions, PCtx),

    ResponseIEs0 = [#v2_cause{v2_cause = request_accepted}],
    ResponseIEs = copy_ies_to_response(IEs, ResponseIEs0, [?'IMSI', ?'ME Identity']),
    Response = response(change_notification_response, Context, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = context_idle_action([], Context),
    {keep_state, Data#{context => Context}, Actions};

handle_request(ReqKey,
	       #gtp{type = suspend_notification} = Request,
	       _Resent, _State, #{context := Context} = Data) ->

    %% don't do anything special for now

    ResponseIEs = [#v2_cause{v2_cause = request_accepted}],
    Response = response(suspend_acknowledge, Context, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = context_idle_action([], Context),
    {keep_state, Data#{context => Context}, Actions};

handle_request(ReqKey,
	       #gtp{type = resume_notification} = Request,
	       _Resent, _State, #{context := Context} = Data) ->

    %% don't do anything special for now

    ResponseIEs = [#v2_cause{v2_cause = request_accepted}],
    Response = response(resume_acknowledge, Context, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = context_idle_action([], Context),
    {keep_state, Data#{context => Context}, Actions};

handle_request(ReqKey,
	       #gtp{type = delete_session_request, ie = IEs} = Request,
	       _Resent, _State, #{context := Context, 'Session' := Session} = Data0) ->

    FqTEI = maps:get(?'Sender F-TEID for Control Plane', IEs, undefined),

    Result =
	do([error_m ||
	       match_context(?'S5/S8-C SGW', Context, FqTEI),
	       return({request_accepted, Data0})
	   ]),

    case Result of
	{ok, {ReplyIEs, Data}} ->
	    process_secondary_rat_usage_data_reports(IEs, Context, Session),
	    close_pdn_context(normal, Data),
	    Response = response(delete_session_response, Context, ReplyIEs),
	    gtp_context:send_response(ReqKey, Request, Response),
	    {next_state, shutdown, Data};

	{error, ReplyIEs} ->
	    Response = response(delete_session_response, Context, ReplyIEs),
	    gtp_context:send_response(ReqKey, Request, Response),
	    keep_state_and_data
    end;

handle_request(ReqKey, _Msg, _Resent, _State, _Data) ->
    gtp_context:request_finished(ReqKey),
    keep_state_and_data.

handle_response(ReqInfo, #gtp{version = v1} = Msg, Request, State, Data) ->
    ?GTP_v1_Interface:handle_response(ReqInfo, Msg, Request, State, Data);

handle_response(CommandReqKey,
		#gtp{type = update_bearer_response,
		     ie = #{?'Cause' := #v2_cause{v2_cause = Cause},
			    ?'Bearer Contexts to be modified' :=
				#v2_bearer_context{
				   group = #{?'Cause' := #v2_cause{v2_cause = BearerCause}}
				  }} = IEs} = Response,
		_Request, run,
		#{context := Context0, pfcp := PCtx,
		  'Session' := Session} = Data0) ->
    gtp_context:request_finished(CommandReqKey),
    Context = gtp_path:bind(Response, false, Context0),
    Data = Data0#{context => Context},

    if Cause =:= request_accepted andalso BearerCause =:= request_accepted ->
	    URRActions = update_session_from_gtp_req(IEs, Session, Context),
	    trigger_defered_usage_report(URRActions, PCtx),
	    {keep_state, Data};
       true ->
	    ?LOG(error, "Update Bearer Request failed with ~p/~p",
			[Cause, BearerCause]),
	    delete_context(undefined, link_broken, Data)
    end;

handle_response(_, timeout, #gtp{type = update_bearer_request}, run, Data) ->
    ?LOG(error, "Update Bearer Request failed with timeout"),
    delete_context(undefined, link_broken, Data);

handle_response({From, TermCause}, timeout, #gtp{type = delete_bearer_request},
		_State, Data) ->
    close_pdn_context(TermCause, Data),
    if is_tuple(From) -> gen_statem:reply(From, {error, timeout});
       true -> ok
    end,
    {next_state, shutdown, Data};

handle_response({From, TermCause},
		#gtp{type = delete_bearer_response,
		     ie = #{?'Cause' := #v2_cause{v2_cause = RespCause}} = IEs} = Response,
		_Request, _State,
		#{context := Context0, 'Session' := Session} = Data) ->
    Context = gtp_path:bind(Response, false, Context0),
    process_secondary_rat_usage_data_reports(IEs, Context, Session),
    close_pdn_context(TermCause, Data),
    if is_tuple(From) -> gen_statem:reply(From, {ok, RespCause});
       true -> ok
    end,
    {next_state, shutdown, Data#{context := Context}};

handle_response(_CommandReqKey, _Response, _Request, State, _Data)
  when State =/= run ->
    keep_state_and_data.

terminate(_Reason, _State, #{context := Context}) ->
    ergw_gsn_lib:release_context_ips(Context),
    ok.

%%%===================================================================
%%% Helper functions
%%%===================================================================
ip2prefix({IP, Prefix}) ->
    <<Prefix:8, (ergw_inet:ip2bin(IP))/binary>>.

response(Cmd, #context{remote_control_teid = #fq_teid{teid = TEID}}, Response) ->
    {Cmd, TEID, Response}.

response(Cmd, Context, IEs0, #gtp{ie = ReqIEs}) ->
    IEs = gtp_v2_c:build_recovery(Cmd, Context, is_map_key(?'Recovery', ReqIEs), IEs0),
    response(Cmd, Context, IEs).

session_failure_to_gtp_cause(_) ->
    system_failure.

authenticate(Context, Session, SessionOpts, Request) ->
    ?LOG(debug, "SessionOpts: ~p", [SessionOpts]),
    case ergw_aaa_session:invoke(Session, SessionOpts, authenticate, [inc_session_id]) of
	{ok, _, _} = Result ->
	    Result;
	Other ->
	    ?LOG(debug, "AuthResult: ~p", [Other]),
	    ?ABORT_CTX_REQUEST(Context, Request, create_session_response,
			       user_authentication_failed)
    end.

ccr_initial(Context, Session, API, SessionOpts, ReqOpts, Request) ->
    case ergw_aaa_session:invoke(Session, SessionOpts, {API, 'CCR-Initial'}, ReqOpts) of
	{ok, _, _} = Result ->
	    Result;
	{Fail, _, _} ->
	    ?ABORT_CTX_REQUEST(Context, Request, create_session_response,
			       session_failure_to_gtp_cause(Fail))
    end.

match_context(_Type, _Context, undefined) ->
    error_m:return(ok);
match_context(Type,
	      #context{
		 remote_control_teid =
		     #fq_teid{
			ip = RemoteCntlIP,
			teid = RemoteCntlTEI
		       }} = Context,
	      #v2_fully_qualified_tunnel_endpoint_identifier{
		 instance       = 0,
		 interface_type = Type,
		 key            = RemoteCntlTEI,
		 ipv4           = RemoteCntlIP4,
		 ipv6           = RemoteCntlIP6} = IE) ->
    case ergw_inet:ip2bin(RemoteCntlIP) of
	RemoteCntlIP4 ->
	    error_m:return(ok);
	RemoteCntlIP6 ->
	    error_m:return(ok);
	_ ->
	    ?LOG(error, "match_context: IP address mismatch, ~p, ~p, ~p",
			[Type, Context, IE]),
	    error_m:fail([#v2_cause{v2_cause = invalid_peer}])
    end;
match_context(Type, Context, IE) ->
    ?LOG(error, "match_context: context not found, ~p, ~p, ~p",
		[Type, Context, IE]),
    error_m:fail([#v2_cause{v2_cause = invalid_peer}]).

pdn_alloc(#v2_pdn_address_allocation{type = non_ip}) ->
    {'Non-IP', undefined, undefined};
pdn_alloc(#v2_pdn_address_allocation{type = ipv4v6,
				     address = << IP6PrefixLen:8, IP6Prefix:16/binary, IP4:4/binary>>}) ->
    {'IPv4v6', ergw_inet:bin2ip(IP4), {ergw_inet:bin2ip(IP6Prefix), IP6PrefixLen}};
pdn_alloc(#v2_pdn_address_allocation{type = ipv4,
				     address = << IP4:4/binary>>}) ->
    {'IPv4', ergw_inet:bin2ip(IP4), undefined};
pdn_alloc(#v2_pdn_address_allocation{type = ipv6,
				     address = << IP6PrefixLen:8, IP6Prefix:16/binary>>}) ->
    {'IPv6', undefined, {ergw_inet:bin2ip(IP6Prefix), IP6PrefixLen}}.

encode_paa(IPv4, undefined) when IPv4 /= undefined ->
    encode_paa(ipv4, ergw_inet:ip2bin(ergw_ip_pool:addr(IPv4)), <<>>);
encode_paa(undefined, IPv6) when IPv6 /= undefined ->
    encode_paa(ipv6, <<>>, ip2prefix(ergw_ip_pool:ip(IPv6)));
encode_paa(IPv4, IPv6) when IPv4 /= undefined, IPv6 /= undefined ->
    encode_paa(ipv4v6, ergw_inet:ip2bin(ergw_ip_pool:addr(IPv4)),
	       ip2prefix(ergw_ip_pool:ip(IPv6))).

encode_paa(Type, IPv4, IPv6) ->
    #v2_pdn_address_allocation{type = Type, address = <<IPv6/binary, IPv4/binary>>}.

close_pdn_context(Reason, #{context := Context, pfcp := PCtx, 'Session' := Session}) ->
    URRs = ergw_gsn_lib:delete_sgi_session(Reason, Context, PCtx),

    %% ===========================================================================

    TermCause =
	if Reason =:= upf_failure;
	   Reason =:= link_broken ->
		?'DIAMETER_BASE_TERMINATION-CAUSE_LINK_BROKEN';
	   Reason =:= administrative ->
		?'DIAMETER_BASE_TERMINATION-CAUSE_ADMINISTRATIVE';
	   true ->
		?'DIAMETER_BASE_TERMINATION-CAUSE_LOGOUT'
	end,

    %% TODO: Monitors, AAA over SGi

    %%  1. CCR on Gx to get PCC rules
    Now = erlang:monotonic_time(),
    ReqOpts = #{now => Now, async => true},
    case ergw_aaa_session:invoke(Session, #{}, {gx, 'CCR-Terminate'}, ReqOpts#{async => false}) of
	{ok, _GxSessionOpts, _} ->
	    ?LOG(debug, "GxSessionOpts: ~p", [_GxSessionOpts]);
	GxOther ->
	    ?LOG(warning, "Gx terminate failed with: ~p", [GxOther])
    end,

    ChargeEv = {terminate, TermCause},
    {Online, Offline, Monitor} = ergw_gsn_lib:usage_report_to_charging_events(URRs, ChargeEv, PCtx),
    ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),
    GyReqServices = ergw_gsn_lib:gy_credit_report(Online),
    ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOpts),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),

    %% ===========================================================================
    ok.

query_usage_report(ChargingKeys, Context, PCtx)
  when is_list(ChargingKeys) ->
    ergw_gsn_lib:query_usage_report(ChargingKeys, Context, PCtx);
query_usage_report(_, Context, PCtx) ->
    ergw_gsn_lib:query_usage_report(Context, PCtx).

triggered_charging_event(ChargeEv, Now, Request,
			 #{context := Context, pfcp := PCtx,
			   'Session' := Session, pcc := PCC}) ->
    try
	ReqOpts = #{now => Now, async => true},

	{_, UsageReport} =
	    query_usage_report(Request, Context, PCtx),
	{Online, Offline, Monitor} =
	    ergw_gsn_lib:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),
	ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),
	GyReqServices = ergw_gsn_lib:gy_credit_request(Online, PCC),
	ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOpts),
	ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session)
    catch
	throw:#ctx_err{} = CtxErr ->
	    ?LOG(error, "Triggered Charging Event failed with ~p", [CtxErr])
    end,
    ok.

defered_usage_report_fun(Owner, URRActions, PCtx) ->
    try
	{_, Report} = ergw_gsn_lib:query_usage_report(offline, undefined, PCtx),
	defered_usage_report(Owner, URRActions, Report)
    catch
	throw:#ctx_err{} = CtxErr ->
	    ?LOG(error, "Defered Usage Report failed with ~p", [CtxErr])
    end.

trigger_defered_usage_report(URRActions, PCtx) ->
    Self = self(),
    proc_lib:spawn(fun() -> defered_usage_report_fun(Self, URRActions, PCtx) end),
    ok.

defer_usage_report(URRActions, UsageReport) ->
    defered_usage_report(self(), URRActions, UsageReport).

apply_context_change(NewContext0, OldContext, URRActions,
		     #{pfcp := PCtx0, pcc := PCC} = Data) ->
    ModifyOpts =
	case {NewContext0, OldContext} of
	    {#context{version = v2}, #context{version = v2}} ->
		#{send_end_marker => true};
	    _ ->
		#{}
	end,
    NewContext = gtp_path:bind(false, NewContext0),
    {PCtx, UsageReport} =
	ergw_gsn_lib:modify_sgi_session(PCC, URRActions,
					ModifyOpts, NewContext, PCtx0),
    gtp_path:unbind(OldContext),
    defer_usage_report(URRActions, UsageReport),
    Data#{context => NewContext, pfcp => PCtx}.

%% 'Idle-Timeout' received from ergw_aaa Session takes precedence over configured one
add_apn_timeout(Opts, Session, Context) ->
    SessionWithTimeout = maps:merge(maps:with(['Idle-Timeout'],Opts), Session),
    Timeout = maps:get('Idle-Timeout', SessionWithTimeout),
    ContextWithTimeout = Context#context{'Idle-Timeout' = Timeout},
    {ContextWithTimeout, SessionWithTimeout}.

map_attr('APN', #{?'Access Point Name' := #v2_access_point_name{apn = APN}}) ->
    unicode:characters_to_binary(lists:join($., APN));
map_attr('IMSI', #{?'IMSI' := #v2_international_mobile_subscriber_identity{imsi = IMSI}}) ->
    IMSI;
map_attr('IMEI', #{?'ME Identity' := #v2_mobile_equipment_identity{mei = IMEI}}) ->
    IMEI;
map_attr('MSISDN', #{?'MSISDN' := #v2_msisdn{msisdn = MSISDN}}) ->
    MSISDN;
map_attr(Value, _) when is_binary(Value); is_list(Value) ->
    Value;
map_attr(Value, _) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
map_attr(Value, _) ->
    io_lib:format("~w", [Value]).

map_username(_IEs, Username, _) when is_binary(Username) ->
    Username;
map_username(_IEs, [], Acc) ->
    iolist_to_binary(lists:reverse(Acc));
map_username(IEs, [H | Rest], Acc) ->
    Part = map_attr(H, IEs),
    map_username(IEs, Rest, [Part | Acc]).


init_session(IEs,
	     #context{control_port = #gtp_port{ip = LocalIP},
		      charging_identifier = ChargingId},
	     #{'Username' := #{default := Username},
	       'Password' := #{default := Password}}) ->
    MappedUsername = map_username(IEs, Username, []),
    {MCC, MNC} = ergw:get_plmn_id(),
    Opts =
	case LocalIP of
	    {_,_,_,_,_,_,_,_} ->
		#{'3GPP-GGSN-IPv6-Address' => LocalIP};
	    _ ->
		#{'3GPP-GGSN-Address' => LocalIP}
	end,
    Opts#{'Username'		=> MappedUsername,
	  'Password'		=> Password,
	  'Service-Type'	=> 'Framed-User',
	  'Framed-Protocol'	=> 'GPRS-PDP-Context',
	  '3GPP-GGSN-MCC-MNC'	=> <<MCC/binary, MNC/binary>>,
	  '3GPP-Charging-Id'	=> ChargingId
     }.

copy_ppp_to_session({pap, 'PAP-Authentication-Request', _Id, Username, Password}, Session0) ->
    Session = Session0#{'Username' => Username, 'Password' => Password},
    maps:without(['CHAP-Challenge', 'CHAP_Password'], Session);
copy_ppp_to_session({chap, 'CHAP-Challenge', _Id, Value, _Name}, Session) ->
    Session#{'CHAP_Challenge' => Value};
copy_ppp_to_session({chap, 'CHAP-Response', _Id, Value, Name}, Session0) ->
    Session = Session0#{'CHAP_Password' => Value, 'Username' => Name},
    maps:without(['Password'], Session);
copy_ppp_to_session(_, Session) ->
    Session.

non_empty_ip(_, {0,0,0,0}, Opts) ->
    Opts;
non_empty_ip(_, {{0,0,0,0,0,0,0,0}, _}, Opts) ->
    Opts;
non_empty_ip(Key, IP, Opts) ->
    maps:put(Key, IP, Opts).

copy_to_session(_, #v2_protocol_configuration_options{config = {0, Options}},
		#{'Username' := #{from_protocol_opts := true}}, _, Session) ->
    lists:foldr(fun copy_ppp_to_session/2, Session, Options);
copy_to_session(_, #v2_access_point_name{apn = APN}, _AAAopts, _, Session) ->
    {NI, _OI} = ergw_node_selection:split_apn(APN),
    Session#{'Called-Station-Id' =>
		 iolist_to_binary(lists:join($., NI))};
copy_to_session(_, #v2_msisdn{msisdn = MSISDN}, _AAAopts, _, Session) ->
    Session#{'Calling-Station-Id' => MSISDN, '3GPP-MSISDN' => MSISDN};
copy_to_session(_, #v2_international_mobile_subscriber_identity{imsi = IMSI}, _AAAopts, _, Session) ->
    case itu_e212:split_imsi(IMSI) of
	{MCC, MNC, _} ->
	    Session#{'3GPP-IMSI' => IMSI,
		     '3GPP-IMSI-MCC-MNC' => <<MCC/binary, MNC/binary>>};
	_ ->
	    Session#{'3GPP-IMSI' => IMSI}
    end;

copy_to_session(_, #v2_pdn_address_allocation{type = ipv4,
					      address = IP4}, _AAAopts, _, Session) ->
    IP4addr = ergw_inet:bin2ip(IP4),
    S0 = Session#{'3GPP-PDP-Type' => 'IPv4'},
    S1 = non_empty_ip('Framed-IP-Address', IP4addr, S0),
    _S = non_empty_ip('Requested-IP-Address', IP4addr, S1);
copy_to_session(_, #v2_pdn_address_allocation{type = ipv6,
					      address = <<IP6PrefixLen:8,
							  IP6Prefix:16/binary>>},
		_AAAopts, _, Session) ->
    IP6addr = {ergw_inet:bin2ip(IP6Prefix), IP6PrefixLen},
    S0 = Session#{'3GPP-PDP-Type' => 'IPv6'},
    S1 = non_empty_ip('Framed-IPv6-Prefix', IP6addr, S0),
    _S = non_empty_ip('Requested-IPv6-Prefix', IP6addr, S1);
copy_to_session(_, #v2_pdn_address_allocation{type = ipv4v6,
					      address = <<IP6PrefixLen:8,
							  IP6Prefix:16/binary,
							  IP4:4/binary>>},
		_AAAopts, _, Session) ->
    IP4addr = ergw_inet:bin2ip(IP4),
    IP6addr = {ergw_inet:bin2ip(IP6Prefix), IP6PrefixLen},
    S0 = Session#{'3GPP-PDP-Type' => 'IPv4v6'},
    S1 = non_empty_ip('Framed-IP-Address', IP4addr, S0),
    S2 = non_empty_ip('Requested-IP-Address', IP4addr, S1),
    S3 = non_empty_ip('Framed-IPv6-Prefix', IP6addr, S2),
    _S = non_empty_ip('Requested-IPv6-Prefix', IP6addr, S3);
copy_to_session(_, #v2_pdn_address_allocation{type = non_ip}, _AAAopts, _, Session) ->
    Session#{'3GPP-PDP-Type' => 'Non-IP'};

%% 3GPP TS 29.274, Rel 15, Table 7.2.1-1, Note 1:
%%   The conditional PDN Type IE is redundant on the S4/S11 and S5/S8 interfaces
%%   (as the PAA IE contains exactly the same field). The receiver may ignore it.
%%

copy_to_session(?'Sender F-TEID for Control Plane',
		#v2_fully_qualified_tunnel_endpoint_identifier{ipv4 = IP4}, _AAAopts,
		#context{remote_control_teid = #fq_teid{ip = {_,_,_,_}}}, Session) ->
    Session#{'3GPP-SGSN-Address' => ergw_inet:bin2ip(IP4)};
copy_to_session(?'Sender F-TEID for Control Plane',
		#v2_fully_qualified_tunnel_endpoint_identifier{ipv6 = IP6}, _AAAopts,
		#context{remote_control_teid = #fq_teid{ip = {_,_,_,_,_,_,_,_}}}, Session) ->
    Session#{'3GPP-SGSN-IPv6-Address' => ergw_inet:bin2ip(IP6)};

copy_to_session(?'Bearer Contexts to be created',
		#v2_bearer_context{
		   group =
		       #{?'EPS Bearer ID' := #v2_eps_bearer_id{eps_bearer_id = EBI}}},
		_AAAopts, _, Session) ->
    Session#{'3GPP-NSAPI' => EBI};
copy_to_session(_, #v2_selection_mode{mode = Mode}, _AAAopts, _, Session) ->
    Session#{'3GPP-Selection-Mode' => Mode};
copy_to_session(_, #v2_charging_characteristics{value = Value}, _AAAopts, _, Session) ->
    Session#{'3GPP-Charging-Characteristics' => Value};

copy_to_session(_, #v2_serving_network{mcc = MCC, mnc = MNC}, _AAAopts, _, Session) ->
    Session#{'3GPP-SGSN-MCC-MNC' => <<MCC/binary, MNC/binary>>};
copy_to_session(_, #v2_mobile_equipment_identity{mei = IMEI}, _AAAopts, _, Session) ->
    Session#{'3GPP-IMEISV' => IMEI};
copy_to_session(_, #v2_rat_type{rat_type = Type}, _AAAopts, _, Session) ->
    Session#{'3GPP-RAT-Type' => Type};

%% 0        CGI
%% 1        SAI
%% 2        RAI
%% 3-127    Spare for future use
%% 128      TAI
%% 129      ECGI
%% 130      TAI and ECGI
%% 131-255  Spare for future use

copy_to_session(_, #v2_user_location_information{tai = TAI, ecgi = ECGI}, _AAAopts, _, Session)
  when is_binary(TAI), is_binary(ECGI) ->
    Value = <<130, TAI/binary, ECGI/binary>>,
    Session#{'TAI' => TAI, 'ECGI' => ECGI, '3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{ecgi = ECGI}, _AAAopts, _, Session)
  when is_binary(ECGI) ->
    Value = <<129, ECGI/binary>>,
    Session#{'ECGI' => ECGI, '3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{tai = TAI}, _AAAopts, _, Session)
  when is_binary(TAI) ->
    Value = <<128, TAI/binary>>,
    Session#{'TAI' => TAI, '3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{rai = RAI}, _AAAopts, _, Session)
  when is_binary(RAI) ->
    Value = <<2, RAI/binary>>,
    Session#{'RAI' => RAI, '3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{sai = SAI}, _AAAopts, _, Session0)
  when is_binary(SAI) ->
    Session = maps:without(['CGI'], Session0#{'SAI' => SAI}),
    Value = <<1, SAI/binary>>,
    Session#{'3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{cgi = CGI}, _AAAopts, _, Session0)
  when is_binary(CGI) ->
    Session = maps:without(['SAI'], Session0#{'CGI' => CGI}),
    Value = <<0, CGI/binary>>,
    Session#{'3GPP-User-Location-Info' => Value};


copy_to_session(_, #v2_ue_time_zone{timezone = TZ, dst = DST}, _AAAopts, _, Session) ->
    Session#{'3GPP-MS-TimeZone' => {TZ, DST}};
copy_to_session(_, _, _AAAopts, _, Session) ->
    Session.

copy_qos_to_session(#{?'Bearer Contexts to be created' :=
			  #v2_bearer_context{
			     group = #{?'Bearer Level QoS' :=
					   #v2_bearer_level_quality_of_service{
					      pci = PCI, pl = PL, pvi = PVI, label = Label,
					      maximum_bit_rate_for_uplink = MBR4ul,
					      maximum_bit_rate_for_downlink = MBR4dl,
					      guaranteed_bit_rate_for_uplink = GBR4ul,
					      guaranteed_bit_rate_for_downlink = GBR4dl}}},
		      ?'APN-AMBR' :=
			  #v2_aggregate_maximum_bit_rate{
			     uplink = AMBR4ul, downlink = AMBR4dl}},
		    Session) ->
    ARP = #{
	    'Priority-Level' => PL,
	    'Pre-emption-Capability' => PCI,
	    'Pre-emption-Vulnerability' => PVI
	   },
    Info = #{
	     'QoS-Class-Identifier' => Label,
	     'Max-Requested-Bandwidth-UL' => MBR4ul * 1000,
	     'Max-Requested-Bandwidth-DL' => MBR4dl * 1000,
	     'Guaranteed-Bitrate-UL' => GBR4ul * 1000,
	     'Guaranteed-Bitrate-DL' => GBR4dl * 1000,

	     %% TBD:
	     %%   [ Bearer-Identifier ]

	     'Allocation-Retention-Priority' => ARP,
	     'APN-Aggregate-Max-Bitrate-UL' => AMBR4ul * 1000,
	     'APN-Aggregate-Max-Bitrate-DL' => AMBR4dl * 1000

	     %%  *[ Conditional-APN-Aggregate-Max-Bitrate ]
	    },
    Session#{'QoS-Information' => Info};
copy_qos_to_session(_, Session) ->
    Session.

sec_rat_udr_to_report([], _, Reports) ->
    Reports;
sec_rat_udr_to_report(#v2_secondary_rat_usage_data_report{irpgw = false}, _, Reports) ->
    Reports;
sec_rat_udr_to_report(#v2_secondary_rat_usage_data_report{irpgw = true} = Report,
		      #context{charging_identifier = ChargingId}, Reports) ->
    [ergw_gsn_lib:secondary_rat_usage_data_report_to_rf(ChargingId, Report)|Reports];
sec_rat_udr_to_report([H|T], Ctx, Reports) ->
    sec_rat_udr_to_report(H, Ctx, sec_rat_udr_to_report(T, Ctx, Reports)).

process_secondary_rat_usage_data_reports(#{?'Secondary RAT Usage Data Report' := SecRatUDR},
					 Context, Session) ->
    Report =
	#{'RAN-Secondary-RAT-Usage-Report' =>
	      sec_rat_udr_to_report(SecRatUDR, Context, [])},
    ergw_aaa_session:invoke(Session, Report, {rf, 'Update'}, #{async => false}),
    ok;
process_secondary_rat_usage_data_reports(_, _, _) ->
    ok.

init_session_from_gtp_req(IEs, AAAopts, Context, Session0) ->
    Session = copy_qos_to_session(IEs, Session0),
    maps:fold(copy_to_session(_, _, AAAopts, Context, _), Session, IEs).

update_session_from_gtp_req(IEs, Session, Context) ->
    OldSOpts = ergw_aaa_session:get(Session),
    NewSOpts0 = copy_qos_to_session(IEs, OldSOpts),
    NewSOpts =
	maps:fold(copy_to_session(_, _, undefined, Context, _), NewSOpts0, IEs),
    ergw_aaa_session:set(Session, NewSOpts),
    gtp_context:collect_charging_events(OldSOpts, NewSOpts, Context).

update_context_cntl_ids(#v2_fully_qualified_tunnel_endpoint_identifier{
			   key = TEI, ipv4 = IP4, ipv6 = IP6}, Context) ->
    IP = ergw_gsn_lib:choose_context_ip(IP4, IP6, Context),
    Context#context{
      remote_control_teid = #fq_teid{ip = ergw_inet:bin2ip(IP), teid = TEI}
     };
update_context_cntl_ids(_ , Context) ->
    Context.

update_context_data_ids(#v2_fully_qualified_tunnel_endpoint_identifier{
			     key = TEI, ipv4 = IP4, ipv6 = IP6}, Context) ->
    IP = ergw_gsn_lib:choose_context_ip(IP4, IP6, Context),
    Context#context{
      remote_data_teid = #fq_teid{ip = ergw_inet:bin2ip(IP), teid = TEI}
     };
update_context_data_ids(_ , Context) ->
    Context.

update_context_tunnel_ids(Cntl, Data, Context0) ->
    Context1 = update_context_cntl_ids(Cntl, Context0),
    update_context_data_ids(Data, Context1).

get_context_from_req(?'Access Point Name', #v2_access_point_name{apn = APN}, Context) ->
    Context#context{apn = APN};
get_context_from_req(?'IMSI', #v2_international_mobile_subscriber_identity{imsi = IMSI}, Context) ->
    Context#context{imsi = IMSI};
get_context_from_req(?'ME Identity', #v2_mobile_equipment_identity{mei = IMEI}, Context) ->
    Context#context{imei = IMEI};
get_context_from_req(?'MSISDN', #v2_msisdn{msisdn = MSISDN}, Context) ->
    Context#context{msisdn = MSISDN};
get_context_from_req(?'PDN Address Allocation', #v2_pdn_address_allocation{type = Type}, Context) ->
    Context#context{pdn_type = Type};
get_context_from_req(_, _, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs} = Req, Context0) ->
    Context1 = gtp_v2_c:update_context_id(Req, Context0),
    maps:fold(fun get_context_from_req/3, Context1, IEs).

enter_ie(_Key, Value, IEs)
  when is_list(IEs) ->
    [Value|IEs].
%% enter_ie(Key, Value, IEs)
%%   when is_map(IEs) ->
%%     IEs#{Key := Value}.

copy_ies_to_response(_, ResponseIEs, []) ->
    ResponseIEs;
copy_ies_to_response(RequestIEs, ResponseIEs0, [H|T]) ->
    ResponseIEs =
	case RequestIEs of
	    #{H := Value} ->
		enter_ie(H, Value, ResponseIEs0);
	    _ ->
		ResponseIEs0
	end,
    copy_ies_to_response(RequestIEs, ResponseIEs, T).


msg(#context{remote_control_teid = #fq_teid{teid = RemoteCntlTEI}}, Type, RequestIEs) ->
    #gtp{version = v2, type = Type, tei = RemoteCntlTEI, ie = RequestIEs}.


send_request(GtpPort, DstIP, DstPort, T3, N3, Msg, ReqInfo) ->
    gtp_context:send_request(GtpPort, DstIP, DstPort, T3, N3, Msg, ReqInfo).

send_request(#context{control_port = GtpPort,
		      remote_control_teid = #fq_teid{ip = RemoteCntlIP}},
	     T3, N3, Msg, ReqInfo) ->
    send_request(GtpPort, RemoteCntlIP, ?GTP2c_PORT, T3, N3, Msg, ReqInfo).

send_request(Context, T3, N3, Type, RequestIEs, ReqInfo) ->
    send_request(Context, T3, N3, msg(Context, Type, RequestIEs), ReqInfo).

delete_context(From, TermCause, #{context := Context} = Data) ->
    Type = delete_bearer_request,
    EBI = 5,
    RequestIEs0 = [#v2_cause{v2_cause = reactivation_requested},
		   #v2_eps_bearer_id{eps_bearer_id = EBI}],
    RequestIEs = gtp_v2_c:build_recovery(Type, Context, false, RequestIEs0),
    send_request(Context, ?T3, ?N3, Type, RequestIEs, {From, TermCause}),
    {next_state, shutdown_initiated, Data}.

allocate_ips(APNOpts, SOpts, PAA, DAF, Context) ->
    ergw_gsn_lib:allocate_ips(pdn_alloc(PAA), APNOpts, SOpts, DAF, Context).

ppp_ipcp_conf_resp(Verdict, Opt, IPCP) ->
    maps:update_with(Verdict, fun(O) -> [Opt|O] end, [Opt], IPCP).

ppp_ipcp_conf(#{'MS-Primary-DNS-Server' := DNS}, {ms_dns1, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_dns1, ergw_inet:ip2bin(DNS)}, IPCP);
ppp_ipcp_conf(#{'MS-Secondary-DNS-Server' := DNS}, {ms_dns2, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_dns2, ergw_inet:ip2bin(DNS)}, IPCP);
ppp_ipcp_conf(#{'MS-Primary-NBNS-Server' := DNS}, {ms_wins1, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_wins1, ergw_inet:ip2bin(DNS)}, IPCP);
ppp_ipcp_conf(#{'MS-Secondary-NBNS-Server' := DNS}, {ms_wins2, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_wins2, ergw_inet:ip2bin(DNS)}, IPCP);

ppp_ipcp_conf(_SessionOpts, Opt, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Reject', Opt, IPCP).

pdn_ppp_pco(SessionOpts, {pap, 'PAP-Authentication-Request', Id, _Username, _Password}, Opts) ->
    [{pap, 'PAP-Authenticate-Ack', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdn_ppp_pco(SessionOpts, {chap, 'CHAP-Response', Id, _Value, _Name}, Opts) ->
    [{chap, 'CHAP-Success', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdn_ppp_pco(SessionOpts, {ipcp,'CP-Configure-Request', Id, CpReqOpts}, Opts) ->
    CpRespOpts = lists:foldr(ppp_ipcp_conf(SessionOpts, _, _), #{}, CpReqOpts),
    maps:fold(fun(K, V, O) -> [{ipcp, K, Id, V} | O] end, Opts, CpRespOpts);

pdn_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv6-Address', <<>>}, Opts) ->
    [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
     || DNS <- maps:get('DNS-Server-IPv6-Address', SessionOpts, [])]
	++ [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
	    || DNS <- maps:get('3GPP-IPv6-DNS-Servers', SessionOpts, [])]
	++ Opts;
pdn_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv4-Address', <<>>}, Opts) ->
    lists:foldr(fun(Key, O) ->
			case maps:find(Key, SessionOpts) of
			    {ok, DNS} ->
				[{?'PCO-DNS-Server-IPv4-Address', ergw_inet:ip2bin(DNS)} | O];
			    _ ->
				O
			end
		end, Opts, ['MS-Secondary-DNS-Server', 'MS-Primary-DNS-Server']);
pdn_ppp_pco(_SessionOpts, PPPReqOpt, Opts) ->
    ?LOG(debug, "Apply PPP Opt: ~p", [PPPReqOpt]),
    Opts.

pdn_pco(SessionOpts, #{?'Protocol Configuration Options' :=
			   #v2_protocol_configuration_options{config = {0, PPPReqOpts}}}, IE) ->
    case lists:foldr(pdn_ppp_pco(SessionOpts, _, _), [], PPPReqOpts) of
	[]   -> IE;
	Opts -> [#v2_protocol_configuration_options{config = {0, Opts}} | IE]
    end;
pdn_pco(_SessionOpts, _RequestIEs, IE) ->
    IE.

context_charging_id(#context{charging_identifier = ChargingId}) ->
    #v2_charging_id{id = <<ChargingId:32>>}.

bearer_context(EBI, Context, IEs) ->
    IE = #v2_bearer_context{
	    group=[#v2_cause{v2_cause = request_accepted},
		   context_charging_id(Context),
		   EBI,
		   #v2_bearer_level_quality_of_service{
		      pl=15,
		      pvi=0,
		      label=9,maximum_bit_rate_for_uplink=0,
		      maximum_bit_rate_for_downlink=0,
		      guaranteed_bit_rate_for_uplink=0,
		      guaranteed_bit_rate_for_downlink=0},
		   s5s8_pgw_gtp_u_tei(Context)]},
    [IE | IEs].

fq_teid(Instance, Type, TEI, {_,_,_,_} = IP) ->
    #v2_fully_qualified_tunnel_endpoint_identifier{
       instance = Instance, interface_type = Type,
       key = TEI, ipv4 = ergw_inet:ip2bin(IP)};
fq_teid(Instance, Type, TEI, {_,_,_,_,_,_,_,_} = IP) ->
    #v2_fully_qualified_tunnel_endpoint_identifier{
       instance = Instance, interface_type = Type,
       key = TEI, ipv6 = ergw_inet:ip2bin(IP)}.

s5s8_pgw_gtp_c_tei(#context{control_port = #gtp_port{ip = IP}, local_control_tei = TEI}) ->
    %% PGW S5/S8/ S2a/S2b F-TEID for PMIP based interface
    %% or for GTP based Control Plane interface
    fq_teid(1, ?'S5/S8-C PGW', TEI, IP).

s5s8_pgw_gtp_u_tei(#context{local_data_endp = #gtp_endp{ip = IP, teid = TEI}}) ->
    fq_teid(2,  ?'S5/S8-U PGW', TEI, IP).

cr_ran_type(1)  -> 'UTRAN';
cr_ran_type(2)  -> 'UTRAN';
cr_ran_type(6)  -> 'EUTRAN';
cr_ran_type(8)  -> 'EUTRAN';
cr_ran_type(9)  -> 'EUTRAN';
cr_ran_type(10) -> 'NR';
cr_ran_type(_)  -> undefined.

%% it is unclear from TS 29.274 if the CRA IE can only be included when the
%% SGSN/MME has indicated support for it in the Indication IE.
%% Some comments in Modify Bearer Request suggest that it might be possbile
%% to unconditionally set it, other places state that is should only be sent
%% when the SGSN/MME indicated support for it.
%% For the moment only include it when the CRSI flag was set.

change_reporting_action(true, ENBCRSI, #{?'RAT Type' :=
					     #v2_rat_type{rat_type = Type}}, Trigger, IE) ->
    change_reporting_action(ENBCRSI, cr_ran_type(Type), Trigger, IE);
change_reporting_action(_, _, _, _, IE) ->
    IE.

change_reporting_action(true, 'EUTRAN', #{'tai-change' := true,
					  'user-location-info-change' := true}, IE) ->
    [#v2_change_reporting_action{
	action = start_reporting_tai__macro_enodeb_id_and_extended_macro_enodeb_id}|IE];
change_reporting_action(true, 'EUTRAN', #{'user-location-info-change' := true}, IE) ->
    [#v2_change_reporting_action{
	action = start_reporting_macro_enodeb_id_and_extended_macro_enodeb_id}|IE];
change_reporting_action(_, 'EUTRAN', #{'tai-change' := true, 'ecgi-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_tai_and_ecgi}|IE];
change_reporting_action(_, 'EUTRAN', #{'tai-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_tai}|IE];
change_reporting_action(_, 'EUTRAN', #{'ecgi-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_ecgi}|IE];
change_reporting_action(_, 'UTRAN', #{'user-location-info-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_cgi_sai_and_rai}|IE];
change_reporting_action(_, 'UTRAN', #{'cgi-sai-change' := true, 'rai-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_cgi_sai_and_rai}|IE];
change_reporting_action(_, 'UTRAN', #{'cgi-sai-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_cgi_sai}|IE];
change_reporting_action(_, 'UTRAN', #{'rai-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_rai}|IE];
change_reporting_action(_, _, _Triggers, IE) ->
    IE.

change_reporting_actions(RequestIEs, IE0) ->
    Indications = gtp_v2_c:get_indication_flags(RequestIEs),
    Triggers = ergw_charging:reporting_triggers(),

    CRSI = proplists:get_bool('CRSI', Indications),
    ENBCRSI = proplists:get_bool('ENBCRSI', Indications),
    _IE = change_reporting_action(CRSI, ENBCRSI, RequestIEs, Triggers, IE0).

create_session_response(Result, SessionOpts, RequestIEs, EBI,
			#context{ms_v4 = MSv4, ms_v6 = MSv6} = Context) ->

    IE0 = bearer_context(EBI, Context, []),
    IE1 = pdn_pco(SessionOpts, RequestIEs, IE0),
    IE2 = change_reporting_actions(RequestIEs, IE1),

    [Result,
     #v2_apn_restriction{restriction_type_value = 0},
     context_charging_id(Context),
     s5s8_pgw_gtp_c_tei(Context),
     encode_paa(MSv4, MSv6) | IE2].

%% Wrapper for gen_statem state_callback_result Actions argument
%% Timeout set in the context of a prolonged idle gtpv2 session
context_idle_action(Actions, #context{'Idle-Timeout' = Timeout})
  when is_integer(Timeout) orelse Timeout =:= infinity ->
    [{{timeout, context_idle}, Timeout, stop_session} | Actions];
context_idle_action(Actions, _) ->
    Actions.
