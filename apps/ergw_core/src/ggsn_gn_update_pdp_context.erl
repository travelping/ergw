%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn_update_pdp_context).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([update_pdp_context/5]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-include("ggsn_gn.hrl").

%%====================================================================
%% Impl.
%%====================================================================

update_pdp_context(ReqKey, Request, _Resent, State, Data) ->
    ergw_context_statem:next(
      update_pdp_context_fun(Request, _, _),
      update_pdp_context_ok(ReqKey, Request, _, _, _),
      update_pdp_context_fail(ReqKey, Request, _, _, _),
      State, Data).

update_pdp_context_ok(ReqKey,
		      #gtp{type = update_pdp_context_request,
			   ie = #{?'Quality of Service Profile' := ReqQoSProfile} = IEs} = Request,
		      _, State,
		      #{context := Context, left_tunnel := LeftTunnel, bearer := Bearer} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ?LOG(debug, "IEs: ~p~nTunnel: ~p~nBearer: ~p~nContext: ~p~n",
	   [IEs, LeftTunnel, Bearer, Context]),

    ResponseIEs0 = [#cause{value = request_accepted},
		    ggsn_gn:context_charging_id(Context),
		    ReqQoSProfile],
    ResponseIEs1 =  ggsn_gn:tunnel_elements(LeftTunnel, ResponseIEs0),
    ResponseIEs =  ggsn_gn:bearer_elements(Bearer, ResponseIEs1),
    Response =  ggsn_gn:response(update_pdp_context_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = ggsn_gn:context_idle_action([], Context),
    {next_state, State, Data, Actions}.

update_pdp_context_fail(ReqKey, #gtp{type = MsgType, seq_no = SeqNo} = Request,
		    #ctx_err{reply = Reply} = Error,
		    _State, #{left_tunnel := Tunnel} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ?LOG(debug, "Error: ~p", [Error]),
    gtp_context:log_ctx_error(Error, []),
    Response0 = if is_list(Reply) orelse is_atom(Reply) ->
			gtp_v1_c:build_response({MsgType, Reply});
		   true ->
			gtp_v1_c:build_response(Reply)
		end,
    Response = case Tunnel of
		   #tunnel{remote = #fq_teid{teid = TEID}} ->
		       Response0#gtp{tei = TEID};
		   _ ->
		       case gtp_v1_c:find_sender_teid(Request) of
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
update_pdp_context_fun(#gtp{type = update_pdp_context_request, ie = IEs} = Request, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	     #{left_tunnel := LeftTunnelOld,
	       bearer := #{left := LeftBearerOld}} <- statem_m:get_data(),
	     ergw_gtp_gsn_lib:update_tunnel_from_gtp_req(ggsn_gn, v1, left, Request),
	     ergw_gtp_gsn_lib:update_tunnel_endpoint(left, Data),
	     URRActions <- ergw_gtp_gsn_lib:collect_charging_events(ggsn_gn, IEs),
	     handle_bearer_change(URRActions, LeftTunnelOld, LeftBearerOld)
	 ]), State, Data).

handle_bearer_change(URRActions, _LeftTunnelOld, LeftBearerOld, LeftBearer)
  when LeftBearerOld =:= LeftBearer ->
    ergw_gtp_gsn_lib:usage_report_m(URRActions);
handle_bearer_change(URRActions, _LeftTunnelOld, LeftBearerOld, LeftBearer)
  when LeftBearerOld =/= LeftBearer ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   SessionInfo <- ergw_gtp_gsn_lib:apply_bearer_change(URRActions, false),

	   Session <- statem_m:get_data(maps:get('Session', _)),
	   statem_m:return(ergw_aaa_session:set(Session, SessionInfo))
       ]).

handle_bearer_change(URRActions, LeftTunnelOld, LeftBearerOld) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{bearer := #{left := LeftBearer}} <- statem_m:get_data(),
	   handle_bearer_change(URRActions, LeftTunnelOld, LeftBearerOld, LeftBearer)
       ]).
