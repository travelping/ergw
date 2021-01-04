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
-export([triggered_charging_event_m/3,
	 usage_report_m/1, usage_report_m/2, usage_report_m/3, usage_report_m3/3,
	 close_context/3, close_context/4,
	 close_context_m/4]).
-export([assign_local_data_teid/2,
	 update_context_from_gtp_req/3,
	 update_tunnel_from_gtp_req/4,
	 update_tunnel_endpoint/2,
	 bind_tunnel/1,
	 terminate_colliding_context/0,
	 init_session/2,
	 collect_charging_events/2]).
-export([handle_peer_change/3, apply_bearer_change/2]).
-export([remote_context_register_new/0,
	 pfcp_create_session/1,
	 pfcp_session_modification/0,
	 pfcp_session_liveness_check/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include_lib("opentelemetry_api/include/otel_tracer.hrl").
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

handle_peer_change(#tunnel{remote = NewFqTEID},
		   #tunnel{remote = OldFqTEID}, TunnelOld)
  when OldFqTEID /= NewFqTEID ->
    ergw_gsn_lib:reassign_tunnel_teid(TunnelOld);
handle_peer_change(_, _, Tunnel) ->
    Tunnel.

%%====================================================================
%% Bearer Support
%%====================================================================

apply_bearer_change(URRActions, SendEM) ->
    do([statem_m ||
	     _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   ModifyOpts =
	       if SendEM -> #{send_end_marker => true};
		  true   -> #{}
	       end,

	   #{pfcp := PCtx0, pcc := PCC, bearer := Bearer} <- statem_m:get_data(),
	   {PCtx, ReqId} <-
	       statem_m:return(
		 ergw_pfcp_context:send_session_modification_request(
		   PCC, URRActions, ModifyOpts, Bearer, PCtx0)),
	   statem_m:modify_data(_#{pfcp => PCtx}),
	   Response <- statem_m:wait(ReqId),

	   PCtx1 <- statem_m:get_data(maps:get(pfcp, _)),
	   {_, UsageReport, SessionInfo} <-
	       statem_m:lift(ergw_pfcp_context:receive_session_modification_response(PCtx1, Response)),
	   statem_m:modify_data(_#{session_info => SessionInfo}),

	   ergw_gtp_gsn_lib:usage_report_m(URRActions, UsageReport),

	   statem_m:return(SessionInfo)
       ]).

%%====================================================================
%% Charging API
%%====================================================================

triggered_charging_event_m(ChargeEv, Now, Request) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, [{ev, ChargeEv}]),

	   UsageReport <- query_usage_report_m(Request),
	   usage_report_m3(ChargeEv, Now, UsageReport)
       ]).

usage_report_finish(_, State, Data) ->
    {next_state, State, Data}.

usage_report_m(URRActions, State, #{pfcp := _, 'Session' := _} = Data) ->
    ergw_context_statem:next(
      statem_m:run(usage_report_m(URRActions), _, _),
      fun usage_report_finish/3,
      fun usage_report_finish/3,
      State, Data);
usage_report_m(_URRActions, State, #{'Session' := _} = Data) ->
    ?LOG(info, "PFCP Usage Report after PFCP context closure"),
    %% FIXME:
    %%   This a a know problem with the sequencing of GTP location updates that
    %%   arrive simultaneously with a context teardown action.
    %%   The location update triggeres a PFCP Modify Session, the teardown a
    %%   PFCP Delete Session, the Modify Session Response can then arrive after
    %%   the teardown action has already removed the PFCP context reference.
    usage_report_finish(ok, State, Data).

usage_report_m([]) ->
    _ = ?LOG(debug, "~s-#1", [?FUNCTION_NAME]),
    do([statem_m || return()]);
usage_report_m(URRActions) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, [{actions, URRActions}]),

	   UsageReport <- query_usage_report_m(offline),
	   usage_report_m(URRActions, UsageReport)
       ]).

usage_report_m(URRActions, UsageReport) ->
    do([statem_m ||
	     _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{pfcp := PCtx, 'Session' := Session} <- statem_m:get_data(),
	   statem_m:return(
	     ergw_gtp_gsn_session:usage_report(URRActions, UsageReport, PCtx, Session))
       ]).

usage_report_m3(ChargeEv, Now, UsageReport) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   PCtx <- statem_m:get_data(maps:get(pfcp, _)),
	   {Online, Offline, Monitor} =
	       ergw_pfcp_context:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),

	   Session <- statem_m:get_data(maps:get('Session', _)),
	   _ = ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),

	   PCC <- statem_m:get_data(maps:get(pcc, _)),
	   GyReqServices = ergw_pcc_context:gy_credit_request(Online, PCC),

	   GyReqId <- statem_m:return(
			ergw_context_statem:send_request(
			  fun() ->
				  ergw_gsn_lib:process_online_charging_events_sync(
				    ChargeEv, GyReqServices, Now, Session)
			  end)),
	   GyResult <- statem_m:wait(GyReqId),
	   gy_response(GyResult, ChargeEv, Now, Offline)
       ]).

gy_response({{fail, _}, [{stop, Cause}]} = Result, _, _, _) ->
    _ = ?LOG(debug, "~s-#1: ~p", [?FUNCTION_NAME, Result]),
    do([statem_m || fail(Cause)]);
gy_response({{fail, Reason} = Result, _}, _, _, _) ->
    _ = ?LOG(debug, "~s-#2: ~p", [?FUNCTION_NAME, Result]),
    do([statem_m || fail(Reason)]);
gy_response(Result, ChargeEv, Now, Offline) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s-#3: ~p", [?FUNCTION_NAME, Result]),

	   GyEvs <- statem_m:lift(Result),

	   Session <- statem_m:get_data(maps:get('Session', _)),
	   _ = ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),

	   %% install the new rules, collect any errors
	   PCCErrors <- gy_events_to_pcc_ctx(Now, GyEvs, _, _),
	   pfcp_session_modification(),

	   %% TODO:
	   %%   * stop session if no PCC rules remain
	   %%   * Charging-Rule-Report for unsuccessfully installed/removed rules
	   return(PCCErrors)
       ]).

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

%% close_context_m/4
close_context_m(_, {API, TermCause}, State, Data) ->
    close_context_m(API, TermCause, State, Data);
close_context_m(API, TermCause, State, #{pfcp := PCtx} = Data)
  when is_atom(TermCause) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	     ReqId <-
		 statem_m:return(
		   ergw_pfcp_context:send_session_deletion_request(TermCause, PCtx)),
	     Response <- statem_m:wait(ReqId),
	     UsageReport <-
		 statem_m:lift(ergw_pfcp_context:receive_session_deletion_response(Response)),
	     close_context_m(API, TermCause, UsageReport)
	 ]), State, Data);
close_context_m(_API, _TermCause, State, Data) ->
    statem_m:return(ok, State, Data).

%% close_context_m/3
close_context_m(API, TermCause, UsageReport)
  when is_atom(TermCause) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{pfcp := PCtx, 'Session' := Session} <- statem_m:get_data(),
	   _ = ergw_gtp_gsn_session:close_context(TermCause, UsageReport, PCtx, Session),
	   _ = ergw_prometheus:termination_cause(API, TermCause),
	   statem_m:modify_data(maps:remove(pfcp, _))
       ]).

%%====================================================================
%% Helper
%%====================================================================

do_query_usage_report_m(Type) ->
    do([statem_m ||
	   PCtx <- statem_m:get_data(maps:get(pfcp, _)),
	   ReqId <- return(ergw_pfcp_context:send_query_usage_report(Type, PCtx)),
	   Response <- statem_m:wait(ReqId),
	   {_, UsageReport, SessionInfo} <-
	       statem_m:lift(
		 ergw_pfcp_context:receive_session_modification_response(PCtx, Response)),
	   statem_m:modify_data(_#{session_info => SessionInfo}),

	   return(UsageReport)
       ]).

query_usage_report_m(ChargingKeys) when is_list(ChargingKeys) ->
    do_query_usage_report_m(ChargingKeys);
query_usage_report_m(Type)
  when Type =:= online; Type =:= offline ->
    do_query_usage_report_m(Type);
query_usage_report_m(_) ->
    do_query_usage_report_m(online).

%%====================================================================
%% new style async FSM impl
%%====================================================================

create_session_m(APN, PAA, DAF, {Candidates, SxConnectId}, SessionOpts0) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   Now = erlang:monotonic_time(),
	   return(ergw_sx_node:wait_connect(SxConnectId)),
	   APNOpts <- statem_m:lift(ergw_apn:get(APN)),
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, [{apnopts, APNOpts}]),
	   UPinfo <- select_upf(Candidates, SessionOpts0, APNOpts),
	   AuthSEvs <- authenticate(),
	   {PCtx, NodeCaps, RightBearer0} <- reselect_upf(Candidates, APNOpts, UPinfo),
	   {Cause, RightBearer} <- allocate_ips(PAA, APNOpts, DAF, RightBearer0),
	   add_apn_timeout(APNOpts),
	   assign_local_data_teid(left, PCtx, NodeCaps, RightBearer),
	   PCCErrors0 <- gx_ccr_i(Now),
	   pcc_ctx_has_rules(),
	   {GySessionOpts, GyEvs} <- gy_ccr_i(Now),
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, [{'GySessionOpts', GySessionOpts},
						 {'GyEvs', GyEvs}]),
	   RfSEvs <- rf_i(Now),
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, [{'RfSEvs', RfSEvs}]),
	   PCCErrors <- pfcp_create_session(Now, PCtx, GyEvs, AuthSEvs, RfSEvs, PCCErrors0),
	   aaa_start(Now),
	   gx_error_report(Now, PCCErrors),
	   remote_context_register_new(),

	   SessionOpts <- statem_m:get_data(maps:get(session_opts, _)),
	   return({Cause, SessionOpts})
       ]).

select_upf(Candidates, SessionOpts0, APNOpts) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   {UPinfo, SessionOpts} <- statem_m:lift(ergw_pfcp_context:select_upf(Candidates, SessionOpts0, APNOpts)),
	   statem_m:modify_data(_#{session_opts => SessionOpts}),
	   return(UPinfo)
       ]).

authenticate() ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{'Session' := Session, session_opts := SessionOpts0} <- statem_m:get_data(),
	   ReqId <- statem_m:return(ergw_context_statem:send_request(fun() -> ergw_gtp_gsn_session:authenticate(Session, SessionOpts0) end)),
	   Response <- statem_m:wait(ReqId),
	   _ = ?LOG(debug, "AuthResponse: ~p", [Response]),
	   {SessionOpts, AuthSEvs} <- statem_m:lift(Response),
	   _ = ?LOG(debug, "SessionOpts: ~p~nAuthSEvs: ~pn", [SessionOpts, AuthSEvs]),
	   statem_m:modify_data(_#{session_opts => SessionOpts}),
	   return(AuthSEvs)
       ]).

reselect_upf(Candidates, APNOpts, UPinfo) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   SessionOpts <- statem_m:get_data(maps:get(session_opts, _)),
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
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, [{apnOpts, APNOpts}]),

	   #{session_opts := SessionOpts, context := Context0} <- statem_m:get_data(),
	   Context <- statem_m:return(add_apn_timeout(APNOpts, SessionOpts, Context0)),
	   statem_m:modify_data(_#{context => Context})
       ]).

%% TBD: unify assign_local_data_teid/2 and assign_local_data_teid/4
assign_local_data_teid(left = Key, NodeCaps) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{pfcp := PCtx, left_tunnel := LeftTunnel,
	     bearer := Bearer0} <- statem_m:get_data(),
	   Bearer <-
	       statem_m:lift(
		 ergw_gsn_lib:assign_local_data_teid(Key, PCtx, NodeCaps, LeftTunnel, Bearer0)),
	   statem_m:modify_data(_#{bearer => Bearer})
       ]);
assign_local_data_teid(right = Key, NodeCaps) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{pfcp := PCtx, right_tunnel := RightTunnel,
	     bearer := Bearer0} <- statem_m:get_data(),
	   Bearer <-
	       statem_m:lift(
		 ergw_gsn_lib:assign_local_data_teid(Key, PCtx, NodeCaps, RightTunnel, Bearer0)),
	   statem_m:modify_data(_#{bearer => Bearer})
       ]).

assign_local_data_teid(left = Key, PCtx, NodeCaps, RightBearer) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{left_tunnel := LeftTunnel, bearer := #{left := LeftBearer}} <- statem_m:get_data(),
	   Bearer <- statem_m:lift(
		       ergw_gsn_lib:assign_local_data_teid(Key, PCtx, NodeCaps, LeftTunnel,
							   #{left => LeftBearer, right => RightBearer})),
	   statem_m:modify_data(_#{bearer => Bearer})
       ]).

gx_ccr_i(Now) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{session_opts := SessionOpts, 'Session' := Session, pcc := PCC0} <- statem_m:get_data(),
	   _ = ergw_aaa_session:set(Session, SessionOpts),
	   GxOpts = #{'Event-Trigger' => ?'DIAMETER_GX_EVENT-TRIGGER_UE_IP_ADDRESS_ALLOCATE',
		      'Bearer-Operation' => ?'DIAMETER_GX_BEARER-OPERATION_ESTABLISHMENT'},
	   ReqId <- statem_m:return(
		      ergw_context_statem:send_request(
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
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

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
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{'Session' := Session, pcc := PCC} <- statem_m:get_data(),

	   %% TBD............
	   CreditsAdd = ergw_pcc_context:pcc_ctx_to_credit_request(PCC),
	   GyReqServices = #{credits => CreditsAdd},

	   ReqId <- statem_m:return(
		      ergw_context_statem:send_request(
			fun() -> ergw_gtp_gsn_session:ccr_initial(Session, gy, GyReqServices, #{now => Now}) end)),
	   Response <- statem_m:wait(ReqId),
	   _ = ?LOG(debug, "Gy CCR-I Response: ~p", [Response]),
	   statem_m:lift(Response)
       ]).

rf_i(Now) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{'Session' := Session} <- statem_m:get_data(),
	   {_, _, RfSEvs} = ergw_aaa_session:invoke(Session, #{}, {rf, 'Initial'}, #{now => Now}),
	   _ = ?LOG(debug, "RfSEvs: ~p", [RfSEvs]),
	   statem_m:return(RfSEvs)
       ]).

%% =============================

update_context_from_gtp_req(Interface, Type, Request) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   Context0 <- statem_m:get_data(maps:get(Type, _)),
	   Context = Interface:update_context_from_gtp_req(Request, Context0),
	   statem_m:modify_data(_#{Type => Context})
       ]).

update_tunnel_from_gtp_req(Interface, Version, left, Request) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{left_tunnel := LeftTunnel0, bearer := #{left := LeftBearer0}} <- statem_m:get_data(),
	   {LeftTunnel, LeftBearer} <-
	       statem_m:lift(Interface:update_tunnel_from_gtp_req(
			       Request, LeftTunnel0#tunnel{version = Version}, LeftBearer0)),
	   statem_m:modify_data(
	     fun(Data) ->
		     maps:update_with(bearer,
				      maps:put(left, LeftBearer, _),
				      Data#{left_tunnel => LeftTunnel})
	     end)
       ]);
update_tunnel_from_gtp_req(Interface, Version, right, Request) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{right_tunnel := RightTunnel0, bearer := #{right := RightBearer0}} <- statem_m:get_data(),
	   {RightTunnel, RightBearer} <-
	       statem_m:lift(Interface:update_tunnel_from_gtp_req(
			       Request, RightTunnel0#tunnel{version = Version}, RightBearer0)),
	   statem_m:modify_data(
	     fun(Data) ->
		     maps:update_with(bearer,
				      maps:put(right, RightBearer, _),
				      Data#{right_tunnel => RightTunnel})
	     end)
       ]).

apply_update_tunnel_endpoint(TunnelOld, Tunnel0) ->
    %% TBD: handle errors
    {ok, Tunnel} = gtp_path:bind_tunnel(Tunnel0),
    gtp_context:tunnel_reg_update(TunnelOld, Tunnel),
    if Tunnel#tunnel.path /= TunnelOld#tunnel.path ->
	    gtp_path:unbind_tunnel(TunnelOld);
       true ->
	    ok
    end,
    Tunnel.

update_tunnel_endpoint(left, #{left_tunnel := LeftTunnelOld}) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, [{side, left}]),

	   LeftTunnel0 <- statem_m:get_data(maps:get(left_tunnel, _)),
	   LeftTunnel <- statem_m:return(apply_update_tunnel_endpoint(
					   LeftTunnelOld, LeftTunnel0)),
	   statem_m:modify_data(_#{left_tunnel => LeftTunnel})
       ]);
update_tunnel_endpoint(right, #{right_tunnel := RightTunnelOld}) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, [{side, right}]),

	   RightTunnel0 <- statem_m:get_data(maps:get(right_tunnel, _)),
	   RightTunnel <- statem_m:return(apply_update_tunnel_endpoint(
					    RightTunnelOld, RightTunnel0)),
	   statem_m:modify_data(_#{right_tunnel => RightTunnel})
       ]).

bind_tunnel(left) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   LeftTunnel0 <- statem_m:get_data(maps:get(left_tunnel, _)),
	   LeftTunnel <- statem_m:lift(gtp_path:bind_tunnel(LeftTunnel0)),
	   statem_m:modify_data(_#{left_tunnel => LeftTunnel})
       ]);
bind_tunnel(right) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   RightTunnel0 <- statem_m:get_data(maps:get(right_tunnel, _)),
	   RightTunnel <- statem_m:lift(gtp_path:bind_tunnel(RightTunnel0)),
	   statem_m:modify_data(_#{right_tunnel => RightTunnel})
       ]).

terminate_colliding_context() ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{left_tunnel := LeftTunnel, context := Context} <- statem_m:get_data(),
	   statem_m:return(gtp_context:terminate_colliding_context(LeftTunnel, Context))
       ]).

init_session(Interface, IEs) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{left_tunnel := LeftTunnel, bearer := #{left := LeftBearer},
	     context := Context, aaa_opts := AAAopts} <- statem_m:get_data(),

	   SessionOpts0 = Interface:init_session(IEs, LeftTunnel, Context, AAAopts),
	   SessionOpts1 =
	       Interface:init_session_from_gtp_req(IEs, AAAopts, LeftTunnel, LeftBearer, SessionOpts0),
	   SessionOpts = Interface:init_session_qos(IEs, SessionOpts1),
	   statem_m:modify_data(_#{session_opts => SessionOpts1}),
	   statem_m:return(SessionOpts)
       ]).

collect_charging_events(Interface, IEs) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{'Session' := Session, left_tunnel := LeftTunnel,
	     bearer := #{left := LeftBearer}} <- statem_m:get_data(),
	   {OldSOpts, NewSOpts} =
	       Interface:update_session_from_gtp_req(IEs, Session, LeftTunnel, LeftBearer),
	   statem_m:return(gtp_context:collect_charging_events(OldSOpts, NewSOpts))
      ]).


%% =============================

pfcp_create_session(PCC) ->
     do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	    #{context := Context, bearer := Bearer, pfcp := PCtx0} <- statem_m:get_data(),

	    {ReqId, PCtx} <-
		statem_m:return(
		  ergw_pfcp_context:send_session_establishment_request(
		    gtp_context, PCC, PCtx0, Bearer, Context)),
	    statem_m:modify_data(_#{pfcp => PCtx}),

	    Response <- statem_m:wait(ReqId),
	    pfcp_create_session_response(Response),

	    statem_m:return()
	]).

pfcp_create_session(Now, PCtx0, GyEvs, AuthSEvs, RfSEvs, PCCErrors0) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{context := Context, bearer := Bearer, pcc := PCC0} <- statem_m:get_data(),
	   {PCC2, PCCErrors1} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, GyEvs, PCC0),
	   PCC3 = ergw_pcc_context:session_events_to_pcc_ctx(AuthSEvs, PCC2),
	   PCC4 = ergw_pcc_context:session_events_to_pcc_ctx(RfSEvs, PCC3),
	   statem_m:modify_data(_#{pcc => PCC4}),
	   {ReqId, PCtx} <-
	       statem_m:return(
		 ergw_pfcp_context:send_session_establishment_request(
		   gtp_context, PCC4, PCtx0, Bearer, Context)),
	   statem_m:modify_data(_#{pfcp => PCtx, mark => set}),
	   D2 <- statem_m:get_data(),
	   _ = ?LOG(debug, "Before Wait (~p): ~p", [self(), D2]),

	   Response <- statem_m:wait(ReqId),
	   _ = ?LOG(debug, "PFCP: ~p", [Response]),

	   D1 <- statem_m:get_data(),
	   _ = ?LOG(debug, "Before Response (~p): ~p", [self(), D1]),
	   pfcp_create_session_response(Response),
	   statem_m:return(PCCErrors0 ++ PCCErrors1)
       ]).

pfcp_create_session_response(Response) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   D1 <- statem_m:get_data(),
	   _ = ?LOG(debug, "After Response (~p): ~p", [self(), D1]),
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

pfcp_session_modification() ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{pfcp := PCtx0, pcc := PCC, bearer := Bearer} <- statem_m:get_data(),
	   {PCtx, ReqId} <-
	       statem_m:return(
		 ergw_pfcp_context:send_session_modification_request(
		   PCC, [], #{}, Bearer, PCtx0)),
	   statem_m:modify_data(_#{pfcp => PCtx}),
	   Response <- statem_m:wait(ReqId),

	   PCtx1 <- statem_m:get_data(maps:get(pfcp, _)),
	   statem_m:lift(
	     ergw_pfcp_context:receive_session_modification_response(PCtx1, Response))
       ]).


aaa_start(Now) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{'Session' := Session, session_opts := SessionOpts} <- statem_m:get_data(),
	   statem_m:return(ergw_aaa_session:invoke(Session, SessionOpts, start, #{now => Now, async => true}))
       ]).

gx_error_report(Now, PCCErrors) ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

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

gy_events_to_pcc_ctx(Now, Evs, State, #{pcc := PCC0} = Data) ->
    {PCC, Errors} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, Evs, PCC0),
    statem_m:return(Errors, State, Data#{pcc => PCC}).

remote_context_register_new() ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   #{context := Context, left_tunnel := LeftTunnel, bearer := Bearer} <- statem_m:get_data(),
	   statem_m:lift(gtp_context:remote_context_register_new(LeftTunnel, Bearer, Context))
       ]).

pfcp_session_liveness_check() ->
    do([statem_m ||
	   _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	   PCtx0 <- statem_m:get_data(maps:get(pfcp, _)),
	   ReqId <-
	       statem_m:return(ergw_pfcp_context:send_session_liveness_check(PCtx0)),
	   Response <- statem_m:wait(ReqId),

	   PCtx1 <- statem_m:get_data(maps:get(pfcp, _)),
	   statem_m:lift(
	     ergw_pfcp_context:receive_session_modification_response(PCtx1, Response))
       ]).

%% -*- mode: Erlang; whitespace-line-column: 120; -*-
