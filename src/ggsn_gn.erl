%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn).

-behaviour(gtp_api).

-compile({parse_transform, cut}).

-export([validate_options/1, init/2, request_spec/3,
	 handle_pdu/4, handle_sx_report/3,
	 handle_request/5, handle_response/5,
	 handle_event/4, terminate/3]).

%% PFCP context API's
%%-export([defered_usage_report/3]).

%% shared API's
-export([init_session/3, init_session_from_gtp_req/3]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").
-include("include/3gpp.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define(T3, 10 * 1000).
-define(N3, 5).

%%====================================================================
%% API
%%====================================================================

-define('Cause',					{cause, 0}).
-define('IMSI',						{international_mobile_subscriber_identity, 0}).
-define('Recovery',					{recovery, 0}).
-define('Tunnel Endpoint Identifier Data I',		{tunnel_endpoint_identifier_data_i, 0}).
-define('Tunnel Endpoint Identifier Control Plane',	{tunnel_endpoint_identifier_control_plane, 0}).
-define('NSAPI',					{nsapi, 0}).
-define('End User Address',				{end_user_address, 0}).
-define('Access Point Name',				{access_point_name, 0}).
-define('Protocol Configuration Options',		{protocol_configuration_options, 0}).
-define('SGSN Address for signalling',			{gsn_address, 0}).
-define('SGSN Address for user traffic',		{gsn_address, 1}).
-define('MSISDN',					{ms_international_pstn_isdn_number, 0}).
-define('Quality of Service Profile',			{quality_of_service_profile, 0}).
-define('IMEI',						{imei, 0}).
-define('APN-AMBR',					{aggregate_maximum_bit_rate, 0}).
-define('Evolved ARP I',				{evolved_allocation_retention_priority_i, 0}).

-define(ABORT_CTX_REQUEST(Context, Request, Type, Cause),
	begin
	    AbortReply = response(Type, Context, [#cause{value = Cause}], Request),
	    throw(?CTX_ERR(?FATAL, AbortReply, Context))
	end).

-define(CAUSE_OK(Cause), (Cause =:= request_accepted orelse
			  Cause =:= new_pdp_type_due_to_network_preference orelse
			  Cause =:= new_pdp_type_due_to_single_address_bearer_only)).

request_spec(v1, _Type, Cause)
  when Cause /= undefined andalso not ?CAUSE_OK(Cause) ->
    [];

request_spec(v1, create_pdp_context_request, _) ->
    [{?'Tunnel Endpoint Identifier Data I',		mandatory},
     {?'NSAPI',						mandatory},
     {?'SGSN Address for signalling',			mandatory},
     {?'SGSN Address for user traffic',			mandatory},
     {?'Quality of Service Profile',			mandatory}];

request_spec(v1, update_pdp_context_request, _) ->
    [{?'Tunnel Endpoint Identifier Data I',		mandatory},
     {?'NSAPI',						mandatory},
     {?'SGSN Address for signalling',			mandatory},
     {?'SGSN Address for user traffic',			mandatory},
     {?'Quality of Service Profile',			mandatory}];

request_spec(v1, _, _) ->
    [].

validate_options(Options) ->
    ?LOG(debug, "GGSN Gn/Gp Options: ~p", [Options]),
    gtp_context:validate_options(fun validate_option/2, Options, []).

validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

init(_Opts, Data) ->
    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),
    SessionOpts = ergw_aaa_session:get(Session),
    OCPcfg = maps:get('Offline-Charging-Profile', SessionOpts, #{}),
    PCC = #pcc_ctx{offline_charging_profile = OCPcfg},
    {ok, run, Data#{'Version' => v1, 'Session' => Session, pcc => PCC}}.

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event({call, From}, delete_context, run, Data) ->
    delete_context(From, administrative, Data);
handle_event({call, From}, delete_context, shutdown, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, ok}}]};
handle_event({call, _From}, delete_context, _State, _Data) ->
    {keep_state_and_data, [postpone]};

handle_event({call, From}, terminate_context, _State, Data) ->
    close_pdp_context(normal, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, Path}, _State,
	     #{context := #context{path = Path}} = Data) ->
    close_pdp_context(normal, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, _Path}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

handle_event(cast, {defered_usage_report, URRActions, UsageReport}, _State,
	    #{pfcp := PCtx, 'Session' := Session}) ->
    Now = erlang:monotonic_time(),
    case proplists:get_value(offline, URRActions) of
	{{Reason, _} = ChargeEv, OldS} ->
	    {_Online, Offline, _} =
		ergw_gsn_lib:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),
	    ergw_gsn_lib:process_offline_charging_events(Reason, Offline, Now, OldS, Session);
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
    close_pdp_context(upf_failure, Data),
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

    GyReqServices = ergw_gsn_lib:gy_credit_request(Online, PCC0, PCC2),
    {ok, _, GyEvs} =
	ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOps),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),
    ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),

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

handle_event(info, _Info, _State, Data) ->
    ?LOG(warning, "~p, handle_info(~p, ~p)", [?MODULE, _Info, Data]),
    keep_state_and_data;

handle_event({timeout, context_idle}, stop_session, _state, Data) ->
    delete_context(undefined, normal, Data);

handle_event(internal, {session, stop, _Session}, run, Data) ->
    delete_context(undefined, normal, Data);
handle_event(internal, {session, stop, _Session}, _, Data) ->
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
    keep_state_and_data.

handle_pdu(ReqKey, #gtp{ie = PDU} = Msg, _State,
	   #{context := Context, pfcp := PCtx} = Data) ->
    ?LOG(debug, "GTP-U GGSN: ~p, ~p", [ReqKey, gtp_c_lib:fmt_gtp(Msg)]),

    ergw_gsn_lib:ip_pdu(PDU, Context, PCtx),
    {keep_state, Data}.

handle_sx_report(#pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{erir = 1}}},
	    _State, Data) ->
    close_pdp_context(normal, Data),
    {shutdown, Data};

%% User Plane Inactivity Timer expired
handle_sx_report(#pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{upir = 1}}},
		 _State, Data) ->
    close_pdp_context(normal, Data),
    {shutdown, Data};

handle_sx_report(#pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{usar = 1},
			      usage_report_srr := UsageReport}},
		 _State, #{pfcp := PCtx, 'Session' := Session, pcc := PCC} = Data) ->

    Now = erlang:monotonic_time(),
    ReqOpts = #{now => Now, async => true},

    ChargeEv = interim,
    {Online, Offline, Monitor} =
	ergw_gsn_lib:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),
    GyReqServices = ergw_gsn_lib:gy_credit_request(Online, PCC),
    ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOpts),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),
    ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),

    {ok, Data};

handle_sx_report(_, _State, Data) ->
    {error, 'System failure', Data}.

defered_usage_report(Server, URRActions, Report) ->
    gen_statem:cast(Server, {defered_usage_report, URRActions, Report}).

%% resent request
handle_request(_ReqKey, _Msg, true, _State, _Data) ->
    %% resent request
    keep_state_and_data;

handle_request(ReqKey,
	       #gtp{type = create_pdp_context_request,
		    ie = #{
			   ?'Access Point Name' := #access_point_name{apn = APN}
			  } = IEs} = Request, _Resent, _State,
	       #{context := Context0, aaa_opts := AAAopts, node_selection := NodeSelect,
		 'Session' := Session, pcc := PCC0} = Data) ->

    APN_FQDN = ergw_node_selection:apn_to_fqdn(APN),
    Services = [{"x-3gpp-upf", "x-sxb"}],
    Candidates = ergw_node_selection:topology_select(APN_FQDN, [], Services, NodeSelect),
    SxConnectId = ergw_sx_node:request_connect(Candidates, 1000),

    EUA = maps:get(?'End User Address', IEs, undefined),
    DAF = proplists:get_bool('Dual Address Bearer Flag', gtp_v1_c:get_common_flags(IEs)),

    Context1 = update_context_from_gtp_req(Request, Context0),
    ContextPreAuth = gtp_path:bind(Request, Context1),

    gtp_context:terminate_colliding_context(ContextPreAuth),

    SessionOpts0 = init_session(IEs, ContextPreAuth, AAAopts),
    SessionOpts1 = init_session_from_gtp_req(IEs, AAAopts, SessionOpts0),
    SessionOpts2 = init_session_qos(IEs, SessionOpts1),

    ergw_sx_node:wait_connect(SxConnectId),
    {UPinfo0, ContextUP} = ergw_gsn_lib:select_upf(Candidates, ContextPreAuth),

    SessionOpts  = init_session_pool(ContextUP, SessionOpts2),
    {ok, ActiveSessionOpts0, AuthSEvs} =
	authenticate(ContextUP, Session, SessionOpts, Request),

    {PendingPCtx1, NodeCaps, APNOpts, ContextVRF} =
	ergw_gsn_lib:reselect_upf(Candidates, ActiveSessionOpts0, ContextUP, UPinfo0),

    {Result, ActiveSessionOpts1, ContextPending1} =
	allocate_ips(APNOpts, ActiveSessionOpts0, EUA, DAF, ContextVRF),
    {ContextPending, ActiveSessionOpts} =
    add_apn_timeout(APNOpts, ActiveSessionOpts1, ContextPending1),
    PendingPCtx = ergw_gsn_lib:session_timeout_to_pctx(ContextPending, PendingPCtx1),
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
	    ?ABORT_CTX_REQUEST(ContextPending, Request, create_pdp_context_response,
			       user_authentication_failed);
	true ->
	    ok
    end,

    %% TBD............
    CreditsAdd = ergw_gsn_lib:pcc_ctx_to_credit_request(PCC1),
    GyReqServices = #{credits => CreditsAdd},

    {ok, GySessionOpts, GyEvs} =
	ccr_initial(ContextPending, Session, gy, GyReqServices, SOpts, Request),
    ?LOG(info, "GySessionOpts: ~p", [GySessionOpts]),
    ?LOG(info,"Initial GyEvs: ~p", [GyEvs]),

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

    ResponseIEs = create_pdp_context_response(Result, ActiveSessionOpts, IEs, Context),
    Response = response(create_pdp_context_response, Context, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = context_idle_action([], Context),
    {keep_state, Data#{context => Context, pfcp => PCtx, pcc => PCC4}, Actions};

handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request,
		    ie = #{?'Quality of Service Profile' := ReqQoSProfile} = IEs} = Request,
	       _Resent, _State,
	       #{context := OldContext, pfcp := PCtx,
		 'Session' := Session} = Data0) ->

    Context0 = update_context_from_gtp_req(Request, OldContext),
    Context = gtp_path:bind(Request, Context0),
    URRActions = update_session_from_gtp_req(IEs, Session, Context),

    Data1 = if Context /= OldContext ->
		     gtp_context:remote_context_update(OldContext, Context),
		     apply_context_change(Context, OldContext, URRActions, Data0);
		true ->
		     trigger_defered_usage_report(URRActions, PCtx),
		     Data0
	     end,

    ResponseIEs0 = [#cause{value = request_accepted},
		    context_charging_id(Context),
		    ReqQoSProfile],
    ResponseIEs = tunnel_endpoint_elements(Context, ResponseIEs0),
    Response = response(update_pdp_context_response, Context, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = context_idle_action([], Context),
    {keep_state, Data1, Actions};

handle_request(ReqKey,
	       #gtp{type = ms_info_change_notification_request, ie = IEs} = Request,
	       _Resent, _State,
	       #{context := OldContext, pfcp := PCtx,
		 'Session' := Session} = Data) ->

    Context = update_context_from_gtp_req(Request, OldContext),
    URRActions = update_session_from_gtp_req(IEs, Session, Context),
    trigger_defered_usage_report(URRActions, PCtx),

    ResponseIEs0 = [#cause{value = request_accepted}],
    ResponseIEs = copy_ies_to_response(IEs, ResponseIEs0, [?'IMSI', ?'IMEI']),
    Response = response(ms_info_change_notification_response, Context, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = context_idle_action([], Context),
    {keep_state, Data#{context => Context}, Actions};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request, ie = _IEs} = Request,
	       _Resent, _State, #{context := Context} = Data) ->
    close_pdp_context(normal, Data),
    Response = response(delete_pdp_context_response, Context, request_accepted),
    gtp_context:send_response(ReqKey, Request, Response),
    {next_state, shutdown, Data};

handle_request(ReqKey, _Msg, _Resent, _State, _Data) ->
    gtp_context:request_finished(ReqKey),
    keep_state_and_data.

handle_response({From, TermCause}, timeout, #gtp{type = delete_pdp_context_request},
		_State, Data) ->
    close_pdp_context(TermCause, Data),
    if is_tuple(From) -> gen_statem:reply(From, {error, timeout});
       true -> ok
    end,
    {next_state, shutdown, Data};

handle_response({From, TermCause},
		#gtp{type = delete_pdp_context_response,
		     ie = #{?'Cause' := #cause{value = Cause}}} = Response,
		_Request, _State,
		#{context := Context0} = Data) ->
    Context = gtp_path:bind(Response, Context0),
    close_pdp_context(TermCause, Data),
    if is_tuple(From) -> gen_statem:reply(From, {ok, Cause});
       true -> ok
    end,
    {next_state, shutdown, Data#{context := Context}}.

terminate(_Reason, _State, #{context := Context}) ->
    ergw_gsn_lib:release_context_ips(Context),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

response(Cmd, #context{remote_control_teid = #fq_teid{teid = TEID}}, Response) ->
    {Cmd, TEID, Response}.

response(Cmd, Context, IEs0, #gtp{ie = #{?'Recovery' := Recovery}}) ->
    IEs = gtp_v1_c:build_recovery(Cmd, Context, Recovery /= undefined, IEs0),
    response(Cmd, Context, IEs).

session_failure_to_gtp_cause(_) ->
    system_failure.

authenticate(Context, Session, SessionOpts, Request) ->
    ?LOG(info, "SessionOpts: ~p", [SessionOpts]),
    case ergw_aaa_session:invoke(Session, SessionOpts, authenticate, [inc_session_id]) of
	{ok, _, _} = Result ->
	    ?LOG(info, "AuthResult: success"),
	    Result;
	Other ->
	    ?LOG(info, "AuthResult: ~p", [Other]),
	    ?ABORT_CTX_REQUEST(Context, Request, create_pdp_context_response,
			       user_authentication_failed)
    end.

ccr_initial(Context, Session, API, SessionOpts, ReqOpts, Request) ->
    case ergw_aaa_session:invoke(Session, SessionOpts, {API, 'CCR-Initial'}, ReqOpts) of
	{ok, _, _} = Result ->
	    Result;
	{Fail, _, _} ->
	    ?ABORT_CTX_REQUEST(Context, Request, create_pdp_context_response,
			       session_failure_to_gtp_cause(Fail))
    end.

pdp_alloc(#end_user_address{pdp_type_organization = 0,
			    pdp_type_number = 2}) ->
    {'Non-IP', undefined, undefined};

pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#21,
			    pdp_address = Address}) ->
    IP4 = case Address of
	      << >> ->
		  {0,0,0,0};
	      <<_:4/bytes>> ->
		  ergw_inet:bin2ip(Address)
	  end,
    {'IPv4', IP4, undefined};

pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#57,
			    pdp_address = Address}) ->
    IP6 = case Address of
	      << >> ->
		  {{0,0,0,0,0,0,0,0},64};
	      <<_:16/bytes>> ->
		  {ergw_inet:bin2ip(Address),128}
	  end,
    {'IPv6', undefined, IP6};

pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#8D,
			    pdp_address = Address}) ->
    case Address of
	<< IP4:4/bytes, IP6:16/bytes >> ->
	    {'IPv4v6', ergw_inet:bin2ip(IP4), {ergw_inet:bin2ip(IP6), 128}};
	<< IP6:16/bytes >> ->
	    {'IPv4v6', {0,0,0,0}, {ergw_inet:bin2ip(IP6), 128}};
	<< IP4:4/bytes >> ->
	    {'IPv4v6', ergw_inet:bin2ip(IP4), {{0,0,0,0,0,0,0,0},64}};
	<<  >> ->
	    {'IPv4v6', {0,0,0,0}, {{0,0,0,0,0,0,0,0},64}}
   end;

pdp_alloc(_) ->
    {undefined, undefined}.

encode_eua({IPv4,_}, undefined) ->
    encode_eua(1, 16#21, ergw_inet:ip2bin(IPv4), <<>>);
encode_eua(undefined, {IPv6,_}) ->
    encode_eua(1, 16#57, <<>>, ergw_inet:ip2bin(IPv6));
encode_eua({IPv4,_}, {IPv6,_}) ->
    encode_eua(1, 16#8D, ergw_inet:ip2bin(IPv4), ergw_inet:ip2bin(IPv6)).

encode_eua(Org, Number, IPv4, IPv6) ->
    #end_user_address{pdp_type_organization = Org,
		      pdp_type_number = Number,
		      pdp_address = <<IPv4/binary, IPv6/binary >>}.

close_pdp_context(Reason, #{context := Context, pfcp := PCtx, 'Session' := Session}) ->
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
	    ?LOG(info, "GxSessionOpts: ~p", [_GxSessionOpts]);
	GxOther ->
	    ?LOG(warning, "Gx terminate failed with: ~p", [GxOther])
    end,

    ChargeEv = {terminate, TermCause},
    {Online, Offline, Monitor} =
	ergw_gsn_lib:usage_report_to_charging_events(URRs, ChargeEv, PCtx),
    GyReqServices = ergw_gsn_lib:gy_credit_report(Online),
    ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOpts),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),
    ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),

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

	GyReqServices = ergw_gsn_lib:gy_credit_request(Online, PCC),
	ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOpts),
	ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),
	ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session)
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
    NewContext = gtp_path:bind(NewContext0),
    {PCtx, UsageReport} =
	ergw_gsn_lib:modify_sgi_session(PCC, URRActions,
					#{}, NewContext, PCtx0),
    gtp_path:unbind(OldContext),
    defer_usage_report(URRActions, UsageReport),
    Data#{context => NewContext, pfcp => PCtx}.

%% 'Idle-Timeout' received from ergw_aaa Session takes precedence over configured one
add_apn_timeout(Opts, Session, Context) ->
    SessionWithTimeout = maps:merge(maps:with(['Idle-Timeout'],Opts), Session),
    Timeout = maps:get('Idle-Timeout', SessionWithTimeout),
    ContextWithTimeout = Context#context{'Idle-Timeout' = Timeout},
    {ContextWithTimeout, SessionWithTimeout}.
 
map_attr('APN', #{?'Access Point Name' := #access_point_name{apn = APN}}) ->
    unicode:characters_to_binary(lists:join($., APN));
map_attr('IMSI', #{?'IMSI' := #international_mobile_subscriber_identity{imsi = IMSI}}) ->
    IMSI;
map_attr('IMEI', #{?'IMEI' := #imei{imei = IMEI}}) ->
    IMEI;
map_attr('MSISDN', #{?'MSISDN' := #ms_international_pstn_isdn_number{
				     msisdn = {isdn_address, _, _, 1, MSISDN}}}) ->
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

hexstr(Value, _Width) when is_binary(Value) ->
    erlang:iolist_to_binary([io_lib:format("~2.16.0B", [X]) || <<X>> <= Value]);
hexstr(Value, Width) when is_integer(Value) ->
     erlang:iolist_to_binary(io_lib:format("~*.16.0B", [Width, Value])).

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
	  '3GPP-Charging-Id'	=> ChargingId,
	  'PDP-Context-Type'	=> primary
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

copy_to_session(_, #protocol_configuration_options{config = {0, Options}},
		#{'Username' := #{from_protocol_opts := true}}, Session) ->
    lists:foldr(fun copy_ppp_to_session/2, Session, Options);
copy_to_session(_, #access_point_name{apn = APN}, _AAAopts, Session) ->
    {NI, _OI} = ergw_node_selection:split_apn(APN),
    Session#{'Called-Station-Id' =>
		 iolist_to_binary(lists:join($., NI))};
copy_to_session(_, #ms_international_pstn_isdn_number{
		   msisdn = {isdn_address, _, _, 1, MSISDN}}, _AAAopts, Session) ->
    Session#{'Calling-Station-Id' => MSISDN, '3GPP-MSISDN' => MSISDN};
copy_to_session(_, #international_mobile_subscriber_identity{imsi = IMSI}, _AAAopts, Session) ->
    case itu_e212:split_imsi(IMSI) of
	{MCC, MNC, _} ->
	    Session#{'3GPP-IMSI' => IMSI,
		     '3GPP-IMSI-MCC-MNC' => <<MCC/binary, MNC/binary>>};
	_ ->
	    Session#{'3GPP-IMSI' => IMSI}
    end;
copy_to_session(_, #end_user_address{pdp_type_organization = 0,
				     pdp_type_number = 1}, _AAAopts, Session) ->
    Session#{'3GPP-PDP-Type' => 'PPP'};
copy_to_session(_, #end_user_address{pdp_type_organization = 0,
				     pdp_type_number = 2}, _AAAopts, Session) ->
    Session#{'3GPP-PDP-Type' => 'Non-IP'};
copy_to_session(_, #end_user_address{pdp_type_organization = 1,
				     pdp_type_number = 16#21,
				     pdp_address = Address}, _AAAopts, Session0) ->
    Session = Session0#{'3GPP-PDP-Type' => 'IPv4'},
    case Address of
	<<_:4/bytes>> ->
	    IP4 = ergw_inet:bin2ip(Address),
	    Session#{'Framed-IP-Address' => IP4,
		     'Requested-IP-Address' => IP4};
	_ ->
	    Session
    end;
copy_to_session(_, #end_user_address{pdp_type_organization = 1,
				     pdp_type_number = 16#57,
				     pdp_address = Address}, _AAAopts, Session0) ->
    Session = Session0#{'3GPP-PDP-Type' => 'IPv6'},
    case Address of
	<<_:16/bytes>> ->
	    IP6 = {ergw_inet:bin2ip(Address), 128},
	    Session#{'Framed-IPv6-Prefix' => IP6,
		     'Requested-IPv6-Prefix' => IP6};
	_ ->
	    Session
    end;
copy_to_session(_, #end_user_address{pdp_type_organization = 1,
				     pdp_type_number = 16#8D,
				     pdp_address = Address}, _AAAopts, Session0) ->
    Session = Session0#{'3GPP-PDP-Type' => 'IPv4v6'},
    case Address of
	<< IP4:4/bytes >> ->
	    IP4addr = ergw_inet:bin2ip(IP4),
	    Session#{'Framed-IP-Address' => IP4addr,
		     'Requested-IP-Address' => IP4addr};
	<< IP6:16/bytes >> ->
	    IP6addr = {ergw_inet:bin2ip(IP6), 128},
	    Session#{'Framed-IPv6-Prefix' => IP6addr,
		     'Requested-IPv6-Prefix' => IP6addr};
	<< IP4:4/bytes, IP6:16/bytes >> ->
	    IP4addr = ergw_inet:bin2ip(IP4),
	    IP6addr = {ergw_inet:bin2ip(IP6), 128},
	    Session#{'Framed-IP-Address' => IP4addr,
		     'Framed-IPv6-Prefix' => IP6addr,
		     'Requested-IP-Address' => IP4addr,
		     'Requested-IPv6-Prefix' => IP6addr};
	_ ->
	    Session
   end;

copy_to_session(_, #gsn_address{instance = 0, address = IP}, _AAAopts, Session)
  when size(IP) == 4 ->
    Session#{'3GPP-SGSN-Address' => ergw_inet:bin2ip(IP)};
copy_to_session(_, #gsn_address{instance = 0, address = IP}, _AAAopts, Session)
  when size(IP) == 16 ->
    Session#{'3GPP-SGSN-IPv6-Address' => ergw_inet:bin2ip(IP)};
copy_to_session(_, #nsapi{instance = 0, nsapi = NSAPI}, _AAAopts, Session) ->
    Session#{'3GPP-NSAPI' => NSAPI};
copy_to_session(_, #selection_mode{mode = Mode}, _AAAopts, Session) ->
    Session#{'3GPP-Selection-Mode' => Mode};
copy_to_session(_, #charging_characteristics{value = Value}, _AAAopts, Session) ->
    Session#{'3GPP-Charging-Characteristics' => Value};
copy_to_session(_, #routeing_area_identity{mcc = MCC, mnc = MNC,
					   lac = LAC, rac = RAC}, _AAAopts, Session) ->
    RAI = <<MCC/binary, MNC/binary, (hexstr(LAC, 4))/binary, (hexstr(RAC, 2))/binary>>,
    Session#{'RAI' => RAI,
	     '3GPP-SGSN-MCC-MNC' => <<MCC/binary, MNC/binary>>};
copy_to_session(_, #imei{imei = IMEI}, _AAAopts, Session) ->
    Session#{'3GPP-IMEISV' => IMEI};
copy_to_session(_, #rat_type{rat_type = Type}, _AAAopts, Session) ->
    Session#{'3GPP-RAT-Type' => Type};
copy_to_session(_, #user_location_information{type = Type, mcc = MCC, mnc = MNC, lac = LAC,
					      ci = CI, sac = SAC} = IE, _AAAopts, Session0) ->
    Session = if Type == 0 ->
		      CGI = <<MCC/binary, MNC/binary, LAC:16, CI:16>>,
		      maps:without(['SAI'], Session0#{'CGI' => CGI});
		 Type == 1 ->
		      SAI = <<MCC/binary, MNC/binary, LAC:16, SAC:16>>,
		      maps:without(['CGI'], Session0#{'SAI' => SAI});
		 true ->
		      Session0
	      end,
    Value = gtp_packet:encode_v1_uli(IE),
    Session#{'3GPP-User-Location-Info' => Value};
copy_to_session(_, #ms_time_zone{timezone = TZ, dst = DST}, _AAAopts, Session) ->
    Session#{'3GPP-MS-TimeZone' => {TZ, DST}};
copy_to_session(_, _, _AAAopts, Session) ->
    Session.

init_session_from_gtp_req(IEs, AAAopts, Session) ->
    maps:fold(copy_to_session(_, _, AAAopts, _), Session, IEs).

init_session_qos(#{?'Quality of Service Profile' :=
		       #quality_of_service_profile{
			  priority = RequestedPriority,
			  data = RequestedQoS}} = IEs, Session0) ->
    %% TODO: use config setting to init default class....
    {NegotiatedARP, NegotiatedQoS, QoS} =
	negotiate_qos(RequestedPriority, RequestedQoS),
    Session = Session0#{'3GPP-Allocation-Retention-Priority' => NegotiatedARP,
			'3GPP-GPRS-Negotiated-QoS-Profile'   => NegotiatedQoS},
    session_qos_info(QoS, NegotiatedARP, IEs, Session);
init_session_qos(_IEs, Session) ->
    Session.

init_session_pool(#context{ipv4_pool = undefined, ipv6_pool = undefined}, Session) ->
    Session;
init_session_pool(#context{ipv4_pool = IPv4Pool, ipv6_pool = undefined}, Session) ->
    Session#{'Framed-Pool' => IPv4Pool};
init_session_pool(#context{ipv4_pool = undefined, ipv6_pool = IPv6Pool}, Session) ->
    Session#{'Framed-IPv6-Pool' => IPv6Pool};
init_session_pool(#context{ipv4_pool = IPv4Pool, ipv6_pool = IPv6Pool}, Session) ->
    Session#{'Framed-Pool' => IPv4Pool, 'Framed-IPv6-Pool' => IPv6Pool}.

update_session_from_gtp_req(IEs, Session, Context) ->
    OldSOpts = ergw_aaa_session:get(Session),
    NewSOpts0 =
	maps:fold(copy_to_session(_, _, undefined, _), OldSOpts, IEs),
    NewSOpts =
	init_session_qos(IEs, NewSOpts0),
    ergw_aaa_session:set(Session, NewSOpts),
    gtp_context:collect_charging_events(OldSOpts, NewSOpts, Context).

negotiate_qos_prio(X) when X > 0 andalso X =< 3 ->
    X;
negotiate_qos_prio(_) ->
    2.

session_qos_info_qci(#qos{
			traffic_class			= 1,		%% Conversational class
			source_statistics_descriptor	= 1}) ->	%% Speech
    1;
session_qos_info_qci(#qos{
			traffic_class			= 1,		%% Conversational class
			transfer_delay			= TransferDelay})
  when TransferDelay >= 150 ->
    2;
session_qos_info_qci(#qos{traffic_class			= 1}) ->	%% Conversational class
%% TransferDelay < 150
    3;
session_qos_info_qci(#qos{traffic_class			= 2}) ->	%% Streaming class
    4;
session_qos_info_qci(#qos{
			traffic_class			= 3,		%% Interactive class
			traffic_handling_priority	= 1,		%% Priority level 1
			signaling_indication		= 1}) ->	%% yes
    5;
session_qos_info_qci(#qos{
			traffic_class			= 3,		%% Interactive class
			signaling_indication		= 0}) ->	%% no
    6;
session_qos_info_qci(#qos{
			traffic_class			= 3,		%% Interactive class
			traffic_handling_priority	= 2}) ->	%% Priority level 2
    7;
session_qos_info_qci(#qos{
			traffic_class			= 3,		%% Interactive class
			traffic_handling_priority	= 3}) ->	%% Priority level 3
    8;
session_qos_info_qci(#qos{traffic_class			= 4}) ->	%% Background class
    9;
session_qos_info_qci(_) -> 9.

session_qos_info_arp(_ARP,
		     #{?'Evolved ARP I' :=
			   #evolved_allocation_retention_priority_i{
			      pci = PCI, pl = PL, pvi = PVI}}) ->
    #{'Priority-Level' => PL,
      'Pre-emption-Capability' => PCI,
      'Pre-emption-Vulnerability' => PVI};
session_qos_info_arp(_ARP = 1, _IEs) ->
    #{'Priority-Level' => 1,
      'Pre-emption-Capability' => 1,         %% TODO operator policy
      'Pre-emption-Vulnerability' => 0};     %% TODO operator policy
session_qos_info_arp(_ARP = 2, _IEs) ->
    #{'Priority-Level' => 2,                 %% TODO operator policy, H + 1 with H >= 1
      'Pre-emption-Capability' => 1,         %% TODO operator policy
      'Pre-emption-Vulnerability' => 0};     %% TODO operator policy
session_qos_info_arp(_ARP = 3, _IEs) ->
    #{'Priority-Level' => 3,                 %% TODO operator policy M + 1 with M >= H + 1
      'Pre-emption-Capability' => 1,         %% TODO operator policy
      'Pre-emption-Vulnerability' => 0}.     %% TODO operator policy

%% the UE may send 'subscribed` as rate. There is nothing in specs that
%% tells how to translate this to requested QoS in Session (Gx/Gy/Rf)
session_qos_bitrate(Key, Value, Info) when is_integer(Value) ->
    Info#{Key => Value * 1000};
session_qos_bitrate(_, _, Info) ->
    Info.

session_qos_info_apn_ambr(_QoS,
			  #{?'APN-AMBR' :=
				#aggregate_maximum_bit_rate{
				   uplink   = AMBR4ul,
				   downlink = AMBR4dl
				  }}, Info0) ->
    Info = session_qos_bitrate('APN-Aggregate-Max-Bitrate-UL', AMBR4ul, Info0),
    session_qos_bitrate('APN-Aggregate-Max-Bitrate-DL', AMBR4dl, Info);
session_qos_info_apn_ambr(#qos{
			     max_bit_rate_uplink   = MBR4ul,
			     max_bit_rate_downlink = MBR4dl},
			  _IEs, Info0) ->
    Info = session_qos_bitrate('APN-Aggregate-Max-Bitrate-UL', MBR4ul, Info0),
    session_qos_bitrate('APN-Aggregate-Max-Bitrate-DL', MBR4dl, Info).

%% see 3GPP TS 29.212 version 15.3.0, Appending B.3.3.3
session_qos_info(#qos{
		    max_bit_rate_uplink          = MBR4ul,
		    max_bit_rate_downlink        = MBR4dl,
		    guaranteed_bit_rate_uplink   = GBR4ul,
		    guaranteed_bit_rate_downlink = GBR4dl
		   } = QoS, ARP, IEs, Session) ->
    Info0 = #{
	      'QoS-Class-Identifier' =>
		  session_qos_info_qci(QoS),
	      'Allocation-Retention-Priority' =>
		  session_qos_info_arp(ARP, IEs)
	     },
    Info1 = session_qos_bitrate('Max-Requested-Bandwidth-UL', MBR4ul, Info0),
    Info2 = session_qos_bitrate('Max-Requested-Bandwidth-DL', MBR4dl, Info1),
    Info3 = session_qos_bitrate('Guaranteed-Bitrate-UL', GBR4ul, Info2),
    Info4 = session_qos_bitrate('Guaranteed-Bitrate-DL', GBR4dl, Info3),
    Info = session_qos_info_apn_ambr(QoS, IEs, Info4),
    Session#{'QoS-Information' => Info};

session_qos_info(_QoS, _ARP, _IEs, Session) ->
    Session.

negotiate_qos(ReqPriority, ReqQoSProfileData) ->
    NegPriority = negotiate_qos_prio(ReqPriority),
    case '3gpp_qos':decode(ReqQoSProfileData) of
	Profile when is_binary(Profile) ->
	    {NegPriority, ReqQoSProfileData, undefined};
	#qos{traffic_class = 0} ->			%% MS to Network: Traffic Class: Subscribed
	    %% 3GPP TS 24.008, Sect. 10.5.6.5,
	    QoS = #qos{
		     delay_class			= 4,		%% best effort
		     reliability_class			= 3,		%% Unacknowledged GTP/LLC,
		     %% Ack RLC, Protected data
		     peak_throughput			= 2,		%% 2000 oct/s (2 kBps)
		     precedence_class			= 3,		%% Low priority
		     mean_throughput			= 31,		%% Best effort
		     traffic_class			= 4,		%% Background class
		     delivery_order			= 2,		%% Without delivery order
		     delivery_of_erroneorous_sdu	= 3,		%% Erroneous SDUs are not delivered
		     max_sdu_size			= 1500,		%% 1500 octets
		     max_bit_rate_uplink		= 16,		%% 16 kbps
		     max_bit_rate_downlink		= 16,		%% 16 kbps
		     residual_ber			= 7,		%% 10^-5
		     sdu_error_ratio			= 4,		%% 10^-4
		     transfer_delay			= 300,		%% 300ms
		     traffic_handling_priority		= 3,		%% Priority level 3
		     guaranteed_bit_rate_uplink		= 0,		%% 0 kbps
		     guaranteed_bit_rate_downlink	= 0,		%% 0 kbps
		     signaling_indication		= 0,		%% Not optimised for signalling traffic
		     source_statistics_descriptor	= 0},		%% unknown
	    {NegPriority, '3gpp_qos':encode(QoS), QoS};
	#qos{} = QoS ->
	    {NegPriority, ReqQoSProfileData, QoS}
    end.

set_fq_teid(Id, undefined, Value) ->
    set_fq_teid(Id, #fq_teid{}, Value);
set_fq_teid(ip, TEID, Value) ->
    TEID#fq_teid{ip = ergw_inet:bin2ip(Value)};
set_fq_teid(teid, TEID, Value) ->
    TEID#fq_teid{teid = Value}.

set_fq_teid(Id, Field, Context, Value) ->
    setelement(Field, Context, set_fq_teid(Id, element(Field, Context), Value)).

get_context_from_req(_, #gsn_address{instance = 0, address = CntlIP}, Context) ->
    IP = ergw_gsn_lib:choose_context_ip(CntlIP, CntlIP, Context),
    set_fq_teid(ip, #context.remote_control_teid, Context, IP);
get_context_from_req(_, #gsn_address{instance = 1, address = DataIP}, Context) ->
    IP = ergw_gsn_lib:choose_context_ip(DataIP, DataIP, Context),
    set_fq_teid(ip, #context.remote_data_teid, Context, IP);
get_context_from_req(_, #tunnel_endpoint_identifier_data_i{instance = 0, tei = DataTEI}, Context) ->
    set_fq_teid(teid, #context.remote_data_teid, Context, DataTEI);
get_context_from_req(_, #tunnel_endpoint_identifier_control_plane{instance = 0, tei = CntlTEI}, Context) ->
    set_fq_teid(teid, #context.remote_control_teid, Context, CntlTEI);
get_context_from_req(?'Access Point Name', #access_point_name{apn = APN}, Context) ->
    Context#context{apn = APN};
get_context_from_req(?'IMSI', #international_mobile_subscriber_identity{imsi = IMSI}, Context) ->
    Context#context{imsi = IMSI};
get_context_from_req(?'IMEI', #imei{imei = IMEI}, Context) ->
    Context#context{imei = IMEI};
get_context_from_req(?'MSISDN', #ms_international_pstn_isdn_number{
				   msisdn = {isdn_address, _, _, 1, MSISDN}}, Context) ->
    Context#context{msisdn = MSISDN};
%% get_context_from_req(#nsapi{instance = 0, nsapi = NSAPI}, #context{state = Data} = Context) ->
%%     Context#context{state = Data#context_state{nsapi = NSAPI}};
get_context_from_req(_, _, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs} = Req, Context0) ->
    Context1 = gtp_v1_c:update_context_id(Req, Context0),
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

send_request(#context{control_port = GtpPort,
		      remote_control_teid =
			  #fq_teid{
			     ip = RemoteCntlIP,
			     teid = RemoteCntlTEI}
		     },
	     T3, N3, Type, RequestIEs, ReqInfo) ->
    Msg = #gtp{version = v1, type = Type, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(GtpPort, RemoteCntlIP, ?GTP1c_PORT, T3, N3, Msg, ReqInfo).

delete_context(From, TermCause, #{context := Context} = Data) ->
    Type = delete_pdp_context_request,
    NSAPI = 5,
    RequestIEs0 = [#nsapi{nsapi = NSAPI},
		   #teardown_ind{value = 1}],
    RequestIEs = gtp_v1_c:build_recovery(Type, Context, false, RequestIEs0),
    send_request(Context, ?T3, ?N3, Type, RequestIEs, {From, TermCause}),
    {next_state, shutdown_initiated, Data}.

allocate_ips(APNOpts, SOpts, EUA, DAF, Context) ->
    ergw_gsn_lib:allocate_ips(pdp_alloc(EUA), APNOpts, SOpts, DAF, Context).

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

pdp_ppp_pco(SessionOpts, {pap, 'PAP-Authentication-Request', Id, _Username, _Password}, Opts) ->
    [{pap, 'PAP-Authenticate-Ack', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdp_ppp_pco(SessionOpts, {chap, 'CHAP-Response', Id, _Value, _Name}, Opts) ->
    [{chap, 'CHAP-Success', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdp_ppp_pco(SessionOpts, {ipcp,'CP-Configure-Request', Id, CpReqOpts}, Opts) ->
    CpRespOpts = lists:foldr(ppp_ipcp_conf(SessionOpts, _, _), #{}, CpReqOpts),
    maps:fold(fun(K, V, O) -> [{ipcp, K, Id, V} | O] end, Opts, CpRespOpts);

pdp_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv6-Address', <<>>}, Opts) ->
    [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
     || DNS <- maps:get('DNS-Server-IPv6-Address', SessionOpts, [])]
	++ [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
	    || DNS <- maps:get('3GPP-IPv6-DNS-Servers', SessionOpts, [])]
	++ Opts;
pdp_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv4-Address', <<>>}, Opts) ->
    lists:foldr(fun(Key, O) ->
			case maps:find(Key, SessionOpts) of
			    {ok, DNS} ->
				[{?'PCO-DNS-Server-IPv4-Address', ergw_inet:ip2bin(DNS)} | O];
			    _ ->
				O
			end
		end, Opts, ['MS-Secondary-DNS-Server', 'MS-Primary-DNS-Server']);
pdp_ppp_pco(_SessionOpts, PPPReqOpt, Opts) ->
    ?LOG(info, "Apply PPP Opt: ~p", [PPPReqOpt]),
    Opts.

pdp_pco(SessionOpts, #{?'Protocol Configuration Options' :=
			   #protocol_configuration_options{config = {0, PPPReqOpts}}}, IE) ->
    case lists:foldr(pdp_ppp_pco(SessionOpts, _, _), [], PPPReqOpts) of
	[]   -> IE;
	Opts -> [#protocol_configuration_options{config = {0, Opts}} | IE]
    end;
pdp_pco(_SessionOpts, _RequestIEs, IE) ->
    IE.

pdp_qos_profile(#{'3GPP-Allocation-Retention-Priority' := NegotiatedPriority,
		  '3GPP-GPRS-Negotiated-QoS-Profile'   := NegotiatedQoS}, IE) ->
    [#quality_of_service_profile{priority = NegotiatedPriority, data = NegotiatedQoS} | IE];
pdp_qos_profile(_SessionOpts, IE) ->
    IE.

tunnel_endpoint_elements(#context{control_port = #gtp_port{ip = CntlIP},
				  local_control_tei = CntlTEI,
				  local_data_endp = #gtp_endp{ip = DataIP, teid = DataTEI}
				 }, IEs) ->
    [#tunnel_endpoint_identifier_data_i{tei = DataTEI},
     #tunnel_endpoint_identifier_control_plane{tei = CntlTEI},
     #gsn_address{instance = 0, address = ergw_inet:ip2bin(CntlIP)},   %% for Control Plane
     #gsn_address{instance = 1, address = ergw_inet:ip2bin(DataIP)}    %% for User Traffic
     | IEs].

context_charging_id(#context{charging_identifier = ChargingId}) ->
    #charging_id{id = <<ChargingId:32>>}.

create_pdp_context_response(Result, SessionOpts, RequestIEs,
			    #context{ms_v4 = MSv4, ms_v6 = MSv6} = Context) ->
    IE0 = [Result,
	   #reordering_required{required = no},
	   context_charging_id(Context),
	   encode_eua(MSv4, MSv6)],
    IE1 = pdp_qos_profile(SessionOpts, IE0),
    IE2 = pdp_pco(SessionOpts, RequestIEs, IE1),
    tunnel_endpoint_elements(Context, IE2).

%% Wrapper for gen_statem state_callback_result Actions argument
%% Timeout set in the context of a prolonged idle gtp session
context_idle_action(Actions, #context{'Idle-Timeout' = Timeout})
  when is_integer(Timeout) orelse Timeout =:= infinity ->
    [{{timeout, context_idle}, Timeout, stop_session} | Actions];
context_idle_action(Actions, _) ->
    Actions.
