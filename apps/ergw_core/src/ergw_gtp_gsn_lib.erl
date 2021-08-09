%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gtp_gsn_lib).

-compile([tuple_calls,
	  {parse_transform, do},
	  {parse_transform, cut}]).

-export([connect_upf_candidates/4, create_session_m/5]).
-export([triggered_charging_event/4, usage_report/3, close_context/3, close_context/4,
	 close_context_m/2]).
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
close_context(_, {API, TermCause}, Data) ->
    close_context(API, TermCause, Data);
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

%% close_context_m/2
close_context_m(_, {API, TermCause}) ->
    close_context_m(API, TermCause);
close_context_m(API, TermCause)
  when is_atom(TermCause) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   PCtx <- statem_m:get_data(maps:get(pfcp, _)),
	   UsageReport = ergw_pfcp_context:delete_session(TermCause, PCtx),
	   close_context_m(API, TermCause, UsageReport)
       ]);
close_context_m(_API, _TermCause) ->
    do([statem_m || return()]).

%% close_context_m/3
close_context_m(API, TermCause, UsageReport)
  when is_atom(TermCause) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{pfcp := PCtx, 'Session' := Session} <- statem_m:get_data(),
	   _ = ergw_gtp_gsn_session:close_context(TermCause, UsageReport, PCtx, Session),
	   _ = ergw_prometheus:termination_cause(API, TermCause),
	   statem_m:modify_data(maps:remove(pfcp, _))
       ]).

%%====================================================================
%% Helper
%%====================================================================

query_usage_report(ChargingKeys, PCtx)
  when is_list(ChargingKeys) ->
    ergw_pfcp_context:query_usage_report(ChargingKeys, PCtx);
query_usage_report(_, PCtx) ->
    ergw_pfcp_context:query_usage_report(PCtx).

%%====================================================================
%% new style async FSM impl
%%====================================================================

create_session_m(APN, PAA, DAF, {Candidates, SxConnectId}, SessionOpts0) ->
    do([statem_m ||
	   Now = erlang:monotonic_time(),
	   return(ergw_sx_node:wait_connect(SxConnectId)),
	   APNOpts <- statem_m:lift(ergw_apn:get(APN)),
	   statem_m:lift(?LOG(debug, "APNOpts: ~p~n", [APNOpts])),
	   UPinfo <- select_upf(Candidates, SessionOpts0, APNOpts),
	   AuthSEvs <- authenticate(),
	   {PCtx, NodeCaps, RightBearer0} <- reselect_upf(Candidates, APNOpts, UPinfo),
	   {Cause, RightBearer} <- allocate_ips(PAA, APNOpts, DAF, RightBearer0),
	   add_apn_timeout(APNOpts),
	   assign_local_data_teid(left, PCtx, NodeCaps, RightBearer),
	   PCCErrors0 <- gx_ccr_i(Now),
	   pcc_ctx_has_rules(),
	   {GySessionOpts, GyEvs} <- gy_ccr_i(Now),
	   statem_m:return(
	     begin
		 ?LOG(debug, "GySessionOpts: ~p", [GySessionOpts]),
		 ?LOG(debug, "Initial GyEvs: ~p", [GyEvs])
	     end),
	   RfSEvs <- rf_i(Now),
	   _ = ?LOG(debug, "RfSEvs: ~p", [RfSEvs]),
	   PCCErrors <- pfcp_create_session(Now, PCtx, GyEvs, AuthSEvs, RfSEvs, PCCErrors0),
	   aaa_start(Now),
	   gx_error_report(Now, PCCErrors),
	   remote_context_register_new(),

	   SessionOpts <- statem_m:get_data(maps:get(session_opts, _)),
	   return({Cause, SessionOpts})
       ]).

select_upf(Candidates, SessionOpts0, APNOpts) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   {UPinfo, SessionOpts} <- statem_m:lift(ergw_pfcp_context:select_upf(Candidates, SessionOpts0, APNOpts)),
	   statem_m:modify_data(_#{session_opts => SessionOpts}),
	   return(UPinfo)
       ]).

authenticate() ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{'Session' := Session, session_opts := SessionOpts0} <- statem_m:get_data(),
	   ReqId <- statem_m:return(gtp_context:send_request(fun() -> ergw_gtp_gsn_session:authenticate(Session, SessionOpts0) end)),
	   Response <- statem_m:wait(ReqId),
	   _ = ?LOG(debug, "AuthResponse: ~p", [Response]),
	   {SessionOpts, AuthSEvs} <- statem_m:lift(Response),
	   _ = ?LOG(debug, "SessionOpts: ~p~nAuthSEvs: ~pn", [SessionOpts, AuthSEvs]),
	   statem_m:modify_data(_#{session_opts => SessionOpts}),
	   return(AuthSEvs)
       ]).

reselect_upf(Candidates, APNOpts, UPinfo) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   SessionOpts <- statem_m:get_data(maps:get(session_opts, _)),
	   statem_m:lift(?LOG(debug, "SessionOpts: ~p~n", [SessionOpts])),
	   statem_m:lift(ergw_pfcp_context:reselect_upf(Candidates, SessionOpts, APNOpts, UPinfo))
       ]).

allocate_ips(PAA, APNOpts, DAF, RightBearer0) ->
    fun (State, #{session_opts := SessionOpts0, context := Context0,
		  left_tunnel := LeftTunnel} = Data0) ->
	    {Result, {Cause, SessionOpts, RightBearer, Context}} =
		ergw_gsn_lib:allocate_ips(PAA, APNOpts, SessionOpts0, DAF, LeftTunnel, RightBearer0, Context0),
	    case Result of
		ok ->
		    Data = Data0#{session_opts => SessionOpts, context => Context},
		    statem_m:return({Cause, RightBearer}, State, Data);
		{error, Error} ->
		    Data = Data0#{context => Context},
		    statem_m:fail(Error, State, Data)
	    end
    end.

add_apn_timeout(APNOpts) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   statem_m:lift(?LOG(debug, "AddApnTimeout: ~p~n", [APNOpts])),
	   #{session_opts := SessionOpts, context := Context0} <- statem_m:get_data(),
	   Context <- statem_m:return(add_apn_timeout(APNOpts, SessionOpts, Context0)),
	   statem_m:modify_data(_#{context => Context})
       ]).

assign_local_data_teid(Key, PCtx, NodeCaps, RightBearer) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   statem_m:lift(?LOG(debug, "AssignLocalDataTeid")),
	   #{left_tunnel := LeftTunnel, bearer := #{left := LeftBearer}} <- statem_m:get_data(),
	   Bearer <- statem_m:lift(
		       ergw_gsn_lib:assign_local_data_teid(Key, PCtx, NodeCaps, LeftTunnel,
							   #{left => LeftBearer, right => RightBearer})),
	   statem_m:modify_data(_#{bearer => Bearer})
       ]).

gx_ccr_i(Now) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{session_opts := SessionOpts, 'Session' := Session, pcc := PCC0} <- statem_m:get_data(),
	   _ = ergw_aaa_session:set(Session, SessionOpts),
	   GxOpts = #{'Event-Trigger' => ?'DIAMETER_GX_EVENT-TRIGGER_UE_IP_ADDRESS_ALLOCATE',
		      'Bearer-Operation' => ?'DIAMETER_GX_BEARER-OPERATION_ESTABLISHMENT'},
	   ReqId <- statem_m:return(
		      gtp_context:send_request(
			fun() -> ergw_gtp_gsn_session:ccr_initial(Session, gx, GxOpts, #{now => Now}) end)),
	   Response <- statem_m:wait(ReqId),
	   _ = ?LOG(debug, "Gx CCR-I Response: ~p", [Response]),
	   {_, GxEvents} <- statem_m:lift(Response),
	   RuleBase = ergw_charging:rulebase(),
	   {PCC, PCCErrors} = ergw_pcc_context:gx_events_to_pcc_ctx(GxEvents, '_', RuleBase, PCC0),
	   statem_m:modify_data(_#{pcc => PCC}),
	   statem_m:return(PCCErrors)
       ]).

pcc_ctx_has_rules() ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   PCC <- statem_m:get_data(maps:get(pcc, _)),
	   case ergw_pcc_context:pcc_ctx_has_rules(PCC) of
	       true ->
		   statem_m:return();
	       _ ->
		   statem_m:fail(user_authentication_failed)
	   end
       ]).

gy_ccr_i(Now) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{'Session' := Session, pcc := PCC} <- statem_m:get_data(),

	   %% TBD............
	   CreditsAdd = ergw_pcc_context:pcc_ctx_to_credit_request(PCC),
	   GyReqServices = #{credits => CreditsAdd},

	   ReqId <- statem_m:return(
		      gtp_context:send_request(
			fun() -> ergw_gtp_gsn_session:ccr_initial(Session, gy, GyReqServices, #{now => Now}) end)),
	   Response <- statem_m:wait(ReqId),
	   _ = ?LOG(debug, "Gy CCR-I Response: ~p", [Response]),
	   statem_m:lift(Response)
       ]).

rf_i(Now) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{'Session' := Session} <- statem_m:get_data(),
	   {_, _, RfSEvs} = ergw_aaa_session:invoke(Session, #{}, {rf, 'Initial'}, #{now => Now}),
	   _ = ?LOG(debug, "RfSEvs: ~p", [RfSEvs]),
	   statem_m:return(RfSEvs)
       ]).

pfcp_create_session(Now, PCtx0, GyEvs, AuthSEvs, RfSEvs, PCCErrors0) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{context := Context, bearer := Bearer, pcc := PCC0} <- statem_m:get_data(),
	   {PCC2, PCCErrors1} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, GyEvs, PCC0),
	   PCC3 = ergw_pcc_context:session_events_to_pcc_ctx(AuthSEvs, PCC2),
	   PCC4 = ergw_pcc_context:session_events_to_pcc_ctx(RfSEvs, PCC3),
	   statem_m:modify_data(_#{pcc => PCC4}),
	   {ReqId, PCtx} <-
	       statem_m:return(
		 ergw_pfcp_context:send_session_establishment_request(
		   gtp_context, PCC4, PCtx0, Bearer, Context)),
	   statem_m:modify_data(_#{pfcp => PCtx}),

	   Response <- statem_m:wait(ReqId),
	   _ = ?LOG(debug, "PFCP: ~p", [Response]),

	   pfcp_create_session_response(Response),
	   statem_m:return(PCCErrors0 ++ PCCErrors1)
       ]).

pfcp_create_session_response(Response) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   _ = ?LOG(debug, "Response: ~p", [Response]),
	   #{bearer := Bearer0, pfcp := PCtx0} <- statem_m:get_data(),
	   {PCtx, Bearer, SessionInfo} <-
	       statem_m:lift(ergw_pfcp_context:receive_session_establishment_response(Response, gtp_context, PCtx0, Bearer0)),
	   statem_m:modify_data(
	     fun(Data) -> maps:update_with(
			    session_opts, maps:merge(_, SessionInfo),
			    Data#{bearer => Bearer, pfcp => PCtx})
	     end)
       ]).

aaa_start(Now) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{'Session' := Session, session_opts := SessionOpts} <- statem_m:get_data(),
	   statem_m:return(ergw_aaa_session:invoke(Session, SessionOpts, start, #{now => Now, async => true}))
       ]).

gx_error_report(Now, PCCErrors) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{'Session' := Session} <- statem_m:get_data(),
	   statem_m:return(
	     begin
		 GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(PCCErrors),
		 if map_size(GxReport) /= 0 ->
			 ergw_aaa_session:invoke(Session, GxReport,
						 {gx, 'CCR-Update'}, #{now => Now, async => true});
		    true ->
			 ok
		 end
	     end)
       ]).

remote_context_register_new() ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{context := Context, left_tunnel := LeftTunnel, bearer := Bearer} <- statem_m:get_data(),
	   statem_m:lift(gtp_context:remote_context_register_new(LeftTunnel, Bearer, Context))
       ]).

%% -*- mode: Erlang; whitespace-line-column: 120; -*-
