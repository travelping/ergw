%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn_proxy).

-behaviour(gtp_api).

-compile({parse_transform, cut}).

-export([validate_options/1, init/2, request_spec/3,
	 handle_pdu/4, handle_sx_report/3, session_events/4,
	 handle_request/5, handle_response/5,
	 handle_event/4, terminate/3]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-import(ergw_aaa_session, [to_session/1]).

-compile([nowarn_unused_record]).

-define(T3, 10 * 1000).
-define(N3, 5).
-define(RESPONSE_TIMEOUT, (?T3 + (?T3 div 2))).

-define(IS_REQUEST_CONTEXT(Key, Msg, Context),
	(is_record(Key, request) andalso
	 is_record(Msg, gtp) andalso
	 Key#request.gtp_port =:= Context#context.control_port andalso
	 Msg#gtp.tei =:= Context#context.local_control_tei)).

-define(IS_REQUEST_CONTEXT_OPTIONAL_TEI(Key, Msg, Context),
	(is_record(Key, request) andalso
	 is_record(Msg, gtp) andalso
	 Key#request.gtp_port =:= Context#context.control_port andalso
	 (Msg#gtp.tei =:= 0 orelse
	  Msg#gtp.tei =:= Context#context.local_control_tei))).

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

-define(CAUSE_OK(Cause), (Cause =:= request_accepted orelse
			  Cause =:= new_pdp_type_due_to_network_preference orelse
			  Cause =:= new_pdp_type_due_to_single_address_bearer_only)).

request_spec(v1, _Type, Cause)
  when Cause /= undefined andalso not ?CAUSE_OK(Cause) ->
    [];

request_spec(v1, create_pdp_context_request, _) ->
    [{?'IMSI',						conditional},
     {{selection_mode, 0},				conditional},
     {?'Tunnel Endpoint Identifier Data I',		mandatory},
     {?'Tunnel Endpoint Identifier Control Plane',	conditional},
     {?'NSAPI',						mandatory},
     {{nsapi, 1},					conditional},
     {{charging_characteristics, 0},			conditional},
     {?'End User Address',				conditional},
     {?'Access Point Name',				conditional},
     {?'SGSN Address for signalling',			mandatory},
     {?'SGSN Address for user traffic',			mandatory},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {?'MSISDN',					conditional},
     {?'Quality of Service Profile',			mandatory},
     {{traffic_flow_template, 0},			conditional},
     {?'IMEI',						conditional}];

request_spec(v1, create_pdp_context_response, _) ->
    [{?'Cause',						mandatory},
     {{reordering_required, 0},				conditional},
     {?'Tunnel Endpoint Identifier Data I',		conditional},
     {?'Tunnel Endpoint Identifier Control Plane',	conditional},
     {{charging_id, 0},					conditional},
     {?'End User Address',				conditional},
     {?'SGSN Address for signalling',			conditional},
     {?'SGSN Address for user traffic',			conditional},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {?'Quality of Service Profile',			conditional}];

%% SGSN initated reqeuest:
%% request_spec(v1, update_pdp_context_request, _) ->
%%     [{?'Tunnel Endpoint Identifier Data I',		mandatory},
%%      {?'Tunnel Endpoint Identifier Control Plane',	conditional},
%%      {?'NSAPI',						mandatory},
%%      {?'SGSN Address for signalling',			mandatory},
%%      {?'SGSN Address for user traffic',			mandatory},
%%      {{gsn_address, 2},					conditional},
%%      {{gsn_address, 3},					conditional},
%%      {?'Quality of Service Profile',			mandatory},
%%      {{traffic_flow_template, 0},			conditional}];

request_spec(v1, update_pdp_context_request, _) ->
    [{?'NSAPI',						mandatory}];

request_spec(v1, update_pdp_context_response, _) ->
    [{{cause, 0},					mandatory},
     {?'Tunnel Endpoint Identifier Data I',		conditional},
     {?'Tunnel Endpoint Identifier Control Plane',	conditional},
     {{charging_id, 0},					conditional},
     {?'SGSN Address for signalling',			conditional},
     {?'SGSN Address for user traffic',			conditional},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {?'Quality of Service Profile',			conditional}];

request_spec(v1, delete_pdp_context_request, _) ->
    [{{teardown_ind, 0},				conditional},
     {?'NSAPI',						mandatory}];

request_spec(v1, delete_pdp_context_response, _) ->
    [{?'Cause',						mandatory}];

request_spec(v1, _, _) ->
    [].

-define(Defaults, []).

validate_options(Opts) ->
    ?LOG(debug, "GGSN Gn/Gp Options: ~p", [Opts]),
    ergw_proxy_lib:validate_options(fun validate_option/2, Opts, ?Defaults).

validate_option(Opt, Value) ->
    ergw_proxy_lib:validate_option(Opt, Value).

-record(context_state, {nsapi}).

init(#{proxy_sockets := ProxyPorts, node_selection := NodeSelect,
       proxy_data_source := ProxyDS, contexts := Contexts}, Data) ->

    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),

    {ok, run, Data#{proxy_ports => ProxyPorts,
		    'Version' => v1, 'Session' => Session, contexts => Contexts,
		    node_selection => NodeSelect, proxy_ds => ProxyDS}}.

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event({call, From}, delete_context, _State, _Data) ->
    ?LOG(warning, "delete_context no handled(yet)"),
    {keep_state_and_data, [{reply, From, ok}]};

handle_event({call, From}, terminate_context, _State, Data) ->
    initiate_pdp_context_teardown(sgsn2ggsn, Data),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, Path}, _State,
	     #{context := #context{path = Path}} = Data) ->
    initiate_pdp_context_teardown(sgsn2ggsn, Data),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, Path}, _State,
	     #{proxy_context := #context{path = Path}} = Data) ->
    initiate_pdp_context_teardown(ggsn2sgsn, Data),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, _Path}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

handle_event(cast, delete_context, _State, _Data) ->
    ?LOG(warning, "delete_context no handled(yet)"),
    keep_state_and_data;

handle_event(cast, {packet_in, _GtpPort, _IP, _Port, _Msg}, _State, _Data) ->
    ?LOG(warning, "packet_in not handled (yet): ~p", [_Msg]),
    keep_state_and_data;

handle_event(info, {timeout, _, {delete_pdp_context_request, Direction, _ReqKey, _Request}},
	     _State, Data) ->
    ?LOG(warning, "Proxy Delete PDP Context Timeout ~p", [Direction]),

    delete_forward_session(normal, Data),
    {next_state, shutdown, Data};

handle_event(info, {'DOWN', _MonitorRef, Type, Pid, _Info}, _State,
	     #{pfcp := #pfcp_ctx{node = Pid}} = Data)
  when Type == process; Type == pfcp ->
    delete_forward_session(upf_failure, Data),
    keep_state_and_data;

handle_event(info, _Info, _State, _Data) ->
    keep_state_and_data.

handle_pdu(ReqKey, Msg, _State, Data) ->
    ?LOG(debug, "GTP-U v1 Proxy: ~p, ~p",
		[ReqKey, gtp_c_lib:fmt_gtp(Msg)]),
    {keep_state, Data}.

handle_sx_report(#pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{erir = 1},
			      error_indication_report :=
				  #error_indication_report{
				     group =
					 #{f_teid :=
					       #f_teid{ipv4 = IP4, ipv6 = IP6} = FTEID0}}}},
		 _State, Data) ->
    FTEID = FTEID0#f_teid{ipv4 = ergw_inet:bin2ip(IP4), ipv6 = ergw_inet:bin2ip(IP6)},
    Direction = fteid_forward_context(FTEID, Data),
    initiate_pdp_context_teardown(Direction, Data),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data};

handle_sx_report(_, _State, Data) ->
    {error, 'System failure', Data}.

session_events(_Session, _Events, _State, Data) ->
    %% TODO: implement Gx/Gy/Rf support
    Data.

%%
%% resend request
%%
handle_request(ReqKey, Request, true, _State,
	       #{context := Context, proxy_context := ProxyContext})
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    keep_state_and_data;

handle_request(ReqKey, Request, true, _State,
	       #{context := Context, proxy_context := ProxyContext})
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->
    ergw_proxy_lib:forward_request(Context, ReqKey, Request),
    keep_state_and_data;

%%
%% some request type need special treatment for resends
%%
handle_request(ReqKey, #gtp{type = create_pdp_context_request} = Request, true,
	       _State, #{proxy_context := ProxyContext}) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    keep_state_and_data;
handle_request(ReqKey, #gtp{type = ms_info_change_notification_request} = Request, true,
	       _State, #{context := Context, proxy_context := ProxyContext})
  when ?IS_REQUEST_CONTEXT_OPTIONAL_TEI(ReqKey, Request, Context) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    keep_state_and_data;

handle_request(_ReqKey, _Request, true, _State, _Data) ->
    ?LOG(error, "resend of request not handled ~p, ~p",
		[_ReqKey, gtp_c_lib:fmt_gtp(_Request)]),
    keep_state_and_data;

handle_request(ReqKey,
	       #gtp{type = create_pdp_context_request,
		    ie = IEs} = Request, _Resent, _State,
	       #{context := Context0, aaa_opts := AAAopts, node_selection := NodeSelect,
		 'Session' := Session} = Data) ->

    Context1 = update_context_from_gtp_req(Request, Context0#context{state = #context_state{}}),
    Context2 = gtp_path:bind(Request, Context1),

    gtp_context:terminate_colliding_context(Context2),
    gtp_context:remote_context_register_new(Context2),

    SessionOpts0 = ggsn_gn:init_session(IEs, Context2, AAAopts),
    SessionOpts = ggsn_gn:init_session_from_gtp_req(IEs, AAAopts, SessionOpts0),

    ProxyInfo = handle_proxy_info(Request, SessionOpts, Context2, Data),

    %% GTP v1 services only, we don't do v1 to v2 conversion (yet)
    Services = [{"x-3gpp-ggsn", "x-gn"}, {"x-3gpp-ggsn", "x-gp"},
		{"x-3gpp-pgw", "x-gn"}, {"x-3gpp-pgw", "x-gp"}],
    ProxyGGSN = ergw_proxy_lib:select_gw(ProxyInfo, Services, NodeSelect, Context2),

    {ProxyGtpPort, DPCandidates} =
	ergw_proxy_lib:select_proxy_sockets(ProxyGGSN, ProxyInfo, Data),
    SxConnectId = ergw_sx_node:request_connect(DPCandidates, 1000),

    {ok, _} = ergw_aaa_session:invoke(Session, SessionOpts, start, #{async => true}),

    ProxyContext0 = init_proxy_context(ProxyGtpPort, Context2, ProxyInfo, ProxyGGSN),
    ProxyContext1 = gtp_path:bind(ProxyContext0),

    ergw_sx_node:wait_connect(SxConnectId),
    {Context, ProxyContext, PCtx} =
	ergw_proxy_lib:create_forward_session(DPCandidates, Context2, ProxyContext1),

    DataNew = Data#{context => Context, proxy_context => ProxyContext, pfcp => PCtx},
    forward_request(sgsn2ggsn, ReqKey, Request, DataNew, Data),

    {keep_state, DataNew};

handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request} = Request,
	       _Resent, _State,
	       #{context := OldContext,
		 proxy_context := OldProxyContext} = Data)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, OldContext) ->

    Context0 = update_context_from_gtp_req(Request, OldContext),
    Context1 = gtp_path:bind(Request, Context0),

    gtp_context:remote_context_update(OldContext, Context1),

    Context = update_path_bind(Context1, OldContext),

    ProxyContext1 = handle_sgsn_change(Context, OldContext, OldProxyContext#context{version = v1}),
    ProxyContext = update_path_bind(ProxyContext1, OldProxyContext),

    DataNew = Data#{context => Context, proxy_context => ProxyContext},
    forward_request(sgsn2ggsn, ReqKey, Request, DataNew, Data),

    {keep_state, DataNew};

%%
%% GGSN to SGW Update PDP Context Request
%%
handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request} = Request,
	       _Resent, _State,
	       #{context := Context0,
		 proxy_context := ProxyContext0} = Data)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext0) ->

    Context = gtp_path:bind(Context0),
    ProxyContext = gtp_path:bind(Request, ProxyContext0),

    DataNew = Data#{context => Context, proxy_context => ProxyContext},
    forward_request(ggsn2sgsn, ReqKey, Request, DataNew, Data),

    {keep_state, DataNew};

handle_request(ReqKey,
	       #gtp{type = ms_info_change_notification_request} = Request,
	       _Resent, _State,
	       #{context := Context0,
		 proxy_context := ProxyContext0} = Data)
  when ?IS_REQUEST_CONTEXT_OPTIONAL_TEI(ReqKey, Request, Context0) ->
    Context = gtp_path:bind(Request, Context0),
    ProxyContext = gtp_path:bind(ProxyContext0),

    DataNew = Data#{context => Context, proxy_context => ProxyContext},
    forward_request(sgsn2ggsn, ReqKey, Request, DataNew, Data),

    {keep_state, DataNew};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request} = Request,
	       _Resent, _State,
	       #{context := Context} = Data0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->

    forward_request(sgsn2ggsn, ReqKey, Request, Data0, Data0),

    Msg = {delete_pdp_context_request, sgsn2ggsn, ReqKey, Request},
    Data = restart_timeout(?RESPONSE_TIMEOUT, Msg, Data0),

    {keep_state, Data};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request} = Request,
	       _Resent, _State,
	       #{proxy_context := ProxyContext} = Data0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->

    forward_request(ggsn2sgsn, ReqKey, Request, Data0, Data0),

    Msg = {delete_pdp_context_request, ggsn2sgsn, ReqKey, Request},
    Data = restart_timeout(?RESPONSE_TIMEOUT, Msg, Data0),

    {keep_state, Data};

handle_request(#request{gtp_port = GtpPort} = ReqKey, Msg, _Resent, _State, _Data) ->
    ?LOG(warning, "Unknown Proxy Message on ~p: ~p", [GtpPort, Msg]),
    gtp_context:request_finished(ReqKey),
    keep_state_and_data.

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = create_pdp_context_response,
		     ie = #{?'Cause' := #cause{value = Cause}}} = Response,
		_Request, _State,
		#{context := PendingContext,
		  proxy_context := PrevProxyCtx,
		  pfcp := PCtx0} = Data) ->
    ?LOG(warning, "OK Proxy Response ~p", [Response]),

    ProxyContext1 = update_context_from_gtp_req(Response, PrevProxyCtx),
    ProxyContext = gtp_path:bind(Response, ProxyContext1),
    gtp_context:remote_context_register(ProxyContext),

    Return =
	if ?CAUSE_OK(Cause) ->
		PCtx =
		    ergw_proxy_lib:modify_forward_session(PendingContext, PendingContext,
							  PrevProxyCtx, ProxyContext, PCtx0),
		{keep_state, Data#{proxy_context => ProxyContext, pfcp => PCtx}};

	   true ->
		delete_forward_session(normal, Data),
		{next_state, shutdown, Data}
	end,

    forward_response(ProxyRequest, Response, PendingContext),
    Return;

handle_response(#proxy_request{direction = sgsn2ggsn,
			       context = PrevContext,
			       proxy_ctx = PrevProxyCtx} = ProxyRequest,
		#gtp{type = update_pdp_context_response} = Response,
		_Request, _State,
		#{context := Context,
		  proxy_context := OldProxyContext,
		  pfcp := PCtx0} = Data) ->
    ?LOG(warning, "OK Proxy Response ~p", [Response]),

    ProxyContext = update_context_from_gtp_req(Response, OldProxyContext),
    gtp_context:remote_context_update(OldProxyContext, ProxyContext),

    PCtx = ergw_proxy_lib:modify_forward_session(PrevContext, Context,
						 PrevProxyCtx, ProxyContext, PCtx0),
    forward_response(ProxyRequest, Response, Context),

    {keep_state, Data#{proxy_context => ProxyContext, pfcp => PCtx}};

handle_response(#proxy_request{direction = ggsn2sgsn} = ProxyRequest,
		#gtp{type = update_pdp_context_response} = Response,
		_Request, _State, #{proxy_context := ProxyContext}) ->
    ?LOG(warning, "OK SGSN Response ~p", [Response]),

    forward_response(ProxyRequest, Response, ProxyContext),
    keep_state_and_data;

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = ms_info_change_notification_response} = Response,
		_Request, _State, #{context := Context}) ->
    ?LOG(warning, "OK Proxy Response ~p", [Response]),

    forward_response(ProxyRequest, Response, Context),
    keep_state_and_data;

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = delete_pdp_context_response} = Response,
		_Request, _State,
		#{context := Context} = Data0) ->
    ?LOG(warning, "OK Proxy Response ~p", [Response]),

    forward_response(ProxyRequest, Response, Context),
    Data = cancel_timeout(Data0),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data};

handle_response(#proxy_request{direction = ggsn2sgsn} = ProxyRequest,
		#gtp{type = delete_pdp_context_response} = Response,
		_Request, _State,
		#{proxy_context := ProxyContext} = Data0) ->
    ?LOG(warning, "OK SGSN Response ~p", [Response]),

    forward_response(ProxyRequest, Response, ProxyContext),
    Data = cancel_timeout(Data0),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data};

handle_response(_ReqInfo, Response, _Req, _State, _Data) ->
    ?LOG(warning, "Unknown Proxy Response ~p", [Response]),
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

response(Cmd, #context{remote_control_teid = #fq_teid{teid = TEID}}, Response) ->
    {Cmd, TEID, Response}.

response(Cmd, Context, IEs0, #gtp{ie = #{?'Recovery' := Recovery}}) ->
    IEs = gtp_v1_c:build_recovery(Cmd, Context, Recovery /= undefined, IEs0),
    response(Cmd, Context, IEs).

handle_proxy_info(Request, Session, Context, #{proxy_ds := ProxyDS}) ->
    PI = proxy_info(Session, Context),
    case gtp_proxy_ds:map(ProxyDS, PI) of
	ProxyInfo when is_map(ProxyInfo) ->
	    ?LOG(debug, "OK Proxy Map: ~p", [ProxyInfo]),
	    ProxyInfo;

	{error, Cause} ->
	    Type = create_pdp_context_response,
	    Reply = response(Type, Context, [#cause{value = Cause}], Request),
	    throw(?CTX_ERR(?FATAL, Reply, Context))
    end.

delete_forward_session(Reason, #{context := Context,
				 proxy_context := ProxyContext,
				 pfcp := PCtx,
				 'Session' := Session}) ->
    URRs = ergw_proxy_lib:delete_forward_session(Reason, Context, ProxyContext, PCtx),
    SessionOpts = to_session(gtp_context:usage_report_to_accounting(URRs)),
    ?LOG(debug, "Accounting Opts: ~p", [SessionOpts]),
    ergw_aaa_session:invoke(Session, SessionOpts, stop, #{async => true}).

handle_sgsn_change(#context{remote_control_teid = NewFqTEID},
		  #context{remote_control_teid = OldFqTEID},
		  #context{control_port = CntlPort} = ProxyContext0)
  when OldFqTEID /= NewFqTEID ->
    {ok, CntlTEI} = gtp_context_reg:alloc_tei(CntlPort),
    ProxyContext = ProxyContext0#context{local_control_tei = CntlTEI},
    gtp_context:remote_context_update(ProxyContext0, ProxyContext),
    ProxyContext;
handle_sgsn_change(_, _, ProxyContext) ->
    ProxyContext.

update_path_bind(NewContext0, OldContext)
  when NewContext0 /= OldContext ->
    NewContext = gtp_path:bind(NewContext0),
    gtp_path:unbind(OldContext),
    NewContext;
update_path_bind(NewContext, _OldContext) ->
    NewContext.

init_proxy_context(CntlPort,
		   #context{imei = IMEI, context_id = ContextId, version = Version,
			    control_interface = Interface, state = CState},
		   #{imsi := IMSI, msisdn := MSISDN, apn := DstAPN}, {_GwNode, GGSN}) ->
    {APN, _OI} = ergw_node_selection:split_apn(DstAPN),
    {ok, CntlTEI} = gtp_context_reg:alloc_tei(CntlPort),
    #context{
       apn               = APN,
       imsi              = IMSI,
       imei              = IMEI,
       msisdn            = MSISDN,
       context_id        = ContextId,

       version           = Version,
       control_interface = Interface,
       control_port      = CntlPort,
       local_control_tei = CntlTEI,
       remote_control_teid =
	   #fq_teid{ip = GGSN},
       state             = CState
      }.

set_fq_teid(Id, undefined, Value) ->
    set_fq_teid(Id, #fq_teid{}, Value);
set_fq_teid(ip, TEID, Value) ->
    TEID#fq_teid{ip = ergw_inet:bin2ip(Value)};
set_fq_teid(teid, TEID, Value) ->
    TEID#fq_teid{teid = Value}.

set_fq_teid(Id, Field, Context, Value) ->
    setelement(Field, Context, set_fq_teid(Id, element(Field, Context), Value)).

get_context_from_req(_, #gsn_address{instance = 0, address = CntlIP}, Context) ->
    set_fq_teid(ip, #context.remote_control_teid, Context, CntlIP);
get_context_from_req(_, #gsn_address{instance = 1, address = DataIP}, Context) ->
    set_fq_teid(ip, #context.remote_data_teid, Context, DataIP);
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
get_context_from_req(_K, #nsapi{instance = 0, nsapi = NSAPI}, #context{state = CState} = Context) ->
    Context#context{state = CState#context_state{nsapi = NSAPI}};
get_context_from_req(_K, _, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs} = Req, Context0) ->
    Context1 = gtp_v1_c:update_context_id(Req, Context0),
    Context = #context{imsi = IMSI, apn = APN} =
	maps:fold(fun get_context_from_req/3, Context1, IEs),
    Context#context{apn = ergw_node_selection:expand_apn(APN, IMSI)}.

set_req_from_context(#context{apn = APN},
		  _K, #access_point_name{instance = 0} = IE)
  when is_list(APN) ->
    IE#access_point_name{apn = APN};
set_req_from_context(#context{imsi = IMSI},
		  _K, #international_mobile_subscriber_identity{instance = 0} = IE)
  when is_binary(IMSI) ->
    IE#international_mobile_subscriber_identity{imsi = IMSI};
set_req_from_context(#context{msisdn = MSISDN},
		  _K, #ms_international_pstn_isdn_number{instance = 0} = IE)
  when is_binary(MSISDN) ->
    IE#ms_international_pstn_isdn_number{msisdn = {isdn_address, 1, 1, 1, MSISDN}};
set_req_from_context(#context{control_port = #gtp_port{ip = CntlIP}},
		     _K, #gsn_address{instance = 0} = IE) ->
    IE#gsn_address{address = ergw_inet:ip2bin(CntlIP)};
set_req_from_context(#context{local_data_endp = #gtp_endp{ip = IP}},
		     _K, #gsn_address{instance = 1} = IE) ->
    IE#gsn_address{address = ergw_inet:ip2bin(IP)};
set_req_from_context(#context{local_data_endp = #gtp_endp{teid = TEI}},
		     _K, #tunnel_endpoint_identifier_data_i{instance = 0} = IE) ->
    IE#tunnel_endpoint_identifier_data_i{tei = TEI};
set_req_from_context(#context{local_control_tei = CntlTEI},
		     _K, #tunnel_endpoint_identifier_control_plane{instance = 0} = IE) ->
    IE#tunnel_endpoint_identifier_control_plane{tei = CntlTEI};
set_req_from_context(_, _K, IE) ->
    IE.

update_gtp_req_from_context(Context, GtpReqIEs) ->
    maps:map(set_req_from_context(Context, _, _), GtpReqIEs).

proxy_info(Session,
	   #context{apn = APN, imsi = IMSI, imei = IMEI, msisdn = MSISDN,
		    remote_control_teid = #fq_teid{ip = GsnC},
		    remote_data_teid = #fq_teid{ip = GsnU}}) ->
    Keys = [{'3GPP-RAT-Type', 'ratType'},
	    {'3GPP-User-Location-Info', 'userLocationInfo'},
	    {'RAI', rai}],
    PI = lists:foldl(
	   fun({Key, MapTo}, P) when is_map_key(Key, Session) ->
		   P#{MapTo => maps:get(Key, Session)};
	      (_, P) -> P
	   end, #{}, Keys),
    PI#{version => v1,
	imsi    => IMSI,
	imei    => IMEI,
	msisdn  => MSISDN,
	apn     => APN,
	servingGwCip => GsnC,
	servingGwUip => GsnU
     }.

build_context_request(#context{remote_control_teid = #fq_teid{teid = TEI}} = Context,
		      NewPeer, #gtp{type = Type, ie = RequestIEs} = Request) ->
    ProxyIEs0 = maps:without([?'Recovery'], RequestIEs),
    ProxyIEs1 = update_gtp_req_from_context(Context, ProxyIEs0),
    ProxyIEs = gtp_v1_c:build_recovery(Type, Context, NewPeer, ProxyIEs1),
    Request#gtp{tei = TEI, seq_no = undefined, ie = ProxyIEs}.

send_request(#context{control_port = GtpPort,
		      remote_control_teid =
			  #fq_teid{
			     ip = RemoteCntlIP,
			     teid = RemoteCntlTEI}
		     },
	     T3, N3, Type, RequestIEs) ->
    Msg = #gtp{version = v1, type = Type, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(GtpPort, RemoteCntlIP, ?GTP1c_PORT, T3, N3, Msg, undefined).

initiate_pdp_context_teardown(Direction, Data) ->
    #context{state = #context_state{nsapi = NSAPI}} =
	Ctx = forward_context(Direction, Data),
    Type = delete_pdp_context_request,
    RequestIEs0 = [#cause{value = request_accepted},
		   #teardown_ind{value = 1},
		   #nsapi{nsapi = NSAPI}],
    RequestIEs = gtp_v1_c:build_recovery(Type, Ctx, false, RequestIEs0),
    send_request(Ctx, ?T3, ?N3, Type, RequestIEs).

fteid_forward_context(#f_teid{ipv4 = IPv4, ipv6 = IPv6, teid = TEID},
		      #{proxy_context :=
			    #context{
			       remote_data_teid =
				   #fq_teid{ip = IP,
					    teid = TEID}}})
  when IP =:= IPv4; IP =:= IPv6 ->
    ggsn2sgsn;
fteid_forward_context(#f_teid{ipv4 = IPv4, ipv6 = IPv6, teid = TEID},
		      #{context :=
			    #context{
			       remote_data_teid =
				   #fq_teid{ip = IP,
					    teid = TEID}}})
  when IP =:= IPv4; IP =:= IPv6 ->
    sgsn2ggsn.

forward_context(sgsn2ggsn, #{proxy_context := Context}) ->
    Context;
forward_context(ggsn2sgsn, #{context := Context}) ->
    Context.

forward_request(Direction, ReqKey,
		#gtp{seq_no = SeqNo,
		     ie = #{?'Recovery' := Recovery}} = Request,
		Data, DataOld) ->
    Context = forward_context(Direction, Data),
    FwdReq = build_context_request(Context, false, Request),

    ergw_proxy_lib:forward_request(Direction, Context, FwdReq, ReqKey,
				   SeqNo, Recovery /= undefined, DataOld).

forward_response(#proxy_request{request = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
		 Response, Context) ->
    GtpResp = build_context_request(Context, NewPeer, Response),
    gtp_context:send_response(ReqKey, GtpResp#gtp{seq_no = SeqNo}).

cancel_timeout(#{timeout := TRef} = Data) ->
    case erlang:cancel_timer(TRef) of
        false ->
            receive {timeout, TRef, _} -> ok
            after 0 -> ok
            end;
        _ ->
            ok
    end,
    maps:remove(timeout, Data);
cancel_timeout(Data) ->
    Data.

restart_timeout(Timeout, Msg, Data) ->
    cancel_timeout(Data),
    Data#{timeout => erlang:start_timer(Timeout, self(), Msg)}.
