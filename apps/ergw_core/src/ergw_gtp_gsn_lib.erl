%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gtp_gsn_lib).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([connect_upf_candidates/4, create_session/10]).
-export([triggered_charging_event/4, usage_report/3, close_context/3, close_context/4]).
-export([handle_peer_change/3, update_tunnel_endpoint/2,
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
	{ok, create_session_fun(APN, PAA, DAF, UPSelInfo, Session, SessionOpts, Context, LeftTunnel, LeftBearer, PCC)}
    catch
	throw:Error ->
	    {error, Error}
    end.

create_session_fun(APN, PAA, DAF, {Candidates, SxConnectId}, Session,
		   SessionOpts0, Context0, LeftTunnel, LeftBearer, PCC0) ->

    ergw_sx_node:wait_connect(SxConnectId),

    APNOpts =
	case ergw_apn:get(APN) of
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

    Context = add_apn_timeout(APNOpts, SessionOpts3, Context1),

    Bearer0 = #{left => LeftBearer, right => RightBearer},
    Bearer1 =
	case ergw_gsn_lib:assign_local_data_teid(left, PCtx0, NodeCaps, LeftTunnel, Bearer0) of
	    {ok, Result7} -> Result7;
	    {error, Err7} -> throw(Err7#ctx_err{context = Context, tunnel = LeftTunnel})
	end,

    ergw_aaa_session:set(Session, SessionOpts3),

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

    {_, _, RfSEvs} = ergw_aaa_session:invoke(Session, #{}, {rf, 'Initial'}, SOpts),

    {PCC2, PCCErrors2} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, GyEvs, PCC1),
    PCC3 = ergw_pcc_context:session_events_to_pcc_ctx(AuthSEvs, PCC2),
    PCC4 = ergw_pcc_context:session_events_to_pcc_ctx(RfSEvs, PCC3),

    {PCtx, Bearer, SessionInfo} =
	case ergw_pfcp_context:create_session(gtp_context, PCC4, PCtx0, Bearer1, Context) of
	       {ok, Result10} -> Result10;
	       {error, Err10} -> throw(Err10#ctx_err{context = Context, tunnel = LeftTunnel})
	   end,

    SessionOpts = maps:merge(SessionOpts3, SessionInfo),
    ergw_aaa_session:invoke(Session, SessionOpts, start, SOpts#{async => true}),

    GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(PCCErrors1 ++ PCCErrors2),
    if map_size(GxReport) /= 0 ->
	    ergw_aaa_session:invoke(Session, GxReport,
				    {gx, 'CCR-Update'}, SOpts#{async => true});
       true ->
	    ok
    end,

    case gtp_context:remote_context_register_new(LeftTunnel, Bearer, Context) of
	ok ->
	    {ok, Cause, SessionOpts, Context, Bearer, PCC4, PCtx};
	{error, #ctx_err{level = Level, where = {File, Line}}} ->
	    ?LOG(debug, #{type => ctx_err, level => Level, file => File,
			  line => Line, reply => system_failure}),
	    {error, system_failure, SessionOpts, Context, Bearer, PCC4, PCtx}
    end.


%% 'Idle-Timeout' received from ergw_aaa Session takes precedence over configured one
add_apn_timeout(Opts, Session, Context) ->
    InactTimeout = maps:get(inactivity_timeout, Opts, infinity),
    SessionTimeout = maps:get('Idle-Timeout', Session, infinity),
    Timeout =
	case {InactTimeout, SessionTimeout} of
	    {_, infinity} -> InactTimeout;
	    {infinity, X} when is_integer(X) -> X + 300 * 1000;
	    {X, Y} when is_integer(X), is_integer(Y) ->
		erlang:max(X, Y + 300 * 1000);
	    _ ->
		48 * 3600 * 1000
	end,
    %% TODO: moving idle_timeout to the PCC ctx might make more sense
    Context#context{inactivity_timeout = Timeout, idle_timeout = SessionTimeout}.

%%====================================================================
%% Tunnel
%%====================================================================

update_tunnel_endpoint(TunnelOld, Tunnel0) ->
    %% TBD: handle errors
    {ok, Tunnel} = gtp_path:bind_tunnel(Tunnel0),
    gtp_context:tunnel_reg_update(TunnelOld, Tunnel),
    if Tunnel#tunnel.path /= TunnelOld#tunnel.path ->
	    gtp_path:unbind_tunnel(TunnelOld);
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

%%====================================================================
%% Bearer Support
%%====================================================================

apply_bearer_change(Bearer, URRActions, SendEM, PCtx0, PCC) ->
    ModifyOpts =
	if SendEM -> #{send_end_marker => true};
	   true   -> #{}
	end,
    case ergw_pfcp_context:modify_session(PCC, URRActions, ModifyOpts, Bearer, PCtx0) of
	{ok, {PCtx, UsageReport, SessionInfo}} ->
	    gtp_context:usage_report(self(), URRActions, UsageReport),
	    {ok, {PCtx, SessionInfo}};
	{error, _} = Error ->
	    Error
    end.

%%====================================================================
%% Charging API
%%====================================================================

triggered_charging_event(ChargeEv, Now, Request,
			 #{pfcp := PCtx, 'Session' := Session, pcc := PCC}) ->
    case query_usage_report(Request, PCtx) of
	{ok, {_, UsageReport, _}} ->
	    ergw_gtp_gsn_session:usage_report_request(
	      ChargeEv, Now, UsageReport, PCtx, PCC, Session);
	{error, CtxErr} ->
	    ?LOG(error, "Triggered Charging Event failed with ~p", [CtxErr])
    end,
    ok.

usage_report(URRActions, UsageReport, #{pfcp := PCtx, 'Session' := Session}) ->
    ergw_gtp_gsn_session:usage_report(URRActions, UsageReport, PCtx, Session);
usage_report(_URRActions, _UsageReport, #{'Session' := _}) ->
    ?LOG(info, "PFCP Usage Report after PFCP context closure"),
    %% FIXME:
    %%   This a a know problem with the sequencing of GTP location updates that
    %%   arrive simultaneously with a context teardown action.
    %%   The location update triggeres a PFCP Modify Session, the teardown a
    %%   PFCP Delete Session, the Modify Session Response can then arrive after
    %%   the teardown action has already removed the PFCP context reference.
    ok.


%% close_context/3
close_context(_, {API, TermCause}, Context) ->
    close_context(API, TermCause, Context);
close_context(API, TermCause, #{pfcp := PCtx} = Data)
  when is_atom(TermCause) ->
    UsageReport = ergw_pfcp_context:delete_session(TermCause, PCtx),
    close_context(API, TermCause, UsageReport, Data);
close_context(_API, _TermCause, Data) ->
    Data.

%% close_context/4
close_context(API, TermCause, UsageReport, #{pfcp := PCtx, 'Session' := Session} = Data)
  when is_atom(TermCause) ->
    ergw_gtp_gsn_session:close_context(TermCause, UsageReport, PCtx, Session),
    ergw_prometheus:termination_cause(API, TermCause),
    maps:remove(pfcp, Data).

%%====================================================================
%% Helper
%%====================================================================

query_usage_report(ChargingKeys, PCtx)
  when is_list(ChargingKeys) ->
    ergw_pfcp_context:query_usage_report(ChargingKeys, PCtx);
query_usage_report(_, PCtx) ->
    ergw_pfcp_context:query_usage_report(PCtx).

%% -*- mode: Erlang; whitespace-line-column: 120; -*-
