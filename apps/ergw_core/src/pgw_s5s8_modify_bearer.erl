%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8_modify_bearer).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([modify_bearer/5]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-include("pgw_s5s8.hrl").

%%====================================================================
%% Impl.
%%====================================================================

modify_bearer(ReqKey, Request, _Resent, State, Data) ->
    ergw_context_statem:next(
      modify_bearer_fun(Request, _, _),
      modify_bearer_ok(ReqKey, Request, _, _, _),
      modify_bearer_fail(ReqKey, Request, _, _, _),
      State, Data).

modify_bearer_ok(ReqKey,
		 #gtp{type = modify_bearer_request,
		      ie = #{?'Bearer Contexts to be modified' :=
				 #v2_bearer_context{group = #{?'EPS Bearer ID' := EBI}}
			    } = IEs} = Request,
		 _, State,
		 #{context := Context, left_tunnel := LeftTunnel, bearer := Bearer} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ?LOG(debug, "IEs: ~p~nEBI: ~p~nTunnel: ~p~nBearer: ~p~nContext: ~p~n",
	   [IEs, EBI, LeftTunnel, Bearer, Context]),

    ResponseIEs0 =
	case maps:is_key(?'Sender F-TEID for Control Plane', IEs) of
	    true ->
		%% take the presens of the FQ-TEID element as SGW change indication
		%%
		%% 3GPP TS 29.274, Sect. 7.2.7 Modify Bearer Request says that we should
		%% consider the content as well, but in practice that is not stable enough
		%% in the presense of middle boxes between the SGW and the PGW
		%%
		[EBI,				%% Linked EPS Bearer ID
		 #v2_apn_restriction{restriction_type_value = 0},
		 pgw_s5s8:context_charging_id(Context) |
		 [#v2_msisdn{msisdn = Context#context.msisdn} || Context#context.msisdn /= undefined]];
	    false ->
		[]
	end,

    ResponseIEs = [#v2_cause{v2_cause = request_accepted},
		   #v2_bearer_context{
		      group=[#v2_cause{v2_cause = request_accepted},
			     pgw_s5s8:context_charging_id(Context),
			     EBI]} |
		   ResponseIEs0],
    Response = pgw_s5s8:response(modify_bearer_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = pgw_s5s8:context_idle_action([], Context),
    ?LOG(debug, "MBR data: ~p", [Data]),
    {next_state, State, Data, Actions};

modify_bearer_ok(ReqKey, #gtp{type = modify_bearer_request, ie = IEs} = Request,
		 _, State, #{context := Context, left_tunnel := LeftTunnel} = Data)
  when not is_map_key(?'Bearer Contexts to be modified', IEs) ->
    ResponseIEs = [#v2_cause{v2_cause = request_accepted}],
    Response = pgw_s5s8:response(modify_bearer_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = pgw_s5s8:context_idle_action([], Context),
    {next_state, State, Data, Actions}.

modify_bearer_fail(ReqKey, #gtp{type = MsgType, seq_no = SeqNo} = Request,
		    #ctx_err{reply = Reply} = Error,
		    _State, #{left_tunnel := Tunnel} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ?LOG(debug, "Error: ~p", [Error]),
    gtp_context:log_ctx_error(Error, []),
    Response0 = if is_list(Reply) orelse is_atom(Reply) ->
			gtp_v2_c:build_response({MsgType, Reply});
		   true ->
			gtp_v2_c:build_response(Reply)
		end,
    Response = case Tunnel of
		   #tunnel{remote = #fq_teid{teid = TEID}} ->
		       Response0#gtp{tei = TEID};
		   _ ->
		       case gtp_v2_c:find_sender_teid(Request) of
			   TEID when is_integer(TEID) ->
			       Response0#gtp{tei = TEID};
			   _ ->
			       Response0#gtp{tei = 0}
		       end
	       end,
    gtp_context:send_response(ReqKey, Response#gtp{seq_no = SeqNo}),
    {stop, normal, Data}.

%% TODO:
%%  Only single or no bearer modification is supported by this and the next function.
%%  Both function are largy identical, only the bearer modification itself is the key
%%  difference. It should be possible to unify that into one handler
modify_bearer_fun(#gtp{type = modify_bearer_request, ie = IEs} = Request, State, Data)
  when is_map_key(?'Bearer Contexts to be modified', IEs) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	     process_secondary_rat_usage_data_reports(IEs),
	     #{left_tunnel := LeftTunnelOld,
	       bearer := #{left := LeftBearerOld}} <- statem_m:get_data(),
	     ergw_gtp_gsn_lib:update_tunnel_from_gtp_req(pgw_s5s8, v2, left, Request),
	     ergw_gtp_gsn_lib:update_tunnel_endpoint(left, Data),
	     URRActions <- ergw_gtp_gsn_lib:collect_charging_events(pgw_s5s8, IEs),
	     handle_bearer_change(URRActions, LeftTunnelOld, LeftBearerOld)
	 ]), State, Data);

modify_bearer_fun(#gtp{type = modify_bearer_request, ie = IEs} = Request, State, Data)
  when not is_map_key(?'Bearer Contexts to be modified', IEs) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	     process_secondary_rat_usage_data_reports(IEs),
	     ergw_gtp_gsn_lib:update_tunnel_from_gtp_req(pgw_s5s8, v2, left, Request),
	     ergw_gtp_gsn_lib:update_tunnel_endpoint(left, Data),
	     URRActions <- ergw_gtp_gsn_lib:collect_charging_events(pgw_s5s8, IEs),
	     ergw_gtp_gsn_lib:usage_report_m(URRActions)
	 ]), State, Data).

process_secondary_rat_usage_data_reports(IEs) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{context := Context, 'Session' := Session} <- statem_m:get_data(),

	   %% TODO: this call blocking AAA API, convert to send_request/wait
	   statem_m:lift(pgw_s5s8:process_secondary_rat_usage_data_reports(IEs, Context, Session))
       ]).

handle_bearer_change(URRActions, _LeftTunnelOld, LeftBearerOld, LeftBearer)
  when LeftBearerOld =:= LeftBearer ->
    _ = ?LOG(debug, "~s-#1", [?FUNCTION_NAME]),
    ergw_gtp_gsn_lib:usage_report_m(URRActions);
handle_bearer_change(URRActions, LeftTunnelOld, LeftBearerOld, LeftBearer)
  when LeftBearerOld =/= LeftBearer ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   LeftTunnel <- statem_m:get_data(maps:get(left_tunnel, _)),
	   SendEM = LeftTunnelOld#tunnel.version == LeftTunnel#tunnel.version,
	   SessionInfo <- ergw_gtp_gsn_lib:apply_bearer_change(URRActions, SendEM),

	   Session <- statem_m:get_data(maps:get('Session', _)),
	   statem_m:return(ergw_aaa_session:set(Session, SessionInfo))
       ]).

handle_bearer_change(URRActions, LeftTunnelOld, LeftBearerOld) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{bearer := #{left := LeftBearer}} <- statem_m:get_data(),
	   handle_bearer_change(URRActions, LeftTunnelOld, LeftBearerOld, LeftBearer)
       ]).
