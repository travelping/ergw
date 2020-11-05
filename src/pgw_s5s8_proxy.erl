%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8_proxy).

-behaviour(gtp_api).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([validate_options/1, init/2, request_spec/3,
	 handle_pdu/4,
	 handle_request/5, handle_response/5,
	 handle_event/4, terminate/3]).

-export([delete_context/3, close_context/3]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define(GTP_v1_Interface, ggsn_gn_proxy).
-define(T3, 10 * 1000).
-define(N3, 5).
-define(RESPONSE_TIMEOUT, (?T3 + (?T3 div 2))).

-define(IS_REQUEST_TUNNEL(Key, Msg, Tunnel),
	(is_record(Key, request) andalso
	 is_record(Msg, gtp) andalso
	 Key#request.socket =:= Tunnel#tunnel.socket andalso
	 Msg#gtp.tei =:= Tunnel#tunnel.local#fq_teid.teid)).

-define(IS_REQUEST_TUNNEL_OPTIONAL_TEI(Key, Msg, Tunnel),
	(is_record(Key, request) andalso
	 is_record(Msg, gtp) andalso
	 Key#request.socket =:= Tunnel#tunnel.socket andalso
	 (Msg#gtp.tei =:= 0 orelse
	  Msg#gtp.tei =:= Tunnel#tunnel.local#fq_teid.teid))).

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

init(#{proxy_sockets := ProxySockets, node_selection := NodeSelect,
       proxy_data_source := ProxyDS, contexts := Contexts},
     #{right_bearer := RightBearer} = Data) ->

    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),

    {ok, run, Data#{proxy_sockets => ProxySockets,
		    'Version' => v2,
		    'Session' => Session,
		    contexts => Contexts,
		    node_selection => NodeSelect,
		    right_bearer => RightBearer#bearer{interface = 'Core'},
		    proxy_ds => ProxyDS}}.

handle_event(Type, Content, State, #{'Version' := v1} = Data) ->
    ?GTP_v1_Interface:handle_event(Type, Content, State, Data);

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event(cast, {packet_in, _Socket, _IP, _Port, _Msg}, _State, _Data) ->
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

handle_request(ReqKey, #gtp{version = v1} = Msg, Resent, State, Data) ->
    ?GTP_v1_Interface:handle_request(ReqKey, Msg, Resent, State, Data#{'Version' => v1});
handle_request(ReqKey, #gtp{version = v2} = Msg, Resent, State, #{'Version' := v1} = Data) ->
    handle_request(ReqKey, Msg, Resent, State, Data#{'Version' => v2});

%%
%% resend request
%%
handle_request(ReqKey, Request, true, _State,
	       #{left_tunnel := LeftTunnel, right_tunnel := RightTunnel})
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, LeftTunnel) ->
    ergw_proxy_lib:forward_request(RightTunnel, ReqKey, Request),
    keep_state_and_data;
handle_request(ReqKey, Request, true, _State,
	       #{left_tunnel := LeftTunnel, right_tunnel := RightTunnel})
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, RightTunnel) ->
    ergw_proxy_lib:forward_request(LeftTunnel, ReqKey, Request),
    keep_state_and_data;

%%
%% some request type need special treatment for resends
%%
handle_request(ReqKey, #gtp{type = create_session_request} = Request, true,
	       _State, #{right_tunnel := RightTunnel}) ->
    ergw_proxy_lib:forward_request(RightTunnel, ReqKey, Request),
    keep_state_and_data;
handle_request(ReqKey, #gtp{type = change_notification_request} = Request, true,
	       _State, #{left_tunnel := LeftTunnel, right_tunnel := RightTunnel})
  when ?IS_REQUEST_TUNNEL_OPTIONAL_TEI(ReqKey, Request, LeftTunnel) ->
    ergw_proxy_lib:forward_request(RightTunnel, ReqKey, Request),
    keep_state_and_data;

handle_request(_ReqKey, _Request, true, _State, _Data) ->
    ?LOG(error, "resend of request not handled ~p, ~p",
		[_ReqKey, gtp_c_lib:fmt_gtp(_Request)]),
    keep_state_and_data;

handle_request(ReqKey,
	       #gtp{type = create_session_request, ie = IEs} = Request,
	       _Resent, _State,
	       #{context := Context0, aaa_opts := AAAopts, node_selection := NodeSelect,
		 left_tunnel := LeftTunnel0,
		 left_bearer := LeftBearer0, right_bearer := RightBearer0,
		 'Session' := Session} = Data) ->

    Context = pgw_s5s8:update_context_from_gtp_req(Request, Context0),

    {LeftTunnel1, LeftBearer1} =
	case pgw_s5s8:update_tunnel_from_gtp_req(Request, LeftTunnel0, LeftBearer0) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{tunnel = LeftTunnel0})
	end,

    LeftTunnel = gtp_path:bind(Request, LeftTunnel1),

    gtp_context:terminate_colliding_context(LeftTunnel, Context),

    SessionOpts0 = pgw_s5s8:init_session(IEs, LeftTunnel, Context, AAAopts),
    SessionOpts = pgw_s5s8:init_session_from_gtp_req(IEs, AAAopts, LeftTunnel, SessionOpts0),

    ProxyInfo =
	case handle_proxy_info(SessionOpts, LeftTunnel, LeftBearer1, Context, Data) of
	    {ok, Result2} -> Result2;
	    {error, Err2} -> throw(Err2#ctx_err{tunnel = LeftTunnel})
	end,

    ProxySocket = ergw_proxy_lib:select_gtp_proxy_sockets(ProxyInfo, Data),

    %% GTP v2 services only, we don't do v1 to v2 conversion (yet)
    Services = [{"x-3gpp-pgw", "x-s8-gtp"}, {"x-3gpp-pgw", "x-s5-gtp"}],
    ProxyGGSN =
	case ergw_proxy_lib:select_gw(ProxyInfo, v2, Services, NodeSelect, ProxySocket) of
	    {ok, Result3} -> Result3;
	    {error, Err3} -> throw(Err3#ctx_err{tunnel = LeftTunnel})
	end,

    Candidates = ergw_proxy_lib:select_sx_proxy_candidate(ProxyGGSN, ProxyInfo, Data),
    SxConnectId = ergw_sx_node:request_connect(Candidates, NodeSelect, 1000),

    {ok, _} = ergw_aaa_session:invoke(Session, SessionOpts, start, #{async =>true}),

    ProxyContext = init_proxy_context(Context, ProxyInfo),
    RightTunnel0 = init_proxy_tunnel(ProxySocket, ProxyGGSN),
    RightTunnel = gtp_path:bind(RightTunnel0),

    ergw_sx_node:wait_connect(SxConnectId),
    {PCtx0, NodeCaps} =
	case ergw_pfcp_context:select_upf(Candidates) of
	    {ok, Result4} -> Result4;
	    {error, Err4} -> throw(Err4#ctx_err{context = ProxyContext, tunnel = LeftTunnel})   %% TBD: proxy context ???
	end,

    LeftBearer =
	case ergw_gsn_lib:assign_local_data_teid(PCtx0, NodeCaps, LeftTunnel, LeftBearer1) of
	    {ok, Result5} -> Result5;
	    {error, Err5} -> throw(Err5#ctx_err{tunnel = LeftTunnel})
	end,
    RightBearer =
	case ergw_gsn_lib:assign_local_data_teid(PCtx0, NodeCaps, RightTunnel, RightBearer0) of
	    {ok, Result6} -> Result6;
	    {error, Err6} -> throw(Err6#ctx_err{tunnel = LeftTunnel})
	end,

    PCC = ergw_proxy_lib:proxy_pcc(),
    PCtx =
	case ergw_pfcp_context:create_pfcp_session(PCtx0, PCC, LeftBearer, RightBearer, Context) of
	    {ok, Result7} -> Result7;
	    {error, Err7} -> throw(Err7#ctx_err{tunnel = LeftTunnel})
	end,

    case gtp_context:remote_context_register_new(
	   LeftTunnel, LeftBearer, RightBearer, Context) of
	ok -> ok;
	{error, Err8} -> throw(Err8#ctx_err{tunnel = LeftTunnel})
    end,

    DataNew = Data#{context => Context, proxy_context => ProxyContext, pfcp => PCtx,
		    left_tunnel => LeftTunnel, right_tunnel => RightTunnel,
		    left_bearer => LeftBearer, right_bearer => RightBearer},
    forward_request(sgw2pgw, ReqKey, Request, RightTunnel, RightBearer, ProxyContext, DataNew, Data),

    {keep_state, DataNew};

handle_request(ReqKey,
	       #gtp{type = modify_bearer_request} = Request,
	       _Resent, _State,
	       #{proxy_context := ProxyContext,
		 left_tunnel := LeftTunnelOld, right_tunnel := RightTunnelOld,
		 left_bearer := LeftBearerOld, right_bearer := RightBearer} = Data)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, LeftTunnelOld) ->
    {LeftTunnel0, LeftBearer} =
	case pgw_s5s8:update_tunnel_from_gtp_req(
	       Request, LeftTunnelOld#tunnel{version = v2}, LeftBearerOld) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{tunnel = LeftTunnelOld})
	end,
    LeftTunnel = ergw_gtp_gsn_lib:update_tunnel_endpoint(Request, LeftTunnelOld, LeftTunnel0),

    RightTunnel0 = ergw_gtp_gsn_lib:handle_peer_change(
		     LeftTunnel, LeftTunnelOld, RightTunnelOld#tunnel{version = v2}),
    RightTunnel = ergw_gtp_gsn_lib:update_tunnel_endpoint(RightTunnelOld, RightTunnel0),

    DataNew = Data#{left_tunnel => LeftTunnel, right_tunnel => RightTunnel,
		    left_bearer => LeftBearer},

    forward_request(sgw2pgw, ReqKey, Request, RightTunnel, RightBearer, ProxyContext, DataNew, Data),

    {keep_state, DataNew};

handle_request(ReqKey,
	       #gtp{type = modify_bearer_command} = Request,
	       _Resent, _State,
	       #{proxy_context := ProxyContext,
		 left_tunnel := LeftTunnel, right_tunnel := RightTunnel,
		 right_bearer := RightBearer} = Data0)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, LeftTunnel) ->

    Data1 = bind_forward_path(sgw2pgw, Request, Data0),

    forward_request(sgw2pgw, ReqKey, Request, RightTunnel, RightBearer, ProxyContext, Data1, Data1),

    Data = trigger_request(RightTunnel, ReqKey, Request, Data1),
    {keep_state, Data};

%%
%% SGW to PGW requests without tunnel endpoint modification
%%
handle_request(ReqKey,
	       #gtp{type = change_notification_request} = Request,
	       _Resent, _State,
	       #{proxy_context := ProxyContext,
		 left_tunnel := LeftTunnel, right_tunnel := RightTunnel,
		 right_bearer := RightBearer} = Data)
  when ?IS_REQUEST_TUNNEL_OPTIONAL_TEI(ReqKey, Request, LeftTunnel) ->

    DataNew = bind_forward_path(sgw2pgw, Request, Data),

    forward_request(sgw2pgw, ReqKey, Request, RightTunnel, RightBearer, ProxyContext, DataNew, Data),

    {keep_state, DataNew};

%%
%% SGW to PGW notifications without tunnel endpoint modification
%%
handle_request(ReqKey,
	       #gtp{type = Type} = Request,
	       _Resent, _State,
	       #{proxy_context := ProxyContext,
		 left_tunnel := LeftTunnel, right_tunnel := RightTunnel,
		 right_bearer := RightBearer} = Data)
  when (Type == suspend_notification orelse
	Type == resume_notification) andalso
       ?IS_REQUEST_TUNNEL(ReqKey, Request, LeftTunnel) ->

    DataNew = bind_forward_path(sgw2pgw, Request, Data),

    forward_request(sgw2pgw, ReqKey, Request, RightTunnel, RightBearer, ProxyContext, DataNew, Data),

    {keep_state, DataNew};

%%
%% PGW to SGW requests without tunnel endpoint modification
%%
handle_request(ReqKey,
	       #gtp{type = update_bearer_request} = Request,
	       _Resent, _State,
	       #{context := Context,
		 left_tunnel := LeftTunnel, right_tunnel := RightTunnel,
		 left_bearer := LeftBearer} = Data0)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, RightTunnel) ->

    Data = bind_forward_path(pgw2sgw, Request, Data0),

    forward_request(pgw2sgw, ReqKey, Request, LeftTunnel, LeftBearer, Context, Data, Data),

    {keep_state, Data};

%%
%% SGW to PGW delete session requests
%%
handle_request(ReqKey,
	       #gtp{type = delete_session_request} = Request,
	       _Resent, _State,
	       #{proxy_context := ProxyContext,
		 left_tunnel := LeftTunnel, right_tunnel := RightTunnel,
		 right_bearer := RightBearer} = Data0)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, LeftTunnel) ->

    forward_request(sgw2pgw, ReqKey, Request, RightTunnel, RightBearer, ProxyContext, Data0, Data0),

    Msg = {delete_session_request, sgw2pgw, ReqKey, Request},
    Data = restart_timeout(?RESPONSE_TIMEOUT, Msg, Data0),

    {keep_state, Data};

%%
%% PGW to SGW delete bearer requests
%%
handle_request(ReqKey,
	       #gtp{type = delete_bearer_request} = Request,
	       _Resent, _State,
	       #{context := Context,
		 left_tunnel := LeftTunnel, right_tunnel := RightTunnel,
		 left_bearer := LeftBearer} = Data0)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, RightTunnel) ->

    forward_request(pgw2sgw, ReqKey, Request, LeftTunnel, LeftBearer, Context, Data0, Data0),

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
		#{context := Context, proxy_context := PrevProxyCtx, pfcp := PCtx0,
		  left_tunnel := LeftTunnel, right_tunnel := RightTunnel0,
		  left_bearer := LeftBearer, right_bearer := RightBearer0} = Data) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    {RightTunnel1, RightBearer} =
	case pgw_s5s8:update_tunnel_from_gtp_req(Response, RightTunnel0, RightBearer0) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{tunnel = LeftTunnel})
	end,
    RightTunnel = gtp_path:bind(Response, RightTunnel1),

    ProxyContext = pgw_s5s8:update_context_from_gtp_req(Response, PrevProxyCtx),

    gtp_context:remote_context_register(
      RightTunnel, LeftBearer, RightBearer, ProxyContext),

    Return =
	if ?CAUSE_OK(Cause) ->
		PCC = ergw_proxy_lib:proxy_pcc(),
		{PCtx, _} =
		    case ergw_pfcp_context:modify_pfcp_session(
			   PCC, [], #{}, LeftBearer, RightBearer, PCtx0) of
			{ok, Result2} -> Result2;
			{error, Err2} -> throw(Err2#ctx_err{tunnel = LeftTunnel})
		    end,
		DataNew =
		    Data#{proxy_context => ProxyContext, pfcp => PCtx,
			  right_tunnel => RightTunnel,
			  left_bearer => LeftBearer, right_bearer => RightBearer},
		{keep_state, DataNew};
	   true ->
		delete_forward_session(normal, Data),
		{next_state, shutdown, Data}
	end,

    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    Return;

handle_response(#proxy_request{direction = sgw2pgw,
			       right_tunnel = RightTunnelPrev} = ProxyRequest,
		#gtp{type = modify_bearer_response} = Response,
		_Request, _State,
		#{context := Context, proxy_context := ProxyContextOld, pfcp := PCtxOld,
		  left_tunnel := LeftTunnel, right_tunnel := RightTunnelOld,
		  left_bearer := LeftBearer, right_bearer := RightBearerOld} = Data) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    {RightTunnel0, RightBearer} =
	case pgw_s5s8:update_tunnel_from_gtp_req(Response, RightTunnelOld, RightBearerOld) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{tunnel = LeftTunnel})
	end,
    RightTunnel =
	ergw_gtp_gsn_lib:update_tunnel_endpoint(Response, RightTunnelOld, RightTunnel0),

    ProxyContext = pgw_s5s8:update_context_from_gtp_req(Response, ProxyContextOld),

    gtp_context:remote_context_register(
      RightTunnel, LeftBearer, RightBearer, ProxyContext),

    SendEM = RightTunnelPrev#tunnel.version == RightTunnel#tunnel.version,
    ModifyOpts =
	if SendEM -> #{send_end_marker => true};
	   true   -> #{}
	end,
    PCC = ergw_proxy_lib:proxy_pcc(),
    {PCtx, _} =
	case ergw_pfcp_context:modify_pfcp_session(
	       PCC, [], ModifyOpts, LeftBearer, RightBearer, PCtxOld) of
	    {ok, Result2} -> Result2;
	    {error, Err2} -> throw(Err2#ctx_err{tunnel = LeftTunnel})
	end,

    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),

    DataNew =
	Data#{proxy_context => ProxyContext, pfcp := PCtx,
	      right_tunnel => RightTunnel, right_bearer => RightBearer},

    {keep_state, DataNew};

%%
%% PGW to SGW response without tunnel endpoint modification
%%
handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		#gtp{type = change_notification_response} = Response,
		_Request, _State,
		#{context := Context, left_tunnel := LeftTunnel, left_bearer := LeftBearer}) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    keep_state_and_data;

%%
%% PGW to SGW acknowledge without tunnel endpoint modification
%%
handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		#gtp{type = Type} = Response,
		_Request, _State,
		#{context := Context, left_tunnel := LeftTunnel, left_bearer := LeftBearer})
  when Type == suspend_acknowledge;
       Type == resume_acknowledge ->
    ?LOG(debug, "OK Proxy Acknowledge ~p", [Response]),

    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    keep_state_and_data;

%%
%% SGW to PGW response without tunnel endpoint modification
%%
handle_response(#proxy_request{direction = pgw2sgw} = ProxyRequest,
		#gtp{type = update_bearer_response} = Response,
		_Request, _State,
		#{proxy_context := ProxyContext,
		  right_tunnel := RightTunnel, right_bearer := RightBearer} = Data) ->
    ?LOG(debug, "OK Response ~p", [Response]),

    forward_response(ProxyRequest, Response, RightTunnel, RightBearer, ProxyContext),
    trigger_request_finished(Response, Data),

    keep_state_and_data;

handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		Response0, #gtp{type = delete_session_request}, _State,
		#{context := Context, left_tunnel := LeftTunnel, left_bearer := LeftBearer} = Data) ->
    ?LOG(debug, "Proxy Response ~p", [Response0]),

    Response =
	if is_record(Response0, gtp) ->
		Response0;
	   true ->
		#gtp{version = v2,
		     type = delete_session_response,
		     ie = #{?'Cause' => #v2_cause{v2_cause = request_accepted}}}
	end,
    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    delete_forward_session(normal, Data),
    {next_state, shutdown, Data};

%%
%% SGW to PGW delete bearer response
%%
handle_response(#proxy_request{direction = pgw2sgw} = ProxyRequest,
		Response0, #gtp{type = delete_bearer_request}, _State,
		#{proxy_context := ProxyContext,
		  right_tunnel := RightTunnel, right_bearer := RightBearer} = Data) ->
    ?LOG(debug, "Proxy Response ~p", [Response0]),

    Response =
	if is_record(Response0, gtp) ->
		Response0;
	   true ->
		#context{default_bearer_id = EBI} = ProxyContext,
		#gtp{version = v2,
		     type = delete_bearer_response,
		     ie = #{?'Cause' => #v2_cause{v2_cause = request_accepted},
			    ?'EPS Bearer ID' =>
				#v2_eps_bearer_id{eps_bearer_id = EBI}}}
	end,
    forward_response(ProxyRequest, Response, RightTunnel, RightBearer, ProxyContext),
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

handle_proxy_info(Session, Tunnel, Bearer, Context, #{proxy_ds := ProxyDS}) ->
    PI = ergw_proxy_lib:proxy_info(Session, Tunnel, Bearer, Context),
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

init_proxy_tunnel(Socket, {_GwNode, PGW}) ->
    Info = ergw_gtp_socket:info(Socket),
    RightTunnel =
	ergw_gsn_lib:assign_tunnel_teid(
	  local, Info, ergw_gsn_lib:init_tunnel('Core', Info, Socket, v2)),
    RightTunnel#tunnel{remote = #fq_teid{ip = PGW}}.

init_proxy_context(#context{imei = IMEI, context_id = ContextId,
			    default_bearer_id = EBI, version = Version},
		   #{imsi := IMSI, msisdn := MSISDN, apn := DstAPN}) ->
    APN = ergw_node_selection:expand_apn(DstAPN, IMSI),

    #context{
       apn               = APN,
       imsi              = IMSI,
       imei              = IMEI,
       msisdn            = MSISDN,

       context_id        = ContextId,
       default_bearer_id = EBI,

       version           = Version
      }.

fq_teid(#fq_teid{ip = {_,_,_,_} = IP, teid = TEI}, IE) ->
    IE#v2_fully_qualified_tunnel_endpoint_identifier{
       key = TEI, ipv4 = ergw_inet:ip2bin(IP)};
fq_teid(#fq_teid{ip = {_,_,_,_,_,_,_,_} = IP, teid = TEI}, IE) ->
    IE#v2_fully_qualified_tunnel_endpoint_identifier{
      key = TEI, ipv6 = ergw_inet:ip2bin(IP)}.

set_bearer(#bearer{local = FqTEID},
	   _, #v2_fully_qualified_tunnel_endpoint_identifier{
		 interface_type = ?'S5/S8-U SGW'} = IE)
  when is_record(FqTEID, fq_teid) ->
    fq_teid(FqTEID, IE);
set_bearer(#bearer{local = FqTEID},
	   _, #v2_fully_qualified_tunnel_endpoint_identifier{
		 interface_type = ?'S5/S8-U PGW'} = IE)
  when is_record(FqTEID, fq_teid) ->
    fq_teid(FqTEID, IE);
set_bearer(_, _K, IE) ->
    IE.

set_req_from_context(_, _, #context{apn = APN},
		     _K, #v2_access_point_name{instance = 0} = IE)
  when is_list(APN) ->
    IE#v2_access_point_name{apn = APN};
set_req_from_context(_, _, #context{imsi = IMSI},
		  _K, #v2_international_mobile_subscriber_identity{instance = 0} = IE)
  when is_binary(IMSI) ->
    IE#v2_international_mobile_subscriber_identity{imsi = IMSI};
set_req_from_context(_, _, #context{msisdn = MSISDN},
		     _K, #v2_msisdn{instance = 0} = IE)
  when is_binary(MSISDN) ->
    IE#v2_msisdn{msisdn = MSISDN};
set_req_from_context(#tunnel{local = FqTEID}, _, _,
		     _K, #v2_fully_qualified_tunnel_endpoint_identifier{
			    interface_type = ?'S5/S8-C SGW'} = IE)
  when is_record(FqTEID, fq_teid) ->
    fq_teid(FqTEID, IE);
set_req_from_context(#tunnel{local = FqTEID}, _, _,
		     _K, #v2_fully_qualified_tunnel_endpoint_identifier{
			    interface_type = ?'S5/S8-C PGW'} = IE)
  when is_record(FqTEID, fq_teid) ->
    fq_teid(FqTEID, IE);
set_req_from_context(_, Bearer, _,
		     _K, #v2_bearer_context{instance = 0, group = BearerGroup} = IE) ->
    IE#v2_bearer_context{group = maps:map(set_bearer(Bearer, _, _), BearerGroup)};
set_req_from_context(_, _, _, _K, IE) ->
    IE.

update_gtp_req_from_context(Tunnel, Bearer, Context, GtpReqIEs) ->
    maps:map(set_req_from_context(Tunnel, Bearer, Context, _, _), GtpReqIEs).

build_context_request(#tunnel{remote = #fq_teid{teid = TEI}} = Tunnel, Bearer,
		      Context, NewPeer, SeqNo,
		      #gtp{type = Type, ie = RequestIEs} = Request) ->
    ProxyIEs0 = maps:without([?'Recovery'], RequestIEs),
    ProxyIEs1 = update_gtp_req_from_context(Tunnel, Bearer, Context, ProxyIEs0),
    ProxyIEs = gtp_v2_c:build_recovery(Type, Tunnel, NewPeer, ProxyIEs1),
    Request#gtp{tei = TEI, seq_no = SeqNo, ie = ProxyIEs}.

msg(#tunnel{remote = #fq_teid{teid = RemoteCntlTEI}}, Type, RequestIEs) ->
    #gtp{version = v2, type = Type, tei = RemoteCntlTEI, ie = RequestIEs}.

send_request(Tunnel, DstIP, DstPort, T3, N3, Msg) ->
    gtp_context:send_request(Tunnel, DstIP, DstPort, T3, N3, Msg, undefined).

send_request(#tunnel{remote = #fq_teid{ip = RemoteCntlIP}} = Tunnel, T3, N3, Msg) ->
    send_request(Tunnel, RemoteCntlIP, ?GTP2c_PORT, T3, N3, Msg).

send_request(Tunnel, T3, N3, Type, RequestIEs) ->
    send_request(Tunnel, T3, N3, msg(Tunnel, Type, RequestIEs)).

initiate_session_teardown(sgw2pgw,
			  #{right_tunnel := Tunnel,
			    proxy_context := #context{default_bearer_id = EBI}}) ->
    Type = delete_session_request,
    RequestIEs0 = [#v2_cause{v2_cause = network_failure},
		   #v2_eps_bearer_id{eps_bearer_id = EBI}],
    RequestIEs = gtp_v2_c:build_recovery(Type, Tunnel, false, RequestIEs0),
    send_request(Tunnel, ?T3, ?N3, Type, RequestIEs);
initiate_session_teardown(pgw2sgw,
			  #{left_tunnel := Tunnel,
			    context := #context{default_bearer_id = EBI}}) ->
    Type = delete_bearer_request,
    RequestIEs0 = [#v2_cause{v2_cause = reactivation_requested},
		   #v2_eps_bearer_id{eps_bearer_id = EBI}],
    RequestIEs = gtp_v2_c:build_recovery(Type, Tunnel, false, RequestIEs0),
    send_request(Tunnel, ?T3, ?N3, Type, RequestIEs).

bind_forward_path(sgw2pgw, Request,
		  #{left_tunnel := LeftTunnel, right_tunnel := RightTunnel} = Data) ->
    Data#{left_tunnel => gtp_path:bind(Request, LeftTunnel),
	  right_tunnel => gtp_path:bind(RightTunnel)};
bind_forward_path(pgw2sgw, Request,
		  #{left_tunnel := LeftTunnel, right_tunnel := RightTunnel} = Data) ->
    Data#{left_tunnel => gtp_path:bind(LeftTunnel),
	  right_tunnel => gtp_path:bind(Request, RightTunnel)}.

forward_request(Direction, ReqKey, #gtp{seq_no = ReqSeqNo, ie = ReqIEs} = Request,
		Tunnel, Bearer, Context,
		#{last_trigger_id := {ReqSeqNo, LastFwdSeqNo, SrcIP, SrcPort, _}}, Data) ->
    FwdReq = build_context_request(Tunnel, Bearer, Context, false, LastFwdSeqNo, Request),
    ergw_proxy_lib:forward_request(Direction, Tunnel, SrcIP, SrcPort, FwdReq, ReqKey,
				   ReqSeqNo, is_map_key(?'Recovery', ReqIEs), Data);

forward_request(Direction, ReqKey, #gtp{seq_no = ReqSeqNo, ie = ReqIEs} = Request,
		Tunnel, Bearer, Context, _, Data) ->
    FwdReq = build_context_request(Tunnel, Bearer, Context, false, undefined, Request),
    ergw_proxy_lib:forward_request(Direction, Tunnel, FwdReq, ReqKey,
				   ReqSeqNo, is_map_key(?'Recovery', ReqIEs), Data).

trigger_request(Tunnel, #request{ip = SrcIP, port = SrcPort} = ReqKey,
		#gtp{seq_no = SeqNo} = Request, Data) ->
    case ergw_proxy_lib:get_seq_no(Tunnel, ReqKey, Request) of
	{ok, FwdSeqNo} ->
	    Data#{last_trigger_id => {FwdSeqNo, SeqNo, SrcIP, SrcPort, ReqKey}};
	_ ->
	    Data
    end.

trigger_request_finished(#gtp{seq_no = SeqNo},
			 #{last_trigger_id :=
			       {_, SeqNo, _, _, CommandReqKey}}) ->
    gtp_context:request_finished(CommandReqKey);
trigger_request_finished(_, _) ->
    ok.

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


close_context(Side, TermCause, Data) ->
    case Side of
	left ->
	    initiate_session_teardown(sgw2pgw, Data);
	right ->
	    initiate_session_teardown(pgw2sgw, Data);
	both ->
	    initiate_session_teardown(sgw2pgw, Data),
	    initiate_session_teardown(pgw2sgw, Data)
    end,
    delete_forward_session(TermCause, Data).

delete_context(From, TermCause, Data) ->
    initiate_session_teardown(sgw2pgw, Data),
    initiate_session_teardown(pgw2sgw, Data),
    delete_forward_session(TermCause, Data),
    Action = case From of
		 undefined -> [];
		 _ -> [{reply, From, ok}]
	     end,
    %% TDB: {next_state, shutdown_initiated, Data}. ????
    {next_state, shutdown, Data, Action}.
