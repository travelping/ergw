%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn_proxy).

-behaviour(gtp_api).

-compile({parse_transform, cut}).

-export([validate_options/1, init/2, request_spec/3,
	 handle_pdu/4, handle_sx_report/3,
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
	 Key#request.socket =:= Context#context.left_tnl#tunnel.socket andalso
	 Msg#gtp.tei =:= Context#context.left_tnl#tunnel.local#fq_teid.teid)).

-define(IS_REQUEST_CONTEXT_OPTIONAL_TEI(Key, Msg, Context),
	(is_record(Key, request) andalso
	 is_record(Msg, gtp) andalso
	 Key#request.socket =:= Context#context.left_tnl#tunnel.socket andalso
	 (Msg#gtp.tei =:= 0 orelse
	  Msg#gtp.tei =:= Context#context.left_tnl#tunnel.local#fq_teid.teid))).

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

init(#{proxy_sockets := ProxySockets, node_selection := NodeSelect,
       proxy_data_source := ProxyDS, contexts := Contexts},
     #{right_bearer := RightBearer} = Data) ->

    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),

    {ok, run, Data#{proxy_sockets => ProxySockets,
		    'Version' => v1,
		    'Session' => Session,
		    contexts => Contexts,
		    node_selection => NodeSelect,
		    right_bearer => RightBearer#bearer{interface = 'Core'},
		    proxy_ds => ProxyDS}}.

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event({call, From}, delete_context, _State, Data) ->
    delete_context(administrative, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, terminate_context, _State, Data) ->
    initiate_pdp_context_teardown(sgsn2ggsn, Data),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, Path}, _State,
	     #{context := #context{left_tnl = #tunnel{path = Path}}} = Data) ->
    initiate_pdp_context_teardown(sgsn2ggsn, Data),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, Path}, _State,
	     #{proxy_context := #context{left_tnl = #tunnel{path = Path}}} = Data) ->
    initiate_pdp_context_teardown(ggsn2sgsn, Data),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, _Path}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

handle_event(cast, delete_context, _State, Data) ->
    delete_context(administrative, Data),
    {next_state, shutdown, Data};

handle_event(cast, {packet_in, _Socket, _IP, _Port, _Msg}, _State, _Data) ->
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
    delete_context(upf_failure, Data),
    {next_state, shutdown, Data};

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

%%
%% resend request
%%
handle_request(ReqKey, Request, true, _State,
	       #{context := Context, proxy_context := ProxyContext})
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->
    RightTunnel = ergw_gsn_lib:tunnel(left, ProxyContext),
    ergw_proxy_lib:forward_request(RightTunnel, ReqKey, Request),
    keep_state_and_data;

handle_request(ReqKey, Request, true, _State,
	       #{context := Context, proxy_context := ProxyContext})
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->
    LeftTunnel = ergw_gsn_lib:tunnel(left, Context),
    ergw_proxy_lib:forward_request(LeftTunnel, ReqKey, Request),
    keep_state_and_data;

%%
%% some request type need special treatment for resends
%%
handle_request(ReqKey, #gtp{type = create_pdp_context_request} = Request, true,
	       _State, #{proxy_context := ProxyContext}) ->
    RightTunnel = ergw_gsn_lib:tunnel(left, ProxyContext),
    ergw_proxy_lib:forward_request(RightTunnel, ReqKey, Request),
    keep_state_and_data;
handle_request(ReqKey, #gtp{type = ms_info_change_notification_request} = Request, true,
	       _State, #{context := Context, proxy_context := ProxyContext})
  when ?IS_REQUEST_CONTEXT_OPTIONAL_TEI(ReqKey, Request, Context) ->
    RightTunnel = ergw_gsn_lib:tunnel(left, ProxyContext),
    ergw_proxy_lib:forward_request(RightTunnel, ReqKey, Request),
    keep_state_and_data;

handle_request(_ReqKey, _Request, true, _State, _Data) ->
    ?LOG(error, "resend of request not handled ~p, ~p",
		[_ReqKey, gtp_c_lib:fmt_gtp(_Request)]),
    keep_state_and_data;

handle_request(ReqKey,
	       #gtp{type = create_pdp_context_request,
		    ie = IEs} = Request, _Resent, _State,
	       #{context := Context0, aaa_opts := AAAopts, node_selection := NodeSelect,
		 left_bearer := LeftBearer0, right_bearer := RightBearer0,
		 'Session' := Session} = Data) ->

   Context = update_context_from_gtp_req(Request, Context0#context{state = #context_state{}}),

    LeftTunnel0 = ergw_gsn_lib:tunnel(left, Context0),

    {LeftTunnel1, LeftBearer1} =
	case ggsn_gn:update_tunnel_from_gtp_req(Request, LeftTunnel0, LeftBearer0) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context})
	end,

    LeftTunnel = gtp_path:bind(Request, LeftTunnel1),

    gtp_context:terminate_colliding_context(LeftTunnel, Context),

    SessionOpts0 = ggsn_gn:init_session(IEs, LeftTunnel, Context, AAAopts),
    SessionOpts = ggsn_gn:init_session_from_gtp_req(IEs, AAAopts, LeftTunnel, SessionOpts0),

    %% TBD.... this is needed for the throws....
    Ctx = ergw_gsn_lib:'#set-'([{left_tnl, LeftTunnel}], Context),

    ProxyInfo =
	case handle_proxy_info(SessionOpts, LeftTunnel, LeftBearer1, Context, Data) of
	    {ok, Result2} -> Result2;
	    {error, Err2} -> throw(Err2#ctx_err{context = Ctx})
	end,

    ProxySocket = ergw_proxy_lib:select_gtp_proxy_sockets(ProxyInfo, Data),

    %% GTP v1 services only, we don't do v1 to v2 conversion (yet)
    Services = [{"x-3gpp-ggsn", "x-gn"}, {"x-3gpp-ggsn", "x-gp"},
		{"x-3gpp-pgw", "x-gn"}, {"x-3gpp-pgw", "x-gp"}],
    ProxyGGSN =
	case ergw_proxy_lib:select_gw(ProxyInfo, v1, Services, NodeSelect, ProxySocket) of
	    {ok, Result3} -> Result3;
	    {error, Err3} -> throw(Err3#ctx_err{context = Ctx})
	end,

    Candidates = ergw_proxy_lib:select_sx_proxy_candidate(ProxyGGSN, ProxyInfo, Data),
    SxConnectId = ergw_sx_node:request_connect(Candidates, NodeSelect, 1000),

    {ok, _} = ergw_aaa_session:invoke(Session, SessionOpts, start, #{async =>true}),

%% ======================================================
    %% TODO........
    ProxyContext = init_proxy_context(ProxySocket, Context, ProxyInfo, ProxyGGSN),

    RightTunnel0 = ergw_gsn_lib:tunnel(left, ProxyContext),
%% ======================================================
    RightTunnel = gtp_path:bind(RightTunnel0),

    ergw_sx_node:wait_connect(SxConnectId),
    {PCtx0, NodeCaps} =
	case ergw_sx_node:select_sx_node(Candidates) of
	    {ok, Result4} -> Result4;
	    {error, Err4} -> throw(Err4#ctx_err{context = ProxyContext})   %% TBD: proxy context ???
	end,

    LeftBearer =
	case ergw_gsn_lib:assign_local_data_teid(PCtx0, NodeCaps, LeftTunnel, LeftBearer1) of
	    {ok, Result5} -> Result5;
	    {error, Err5} -> throw(Err5#ctx_err{context = Ctx})
	end,
    RightBearer =
	case ergw_gsn_lib:assign_local_data_teid(PCtx0, NodeCaps, RightTunnel, RightBearer0) of
	    {ok, Result6} -> Result6;
	    {error, Err6} -> throw(Err6#ctx_err{context = Ctx})
	end,

    PCC = ergw_proxy_lib:proxy_pcc(),
    PCtx =
	case ergw_pfcp_context:create_pfcp_session(PCtx0, PCC, LeftBearer, RightBearer, Ctx) of
	    {ok, Result7} -> Result7;
	    {error, Err7} -> throw(Err7#ctx_err{context = Ctx})
	end,

    FinalContext =
	ergw_gsn_lib:'#set-'([{left_tnl, LeftTunnel}], Context),
    FinalProxyContext =
	ergw_gsn_lib:'#set-'([{left_tnl, RightTunnel}], ProxyContext),

    case gtp_context:remote_context_register_new(
	   LeftTunnel, LeftBearer, RightBearer, FinalContext) of
	ok -> ok;
	{error, Err8} -> throw(Err8#ctx_err{context = FinalContext})
    end,

    DataNew =
	Data#{context => FinalContext, proxy_context => FinalProxyContext, pfcp => PCtx,
	      left_bearer => LeftBearer, right_bearer => RightBearer},

    forward_request(sgsn2ggsn, ReqKey, Request, RightTunnel, RightBearer, ProxyContext, Data),

    {keep_state, DataNew};

handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request} = Request,
	       _Resent, _State,
	       #{context := OldContext, proxy_context := OldProxyContext,
		 left_bearer := LeftBearerOld, right_bearer := RightBearer} = Data)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, OldContext) ->
    LeftTunnelOld = ergw_gsn_lib:tunnel(left, OldContext),
    {LeftTunnel0, LeftBearer} =
	case ggsn_gn:update_tunnel_from_gtp_req(
	       Request, LeftTunnelOld#tunnel{version = v1}, LeftBearerOld) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = OldContext})
	end,

    LeftTunnel1 = gtp_path:bind(Request, LeftTunnel0),
    gtp_context:tunnel_reg_update(LeftTunnelOld, LeftTunnel1),
    LeftTunnel = update_path_bind(LeftTunnel1, LeftTunnelOld),

    RightTunnelOld = ergw_gsn_lib:tunnel(left, OldProxyContext),
    RightTunnel1 =
	handle_sgsn_change(LeftTunnel, LeftTunnelOld, RightTunnelOld#tunnel{version = v1}),
    RightTunnel = update_path_bind(RightTunnel1, RightTunnelOld),

    FinalContext =
	ergw_gsn_lib:'#set-'([{left_tnl, LeftTunnel}], OldContext),
    FinalProxyContext =
	ergw_gsn_lib:'#set-'([{left_tnl, RightTunnel}], OldProxyContext),
    DataNew =
	Data#{context => FinalContext, proxy_context => FinalProxyContext,
	      left_bearer => LeftBearer},

    forward_request(sgsn2ggsn, ReqKey, Request, RightTunnel, RightBearer, FinalProxyContext, Data),

    {keep_state, DataNew};

%%
%% GGSN to SGW Update PDP Context Request
%%
handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request} = Request,
	       _Resent, _State,
	       #{context := Context, proxy_context := ProxyContext,
		 left_bearer := LeftBearer} = Data)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->

    DataNew = bind_forward_path(ggsn2sgsn, Request, Data),

    LeftTunnel = ergw_gsn_lib:tunnel(left, Context),
    forward_request(ggsn2sgsn, ReqKey, Request, LeftTunnel, LeftBearer, Context, Data),

    {keep_state, DataNew};

handle_request(ReqKey,
	       #gtp{type = ms_info_change_notification_request} = Request,
	       _Resent, _State,
	       #{context := Context, proxy_context := ProxyContext,
		 right_bearer := RightBearer} = Data)
  when ?IS_REQUEST_CONTEXT_OPTIONAL_TEI(ReqKey, Request, Context) ->

    DataNew = bind_forward_path(sgsn2ggsn, Request, Data),

    RightTunnel = ergw_gsn_lib:tunnel(left, ProxyContext),
    forward_request(sgsn2ggsn, ReqKey, Request, RightTunnel, RightBearer, ProxyContext, Data),

    {keep_state, DataNew};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request} = Request,
	       _Resent, _State,
	       #{context := Context, proxy_context := ProxyContext,
		 right_bearer := RightBearer} = Data0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->
    RightTunnel = ergw_gsn_lib:tunnel(left, ProxyContext),
    forward_request(sgsn2ggsn, ReqKey, Request, RightTunnel, RightBearer, ProxyContext, Data0),

    Msg = {delete_pdp_context_request, sgsn2ggsn, ReqKey, Request},
    Data = restart_timeout(?RESPONSE_TIMEOUT, Msg, Data0),

    {keep_state, Data};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request} = Request,
	       _Resent, _State,
	       #{context := Context, proxy_context := ProxyContext,
		 left_bearer := LeftBearer} = Data0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->
    LeftTunnel = ergw_gsn_lib:tunnel(left, Context),
    forward_request(ggsn2sgsn, ReqKey, Request, LeftTunnel, LeftBearer, Context, Data0),

    Msg = {delete_pdp_context_request, ggsn2sgsn, ReqKey, Request},
    Data = restart_timeout(?RESPONSE_TIMEOUT, Msg, Data0),

    {keep_state, Data};

handle_request(#request{socket = Socket} = ReqKey, Msg, _Resent, _State, _Data) ->
    ?LOG(warning, "Unknown Proxy Message on ~p: ~p", [Socket, Msg]),
    gtp_context:request_finished(ReqKey),
    keep_state_and_data.

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = create_pdp_context_response,
		     ie = #{?'Cause' := #cause{value = Cause}}} = Response,
		_Request, _State,
		#{context := Context, proxy_context := PrevProxyCtx, pfcp := PCtx0,
		  left_bearer := LeftBearer, right_bearer := RightBearer0} = Data) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    RightTunnel0 = ergw_gsn_lib:tunnel(left, PrevProxyCtx),

    {RightTunnel1, RightBearer} =
	case ggsn_gn:update_tunnel_from_gtp_req(Response, RightTunnel0, RightBearer0) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context})
	end,
    RightTunnel = gtp_path:bind(Response, RightTunnel1),

    ProxyContext1 = update_context_from_gtp_req(Response, PrevProxyCtx),

    ProxyContext =
	ergw_gsn_lib:'#set-'([{left_tnl, RightTunnel}], ProxyContext1),
    gtp_context:remote_context_register(
      RightTunnel, LeftBearer, RightBearer, ProxyContext),

    Return =
	if ?CAUSE_OK(Cause) ->
		PCC = ergw_proxy_lib:proxy_pcc(),
		{PCtx, _} =
		    case ergw_pfcp_context:modify_pfcp_session(
			   PCC, [], #{}, LeftBearer, RightBearer, PCtx0) of
			{ok, Result2} -> Result2;
			{error, Err2} -> throw(Err2#ctx_err{context = Context})
		    end,
		DataNew =
		    Data#{proxy_context => ProxyContext, pfcp => PCtx,
			  right_bearer => RightBearer},
		{keep_state, DataNew};
	   true ->
		delete_forward_session(normal, Data),
		{next_state, shutdown, Data}
	end,

    LeftTunnel = ergw_gsn_lib:tunnel(left, Context),
    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    Return;

handle_response(#proxy_request{direction = sgsn2ggsn,
			       context = PrevContext} = ProxyRequest,
		#gtp{type = update_pdp_context_response} = Response,
		_Request, _State,
		#{context := Context, proxy_context := ProxyContextOld, pfcp := PCtxOld,
		  left_bearer := LeftBearer, right_bearer := RightBearerOld} = Data) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    RightTunnelOld = ergw_gsn_lib:tunnel(left, ProxyContextOld),

    {RightTunnel0, RightBearer} =
	case ggsn_gn:update_tunnel_from_gtp_req(Response, RightTunnelOld, RightBearerOld) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context})
	end,
    RightTunnel1 = gtp_path:bind(Response, RightTunnel0),
    gtp_context:tunnel_reg_update(RightTunnelOld, RightTunnel1),
    RightTunnel = update_path_bind(RightTunnel0, RightTunnelOld),

    ProxyContext1 = update_context_from_gtp_req(Response, ProxyContextOld),

    FinalProxyContext =
	ergw_gsn_lib:'#set-'([{left_tnl, RightTunnel}], ProxyContext1),
    gtp_context:remote_context_register(
      RightTunnel, LeftBearer, RightBearer, FinalProxyContext),

    PCC = ergw_proxy_lib:proxy_pcc(),
    {PCtx, _} =
	case ergw_pfcp_context:modify_pfcp_session(
	       PCC, [], #{}, LeftBearer, RightBearer, PCtxOld) of
	    {ok, Result2} -> Result2;
	    {error, Err2} -> throw(Err2#ctx_err{context = PrevContext})
	end,

    LeftTunnel = ergw_gsn_lib:tunnel(left, Context),
    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),

    DataNew =
	Data#{proxy_context => FinalProxyContext, pfcp := PCtx,
	     right_bearer => RightBearer},
    {keep_state, DataNew};

handle_response(#proxy_request{direction = ggsn2sgsn} = ProxyRequest,
		#gtp{type = update_pdp_context_response} = Response,
		_Request, _State,
		#{proxy_context := ProxyContext, right_bearer := RightBearer}) ->
    ?LOG(debug, "OK SGSN Response ~p", [Response]),

    RightTunnel = ergw_gsn_lib:tunnel(left, ProxyContext),
    forward_response(ProxyRequest, Response, RightTunnel, RightBearer, ProxyContext),
    keep_state_and_data;

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = ms_info_change_notification_response} = Response,
		_Request, _State, #{context := Context, left_bearer := LeftBearer}) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    LeftTunnel = ergw_gsn_lib:tunnel(left, Context),
    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    keep_state_and_data;

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = delete_pdp_context_response} = Response,
		_Request, _State,
		#{context := Context, left_bearer := LeftBearer} = Data0) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    LeftTunnel = ergw_gsn_lib:tunnel(left, Context),
    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),

    Data = cancel_timeout(Data0),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data};

handle_response(#proxy_request{direction = ggsn2sgsn} = ProxyRequest,
		#gtp{type = delete_pdp_context_response} = Response,
		_Request, _State,
		#{proxy_context := ProxyContext, right_bearer := RightBearer} = Data0) ->
    ?LOG(debug, "OK SGSN Response ~p", [Response]),

    RightTunnel = ergw_gsn_lib:tunnel(left, ProxyContext),
    forward_response(ProxyRequest, Response, RightTunnel, RightBearer, ProxyContext),
    Data = cancel_timeout(Data0),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data};

handle_response(#proxy_request{request = ReqKey} = _ReqInfo,
		Response, _Request, _State, _Data) ->
    ?LOG(warning, "Unknown Proxy Response ~p", [Response]),

    gtp_context:request_finished(ReqKey),
    keep_state_and_data;

handle_response(_, Response, _Request, _State, _Data) ->
    ?LOG(warning, "Unknown Proxy Response ~p", [Response]),
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% %% response/3
%% response(Cmd, #tunnel{remote = #fq_teid{teid = TEID}}, Response) ->
%%     {Cmd, TEID, Response}.

%% %% response/4
%% response(Cmd, Tunnel, IEs0, #gtp{ie = ReqIEs})
%%   when is_record(Tunnel, tunnel) ->
%%     IEs = gtp_v1_c:build_recovery(Cmd, Tunnel, is_map_key(?'Recovery', ReqIEs), IEs0),
%%     response(Cmd, Tunnel, IEs).

handle_proxy_info(Session, Tunnel, Bearer, Context, #{proxy_ds := ProxyDS}) ->
    PI = proxy_info(Session, Tunnel, Bearer, Context),
    case gtp_proxy_ds:map(ProxyDS, PI) of
	ProxyInfo when is_map(ProxyInfo) ->
	    ?LOG(debug, "OK Proxy Map: ~p", [ProxyInfo]),
	    {ok, ProxyInfo};

	{error, Cause} ->
	    ?LOG(warning, "Failed Proxy Map: ~p", [Cause]),
	    {error, ?CTX_ERR(?FATAL, Cause)}
    end.

delete_forward_session(Reason, #{pfcp := PCtx, 'Session' := Session}) ->
    URRs = ergw_pfcp_context:delete_pfcp_session(Reason, PCtx),
    SessionOpts = to_session(gtp_context:usage_report_to_accounting(URRs)),
    ?LOG(debug, "Accounting Opts: ~p", [SessionOpts]),
    ergw_aaa_session:invoke(Session, SessionOpts, stop, #{async => true}).

handle_sgsn_change(#tunnel{remote = NewFqTEID},
		  #tunnel{remote = OldFqTEID}, RightTunnelOld)
  when OldFqTEID /= NewFqTEID ->
    RightTunnel = ergw_gsn_lib:reassign_tunnel_teid(RightTunnelOld),
    gtp_context:tunnel_reg_update(RightTunnelOld, RightTunnel),
    RightTunnel;
handle_sgsn_change(_, _, RightTunnel) ->
    RightTunnel.

update_path_bind(NewTunnel0, OldTunnel)
  when NewTunnel0 /= OldTunnel ->
    NewTunnel = gtp_path:bind(NewTunnel0),
    gtp_path:unbind(OldTunnel),
    NewTunnel;
update_path_bind(NewTunnel, _OldTunnel) ->
    NewTunnel.

init_proxy_context(Socket,
		   #context{imei = IMEI, context_id = ContextId, version = Version,
			    state = CState},
		   #{imsi := IMSI, msisdn := MSISDN, apn := DstAPN}, {_GwNode, GGSN}) ->
    {APN, _OI} = ergw_node_selection:split_apn(DstAPN),
    Info = ergw_gtp_socket:info(Socket),
    ProxyTnl0 =
	ergw_gsn_lib:assign_tunnel_teid(
	  local, Info, ergw_gsn_lib:init_tunnel('Core', Info, Socket, v1)),
    ProxyTnl = ProxyTnl0#tunnel{remote = #fq_teid{ip = GGSN}},

    #context{
       apn               = APN,
       imsi              = IMSI,
       imei              = IMEI,
       msisdn            = MSISDN,
       context_id        = ContextId,

       version           = Version,
       left_tnl          = ProxyTnl,

       state             = CState
      }.

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

set_req_from_context(_, _, #context{apn = APN},
		     _K, #access_point_name{instance = 0} = IE)
  when is_list(APN) ->
    IE#access_point_name{apn = APN};
set_req_from_context(_, _, #context{imsi = IMSI},
		     _K, #international_mobile_subscriber_identity{instance = 0} = IE)
  when is_binary(IMSI) ->
    IE#international_mobile_subscriber_identity{imsi = IMSI};
set_req_from_context(_, _, #context{msisdn = MSISDN},
		  _K, #ms_international_pstn_isdn_number{instance = 0} = IE)
  when is_binary(MSISDN) ->
    IE#ms_international_pstn_isdn_number{msisdn = {isdn_address, 1, 1, 1, MSISDN}};
set_req_from_context(#tunnel{local = #fq_teid{ip = IP}}, _, _,
		     _K, #gsn_address{instance = 0} = IE) ->
    IE#gsn_address{address = ergw_inet:ip2bin(IP)};
set_req_from_context(_, #bearer{local = #fq_teid{ip = IP}}, _,
		     _K, #gsn_address{instance = 1} = IE) ->
    IE#gsn_address{address = ergw_inet:ip2bin(IP)};
set_req_from_context(_, #bearer{local = #fq_teid{teid = TEI}}, _,
		     _K, #tunnel_endpoint_identifier_data_i{instance = 0} = IE) ->
    IE#tunnel_endpoint_identifier_data_i{tei = TEI};
set_req_from_context(#tunnel{local = #fq_teid{teid = TEI}}, _, _,
		     _K, #tunnel_endpoint_identifier_control_plane{instance = 0} = IE) ->
    IE#tunnel_endpoint_identifier_control_plane{tei = TEI};
set_req_from_context(_, _, _, _K, IE) ->
    IE.

update_gtp_req_from_context(Tunnel, Bearer, Context, GtpReqIEs) ->
    maps:map(set_req_from_context(Tunnel, Bearer, Context, _, _), GtpReqIEs).

proxy_info(Session,
	   #tunnel{remote = #fq_teid{ip = GsnC}},
	   #bearer{remote = #fq_teid{ip = GsnU}},
	   #context{apn = APN, imsi = IMSI, imei = IMEI, msisdn = MSISDN}) ->
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

build_context_request(#tunnel{remote = #fq_teid{teid = TEI}} = Tunnel, Bearer,
		      Context, NewPeer, SeqNo,
		      #gtp{type = Type, ie = RequestIEs} = Request) ->
    ProxyIEs0 = maps:without([?'Recovery'], RequestIEs),
    ProxyIEs1 = update_gtp_req_from_context(Tunnel, Bearer, Context, ProxyIEs0),
    ProxyIEs = gtp_v1_c:build_recovery(Type, Tunnel, NewPeer, ProxyIEs1),
    Request#gtp{tei = TEI, seq_no = SeqNo, ie = ProxyIEs}.

msg(#tunnel{remote = #fq_teid{teid = RemoteCntlTEI}}, Type, RequestIEs) ->
    #gtp{version = v1, type = Type, tei = RemoteCntlTEI, ie = RequestIEs}.

send_request(Tunnel, DstIP, DstPort, T3, N3, Msg) ->
    gtp_context:send_request(Tunnel, DstIP, DstPort, T3, N3, Msg, undefined).

send_request(#tunnel{remote = #fq_teid{ip = RemoteCntlIP}} = Tunnel, T3, N3, Msg) ->
    send_request(Tunnel, RemoteCntlIP, ?GTP1c_PORT, T3, N3, Msg).

send_request(Tunnel, T3, N3, Type, RequestIEs) ->
    send_request(Tunnel, T3, N3, msg(Tunnel, Type, RequestIEs)).

initiate_pdp_context_teardown(Direction, Data) ->
    #context{left_tnl = Tunnel,
	     state = #context_state{nsapi = NSAPI}} =
	forward_context(Direction, Data),
    Type = delete_pdp_context_request,
    RequestIEs0 = [#cause{value = request_accepted},
		   #teardown_ind{value = 1},
		   #nsapi{nsapi = NSAPI}],
    RequestIEs = gtp_v1_c:build_recovery(Type, Tunnel, false, RequestIEs0),
    send_request(Tunnel, ?T3, ?N3, Type, RequestIEs).

bind_forward_path(sgsn2ggsn, Request,
		  #{context := #context{left_tnl = LeftTunnel} = Context,
		    proxy_context := #context{left_tnl = RightTunnel} = ProxyContext
		   } = Data) ->
    Data#{
	  context => Context#context{left_tnl = gtp_path:bind(Request, LeftTunnel)},
	  proxy_context => ProxyContext#context{left_tnl = gtp_path:bind(RightTunnel)}
	 };
bind_forward_path(ggsn2sgsn, Request,
		  #{context := #context{left_tnl = LeftTunnel} = Context,
		    proxy_context := #context{left_tnl = RightTunnel} = ProxyContext
		   } = Data) ->
    Data#{
	  context => Context#context{left_tnl = gtp_path:bind(LeftTunnel)},
	  proxy_context => ProxyContext#context{left_tnl = gtp_path:bind(Request, RightTunnel)}
	 }.

fteid_forward_context(#f_teid{ipv4 = IPv4, ipv6 = IPv6, teid = TEID},
		      #{right_bearer := #bearer{remote = #fq_teid{ip = IP, teid = TEID}}})
  when IP =:= IPv4; IP =:= IPv6 ->
    ggsn2sgsn;
fteid_forward_context(#f_teid{ipv4 = IPv4, ipv6 = IPv6, teid = TEID},
		      #{left_bearer := #bearer{remote = #fq_teid{ip = IP, teid = TEID}}})
  when IP =:= IPv4; IP =:= IPv6 ->
    sgsn2ggsn.

forward_context(sgsn2ggsn, #{proxy_context := Context}) ->
    Context;
forward_context(ggsn2sgsn, #{context := Context}) ->
    Context.

forward_request(Direction, ReqKey, #gtp{seq_no = ReqSeqNo, ie = ReqIEs} = Request,
		Tunnel, Bearer, Context, Data) ->
    FwdReq = build_context_request(Tunnel, Bearer, Context, false, undefined, Request),
    ergw_proxy_lib:forward_request(Direction, Tunnel, FwdReq, ReqKey,
				   ReqSeqNo, is_map_key(?'Recovery', ReqIEs), Data).

forward_response(#proxy_request{request = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
		 Response, Tunnel, Bearer, Context) ->
    GtpResp = build_context_request(Tunnel, Bearer, Context, NewPeer, SeqNo, Response),
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

delete_context(Reason, Data) ->
    initiate_pdp_context_teardown(sgsn2ggsn, Data),
    initiate_pdp_context_teardown(ggsn2sgsn, Data),
    delete_forward_session(Reason, Data).
