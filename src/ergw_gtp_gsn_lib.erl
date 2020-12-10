%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gtp_gsn_lib).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([connect_upf_candidates/4, create_session/10]).
-export([triggered_charging_event/4, usage_report/3, close_context/3]).
-export([update_tunnel_endpoint/3, handle_peer_change/3, update_tunnel_endpoint/2,
	 apply_bearer_change/5]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

%%====================================================================
%% Session Setup
%%====================================================================

connect_upf_candidates(APN, Services, NodeSelect, PeerUpNode) ->
    APN_FQDN = ergw_node_selection:apn_to_fqdn(APN),
    Candidates = ergw_node_selection:topology_select(APN_FQDN, PeerUpNode, Services, NodeSelect),
    SxConnectId = ergw_sx_node:request_connect(Candidates, NodeSelect, 1000),

    {ok, {Candidates, SxConnectId}}.

create_session(APN, PAA, DAF, UPSelInfo, Session, SessionOpts, Context, LeftTunnel, LeftBearer, PCC) ->
    try
	create_session_fun(APN, PAA, DAF, UPSelInfo, Session, SessionOpts, Context, LeftTunnel, LeftBearer, PCC)
    catch
	throw:Error ->
	    {error, Error}
    end.

create_session_fun(APN, PAA, DAF, {Candidates, SxConnectId}, Session,
		   SessionOpts0, Context0, LeftTunnel, LeftBearer, PCC0) ->

    ergw_sx_node:wait_connect(SxConnectId),

    APNOpts =
	case ergw_gsn_lib:apn(APN) of
	    {ok, Result2} -> Result2;
	    {error, Err2} -> throw(Err2#ctx_err{context = Context0, tunnel = LeftTunnel})
	end,

    {UPinfo, SessionOpts1} =
	case ergw_pfcp_context:select_upf(Candidates, SessionOpts0, APNOpts) of
	    {ok, Result3} -> Result3;
	    {error, Err3} -> throw(Err3#ctx_err{context = Context0, tunnel = LeftTunnel})
	end,

    {SessionOpts2, AuthSEvs} =
	case ergw_gtp_gsn_session:authenticate(Session, SessionOpts1) of
	    {ok, Result4} -> Result4;
	    {error, Err4} -> throw(Err4#ctx_err{context = Context0, tunnel = LeftTunnel})
	end,

    {PCtx0, NodeCaps, RightBearer0} =
	case ergw_pfcp_context:reselect_upf(Candidates, SessionOpts2, APNOpts, UPinfo) of
	    {ok, Result5} -> Result5;
	    {error, Err5} -> throw(Err5#ctx_err{context = Context0, tunnel = LeftTunnel})
	end,

    {Result6, {Cause, SessionOpts3, RightBearer, Context1}} =
	ergw_gsn_lib:allocate_ips(PAA, APNOpts, SessionOpts2, DAF, LeftTunnel, RightBearer0, Context0),
    case Result6 of
	ok -> ok;
	{error, Err6} -> throw(Err6#ctx_err{context = Context1, tunnel = LeftTunnel})
    end,

    {Context, SessionOpts} = add_apn_timeout(APNOpts, SessionOpts3, Context1),

    Bearer0 = #{left => LeftBearer, right => RightBearer},
    Bearer1 =
	case ergw_gsn_lib:assign_local_data_teid(left, PCtx0, NodeCaps, LeftTunnel, Bearer0) of
	    {ok, Result7} -> Result7;
	    {error, Err7} -> throw(Err7#ctx_err{context = Context, tunnel = LeftTunnel})
	end,

    ergw_aaa_session:set(Session, SessionOpts),

    Now = erlang:monotonic_time(),
    SOpts = #{now => Now},

    GxOpts = #{'Event-Trigger' => ?'DIAMETER_GX_EVENT-TRIGGER_UE_IP_ADDRESS_ALLOCATE',
	       'Bearer-Operation' => ?'DIAMETER_GX_BEARER-OPERATION_ESTABLISHMENT'},

    {_, GxEvents} =
	case ergw_gtp_gsn_session:ccr_initial(Session, gx, GxOpts, SOpts) of
	    {ok, Result8} -> Result8;
	    {error, Err8} -> throw(Err8#ctx_err{context = Context, tunnel = LeftTunnel})
	end,

    RuleBase = ergw_charging:rulebase(),
    {PCC1, PCCErrors1} = ergw_pcc_context:gx_events_to_pcc_ctx(GxEvents, '_', RuleBase, PCC0),
    case ergw_pcc_context:pcc_ctx_has_rules(PCC1) of
	true ->
	    ok;
	_ ->
	    throw(?CTX_ERR(?FATAL, user_authentication_failed, tunnel = LeftTunnel))
    end,

    %% TBD............
    CreditsAdd = ergw_pcc_context:pcc_ctx_to_credit_request(PCC1),
    GyReqServices = #{credits => CreditsAdd},

    {GySessionOpts, GyEvs} =
	case ergw_gtp_gsn_session:ccr_initial(Session, gy, GyReqServices, SOpts) of
	    {ok, Result9} -> Result9;
	    {error, Err9} -> throw(Err9#ctx_err{context = Context, tunnel = LeftTunnel})
	end,

    ?LOG(debug, "GySessionOpts: ~p", [GySessionOpts]),
    ?LOG(debug, "Initial GyEvs: ~p", [GyEvs]),

    ergw_aaa_session:invoke(Session, #{}, start, SOpts),
    {_, _, RfSEvs} = ergw_aaa_session:invoke(Session, #{}, {rf, 'Initial'}, SOpts),

    {PCC2, PCCErrors2} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, GyEvs, PCC1),
    PCC3 = ergw_pcc_context:session_events_to_pcc_ctx(AuthSEvs, PCC2),
    PCC4 = ergw_pcc_context:session_events_to_pcc_ctx(RfSEvs, PCC3),

    {PCtx, Bearer} =
	case ergw_pfcp_context:create_session(gtp_context, PCC4, PCtx0, Bearer1, Context) of
	       {ok, Result10} -> Result10;
	       {error, Err10} -> throw(Err10#ctx_err{context = Context, tunnel = LeftTunnel})
	   end,

    GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(PCCErrors1 ++ PCCErrors2),
    if map_size(GxReport) /= 0 ->
	    ergw_aaa_session:invoke(Session, GxReport,
				    {gx, 'CCR-Update'}, SOpts#{async => true});
       true ->
	    ok
    end,

    case gtp_context:remote_context_register_new(LeftTunnel, Bearer, Context) of
	ok -> ok;
	{error, Err11} -> throw(Err11#ctx_err{context = Context, tunnel = LeftTunnel})
    end,

    {ok, {Cause, SessionOpts, Context, Bearer, PCC4, PCtx}}.

%% 'Idle-Timeout' received from ergw_aaa Session takes precedence over configured one
add_apn_timeout(Opts, Session, Context) ->
    SessionWithTimeout = maps:merge(maps:with(['Idle-Timeout'],Opts), Session),
    Timeout = maps:get('Idle-Timeout', SessionWithTimeout),
    ContextWithTimeout = Context#context{'Idle-Timeout' = Timeout},
    {ContextWithTimeout, SessionWithTimeout}.

%%====================================================================
%% Tunnel
%%====================================================================

update_tunnel_endpoint(Msg, TunnelOld, Tunnel0) ->
    Tunnel = gtp_path:bind(Msg, Tunnel0),
    gtp_context:tunnel_reg_update(TunnelOld, Tunnel),
    if Tunnel#tunnel.path /= TunnelOld#tunnel.path ->
	    gtp_path:unbind(TunnelOld);
       true ->
	    ok
    end,
    Tunnel.

handle_peer_change(#tunnel{remote = NewFqTEID},
		   #tunnel{remote = OldFqTEID}, TunnelOld)
  when OldFqTEID /= NewFqTEID ->
    ergw_gsn_lib:reassign_tunnel_teid(TunnelOld);
handle_peer_change(_, _, Tunnel) ->
    Tunnel.

update_tunnel_endpoint(TunnelOld, Tunnel0) ->
    Tunnel = gtp_path:bind(Tunnel0),
    gtp_context:tunnel_reg_update(TunnelOld, Tunnel),
    if Tunnel#tunnel.path /= TunnelOld#tunnel.path ->
	    gtp_path:unbind(TunnelOld);
       true ->
	    ok
    end,
    Tunnel.

%%====================================================================
%% Bearer Support
%%====================================================================

apply_bearer_change(Bearer, URRActions, SendEM, PCtx0, PCC) ->
    ModifyOpts =
	if SendEM -> #{send_end_marker => true};
	   true   -> #{}
	end,
    case ergw_pfcp_context:modify_session(PCC, URRActions, ModifyOpts, Bearer, PCtx0) of
	{ok, {PCtx, UsageReport}} ->
	    gtp_context:usage_report(self(), URRActions, UsageReport),
	    {ok, PCtx};
	{error, _} = Error ->
	    Error
    end.

%%====================================================================
%% Charging API
%%====================================================================

triggered_charging_event(ChargeEv, Now, Request,
			 #{pfcp := PCtx, 'Session' := Session, pcc := PCC}) ->
    case query_usage_report(Request, PCtx) of
	{ok, {_, UsageReport}} ->
	    ergw_gtp_gsn_session:usage_report_request(
	      ChargeEv, Now, UsageReport, PCtx, PCC, Session);
	{error, CtxErr} ->
	    ?LOG(error, "Triggered Charging Event failed with ~p", [CtxErr])
    end,
    ok.

usage_report(URRActions, UsageReport, #{pfcp := PCtx, 'Session' := Session}) ->
    ergw_gtp_gsn_session:usage_report(URRActions, UsageReport, PCtx, Session).

%% close_context/3
close_context(_, {API, TermCause}, Context) ->
    close_context(API, TermCause, Context);
close_context(API, TermCause, #{pfcp := PCtx, 'Session' := Session})
  when is_atom(TermCause) ->
    UsageReport = ergw_pfcp_context:delete_session(TermCause, PCtx),
    ergw_gtp_gsn_session:close_context(TermCause, UsageReport, PCtx, Session),
    ergw_prometheus:termination_cause(API, TermCause),
    ok.

%%====================================================================
%% Helper
%%====================================================================

query_usage_report(ChargingKeys, PCtx)
  when is_list(ChargingKeys) ->
    ergw_pfcp_context:query_usage_report(ChargingKeys, PCtx);
query_usage_report(_, PCtx) ->
    ergw_pfcp_context:query_usage_report(PCtx).

%% -*- mode: Erlang; whitespace-line-column: 120; -*-
