%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8_proxy).

-behaviour(gtp_api).

-compile({parse_transform, cut}).
-compile({parse_transform, do}).

-export([validate_options/1, init/2, request_spec/3,
	 handle_pdu/4, handle_sx_report/3, session_events/4,
	 handle_request/5, handle_response/5,
	 handle_event/4, terminate/3]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define(GTP_v1_Interface, ggsn_gn_proxy).
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

%====================================================================
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
-define('Bearer Contexts',				{v2_bearer_context, 0}).
-define('Protocol Configuration Options',		{v2_protocol_configuration_options, 0}).
-define('ME Identity',					{v2_mobile_equipment_identity, 0}).
-define('AMBR',						{v2_aggregate_maximum_bit_rate, 0}).

-define('EPS Bearer ID',                                {v2_eps_bearer_id, 0}).

-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).

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
    [{?'RAT Type',					mandatory},
     {?'Sender F-TEID for Control Plane',		mandatory},
     {?'Access Point Name',				mandatory},
     {?'Bearer Contexts',				mandatory}];
request_spec(v2, create_session_response, _) ->
    [{?'Cause',						mandatory},
     {?'Bearer Contexts',				mandatory}];
request_spec(v2, modify_bearer_request, _) ->
    [];
request_spec(v2, modify_bearer_response, _) ->
    [{?'Cause',						mandatory}];
request_spec(v2, modify_bearer_command, _) ->
    [];
request_spec(v2, delete_session_request, _) ->
    [];
request_spec(v2, delete_session_response, _) ->
    [{?'Cause',						mandatory}];
request_spec(v2, update_bearer_request, _) ->
    [{?'Bearer Contexts',				mandatory},
     {?'AMBR',						mandatory}];
request_spec(v2, update_bearer_response, _) ->
    [{?'Cause',						mandatory},
     {?'Bearer Contexts',				mandatory}];
request_spec(v2, delete_bearer_request, _) ->
    [];
request_spec(v2, delete_bearer_response, _) ->
    [{?'Cause',						mandatory}];
request_spec(v2, suspend_notification, _) ->
    [];
request_spec(v2, suspend_acknowledge, _) ->
    [{?'Cause',						mandatory}];
request_spec(v2, resume_notification, _) ->
    [{?'IMSI',						mandatory}];
request_spec(v2, resume_acknowledge, _) ->
    [{?'Cause',						mandatory}];
request_spec(v2, _, _) ->
    [].

-define(Defaults, []).

validate_options(Opts) ->
    ?LOG(debug, "PGW S5/S8 Options: ~p", [Opts]),
    ergw_proxy_lib:validate_options(fun validate_option/2, Opts, ?Defaults).

validate_option(Opt, Value) ->
    ergw_proxy_lib:validate_option(Opt, Value).

-record(context_state, {ebi}).

init(#{proxy_sockets := ProxyPorts, node_selection := NodeSelect,
       proxy_data_source := ProxyDS, contexts := Contexts}, Data) ->

    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),

    {ok, run, Data#{proxy_ports => ProxyPorts,
		    'Version' => v2, 'Session' => Session, contexts => Contexts,
		    node_selection => NodeSelect, proxy_ds => ProxyDS}}.

handle_event(Type, Content, State, #{'Version' := v1} = Data) ->
    ?GTP_v1_Interface:handle_event(Type, Content, State, Data);

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event({call, From}, delete_context, _State, _Data) ->
    ?LOG(warning, "delete_context no handled(yet)"),
    {keep_state_and_data, [{reply, From, ok}]};

handle_event({call, From}, terminate_context, _State, Data) ->
    initiate_session_teardown(sgw2pgw, Data),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, Path}, _State,
	     #{context := #context{path = Path}} = Data) ->
    initiate_session_teardown(sgw2pgw, Data),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, Path}, _State,
	     #{proxy_context := #context{path = Path}} = Data) ->
    initiate_session_teardown(pgw2sgw, Data),
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

handle_event(info, {timeout, _, {delete_session_request, Direction, _ReqKey, _Request}},
	     _State, Data) ->
    ?LOG(warning, "Proxy Delete Session Timeout ~p", [Direction]),

    delete_forward_session(normal, Data),
    {next_state, shutdown, Data};

handle_event(info, {timeout, _, {delete_bearer_request, Direction, _ReqKey, _Request}},
	     _State, Data) ->
    ?LOG(warning, "Proxy Delete Bearer Timeout ~p", [Direction]),

    delete_forward_session(normal, Data),
    {next_state, shutdown, Data};

handle_event(info, {'DOWN', _MonitorRef, Type, Pid, _Info}, _State,
	     #{pfcp := #pfcp_ctx{node = Pid}} = Data)
  when Type == process; Type == pfcp ->
    initiate_session_teardown(sgw2pgw, Data),
    initiate_session_teardown(pgw2sgw, Data),
    delete_forward_session(upf_failure, Data),
    {next_state, shutdown, Data};

handle_event(info, _Info, _State, _Data) ->
    keep_state_and_data.

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

handle_pdu(ReqKey, Msg, _State, Data) ->
    ?LOG(debug, "GTP-U v2 Proxy: ~p, ~p",
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
    initiate_session_teardown(Direction, Data),
    delete_forward_session(normal, Data),
    {shutdown, Data};

handle_sx_report(_, _State, Data) ->
    {error, 'System failure', Data}.

session_events(_Session, _Events, _State, Data) ->
    %% TODO: implement Gx/Gy/Rf support
    Data.

handle_request(ReqKey, #gtp{version = v1} = Msg, Resent, State, Data) ->
    ?GTP_v1_Interface:handle_request(ReqKey, Msg, Resent, State, Data#{'Version' => v1});
handle_request(ReqKey, #gtp{version = v2} = Msg, Resent, State, #{'Version' := v1} = Data) ->
    handle_request(ReqKey, Msg, Resent, State, Data#{'Version' => v2});

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
handle_request(ReqKey, #gtp{type = create_session_request} = Request, true,
	       _State, #{proxy_context := ProxyContext}) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    keep_state_and_data;
handle_request(ReqKey, #gtp{type = change_notification_request} = Request, true,
	       _State, #{context := Context, proxy_context := ProxyContext})
  when ?IS_REQUEST_CONTEXT_OPTIONAL_TEI(ReqKey, Request, Context) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    keep_state_and_data;

handle_request(_ReqKey, _Request, true, _State, _Data) ->
    ?LOG(error, "resend of request not handled ~p, ~p",
		[_ReqKey, gtp_c_lib:fmt_gtp(_Request)]),
    keep_state_and_data;

handle_request(ReqKey,
	       #gtp{type = create_session_request, ie = IEs} = Request,
	       _Resent, _State,
	       #{context := Context0, aaa_opts := AAAopts, node_selection := NodeSelect,
		 'Session' := Session} = Data) ->

    Context1 = update_context_from_gtp_req(Request, Context0#context{state = #context_state{}}),
    Context2 = gtp_path:bind(Request, false, Context1),

    gtp_context:terminate_colliding_context(Context2),
    gtp_context:remote_context_register_new(Context2),

    SessionOpts0 = pgw_s5s8:init_session(IEs, Context2, AAAopts),
    SessionOpts = pgw_s5s8:init_session_from_gtp_req(IEs, AAAopts, Context2, SessionOpts0),

    ProxyInfo = handle_proxy_info(Request, SessionOpts, Context2, Data),
    ProxyGtpPort = ergw_proxy_lib:select_gtp_proxy_sockets(ProxyInfo, Data),

    %% GTP v2 services only, we don't do v1 to v2 conversion (yet)
    Services = [{"x-3gpp-pgw", "x-s8-gtp"}, {"x-3gpp-pgw", "x-s5-gtp"}],
    ProxyGGSN = ergw_proxy_lib:select_gw(ProxyInfo, Services, NodeSelect, ProxyGtpPort, Context2),

    DPCandidates = ergw_proxy_lib:select_sx_proxy_candidate(ProxyGGSN, ProxyInfo, Data),

    SxConnectId = ergw_sx_node:request_connect(DPCandidates, NodeSelect, 1000),

    {ok, _} = ergw_aaa_session:invoke(Session, SessionOpts, start, #{async =>true}),

    ProxyContext0 = init_proxy_context(ProxyGtpPort, Context2, ProxyInfo, ProxyGGSN),
    ProxyContext1 = gtp_path:bind(true, ProxyContext0),

    ergw_sx_node:wait_connect(SxConnectId),
    {Context, ProxyContext, PCtx} =
	ergw_proxy_lib:create_forward_session(DPCandidates, Context2, ProxyContext1),

    DataNew = Data#{context => Context, proxy_context => ProxyContext, pfcp => PCtx},
    forward_request(sgw2pgw, ReqKey, Request, DataNew, Data),

    {keep_state, DataNew};

handle_request(ReqKey,
	       #gtp{type = modify_bearer_request} = Request,
	       _Resent, _State,
	       #{context := OldContext,
		 proxy_context := OldProxyContext} = Data)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, OldContext) ->

    Context0 = update_context_from_gtp_req(Request, OldContext),
    Context1 = gtp_path:bind(Request, false, Context0),

    gtp_context:remote_context_update(OldContext, Context1),

    Context = update_path_bind(Context1, OldContext),

    ProxyContext1 = handle_sgw_change(Context, OldContext, OldProxyContext#context{version = v2}),
    ProxyContext = update_path_bind(ProxyContext1, OldProxyContext),

    DataNew = Data#{context => Context, proxy_context => ProxyContext},
    forward_request(sgw2pgw, ReqKey, Request, DataNew, Data),

    {keep_state, DataNew};

handle_request(ReqKey,
	       #gtp{type = modify_bearer_command} = Request,
	       _Resent, _State,
	       #{context := Context} = Data0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->

    Data1 = bind_forward_path(sgw2pgw, Request, Data0),
    forward_request(sgw2pgw, ReqKey, Request, Data1, Data0),

    Data = trigger_request(sgw2pgw, ReqKey, Request, Data1),
    {keep_state, Data};

%%
%% SGW to PGW requests without tunnel endpoint modification
%%
handle_request(ReqKey,
	       #gtp{type = change_notification_request} = Request,
	       _Resent, _State,
	       #{context := Context} = Data)
  when ?IS_REQUEST_CONTEXT_OPTIONAL_TEI(ReqKey, Request, Context) ->

    DataNew = bind_forward_path(sgw2pgw, Request, Data),
    forward_request(sgw2pgw, ReqKey, Request, DataNew, Data),

    {keep_state, DataNew};

%%
%% SGW to PGW notifications without tunnel endpoint modification
%%
handle_request(ReqKey,
	       #gtp{type = Type} = Request,
	       _Resent, _State,
	       #{context := Context} = Data)
  when (Type == suspend_notification orelse
	Type == resume_notification) andalso
       ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->

    DataNew = bind_forward_path(sgw2pgw, Request, Data),
    forward_request(sgw2pgw, ReqKey, Request, DataNew, Data),

    {keep_state, DataNew};

%%
%% PGW to SGW requests without tunnel endpoint modification
%%
handle_request(ReqKey,
	       #gtp{type = update_bearer_request} = Request,
	       _Resent, _State,
	       #{proxy_context := ProxyContext} = Data0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->

    Data = bind_forward_path(pgw2sgw, Request, Data0),
    forward_request(pgw2sgw, ReqKey, Request, Data, Data),
    {keep_state, Data};

%%
%% SGW to PGW delete session requests
%%
handle_request(ReqKey,
	       #gtp{type = delete_session_request} = Request,
	       _Resent, _State,
	       #{context := Context} = Data0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->

    forward_request(sgw2pgw, ReqKey, Request, Data0, Data0),

    Msg = {delete_session_request, sgw2pgw, ReqKey, Request},
    Data = restart_timeout(?RESPONSE_TIMEOUT, Msg, Data0),

    {keep_state, Data};

%%
%% PGW to SGW delete bearer requests
%%
handle_request(ReqKey,
	       #gtp{type = delete_bearer_request} = Request,
	       _Resent, _State,
	       #{proxy_context := ProxyContext} = Data0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->

    forward_request(pgw2sgw, ReqKey, Request, Data0, Data0),

    Msg = {delete_bearer_request, pgw2sgw, ReqKey, Request},
    Data = restart_timeout(?RESPONSE_TIMEOUT, Msg, Data0),

    {keep_state, Data};

handle_request(ReqKey, _Request, _Resent, _State, _Data) ->
    gtp_context:request_finished(ReqKey),
    keep_state_and_data.

handle_response(ReqInfo, #gtp{version = v1} = Msg, Request, State, Data) ->
    ?GTP_v1_Interface:handle_response(ReqInfo, Msg, Request, State, Data);

handle_response(_, _Response, _Request, shutdown, _Data) ->
    keep_state_and_data;

handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		#gtp{type = create_session_response,
		     ie = #{?'Cause' := #v2_cause{v2_cause = Cause}}} = Response,
		_Request, _State,
		#{context := Context,
		  proxy_context := PrevProxyCtx,
		  pfcp := PCtx0} = Data) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    ProxyContext1 = update_context_from_gtp_req(Response, PrevProxyCtx),
    ProxyContext = gtp_path:bind(Response, true, ProxyContext1),
    gtp_context:remote_context_register(ProxyContext),

    Return =
	if ?CAUSE_OK(Cause) ->
		PCtx =
		    ergw_proxy_lib:modify_forward_session(Context, Context,
							  PrevProxyCtx, ProxyContext, PCtx0),
		{keep_state, Data#{proxy_context => ProxyContext, pfcp => PCtx}};
	   true ->
		delete_forward_session(normal, Data),
		{next_state, shutdown, Data}
	end,

    forward_response(ProxyRequest, Response, Context),
    Return;

handle_response(#proxy_request{direction = sgw2pgw,
			       context = PrevContext,
			       proxy_ctx = PrevProxyCtx} = ProxyRequest,
		#gtp{type = modify_bearer_response} = Response,
		_Request, _State,
		#{context := Context,
		  proxy_context := OldProxyContext,
		  pfcp := PCtx0} = Data) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    ProxyContext = update_context_from_gtp_req(Response, OldProxyContext),
    gtp_context:remote_context_update(OldProxyContext, ProxyContext),

    PCtx = ergw_proxy_lib:modify_forward_session(PrevContext, Context,
						 PrevProxyCtx, ProxyContext, PCtx0),
    forward_response(ProxyRequest, Response, Context),

    {keep_state, Data#{proxy_context => ProxyContext, pfcp => PCtx}};

%%
%% PGW to SGW response without tunnel endpoint modification
%%
handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		#gtp{type = change_notification_response} = Response,
		_Request, _State, #{context := Context}) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    forward_response(ProxyRequest, Response, Context),
    keep_state_and_data;

%%
%% PGW to SGW acknowledge without tunnel endpoint modification
%%
handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		#gtp{type = Type} = Response,
		_Request, _State, #{context := Context})
  when Type == suspend_acknowledge;
       Type == resume_acknowledge ->
    ?LOG(debug, "OK Proxy Acknowledge ~p", [Response]),

    forward_response(ProxyRequest, Response, Context),
    keep_state_and_data;

%%
%% SGW to PGW response without tunnel endpoint modification
%%
handle_response(#proxy_request{direction = pgw2sgw} = ProxyRequest,
		#gtp{type = update_bearer_response} = Response,
		_Request, _State,
		#{proxy_context := ProxyContext} = Data) ->
    ?LOG(debug, "OK Response ~p", [Response]),

    forward_response(ProxyRequest, Response, ProxyContext),
    trigger_request_finished(Response, Data),

    keep_state_and_data;

handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		Response0, #gtp{type = delete_session_request}, _State,
		#{context := Context} = Data) ->
    ?LOG(debug, "Proxy Response ~p", [Response0]),

    Response =
	if is_record(Response0, gtp) ->
		Response0;
	   true ->
		#gtp{version = v2,
		     type = delete_session_response,
		     ie = #{?'Cause' => #v2_cause{v2_cause = request_accepted}}}
	end,
    forward_response(ProxyRequest, Response, Context),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data};

%%
%% SGW to PGW delete bearer response
%%
handle_response(#proxy_request{direction = pgw2sgw} = ProxyRequest,
		Response0, #gtp{type = delete_bearer_request}, _State,
		#{proxy_context := ProxyContext} = Data) ->
    ?LOG(debug, "Proxy Response ~p", [Response0]),

    Response =
	if is_record(Response0, gtp) ->
		Response0;
	   true ->
		#context{state = #context_state{ebi = EBI}} = ProxyContext,
		#gtp{version = v2,
		     type = delete_bearer_response,
		     ie = #{?'Cause' => #v2_cause{v2_cause = request_accepted},
			    ?'EPS Bearer ID' =>
				#v2_eps_bearer_id{eps_bearer_id = EBI}}}
	end,
    forward_response(ProxyRequest, Response, ProxyContext),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data};

handle_response(#proxy_request{request = ReqKey} = _ReqInfo,
		Response, _Request, _State, _Data) ->
    ?LOG(warning, "Unknown Proxy Response ~p", [Response]),

    gtp_context:request_finished(ReqKey),
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.

%%%===================================================================
%%% Helper functions
%%%===================================================================

response(Cmd, #context{remote_control_teid = #fq_teid{teid = TEID}}, Response) ->
    {Cmd, TEID, Response}.

response(Cmd, Context, IEs0, #gtp{ie = ReqIEs}) ->
    IEs = gtp_v2_c:build_recovery(Cmd, Context, is_map_key(?'Recovery', ReqIEs), IEs0),
    response(Cmd, Context, IEs).

handle_proxy_info(Request, Session, Context, #{proxy_ds := ProxyDS}) ->
    PI = proxy_info(Session, Context),
    case gtp_proxy_ds:map(ProxyDS, PI) of
	ProxyInfo when is_map(ProxyInfo) ->
	    ?LOG(debug, "OK Proxy Map: ~p", [ProxyInfo]),
	    ProxyInfo;

	{error, Cause} ->
	    ?LOG(warning, "Failed Proxy Map: ~p", [{error, Cause}]),
	    Type = create_session_response,
	    Reply = response(Type, Context, [#v2_cause{v2_cause = Cause}], Request),
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

handle_sgw_change(#context{remote_control_teid = NewFqTEID},
		  #context{remote_control_teid = OldFqTEID},
		  #context{control_port = CntlPort} = ProxyContext0)
  when OldFqTEID /= NewFqTEID ->
    {ok, CntlTEI} = gtp_context_reg:alloc_tei(CntlPort),
    ProxyContext = ProxyContext0#context{local_control_tei = CntlTEI},
    gtp_context:remote_context_update(ProxyContext0, ProxyContext),
    ProxyContext;
handle_sgw_change(_, _, ProxyContext) ->
    ProxyContext.

update_path_bind(NewContext0, OldContext)
  when NewContext0 /= OldContext ->
    NewContext = gtp_path:bind(false, NewContext0),
    gtp_path:unbind(OldContext),
    NewContext;
update_path_bind(NewContext, _OldContext) ->
    NewContext.

init_proxy_context(CntlPort,
		   #context{imei = IMEI, context_id = ContextId, version = Version,
			    control_interface = Interface, state = CState},
		   #{imsi := IMSI, msisdn := MSISDN, apn := DstAPN}, {_GwNode, PGW}) ->
    APN = ergw_node_selection:expand_apn(DstAPN, IMSI),
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
	   #fq_teid{ip = PGW},
       state             = CState
      }.

get_context_from_bearer(_, #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-U SGW',
			      key = TEI, ipv4 = IP4, ipv6 = IP6}, Context) ->
    IP = ergw_gsn_lib:choose_context_ip(IP4, IP6, Context),
    Context#context{
      remote_data_teid = #fq_teid{ip = ergw_inet:bin2ip(IP), teid = TEI}
     };
get_context_from_bearer(_, #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-U PGW',
			      key = TEI, ipv4 = IP4, ipv6 = IP6}, Context) ->
    IP = ergw_gsn_lib:choose_context_ip(IP4, IP6, Context),
    Context#context{
      remote_data_teid = #fq_teid{ip = ergw_inet:bin2ip(IP), teid = TEI}
     };
get_context_from_bearer(?'EPS Bearer ID', #v2_eps_bearer_id{eps_bearer_id = EBI},
			#context{state = CState} = Context) ->
    Context#context{state = CState#context_state{ebi = EBI}};
get_context_from_bearer(_K, _, Context) ->
    Context.

get_context_from_req(_, #v2_fully_qualified_tunnel_endpoint_identifier{
			   interface_type = ?'S5/S8-C SGW',
			   key = TEI, ipv4 = IP4, ipv6 = IP6}, Context) ->
    IP = ergw_gsn_lib:choose_context_ip(IP4, IP6, Context),
    Context#context{
      remote_control_teid = #fq_teid{ip = ergw_inet:bin2ip(IP), teid = TEI}
     };
get_context_from_req(_, #v2_fully_qualified_tunnel_endpoint_identifier{
			   interface_type = ?'S5/S8-C PGW',
			   key = TEI, ipv4 = IP4, ipv6 = IP6}, Context) ->
    IP = ergw_gsn_lib:choose_context_ip(IP4, IP6, Context),
    Context#context{
      remote_control_teid = #fq_teid{ip = ergw_inet:bin2ip(IP), teid = TEI}
     };
get_context_from_req(_K, #v2_bearer_context{instance = 0, group = Bearer}, Context) ->
    maps:fold(fun get_context_from_bearer/3, Context, Bearer);
get_context_from_req(?'Access Point Name', #v2_access_point_name{apn = APN}, Context) ->
    Context#context{apn = APN};
get_context_from_req(?'IMSI', #v2_international_mobile_subscriber_identity{imsi = IMSI}, Context) ->
    Context#context{imsi = IMSI};
get_context_from_req(?'ME Identity', #v2_mobile_equipment_identity{mei = IMEI}, Context) ->
    Context#context{imei = IMEI};
get_context_from_req(?'MSISDN', #v2_msisdn{msisdn = MSISDN}, Context) ->
    Context#context{msisdn = MSISDN};
get_context_from_req(_K, _, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs} = Req, Context0) ->
    Context1 = gtp_v2_c:update_context_id(Req, Context0),
    Context = #context{imsi = IMSI, apn = APN} =
	maps:fold(fun get_context_from_req/3, Context1, IEs),
    Context#context{apn = ergw_node_selection:expand_apn(APN, IMSI)}.

fq_teid(TEI, {_,_,_,_} = IP, IE) ->
    IE#v2_fully_qualified_tunnel_endpoint_identifier{
       key = TEI, ipv4 = ergw_inet:ip2bin(IP)};
fq_teid(TEI, {_,_,_,_,_,_,_,_} = IP, IE) ->
    IE#v2_fully_qualified_tunnel_endpoint_identifier{
      key = TEI, ipv6 = ergw_inet:ip2bin(IP)}.

set_bearer_from_context(#context{local_data_endp = #gtp_endp{ip = IP, teid = TEI}},
			_, #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-U SGW'} = IE) ->
    fq_teid(TEI, IP, IE);
set_bearer_from_context(#context{local_data_endp = #gtp_endp{ip = IP, teid = TEI}},
			_, #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-U PGW'} = IE) ->
    fq_teid(TEI, IP, IE);
set_bearer_from_context(_, _K, IE) ->
    IE.

set_req_from_context(#context{apn = APN},
		     _K, #v2_access_point_name{instance = 0} = IE)
  when is_list(APN) ->
    IE#v2_access_point_name{apn = APN};
set_req_from_context(#context{imsi = IMSI},
		  _K, #v2_international_mobile_subscriber_identity{instance = 0} = IE)
  when is_binary(IMSI) ->
    IE#v2_international_mobile_subscriber_identity{imsi = IMSI};
set_req_from_context(#context{msisdn = MSISDN},
		     _K, #v2_msisdn{instance = 0} = IE)
  when is_binary(MSISDN) ->
    IE#v2_msisdn{msisdn = MSISDN};
set_req_from_context(#context{control_port = #gtp_port{ip = CntlIP}, local_control_tei = CntlTEI},
		     _K, #v2_fully_qualified_tunnel_endpoint_identifier{
			    interface_type = ?'S5/S8-C SGW'} = IE) ->
    fq_teid(CntlTEI, CntlIP, IE);
set_req_from_context(#context{control_port = #gtp_port{ip = CntlIP}, local_control_tei = CntlTEI},
		     _K, #v2_fully_qualified_tunnel_endpoint_identifier{
			    interface_type = ?'S5/S8-C PGW'} = IE) ->
    fq_teid(CntlTEI, CntlIP, IE);
set_req_from_context(Context, _K, #v2_bearer_context{instance = 0, group = Bearer} = IE) ->
    IE#v2_bearer_context{group = maps:map(set_bearer_from_context(Context, _, _), Bearer)};
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
    PI#{version => v2,
	imsi    => IMSI,
	imei    => IMEI,
	msisdn  => MSISDN,
	apn     => APN,
	servingGwCip => GsnC,
	servingGwUip => GsnU
       }.

build_context_request(#context{remote_control_teid = #fq_teid{teid = TEI}} = Context,
		      NewPeer, SeqNo, #gtp{type = Type, ie = RequestIEs} = Request) ->
    ProxyIEs0 = maps:without([?'Recovery'], RequestIEs),
    ProxyIEs1 = update_gtp_req_from_context(Context, ProxyIEs0),
    ProxyIEs = gtp_v2_c:build_recovery(Type, Context, NewPeer, ProxyIEs1),
    Request#gtp{tei = TEI, seq_no = SeqNo, ie = ProxyIEs}.

send_request(#context{control_port = GtpPort,
		      remote_control_teid =
			  #fq_teid{
			     ip = RemoteCntlIP,
			     teid = RemoteCntlTEI}
		     },
	     T3, N3, Type, RequestIEs) ->
    Msg = #gtp{version = v2, type = Type, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(GtpPort, RemoteCntlIP, ?GTP2c_PORT, T3, N3, Msg, undefined).

initiate_session_teardown(sgw2pgw,
			  #{proxy_context :=
				#context{state = #context_state{ebi = EBI}} = Ctx}) ->
    Type = delete_session_request,
    RequestIEs0 = [#v2_cause{v2_cause = network_failure},
		   #v2_eps_bearer_id{eps_bearer_id = EBI}],
    RequestIEs = gtp_v2_c:build_recovery(Type, Ctx, false, RequestIEs0),
    send_request(Ctx, ?T3, ?N3, Type, RequestIEs);
initiate_session_teardown(pgw2sgw,
			  #{context :=
				#context{state = #context_state{ebi = EBI}} = Ctx}) ->
    Type = delete_bearer_request,
    RequestIEs0 = [#v2_cause{v2_cause = reactivation_requested},
		   #v2_eps_bearer_id{eps_bearer_id = EBI}],
    RequestIEs = gtp_v2_c:build_recovery(Type, Ctx, false, RequestIEs0),
    send_request(Ctx, ?T3, ?N3, Type, RequestIEs).

bind_forward_path(sgw2pgw, Request, #{context := Context,
				      proxy_context := ProxyContext} = Data) ->
    Data#{
      context => gtp_path:bind(Request, false, Context),
      proxy_context => gtp_path:bind(true, ProxyContext)
     };
bind_forward_path(pgw2sgw, Request, #{context := Context,
				      proxy_context := ProxyContext} = Data) ->
    Data#{
      context => gtp_path:bind(false, Context),
      proxy_context => gtp_path:bind(Request, true, ProxyContext)
     }.

fteid_forward_context(#f_teid{ipv4 = IPv4, ipv6 = IPv6, teid = TEID},
		      #{proxy_context :=
			    #context{
			       remote_data_teid =
				   #fq_teid{ip = IP,
					    teid = TEID}}})
  when IP =:= IPv4; IP =:= IPv6 ->
    pgw2sgw;
fteid_forward_context(#f_teid{ipv4 = IPv4, ipv6 = IPv6, teid = TEID},
		      #{context :=
			    #context{
			       remote_data_teid =
				   #fq_teid{ip = IP,
					    teid = TEID}}})
  when IP =:= IPv4; IP =:= IPv6 ->
    sgw2pgw.

forward_context(sgw2pgw, #{proxy_context := Context}) ->
    Context;
forward_context(pgw2sgw, #{context := Context}) ->
    Context.

forward_request(Direction, ReqKey,
		#gtp{seq_no = ReqSeqNo, ie = ReqIEs} = Request,
		#{last_trigger_id :=
		      {ReqSeqNo, LastFwdSeqNo, GtpPort, SrcIP, SrcPort, _}} = Data,
	       DataOld) ->

    Context = forward_context(Direction, Data),
    FwdReq = build_context_request(Context, false, LastFwdSeqNo, Request),
    ergw_proxy_lib:forward_request(Direction, GtpPort, SrcIP, SrcPort, FwdReq, ReqKey,
				   ReqSeqNo, is_map_key(?'Recovery', ReqIEs), DataOld);
forward_request(Direction, ReqKey,
		#gtp{seq_no = ReqSeqNo, ie = ReqIEs} = Request,
		Data, DataOld) ->
    Context = forward_context(Direction, Data),
    FwdReq = build_context_request(Context, false, undefined, Request),
    ergw_proxy_lib:forward_request(Direction, Context, FwdReq, ReqKey,
				   ReqSeqNo, is_map_key(?'Recovery', ReqIEs), DataOld).

trigger_request(Direction, #request{gtp_port = GtpPort, ip = SrcIP, port = SrcPort} = ReqKey,
		#gtp{seq_no = SeqNo} = Request, Data) ->
    Context = forward_context(Direction, Data),
    case ergw_proxy_lib:get_seq_no(Context, ReqKey, Request) of
	{ok, FwdSeqNo} ->
	    Data#{last_trigger_id => {FwdSeqNo, SeqNo, GtpPort, SrcIP, SrcPort, ReqKey}};
	_ ->
	    Data
    end.

trigger_request_finished(#gtp{seq_no = SeqNo},
			 #{last_trigger_id :=
			       {_, SeqNo, _, _, _, CommandReqKey}}) ->
    gtp_context:request_finished(CommandReqKey);
trigger_request_finished(_, _) ->
    ok.

forward_response(#proxy_request{request = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
		 Response, Context) ->
    GtpResp = build_context_request(Context, NewPeer, SeqNo, Response),
    gtp_context:send_response(ReqKey, GtpResp).

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
