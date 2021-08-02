%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn_proxy).

-behaviour(gtp_api).

%% interim measure, to make refactoring simpler
-compile([export_all, nowarn_export_all]).
-ignore_xref([?MODULE]).

-compile({parse_transform, cut}).

-export([validate_options/1, init/2, request_spec/3,
	 handle_pdu/4,
	 handle_request/5, handle_response/5,
	 handle_event/4, terminate/3]).

-export([delete_context/4, close_context/5]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").
-include("ggsn_gn.hrl").

-import(ergw_aaa_session, [to_session/1]).

-compile([nowarn_unused_record]).

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

%%====================================================================
%% API
%%====================================================================

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

-define(HandlerDefaults, [{protocol, undefined}]).

validate_options(Opts) ->
    ?LOG(debug, "GGSN Gn/Gp Options: ~p", [Opts]),
    ergw_proxy_lib:validate_options(fun validate_option/2, Opts, ?HandlerDefaults).

validate_option(Opt, Value) ->
    ergw_proxy_lib:validate_option(Opt, Value).

init(#{proxy_sockets := ProxySockets, node_selection := NodeSelect,
       proxy_data_source := ProxyDS, contexts := Contexts},
     #{bearer := #{right := RightBearer} = Bearer} = Data0) ->

    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),

    Data = Data0#{proxy_sockets => ProxySockets,
		  'Version' => v1,
		  'Session' => Session,
		  contexts => Contexts,
		  node_selection => NodeSelect,
		  bearer => Bearer#{right => RightBearer#bearer{interface = 'Core'}},
		  proxy_ds => ProxyDS},
    {ok, ergw_context:init_state(), Data}.

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event(cast, {packet_in, _Socket, _IP, _Port, _Msg}, _State, _Data) ->
    ?LOG(warning, "packet_in not handled (yet): ~p", [_Msg]),
    keep_state_and_data;

handle_event(info, {timeout, _, {delete_pdp_context_request, Direction, _ReqKey, _Request}},
	     State, Data0) ->
    ?LOG(warning, "Proxy Delete PDP Context Timeout ~p", [Direction]),

    Data = delete_forward_session(normal, Data0),
    {next_state, State#{session := shutdown}, Data};

handle_event(info, _Info, _State, _Data) ->
    keep_state_and_data;

handle_event(state_timeout, #proxy_request{} = ReqKey,
	     #{session := connecting} = State, Data0) ->
    gtp_context:request_finished(ReqKey),
    Data = delete_forward_session(normal, Data0),
    {next_state, State#{session := shutdown}, Data};

handle_event(state_timeout, _, #{session := connecting} = State, Data0) ->
    Data = delete_forward_session(normal, Data0),
    {next_state, State#{session := shutdown}, Data}.

handle_pdu(ReqKey, Msg, _State, Data) ->
    ?LOG(debug, "GTP-U v1 Proxy: ~p, ~p",
		[ReqKey, gtp_c_lib:fmt_gtp(Msg)]),
    {keep_state, Data}.

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
handle_request(ReqKey, #gtp{type = create_pdp_context_request} = Request, true,
	       _State, #{right_tunnel := RightTunnel}) ->
    ergw_proxy_lib:forward_request(RightTunnel, ReqKey, Request),
    keep_state_and_data;
handle_request(ReqKey, #gtp{type = ms_info_change_notification_request} = Request, true,
	       _State, #{left_tunnel := LeftTunnel, right_tunnel := RightTunnel})
  when ?IS_REQUEST_TUNNEL_OPTIONAL_TEI(ReqKey, Request, LeftTunnel) ->
    ergw_proxy_lib:forward_request(RightTunnel, ReqKey, Request),
    keep_state_and_data;

handle_request(_ReqKey, _Request, true, _State, _Data) ->
    ?LOG(error, "resend of request not handled ~p, ~p",
		[_ReqKey, gtp_c_lib:fmt_gtp(_Request)]),
    keep_state_and_data;

handle_request(ReqKey, #gtp{type = create_pdp_context_request} = Request, Resent,
	       #{session := SState} = State, Data)
  when SState == init; SState == connecting ->
    ggsn_gn_proxy_create_pdp_context:create_pdp_context(ReqKey, Request, Resent, State, Data);

handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request} = Request,
	       _Resent, #{session := connected},
	       #{proxy_context := ProxyContext,
		 left_tunnel := LeftTunnelOld, right_tunnel := RightTunnelOld,
		 bearer := #{left := LeftBearerOld, right := RightBearer} = Bearer} = Data)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, LeftTunnelOld) ->
    {LeftTunnel0, LeftBearer} =
	case ggsn_gn:update_tunnel_from_gtp_req(
	       Request, LeftTunnelOld#tunnel{version = v1}, LeftBearerOld) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{tunnel = LeftTunnelOld})
	end,
    LeftTunnel = ergw_gtp_gsn_lib:update_tunnel_endpoint(LeftTunnelOld, LeftTunnel0),

    RightTunnel0 = ergw_gtp_gsn_lib:handle_peer_change(
		     LeftTunnel, LeftTunnelOld, RightTunnelOld#tunnel{version = v1}),
    RightTunnel1 = ergw_gtp_gsn_lib:update_tunnel_endpoint(RightTunnelOld, RightTunnel0),
    {ok, {Lease, RightTunnel}} = gtp_path:aquire_lease(RightTunnel1),

    DataNew =
	Data#{left_tunnel => LeftTunnel, right_tunnel => RightTunnel,
	      bearer => Bearer#{left => LeftBearer}},

    forward_request(sgsn2ggsn, ReqKey, Request, RightTunnel, Lease, RightBearer, ProxyContext, Data),

    {keep_state, DataNew};

%%
%% GGSN to SGW Update PDP Context Request
%%
handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request} = Request,
	       _Resent, #{session := connected},
	       #{context := Context, right_tunnel := RightTunnel,
		 bearer := #{left := LeftBearer}} = Data)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, RightTunnel) ->
    {Lease, LeftTunnel, DataNew} = forward_activity(ggsn2sgsn, Request, Data),
    forward_request(ggsn2sgsn, ReqKey, Request, LeftTunnel, Lease, LeftBearer, Context, Data),

    {keep_state, DataNew};

handle_request(ReqKey,
	       #gtp{type = ms_info_change_notification_request} = Request,
	       _Resent, #{session := connected},
	       #{proxy_context := ProxyContext, left_tunnel := LeftTunnel,
		 bearer := #{right := RightBearer}} = Data)
  when ?IS_REQUEST_TUNNEL_OPTIONAL_TEI(ReqKey, Request, LeftTunnel) ->
    {Lease, RightTunnel, DataNew} = forward_activity(sgsn2ggsn, Request, Data),
    forward_request(sgsn2ggsn, ReqKey, Request, RightTunnel, Lease, RightBearer, ProxyContext, Data),

    {keep_state, DataNew};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request} = Request,
	       _Resent, #{session := connected},
	       #{proxy_context := ProxyContext, left_tunnel := LeftTunnel,
		 bearer := #{right := RightBearer}} = Data0)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, LeftTunnel) ->
    {Lease, RightTunnel, Data1} = forward_activity(sgsn2ggsn, Request, Data0),
    forward_request(sgsn2ggsn, ReqKey, Request, RightTunnel, Lease, RightBearer, ProxyContext, Data1),

    Msg = {delete_pdp_context_request, sgsn2ggsn, ReqKey, Request},
    Data = restart_timeout(?RESPONSE_TIMEOUT, Msg, Data1),

    {keep_state, Data};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request} = Request,
	       _Resent, #{session := connected},
	       #{context := Context, right_tunnel := RightTunnel,
		 bearer := #{left := LeftBearer}} = Data0)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, RightTunnel) ->
    {Lease, LeftTunnel, Data1} = forward_activity(ggsn2sgsn, Request, Data0),
    forward_request(ggsn2sgsn, ReqKey, Request, LeftTunnel, Lease, LeftBearer, Context, Data1),

    Msg = {delete_pdp_context_request, ggsn2sgsn, ReqKey, Request},
    Data = restart_timeout(?RESPONSE_TIMEOUT, Msg, Data1),

    {keep_state, Data};

handle_request(#request{socket = Socket} = ReqKey, Msg, _Resent, _State, _Data) ->
    ?LOG(warning, "Unknown Proxy Message on ~p: ~p", [Socket, Msg]),
    gtp_context:request_finished(ReqKey),
    keep_state_and_data.

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		timeout, #gtp{type = create_session_request},
		#{session := SState}, Data)
  when SState == connected; SState == connecting ->
    forward_request_done(ProxyRequest, Data),
    keep_state_and_data;

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = create_pdp_context_response,
		     ie = #{?'Cause' := #cause{value = Cause}}} = Response,
		_Request, State,
		#{context := Context, proxy_context := PrevProxyCtx, pfcp := PCtx0,
		  left_tunnel := LeftTunnel, right_tunnel := RightTunnel0,
		  bearer := #{left := LeftBearer, right := RightBearer0} = Bearer0} = Data0) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    forward_request_done(ProxyRequest, Data0),
    {RightTunnel1, RightBearer} =
	case ggsn_gn:update_tunnel_from_gtp_req(Response, RightTunnel0, RightBearer0) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{tunnel = LeftTunnel})
	end,
    RightTunnel =
	case gtp_path:bind_tunnel(RightTunnel1) of
	    {ok, RT} -> RT;
	    {error, Err1a} -> throw(Err1a#ctx_err{context = Context, tunnel = RightTunnel1})
	end,
    Bearer = Bearer0#{right := RightBearer},

    ProxyContext = ggsn_gn:update_context_from_gtp_req(Response, PrevProxyCtx),

    gtp_context:remote_context_register(RightTunnel, Bearer, ProxyContext),

    Return =
	if ?CAUSE_OK(Cause) ->
		PCC = ergw_proxy_lib:proxy_pcc(),
		{PCtx, _, _} =
		    case ergw_pfcp_context:modify_session(PCC, [], #{}, Bearer, PCtx0) of
			{ok, Result2} -> Result2;
			{error, Err2} -> throw(Err2#ctx_err{tunnel = LeftTunnel})
		    end,
		Data =
		    Data0#{proxy_context => ProxyContext, pfcp => PCtx,
			  right_tunnel => RightTunnel, bearer => Bearer},
		{next_state, State#{session := connected}, Data};
	   true ->
		Data = delete_forward_session(normal, Data0),
		{next_state, State#{session := shutdown}, Data}
	end,

    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    Return;

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = update_pdp_context_response} = Response,
		_Request, _State,
		#{context := Context, proxy_context := ProxyContextOld, pfcp := PCtxOld,
		  left_tunnel := LeftTunnel, right_tunnel := RightTunnelOld,
		  bearer := #{left := LeftBearer, right := RightBearerOld} = Bearer0} = Data) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    forward_request_done(ProxyRequest, Data),
    {RightTunnel0, RightBearer} =
	case ggsn_gn:update_tunnel_from_gtp_req(Response, RightTunnelOld, RightBearerOld) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{tunnel = LeftTunnel})
	end,
    RightTunnel = ergw_gtp_gsn_lib:update_tunnel_endpoint(RightTunnelOld, RightTunnel0),
    Bearer = Bearer0#{right := RightBearer},

    ProxyContext = ggsn_gn:update_context_from_gtp_req(Response, ProxyContextOld),

    gtp_context:remote_context_register(RightTunnel, Bearer, ProxyContext),

    PCC = ergw_proxy_lib:proxy_pcc(),
    {PCtx, _, _} =
	case ergw_pfcp_context:modify_session(PCC, [], #{}, Bearer, PCtxOld) of
	    {ok, Result2} -> Result2;
	    {error, Err2} -> throw(Err2#ctx_err{tunnel = LeftTunnel})
	end,

    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),

    DataNew =
	Data#{proxy_context => ProxyContext, pfcp => PCtx,
	      right_tunnel => RightTunnel, bearer => Bearer},
    {keep_state, DataNew};

handle_response(#proxy_request{direction = ggsn2sgsn} = ProxyRequest,
		#gtp{type = update_pdp_context_response} = Response,
		_Request, _State,
		#{proxy_context := ProxyContext,
		  right_tunnel := RightTunnel, bearer := #{right := RightBearer}} = Data) ->
    ?LOG(debug, "OK SGSN Response ~p", [Response]),

    forward_request_done(ProxyRequest, Data),
    forward_response(ProxyRequest, Response, RightTunnel, RightBearer, ProxyContext),
    {keep_state, Data};

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = ms_info_change_notification_response} = Response,
		_Request, _State,
		#{context := Context,
		  left_tunnel := LeftTunnel, bearer := #{left := LeftBearer}} = Data) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    forward_request_done(ProxyRequest, Data),
    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    {keep_state, Data};

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = delete_pdp_context_response} = Response,
		_Request, State,
		#{context := Context,
		  left_tunnel := LeftTunnel, bearer := #{left := LeftBearer}} = Data0) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    forward_request_done(ProxyRequest, Data0),
    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),

    Data1 = cancel_timeout(Data0),
    Data = delete_forward_session(normal, Data1),
    {next_state, State#{session := shutdown}, Data};

handle_response(#proxy_request{direction = ggsn2sgsn} = ProxyRequest,
		#gtp{type = delete_pdp_context_response} = Response,
		_Request, State,
		#{proxy_context := ProxyContext,
		  right_tunnel := RightTunnel, bearer := #{right := RightBearer}} = Data0) ->
    ?LOG(debug, "OK SGSN Response ~p", [Response]),

    forward_request_done(ProxyRequest, Data0),
    forward_response(ProxyRequest, Response, RightTunnel, RightBearer, ProxyContext),
    Data1 = cancel_timeout(Data0),
    Data = delete_forward_session(normal, Data1),
    {next_state, State#{session := shutdown}, Data};

handle_response(#proxy_request{request = ReqKey} = ProxyRequest,
		Response, _Request, _State, Data) ->
    ?LOG(warning, "Unknown Proxy Response ~p", [Response]),

    forward_request_done(ProxyRequest, Data),
    gtp_context:request_finished(ReqKey),
    keep_state_and_data;

handle_response(_, _, #gtp{type = delete_pdp_context_request},
		#{session := shutdown}, _) ->
    keep_state_and_data;

handle_response({Direction, _, From}, timeout, #gtp{type = delete_pdp_context_request},
		#{session := shutdown_initiated} = State, Data) ->
    pdp_context_teardown_response({error, timeout}, Direction, From, State, Data);

handle_response({Direction, _, From}, #gtp{type = delete_pdp_context_response},
		_Request, #{session := shutdown_initiated} = State, Data) ->
    pdp_context_teardown_response(ok, Direction, From, State, Data).

terminate(_Reason, _State, _Data) ->
    ok.

%%%===================================================================
%%% Internal functions
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

delete_forward_session(Reason, #{pfcp := PCtx, 'Session' := Session} = Data) ->
    URRs = ergw_pfcp_context:delete_session(Reason, PCtx),
    SessionOpts = to_session(gtp_context:usage_report_to_accounting(URRs)),
    ?LOG(debug, "Accounting Opts: ~p", [SessionOpts]),
    ergw_aaa_session:invoke(Session, SessionOpts, stop, #{async => true}),
    maps:remove(pfcp, Data).

init_proxy_tunnel(Socket, {_GwNode, GGSN}) ->
    Info = ergw_gtp_socket:info(Socket),
    RightTunnel =
	ergw_gsn_lib:assign_tunnel_teid(
	  local, Info, ergw_gsn_lib:init_tunnel('Core', Info, Socket, v1)),
    RightTunnel#tunnel{remote = #fq_teid{ip = GGSN}}.

init_proxy_context(#context{imei = IMEI, context_id = ContextId,
			    default_bearer_id = NSAPI, version = Version},
		   #{imsi := IMSI, msisdn := MSISDN, apn := DstAPN}) ->
    {APN, _OI} = ergw_node_selection:split_apn(DstAPN),

    #context{
       apn               = APN,
       imsi              = IMSI,
       imei              = IMEI,
       msisdn            = MSISDN,

       context_id        = ContextId,
       default_bearer_id = NSAPI,

       version           = Version
      }.

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

build_context_request(#tunnel{remote = #fq_teid{teid = TEI}} = Tunnel, Bearer,
		      Context, NewPeer, SeqNo,
		      #gtp{type = Type, ie = RequestIEs} = Request) ->
    ProxyIEs0 = maps:without([?'Recovery'], RequestIEs),
    ProxyIEs1 = update_gtp_req_from_context(Tunnel, Bearer, Context, ProxyIEs0),
    ProxyIEs = gtp_v1_c:build_recovery(Type, Tunnel, NewPeer, ProxyIEs1),
    Request#gtp{tei = TEI, seq_no = SeqNo, ie = ProxyIEs}.

msg(#tunnel{remote = #fq_teid{teid = RemoteCntlTEI}}, Type, RequestIEs) ->
    #gtp{version = v1, type = Type, tei = RemoteCntlTEI, ie = RequestIEs}.

send_request(Tunnel, DstIP, DstPort, T3, N3, Msg, ReqInfo) ->
    gtp_context:send_request(Tunnel, any, DstIP, DstPort, T3, N3, Msg, ReqInfo).

send_request(#tunnel{remote = #fq_teid{ip = RemoteCntlIP}} = Tunnel, T3, N3, Msg, ReqInfo) ->
    send_request(Tunnel, RemoteCntlIP, ?GTP2c_PORT, T3, N3, Msg, ReqInfo).

send_request(Tunnel, T3, N3, Type, RequestIEs, ReqInfo) ->
    send_request(Tunnel, T3, N3, msg(Tunnel, Type, RequestIEs), ReqInfo).

initiate_pdp_context_teardown(sgsn2ggsn = Direction, From, #{session := connected},
			      #{right_tunnel := Tunnel,
				proxy_context := #context{default_bearer_id = NSAPI}} = Data) ->
    Type = delete_pdp_context_request,
    RequestIEs0 = [#cause{value = request_accepted},
		   #teardown_ind{value = 1},
		   #nsapi{nsapi = NSAPI}],
    RequestIEs = gtp_v1_c:build_recovery(Type, Tunnel, false, RequestIEs0),
    {ok, {Lease, _}} = gtp_path:aquire_lease(Tunnel),
    send_request(Tunnel, ?T3, ?N3, Type, RequestIEs, {Direction, Lease, From}),
    maps:update_with(shutdown, [Direction|_], [Direction], Data);
initiate_pdp_context_teardown(ggsn2sgsn = Direction, From, #{session := SState},
			      #{left_tunnel := Tunnel,
				context := #context{default_bearer_id = NSAPI}} = Data)
  when SState == connected; SState == connecting ->
    Type = delete_pdp_context_request,
    RequestIEs0 = [#cause{value = request_accepted},
		   #teardown_ind{value = 1},
		   #nsapi{nsapi = NSAPI}],
    RequestIEs = gtp_v1_c:build_recovery(Type, Tunnel, false, RequestIEs0),
    {ok, {Lease, _}} = gtp_path:aquire_lease(Tunnel),
    send_request(Tunnel, ?T3, ?N3, Type, RequestIEs, {Direction, Lease, From}),
    maps:update_with(shutdown, [Direction|_], [Direction], Data);
initiate_pdp_context_teardown(_, _, _, Data) ->
    Data.

pdp_context_teardown_response(Answer, Direction, From,
			      State, #{shutdown := Shutdown0} = Data0) ->
    case lists:delete(Direction, Shutdown0) of
	[] ->
	    Action = case From of
			 undefined -> [];
			 _ -> [{reply, From, Answer}]
		     end,
	    Data = maps:remove(shutdown, Data0),
	    {next_state, State#{session := shutdown}, Data, Action};
	Shutdown ->
	    {keep_state, Data0#{shutdown => Shutdown}}
    end.

forward_activity(sgsn2ggsn, _Request, #{right_tunnel := RightTunnel0} = Data) ->
    {ok, {Lease, RightTunnel}} = gtp_path:aquire_lease(RightTunnel0),
    {Lease, RightTunnel, Data#{right_tunnel => RightTunnel}};
forward_activity(ggsn2sgsn, _Request, #{left_tunnel := LeftTunnel0} = Data) ->
    {ok, {Lease, LeftTunnel}} = gtp_path:aquire_lease(LeftTunnel0),
    {Lease, LeftTunnel, Data#{left_tunnel => LeftTunnel}}.

forward_request(Direction, ReqKey, #gtp{seq_no = ReqSeqNo, ie = ReqIEs} = Request,
		Tunnel, Lease, Bearer, Context, Data) ->
    FwdReq = build_context_request(Tunnel, Bearer, Context, false, undefined, Request),
    ergw_proxy_lib:forward_request(Direction, Tunnel, Lease, any, FwdReq, ReqKey,
				   ReqSeqNo, is_map_key(?'Recovery', ReqIEs), Data).

forward_request_done(#proxy_request{direction = Direction, lease = Lease}, Data) ->
    forward_request_done( Direction, Lease, Data);
forward_request_done({Direction, Lease, _}, Data)
 when is_atom(Direction), is_reference(Lease) ->
    forward_request_done(Direction, Lease, Data).

forward_request_done(sgsn2ggsn, Lease, #{right_tunnel := RightTunnel}) ->
    gtp_path:release_lease(Lease, RightTunnel);
forward_request_done(ggsn2sgsn, Lease, #{left_tunnel := LeftTunnel}) ->
    gtp_path:release_lease(Lease, LeftTunnel).

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

close_context(Side, TermCause, active, #{session := SState} = State, Data)
  when SState == connected; SState == connecting ->
    case Side of
	left ->
	    initiate_pdp_context_teardown(sgsn2ggsn, undefined, State, Data);
	right ->
	    initiate_pdp_context_teardown(ggsn2sgsn, undefined, State, Data);
	both ->
	    initiate_pdp_context_teardown(sgsn2ggsn, undefined, State, Data),
	    initiate_pdp_context_teardown(ggsn2sgsn, undefined, State, Data)
    end,
    delete_forward_session(TermCause, Data);
close_context(_Side, TermCause, silent, #{session := SState}, Data)
  when SState == connected; SState == connecting ->
    delete_forward_session(TermCause, Data);
close_context(_, _, _, _, Data) ->
    Data.

delete_context(From, TermCause, #{session := SState} = State, Data0)
  when SState == connected; SState == connecting ->
    Data1 = initiate_pdp_context_teardown(sgsn2ggsn, From, State, Data0),
    Data2 = initiate_pdp_context_teardown(ggsn2sgsn, From, State, Data1),
    Data = delete_forward_session(TermCause, Data2),
    {next_state, State#{session := shutdown_initiated}, Data};
delete_context(undefined, _, _, _) ->
    keep_state_and_data;
delete_context(From, _, _, _) ->
    {keep_state_and_data, [{reply, From, ok}]}.
