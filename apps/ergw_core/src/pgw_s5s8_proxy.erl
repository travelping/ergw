%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8_proxy).

-behaviour(gtp_api).

%% interim measure, to make refactoring simpler
-compile([export_all, nowarn_export_all]).
-ignore_xref([?MODULE]).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([validate_options/1, init/2, request_spec/3,
	 handle_pdu/4,
	 handle_request/5, handle_response/5,
	 handle_event/4, terminate/3]).

-export([delete_context/4, close_context/5]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").
-include("pgw_s5s8.hrl").

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
     {?'APN-AMBR',					mandatory}];
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

-define(HandlerDefaults, [{protocol, undefined}]).

validate_options(Opts) ->
    ?LOG(debug, "PGW S5/S8 Options: ~p", [Opts]),
    ergw_proxy_lib:validate_options(fun validate_option/2, Opts, ?HandlerDefaults).

validate_option(Opt, Value) ->
    ergw_proxy_lib:validate_option(Opt, Value).

init(#{proxy_sockets := ProxySockets, node_selection := NodeSelect,
       proxy_data_source := ProxyDS, contexts := Contexts},
     #{bearer := #{right := RightBearer} = Bearer} = Data0) ->

    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),

    Data = Data0#{proxy_sockets => ProxySockets,
		  'Version' => v2,
		  'Session' => Session,
		  contexts => Contexts,
		  node_selection => NodeSelect,
		  bearer => Bearer#{right => RightBearer#bearer{interface = 'Core'}},
		  proxy_ds => ProxyDS},
    {ok, ergw_context:init_state(), Data}.

handle_event(Type, Content, State, #{'Version' := v1} = Data) ->
    ?GTP_v1_Interface:handle_event(Type, Content, State, Data);

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event(cast, {packet_in, _Socket, _IP, _Port, _Msg}, _State, _Data) ->
    ?LOG(warning, "packet_in not handled (yet): ~p", [_Msg]),
    keep_state_and_data;

handle_event(info, {timeout, _, {delete_session_request, Direction, _ReqKey, _Request}},
	     State, Data0) ->
    ?LOG(warning, "Proxy Delete Session Timeout ~p", [Direction]),

    Data = delete_forward_session(normal, Data0),
    {next_state, State#{session := shutdown}, Data};

handle_event(info, {timeout, _, {delete_bearer_request, Direction, _ReqKey, _Request}},
	     State, Data0) ->
    ?LOG(warning, "Proxy Delete Bearer Timeout ~p", [Direction]),

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

handle_request(ReqKey, #gtp{type = create_session_request} = Request, Resent,
	       #{session := SState} = State, Data)
  when SState == init; SState == connecting ->
    pgw_s5s8_proxy_create_session:create_session(ReqKey, Request, Resent, State, Data);

handle_request(ReqKey, #gtp{type = modify_bearer_request} = Request, Resent,
	       #{session := connected} = State, #{left_tunnel := LeftTunnel} = Data)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, LeftTunnel) ->
    pgw_s5s8_proxy_modify_bearer:modify_bearer(ReqKey, Request, Resent, State, Data);

handle_request(ReqKey,
	       #gtp{type = modify_bearer_command} = Request,
	       _Resent, #{session := connected},
	       #{proxy_context := ProxyContext, left_tunnel := LeftTunnel,
		 bearer := #{right := RightBearer}} = Data0)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, LeftTunnel) ->
    {Lease, RightTunnel, Data1} = forward_activity(sgw2pgw, Request, Data0),
    forward_request(sgw2pgw, ReqKey, Request, RightTunnel, Lease, RightBearer, ProxyContext, Data1, Data1),

    Data = trigger_request(RightTunnel, ReqKey, Request, Data1),
    {keep_state, Data};

%%
%% SGW to PGW requests without tunnel endpoint modification
%%
handle_request(ReqKey,
	       #gtp{type = change_notification_request} = Request,
	       _Resent, #{session := connected},
	       #{proxy_context := ProxyContext, left_tunnel := LeftTunnel,
		 bearer := #{right := RightBearer}} = Data)
  when ?IS_REQUEST_TUNNEL_OPTIONAL_TEI(ReqKey, Request, LeftTunnel) ->
    {Lease, RightTunnel, DataNew} = forward_activity(sgw2pgw, Request, Data),
    forward_request(sgw2pgw, ReqKey, Request, RightTunnel, Lease, RightBearer, ProxyContext, DataNew, Data),

    {keep_state, DataNew};

%%
%% SGW to PGW notifications without tunnel endpoint modification
%%
handle_request(ReqKey,
	       #gtp{type = Type} = Request,
	       _Resent, #{session := connected},
	       #{proxy_context := ProxyContext, left_tunnel := LeftTunnel,
		 bearer := #{right := RightBearer}} = Data)
  when (Type == suspend_notification orelse
	Type == resume_notification) andalso
       ?IS_REQUEST_TUNNEL(ReqKey, Request, LeftTunnel) ->
    {Lease, RightTunnel, DataNew} = forward_activity(sgw2pgw, Request, Data),
    forward_request(sgw2pgw, ReqKey, Request, RightTunnel, Lease, RightBearer, ProxyContext, DataNew, Data),

    {keep_state, Data};

%%
%% PGW to SGW requests without tunnel endpoint modification
%%
handle_request(ReqKey,
	       #gtp{type = update_bearer_request} = Request,
	       _Resent, #{session := connected},
	       #{context := Context, right_tunnel := RightTunnel,
		 bearer := #{left := LeftBearer}} = Data0)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, RightTunnel) ->
    {Lease, LeftTunnel, Data} = forward_activity(pgw2sgw, Request, Data0),
    forward_request(pgw2sgw, ReqKey, Request, LeftTunnel, Lease, LeftBearer, Context, Data, Data),

    {keep_state, Data};

%%
%% SGW to PGW delete session requests
%%
handle_request(ReqKey,
	       #gtp{type = delete_session_request} = Request,
	       _Resent, #{session := connected},
	       #{proxy_context := ProxyContext, left_tunnel := LeftTunnel,
		 bearer := #{right := RightBearer}} = Data0)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, LeftTunnel) ->
    {Lease, RightTunnel, Data1} = forward_activity(sgw2pgw, Request, Data0),
    forward_request(sgw2pgw, ReqKey, Request, RightTunnel, Lease, RightBearer, ProxyContext, Data0, Data1),

    Msg = {delete_session_request, sgw2pgw, ReqKey, Request},
    Data = restart_timeout(?RESPONSE_TIMEOUT, Msg, Data1),

    {keep_state, Data};

%%
%% PGW to SGW delete bearer requests
%%
handle_request(ReqKey,
	       #gtp{type = delete_bearer_request} = Request,
	       _Resent, _State,
	       #{context := Context, right_tunnel := RightTunnel,
		 bearer := #{left := LeftBearer}} = Data0)
  when ?IS_REQUEST_TUNNEL(ReqKey, Request, RightTunnel) ->
    {Lease, LeftTunnel, Data1} = forward_activity(pgw2sgw, Request, Data0),
    forward_request(pgw2sgw, ReqKey, Request, LeftTunnel, Lease, LeftBearer, Context, Data0, Data1),

    Msg = {delete_bearer_request, pgw2sgw, ReqKey, Request},
    Data = restart_timeout(?RESPONSE_TIMEOUT, Msg, Data1),

    {keep_state, Data};

handle_request(_ReqKey, _Request, _Resent, #{session := connecting}, _Data) ->
    {keep_state_and_data, [postpone]};

handle_request(ReqKey, _Request, _Resent, _State, _Data) ->
    gtp_context:request_finished(ReqKey),
    keep_state_and_data.

handle_response(ReqInfo, #gtp{version = v1} = Msg, Request, State, Data) ->
    ?GTP_v1_Interface:handle_response(ReqInfo, Msg, Request, State, Data);

handle_response(ProxyRequest, _Response, _Request, #{session := shutdown}, Data) ->
    forward_request_done(ProxyRequest, Data),
    keep_state_and_data;

handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		timeout, #gtp{type = create_session_request}, #{session := SState}, Data)
  when SState == connected; SState == connecting ->
    forward_request_done(ProxyRequest, Data),
    keep_state_and_data;

handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		#gtp{type = create_session_response} = Response, Request, State, Data) ->
    forward_request_done(ProxyRequest, Data),
    pgw_s5s8_proxy_create_session:create_session_response(ProxyRequest, Response, Request,
							  State, Data);

handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		#gtp{type = modify_bearer_response} = Response, Request, State, Data) ->
    forward_request_done(ProxyRequest, Data),
    pgw_s5s8_proxy_modify_bearer:modify_bearer_response(ProxyRequest, Response, Request,
							State, Data);
%%
%% PGW to SGW response without tunnel endpoint modification
%%
handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		#gtp{type = change_notification_response} = Response,
		_Request, _State,
		#{context := Context, left_tunnel := LeftTunnel,
		  bearer := #{left := LeftBearer}} = Data) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),

    forward_request_done(ProxyRequest, Data),
    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    {keep_state, Data};

%%
%% PGW to SGW acknowledge without tunnel endpoint modification
%%
handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		#gtp{type = Type} = Response,
		_Request, _State,
		#{context := Context, left_tunnel := LeftTunnel,
		  bearer := #{left := LeftBearer}} = Data)
  when Type == suspend_acknowledge;
       Type == resume_acknowledge ->
    ?LOG(debug, "OK Proxy Acknowledge ~p", [Response]),

    forward_request_done(ProxyRequest, Data),
    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    {keep_state, Data};

%%
%% SGW to PGW response without tunnel endpoint modification
%%
handle_response(#proxy_request{direction = pgw2sgw} = ProxyRequest,
		#gtp{type = update_bearer_response} = Response,
		_Request, _State,
		#{proxy_context := ProxyContext,
		  right_tunnel := RightTunnel, bearer := #{right := RightBearer}} = Data) ->
    ?LOG(debug, "OK Response ~p", [Response]),

    forward_request_done(ProxyRequest, Data),
    forward_response(ProxyRequest, Response, RightTunnel, RightBearer, ProxyContext),
    trigger_request_finished(Response, Data),

    {keep_state, Data};

handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		Response0, #gtp{type = delete_session_request}, State,
		#{context := Context, left_tunnel := LeftTunnel, bearer := #{left := LeftBearer}} = Data0) ->
    ?LOG(debug, "Proxy Response ~p", [Response0]),

    forward_request_done(ProxyRequest, Data0),
    Response =
	if is_record(Response0, gtp) ->
		Response0;
	   true ->
		#gtp{version = v2,
		     type = delete_session_response,
		     ie = #{?'Cause' => #v2_cause{v2_cause = request_accepted}}}
	end,
    forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    Data = delete_forward_session(normal, Data0),
    {next_state, State#{session := shutdown}, Data};

%%
%% SGW to PGW delete bearer response
%%
handle_response(#proxy_request{direction = pgw2sgw} = ProxyRequest,
		Response0, #gtp{type = delete_bearer_request}, State,
		#{proxy_context := ProxyContext,
		  right_tunnel := RightTunnel, bearer := #{right := RightBearer}} = Data0) ->
    ?LOG(debug, "Proxy Response ~p", [Response0]),

    forward_request_done(ProxyRequest, Data0),
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
    Data = delete_forward_session(normal, Data0),
    {next_state, State#{session := shutdown}, Data};

handle_response(#proxy_request{request = ReqKey} = ProxyRequest,
		Response, _Request, _State, Data) ->
    ?LOG(warning, "Unknown Proxy Response ~p", [Response]),

    forward_request_done(ProxyRequest, Data),
    gtp_context:request_finished(ReqKey),
    keep_state_and_data;

handle_response(_, _, #gtp{type = Type}, #{session := shutdown}, _)
  when Type =:= delete_bearer_request;
       Type =:= delete_session_request ->
    keep_state_and_data;

handle_response({Direction, From}, timeout, #gtp{type = Type},
		#{session := shutdown_initiated} = State, Data)
  when Type =:= delete_bearer_request;
       Type =:= delete_session_request ->
    session_teardown_response({error, timeout}, Direction, From, State, Data);

handle_response({Direction, From}, #gtp{type = Type}, _,
		#{session := shutdown_initiated} = State, Data)
  when Type =:= delete_bearer_response;
       Type =:= delete_session_response ->
    session_teardown_response(ok, Direction, From, State, Data).

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

delete_forward_session(Reason, #{pfcp := PCtx, 'Session' := Session} = Data) ->
    URRs = ergw_pfcp_context:delete_session(Reason, PCtx),
    SessionOpts = to_session(gtp_context:usage_report_to_accounting(URRs)),
    ?LOG(debug, "Accounting Opts: ~p", [SessionOpts]),
    ergw_aaa_session:invoke(Session, SessionOpts, stop, #{async => true}),
    maps:remove(pfcp, Data).

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

send_request(Tunnel, DstIP, DstPort, T3, N3, Msg, ReqInfo) ->
    gtp_context:send_request(Tunnel, any, DstIP, DstPort, T3, N3, Msg, ReqInfo).

send_request(#tunnel{remote = #fq_teid{ip = RemoteCntlIP}} = Tunnel, T3, N3, Msg, ReqInfo) ->
    send_request(Tunnel, RemoteCntlIP, ?GTP2c_PORT, T3, N3, Msg, ReqInfo).

send_request(Tunnel, T3, N3, Type, RequestIEs, ReqInfo) ->
    send_request(Tunnel, T3, N3, msg(Tunnel, Type, RequestIEs), ReqInfo).

initiate_session_teardown(sgw2pgw = Direction, From, #{session := connected},
			  #{right_tunnel := Tunnel,
			    proxy_context := #context{default_bearer_id = EBI}} = Data) ->
    Type = delete_session_request,
    RequestIEs0 = [#v2_cause{v2_cause = network_failure},
		   #v2_eps_bearer_id{eps_bearer_id = EBI}],
    RequestIEs = gtp_v2_c:build_recovery(Type, Tunnel, false, RequestIEs0),
    {ok, {Lease, _}} = gtp_path:aquire_lease(Tunnel),
    send_request(Tunnel, ?T3, ?N3, Type, RequestIEs, {Direction, Lease, From}),
    maps:update_with(shutdown, [Direction|_], [Direction], Data);
initiate_session_teardown(pgw2sgw = Direction, From, #{session := SState},
			  #{left_tunnel := Tunnel,
			    context := #context{default_bearer_id = EBI}} = Data)
  when SState == connected; SState == connecting ->
    Type = delete_bearer_request,
    RequestIEs0 = [#v2_cause{v2_cause = reactivation_requested},
		   #v2_eps_bearer_id{eps_bearer_id = EBI}],
    RequestIEs = gtp_v2_c:build_recovery(Type, Tunnel, false, RequestIEs0),
    {ok, {Lease, _}} = gtp_path:aquire_lease(Tunnel),
    send_request(Tunnel, ?T3, ?N3, Type, RequestIEs, {Direction, Lease, From}),
    maps:update_with(shutdown, [Direction|_], [Direction], Data);
initiate_session_teardown(_, _, _, Data) ->
    Data.

session_teardown_response(Answer, Direction, From, State, #{shutdown := Shutdown0} = Data0) ->
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

forward_activity(sgw2pgw, _Request, #{right_tunnel := RightTunnel0} = Data) ->
    {ok, {Lease, RightTunnel}} = gtp_path:aquire_lease(RightTunnel0),
    {Lease, RightTunnel, Data#{right_tunnel => RightTunnel}};
forward_activity(pgw2sgw, _Request, #{left_tunnel := LeftTunnel0} = Data) ->
    {ok, {Lease, LeftTunnel}} = gtp_path:aquire_lease(LeftTunnel0),
    {Lease, LeftTunnel, Data#{left_tunnel => LeftTunnel}}.

forward_request(Direction, ReqKey, #gtp{seq_no = ReqSeqNo, ie = ReqIEs} = Request,
		Tunnel, Lease, Bearer, Context,
		#{last_trigger_id :=
		      {ReqSeqNo, LastFwdSeqNo, Src, IP, Port, _}}, Data) ->
    FwdReq = build_context_request(Tunnel, Bearer, Context, false, LastFwdSeqNo, Request),
    ergw_proxy_lib:forward_request(Direction, Tunnel, Lease, Src,IP, Port, FwdReq, ReqKey,
				   ReqSeqNo, is_map_key(?'Recovery', ReqIEs), Data);

forward_request(Direction, ReqKey, #gtp{seq_no = ReqSeqNo, ie = ReqIEs} = Request,
		Tunnel, Lease, Bearer, Context, _, Data) ->
    FwdReq = build_context_request(Tunnel, Bearer, Context, false, undefined, Request),
    ergw_proxy_lib:forward_request(Direction, Tunnel, Lease, any, FwdReq, ReqKey,
				   ReqSeqNo, is_map_key(?'Recovery', ReqIEs), Data).

forward_request_done(#proxy_request{direction = Direction, lease = Lease}, Data) ->
    forward_request_done(Direction, Lease, Data);
forward_request_done({Direction, Lease, _}, Data)
 when is_atom(Direction), is_reference(Lease) ->
    forward_request_done(Direction, Lease, Data).

forward_request_done(sgw2pgw, Lease, #{right_tunnel := RightTunnel}) ->
    gtp_path:release_lease(Lease, RightTunnel);
forward_request_done(pgw2sgw, Lease, #{left_tunnel := LeftTunnel}) ->
    gtp_path:release_lease(Lease, LeftTunnel).

trigger_request(Tunnel, #request{src = Src, ip = IP, port = Port} = ReqKey,
		#gtp{seq_no = SeqNo} = Request, Data) ->
    case ergw_proxy_lib:get_seq_no(Tunnel, ReqKey, Request) of
	{ok, FwdSeqNo} ->
	    Data#{last_trigger_id => {FwdSeqNo, SeqNo, Src, IP, Port, ReqKey}};
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
	    initiate_session_teardown(sgw2pgw, undefined, State, Data);
	right ->
	    initiate_session_teardown(pgw2sgw, undefined, State, Data);
	both ->
	    initiate_session_teardown(sgw2pgw, undefined, State, Data),
	    initiate_session_teardown(pgw2sgw, undefined, State, Data)
    end,
    delete_forward_session(TermCause, Data);
close_context(_Side, TermCause, silent, #{session := SState}, Data)
  when SState == connected; SState == connecting ->
    delete_forward_session(TermCause, Data);
close_context(_, _, _, _, Data) ->
    Data.

delete_context(From, TermCause, #{session := SState} = State, Data0)
  when SState == connected; SState == connecting ->
    Data1 = initiate_session_teardown(sgw2pgw, From, State, Data0),
    Data2 = initiate_session_teardown(pgw2sgw, From, State, Data1),
    Data = delete_forward_session(TermCause, Data2),
    {next_state, State#{session := shutdown_initiated}, Data};
delete_context(undefined, _, _, _) ->
    keep_state_and_data;
delete_context(From, _, _, _) ->
    {keep_state_and_data, [{reply, From, ok}]}.
