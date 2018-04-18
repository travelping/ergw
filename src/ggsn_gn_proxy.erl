%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn_proxy).

-behaviour(gtp_api).

-compile({parse_transform, cut}).

-export([validate_options/1, init/2, request_spec/3,
	 handle_request/4, handle_response/4,
	 handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").
-include("gtp_proxy_ds.hrl").

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
    lager:debug("GGSN Gn/Gp Options: ~p", [Opts]),
    ergw_proxy_lib:validate_options(fun validate_option/2, Opts, ?Defaults).

validate_option(Opt, Value) ->
    ergw_proxy_lib:validate_option(Opt, Value).

-record(context_state, {nsapi}).

init(#{proxy_sockets := ProxyPorts, node_selection := NodeSelect,
       proxy_data_source := ProxyDS, contexts := Contexts}, State) ->

    SessionOpts = [{'Accouting-Update-Fun', fun accounting_update/2}],
    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session(SessionOpts)),

    {ok, State#{proxy_ports => ProxyPorts,
		'Session' => Session, contexts => Contexts,
		node_selection => NodeSelect, proxy_ds => ProxyDS}}.

handle_call(query_usage_report, _From,
	    #{context := Context} = State) ->
    Reply = ergw_proxy_lib:query_usage_report(Context),
    {reply, Reply, State};

handle_call(delete_context, _From, State) ->
    lager:warning("delete_context no handled(yet)"),
    {reply, ok, State};

handle_call(terminate_context, _From, State) ->
    initiate_pdp_context_teardown(sgsn2ggsn, State),
    delete_forward_session(State),
    {stop, normal, ok, State};

handle_call({path_restart, Path}, _From,
	    #{context := #context{path = Path}} = State) ->
    initiate_pdp_context_teardown(sgsn2ggsn, State),
    delete_forward_session(State),
    {stop, normal, ok, State};

handle_call({path_restart, Path}, _From, #{proxy_context := #context{path = Path}} = State) ->
    initiate_pdp_context_teardown(ggsn2sgsn, State),
    delete_forward_session(State),
    {stop, normal, ok, State};

handle_call({path_restart, _Path}, _From, State) ->
    {reply, ok, State}.

handle_cast({packet_in, _GtpPort, _IP, _Port, _Msg}, State) ->
    lager:warning("packet_in not handled (yet): ~p", [_Msg]),
    {noreply, State}.

handle_info({ReqKey,
	     #pfcp{version = v1, type = session_report_request, seq_no = SeqNo,
		   ie = #{
		     report_type := #report_type{erir = 1},
		     error_indication_report :=
			 #error_indication_report{group = #{f_teid := FTEID0}}
		    }
		  }}, #{context := Ctx} = State) ->
    SxResponse =
	#pfcp{version = v1, type = session_report_response, seq_no = SeqNo,
	      ie = [#pfcp_cause{cause = 'Request accepted'}]},
    ergw_gsn_lib:send_sx_response(ReqKey, Ctx, SxResponse),

    FTEID = FTEID0#f_teid{ipv4 = gtp_c_lib:bin2ip(FTEID0#f_teid.ipv4),
			  ipv6 = gtp_c_lib:bin2ip(FTEID0#f_teid.ipv6)},
    Direction = fteid_forward_context(FTEID, State),
    initiate_pdp_context_teardown(Direction, State),
    delete_forward_session(State),
    {stop, normal, State};

handle_info({timeout, _, {delete_pdp_context_request, Direction, _ReqKey, _Request}}, State) ->
    lager:warning("Proxy Delete PDP Context Timeout ~p", [Direction]),

    delete_forward_session(State),
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%
%% resend request
%%
handle_request(ReqKey, Request, true,
	       #{context := Context, proxy_context := ProxyContext} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    {noreply, State};
handle_request(ReqKey, Request, true,
	       #{context := Context, proxy_context := ProxyContext} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->
    ergw_proxy_lib:forward_request(Context, ReqKey, Request),
    {noreply, State};

%%
%% some request type need special treatment for resends
%%
handle_request(ReqKey, #gtp{type = create_pdp_context_request} = Request, true,
	       #{proxy_context := ProxyContext} = State) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    {noreply, State};
handle_request(ReqKey, #gtp{type = ms_info_change_notification_request} = Request, true,
	       #{context := Context, proxy_context := ProxyContext} = State)
  when ?IS_REQUEST_CONTEXT_OPTIONAL_TEI(ReqKey, Request, Context) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    {noreply, State};

handle_request(_ReqKey, _Request, true, State) ->
    lager:error("resend of request not handled ~p, ~p",
		[lager:pr(_ReqKey, ?MODULE), gtp_c_lib:fmt_gtp(_Request)]),
    {noreply, State};

handle_request(ReqKey,
	       #gtp{type = create_pdp_context_request,
		    ie = IEs} = Request, _Resent,
	       #{context := Context0, aaa_opts := AAAopts,
		 'Session' := Session} = State) ->

    Context1 = update_context_from_gtp_req(Request, Context0#context{state = #context_state{}}),
    ContextPreProxy = gtp_path:bind(Request, Context1),

    gtp_context:terminate_colliding_context(ContextPreProxy),
    gtp_context:remote_context_register_new(ContextPreProxy),

    ProxyInfo = handle_proxy_info(Request, ContextPreProxy, State),
    #proxy_ggsn{restrictions = Restrictions} = ProxyGGSN0 = gtp_proxy_ds:lb(ProxyInfo),

    %% GTP v1 services only, we don't do v1 to v2 conversion (yet)
    Services = [{"x-3gpp-ggsn", "x-gn"}, {"x-3gpp-ggsn", "x-gp"},
		{"x-3gpp-pgw", "x-gn"}, {"x-3gpp-pgw", "x-gp"}],
    ProxyGGSN = ergw_proxy_lib:select_proxy_gsn(ProxyInfo, ProxyGGSN0, Services, State),

    Context = ContextPreProxy#context{restrictions = Restrictions},
    gtp_context:enforce_restrictions(Request, Context),

    {ProxyGtpPort, DPCandidates} = ergw_proxy_lib:select_proxy_sockets(ProxyGGSN, State),

    SessionOpts0 = ggsn_gn:init_session(IEs, Context, AAAopts),
    SessionOpts = ggsn_gn:init_session_from_gtp_req(IEs, AAAopts, SessionOpts0),
    ergw_aaa_session:start(Session, SessionOpts),

    ProxyContext0 = init_proxy_context(ProxyGtpPort, Context, ProxyInfo, ProxyGGSN),
    ProxyContext1 = gtp_path:bind(ProxyContext0),

    {ContextNew, ProxyContext} =
	ergw_proxy_lib:create_forward_session(DPCandidates, Context, ProxyContext1),

    StateNew = State#{context => ContextNew, proxy_context => ProxyContext},
    forward_request(sgsn2ggsn, ReqKey, Request, StateNew, State),

    {noreply, StateNew};

handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request} = Request, _Resent,
	       #{context := OldContext,
		 proxy_context := OldProxyContext} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, OldContext) ->

    Context0 = update_context_from_gtp_req(Request, OldContext),
    Context1 = gtp_path:bind(Request, Context0),

    gtp_context:enforce_restrictions(Request, Context1),
    gtp_context:remote_context_update(OldContext, Context1),

    Context = update_path_bind(Context1, OldContext),
    ProxyContext = update_path_bind(OldProxyContext#context{version = v1}, OldProxyContext),

    StateNew = State#{context => Context, proxy_context => ProxyContext},
    forward_request(sgsn2ggsn, ReqKey, Request, StateNew, State),

    {noreply, StateNew};

%%
%% GGSN to SGW Update PDP Context Request
%%
handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request} = Request, _Resent,
	       #{context := Context0,
		 proxy_context := ProxyContext0} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext0) ->

    Context = gtp_path:bind(Context0),
    ProxyContext = gtp_path:bind(Request, ProxyContext0),

    StateNew = State#{context => Context, proxy_context => ProxyContext},
    forward_request(ggsn2sgsn, ReqKey, Request, StateNew, State),

    {noreply, StateNew};

handle_request(ReqKey,
	       #gtp{type = ms_info_change_notification_request} = Request,
	       _Resent,
	       #{context := Context0,
		 proxy_context := ProxyContext0} = State)
  when ?IS_REQUEST_CONTEXT_OPTIONAL_TEI(ReqKey, Request, Context0) ->
    Context = gtp_path:bind(Request, Context0),
    ProxyContext = gtp_path:bind(ProxyContext0),

    StateNew = State#{context => Context, proxy_context => ProxyContext},
    forward_request(sgsn2ggsn, ReqKey, Request, StateNew, State),

    {noreply, StateNew};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request} = Request, _Resent,
	       #{context := Context} = State0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->

    forward_request(sgsn2ggsn, ReqKey, Request, State0, State0),

    Msg = {delete_pdp_context_request, sgsn2ggsn, ReqKey, Request},
    State = restart_timeout(?RESPONSE_TIMEOUT, Msg, State0),

    {noreply, State};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request} = Request, _Resent,
	       #{proxy_context := ProxyContext} = State0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->

    forward_request(ggsn2sgsn, ReqKey, Request, State0, State0),

    Msg = {delete_pdp_context_request, ggsn2sgsn, ReqKey, Request},
    State = restart_timeout(?RESPONSE_TIMEOUT, Msg, State0),

    {noreply, State};

handle_request(#request{gtp_port = GtpPort} = ReqKey, Msg, _Resent, State) ->
    lager:warning("Unknown Proxy Message on ~p: ~p", [GtpPort, lager:pr(Msg, ?MODULE)]),
    gtp_context:request_finished(ReqKey),
    {noreply, State}.

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = create_pdp_context_response,
		     ie = #{?'Cause' := #cause{value = Cause}}} = Response, _Request,
		#{context := Context,
		  proxy_context := PrevProxyCtx} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext1 = update_context_from_gtp_req(Response, PrevProxyCtx),
    ProxyContext = gtp_path:bind(Response, ProxyContext1),
    gtp_context:remote_context_register(ProxyContext),

    forward_response(ProxyRequest, Response, Context),

    if ?CAUSE_OK(Cause) ->
	    ergw_proxy_lib:modify_forward_session(Context, Context, PrevProxyCtx, ProxyContext),
	    {noreply, State#{proxy_context => ProxyContext}};

       true ->
	    {stop, State}
    end;

handle_response(#proxy_request{direction = sgsn2ggsn,
			       context = PrevContext,
			       proxy_ctx = PrevProxyCtx} = ProxyRequest,
		#gtp{type = update_pdp_context_response} = Response, _Request,
		#{context := Context,
		  proxy_context := OldProxyContext} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext = update_context_from_gtp_req(Response, OldProxyContext),
    gtp_context:remote_context_update(OldProxyContext, ProxyContext),

    forward_response(ProxyRequest, Response, Context),
    ergw_proxy_lib:modify_forward_session(PrevContext, Context, PrevProxyCtx, ProxyContext),

    {noreply, State#{proxy_context => ProxyContext}};

handle_response(#proxy_request{direction = ggsn2sgsn} = ProxyRequest,
		#gtp{type = update_pdp_context_response} = Response, _Request,
		#{proxy_context := ProxyContext} = State) ->
    lager:warning("OK SGSN Response ~p", [lager:pr(Response, ?MODULE)]),

    forward_response(ProxyRequest, Response, ProxyContext),
    {noreply, State};

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = ms_info_change_notification_response} = Response, _Request,
		#{context := Context} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    forward_response(ProxyRequest, Response, Context),
    {noreply, State};

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = delete_pdp_context_response} = Response, _Request,
		#{context := Context} = State0) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    forward_response(ProxyRequest, Response, Context),
    State = cancel_timeout(State0),
    delete_forward_session(State),
    {stop, State};


handle_response(#proxy_request{direction = ggsn2sgsn} = ProxyRequest,
		#gtp{type = delete_pdp_context_response} = Response, _Request,
		#{proxy_context := ProxyContext} = State0) ->
    lager:warning("OK SGSN Response ~p", [lager:pr(Response, ?MODULE)]),

    forward_response(ProxyRequest, Response, ProxyContext),
    State = cancel_timeout(State0),
    delete_forward_session(State),
    {stop, State};


handle_response(_ReqInfo, Response, _Req, State) ->
    lager:warning("Unknown Proxy Response ~p", [lager:pr(Response, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_proxy_info(#gtp{ie = #{?'Recovery' := Recovery}},
		  Context, #{proxy_ds := ProxyDS}) ->
    ProxyInfo0 = proxy_info(Context),
    case ProxyDS:map(ProxyInfo0) of
	{ok, #proxy_info{} = ProxyInfo} ->
	    lager:debug("OK Proxy Map: ~p", [lager:pr(ProxyInfo, ?MODULE)]),
	    ProxyInfo;

	Other ->
	    lager:warning("Failed Proxy Map: ~p", [Other]),

	    ResponseIEs0 = [#cause{value = user_authentication_failed}],
	    ResponseIEs = gtp_v1_c:build_recovery(Context, Recovery /= undefined, ResponseIEs0),
	    throw(?CTX_ERR(?FATAL,
			   {create_pdp_context_response,
			    Context#context.remote_control_tei,
			    ResponseIEs}, Context))
    end.

usage_report_to_accounting(
  #{volume_measurement :=
	#volume_measurement{uplink = RcvdBytes, downlink = SendBytes},
    tp_packet_measurement :=
	#tp_packet_measurement{uplink = RcvdPkts, downlink = SendPkts}}) ->
    [{'InPackets',  RcvdPkts},
     {'OutPackets', SendPkts},
     {'InOctets',   RcvdBytes},
     {'OutOctets',  SendBytes}];
usage_report_to_accounting(
  #{volume_measurement :=
	#volume_measurement{uplink = RcvdBytes, downlink = SendBytes}}) ->
    [{'InOctets',   RcvdBytes},
     {'OutOctets',  SendBytes}];
usage_report_to_accounting(#usage_report_smr{group = UR}) ->
    usage_report_to_accounting(UR);
usage_report_to_accounting(#usage_report_sdr{group = UR}) ->
    usage_report_to_accounting(UR);
usage_report_to_accounting(#usage_report_srr{group = UR}) ->
    usage_report_to_accounting(UR);
usage_report_to_accounting([H|_]) ->
    usage_report_to_accounting(H);
usage_report_to_accounting(undefined) ->
    [].

accounting_update(GTP, SessionOpts) ->
    case gen_server:call(GTP, query_usage_report) of
	#pfcp{type = session_modification_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} = IEs} ->
	    Acc = to_session(usage_report_to_accounting(
			       maps:get(usage_report_smr, IEs, undefined))),
	    ergw_aaa_session:merge(SessionOpts, Acc);
	_Other ->
	    lager:warning("Gn/Gp proxy: got unexpected Query response: ~p",
			  [lager:pr(_Other, ?MODULE)]),
	    to_session([])
    end.

delete_forward_session(#{context := Context, proxy_context := ProxyContext,
			 'Session' := Session}) ->
    SessionOpts =
	case ergw_proxy_lib:delete_forward_session(Context, ProxyContext) of
	    #pfcp{type = session_deletion_response,
		  ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} = IEs} ->
		to_session(usage_report_to_accounting(
			     maps:get(usage_report_sdr, IEs, undefined)));
	    _Other ->
		lager:warning("Gn/Gp proxy: Session Deletion failed with ~p",
			      [lager:pr(_Other, ?MODULE)]),
		to_session([])
	end,
    lager:debug("Accounting Opts: ~p", [SessionOpts]),
    ergw_aaa_session:stop(Session, SessionOpts).

update_path_bind(NewContext0, OldContext)
  when NewContext0 /= OldContext ->
    NewContext = gtp_path:bind(NewContext0),
    gtp_path:unbind(OldContext),
    NewContext;
update_path_bind(NewContext, _OldContext) ->
    NewContext.

init_proxy_context(CntlPort,
		   #context{imei = IMEI, context_id = ContextId, version = Version,
			    control_interface = Interface, state = State},
		   #proxy_info{imsi = IMSI, msisdn = MSISDN},
		   #proxy_ggsn{address = GGSN, dst_apn = APN}) ->

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
       remote_control_ip = GGSN,
       state             = State
      }.

get_context_from_req(_K, #gsn_address{instance = 0, address = CntlIP}, Context) ->
    Context#context{remote_control_ip = gtp_c_lib:bin2ip(CntlIP)};
get_context_from_req(_K, #gsn_address{instance = 1, address = DataIP}, Context) ->
    Context#context{remote_data_ip = gtp_c_lib:bin2ip(DataIP)};
get_context_from_req(_K, #tunnel_endpoint_identifier_data_i{instance = 0, tei = DataTEI}, Context) ->
    Context#context{remote_data_tei = DataTEI};
get_context_from_req(_K, #tunnel_endpoint_identifier_control_plane{instance = 0, tei = CntlTEI}, Context) ->
    Context#context{remote_control_tei = CntlTEI};
get_context_from_req(?'Access Point Name', #access_point_name{apn = APN}, Context) ->
    Context#context{apn = APN};
get_context_from_req(?'IMSI', #international_mobile_subscriber_identity{imsi = IMSI}, Context) ->
    Context#context{imsi = IMSI};
get_context_from_req(?'IMEI', #imei{imei = IMEI}, Context) ->
    Context#context{imei = IMEI};
get_context_from_req(?'MSISDN', #ms_international_pstn_isdn_number{
				   msisdn = {isdn_address, _, _, 1, MSISDN}}, Context) ->
    Context#context{msisdn = MSISDN};
get_context_from_req(_K, #nsapi{instance = 0, nsapi = NSAPI}, #context{state = State} = Context) ->
    Context#context{state = State#context_state{nsapi = NSAPI}};
get_context_from_req(_K, _, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs} = Req, Context0) ->
    Context1 = gtp_v1_c:update_context_id(Req, Context0),
    maps:fold(fun get_context_from_req/3, Context1, IEs).

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
    IE#gsn_address{address = gtp_c_lib:ip2bin(CntlIP)};
set_req_from_context(#context{data_port = #gtp_port{ip = DataIP}},
		     _K, #gsn_address{instance = 1} = IE) ->
    IE#gsn_address{address = gtp_c_lib:ip2bin(DataIP)};
set_req_from_context(#context{local_data_tei = DataTEI},
		     _K, #tunnel_endpoint_identifier_data_i{instance = 0} = IE) ->
    IE#tunnel_endpoint_identifier_data_i{tei = DataTEI};
set_req_from_context(#context{local_control_tei = CntlTEI},
		     _K, #tunnel_endpoint_identifier_control_plane{instance = 0} = IE) ->
    IE#tunnel_endpoint_identifier_control_plane{tei = CntlTEI};
set_req_from_context(_, _K, IE) ->
    IE.

update_gtp_req_from_context(Context, GtpReqIEs) ->
    maps:map(set_req_from_context(Context, _, _), GtpReqIEs).

proxy_info(#context{apn = APN, imsi = IMSI, msisdn = MSISDN, restrictions = Restrictions}) ->
    GGSNs = [#proxy_ggsn{dst_apn = APN, restrictions = Restrictions}],
    LookupAPN = (catch gtp_c_lib:normalize_labels(APN)),
    #proxy_info{ggsns = GGSNs, imsi = IMSI, msisdn = MSISDN, src_apn = LookupAPN}.

build_context_request(#context{remote_control_tei = TEI} = Context,
		      NewPeer, #gtp{ie = RequestIEs} = Request) ->
    ProxyIEs0 = maps:without([?'Recovery'], RequestIEs),
    ProxyIEs1 = update_gtp_req_from_context(Context, ProxyIEs0),
    ProxyIEs = gtp_v1_c:build_recovery(Context, NewPeer, ProxyIEs1),
    Request#gtp{tei = TEI, seq_no = undefined, ie = ProxyIEs}.

send_request(#context{control_port = GtpPort,
		      remote_control_tei = RemoteCntlTEI,
		      remote_control_ip = RemoteCntlIP},
	     T3, N3, Type, RequestIEs) ->
    Msg = #gtp{version = v1, type = Type, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(GtpPort, RemoteCntlIP, ?GTP1c_PORT, T3, N3, Msg, undefined).

initiate_pdp_context_teardown(Direction, State) ->
    #context{state = #context_state{nsapi = NSAPI}} =
	Ctx = forward_context(Direction, State),
    RequestIEs0 = [#cause{value = request_accepted},
		   #teardown_ind{value = 1},
		   #nsapi{nsapi = NSAPI}],
    RequestIEs = gtp_v1_c:build_recovery(Ctx, false, RequestIEs0),
    send_request(Ctx, ?T3, ?N3, delete_pdp_context_request, RequestIEs).

fteid_forward_context(#f_teid{ipv4 = IPv4, ipv6 = IPv6, teid = TEID},
		      #{proxy_context := #context{remote_data_ip = IP,
						  remote_data_tei = TEID}})
  when IP =:= IPv4; IP =:= IPv6 ->
    ggsn2sgsn;
fteid_forward_context(#f_teid{ipv4 = IPv4, ipv6 = IPv6, teid = TEID},
		      #{context := #context{remote_data_ip = IP,
					    remote_data_tei = TEID}})
  when IP =:= IPv4; IP =:= IPv6 ->
    sgsn2ggsn.

forward_context(sgsn2ggsn, #{proxy_context := Context}) ->
    Context;
forward_context(ggsn2sgsn, #{context := Context}) ->
    Context.

forward_request(Direction, ReqKey,
		#gtp{seq_no = SeqNo,
		     ie = #{?'Recovery' := Recovery}} = Request,
		State, StateOld) ->
    Context = forward_context(Direction, State),
    FwdReq = build_context_request(Context, false, Request),

    ergw_proxy_lib:forward_request(Direction, Context, FwdReq, ReqKey,
				   SeqNo, Recovery /= undefined, StateOld).

forward_response(#proxy_request{request = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
		 Response, Context) ->
    GtpResp = build_context_request(Context, NewPeer, Response),
    gtp_context:send_response(ReqKey, GtpResp#gtp{seq_no = SeqNo}).

cancel_timeout(#{timeout := TRef} = State) ->
    case erlang:cancel_timer(TRef) of
        false ->
            receive {timeout, TRef, _} -> ok
            after 0 -> ok
            end;
        _ ->
            ok
    end,
    maps:remove(timeout, State);
cancel_timeout(State) ->
    State.

restart_timeout(Timeout, Msg, State) ->
    cancel_timeout(State),
    State#{timeout => erlang:start_timer(Timeout, self(), Msg)}.
