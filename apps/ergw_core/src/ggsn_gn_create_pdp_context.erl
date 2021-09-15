%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn_create_pdp_context).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([create_pdp_context/5]).

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

create_pdp_context(ReqKey, Request, _Resent, State, Data) ->
    ergw_context_statem:next(
      create_pdp_context_fun(Request, _, _),
      create_pdp_context_ok(ReqKey, Request, _, _, _),
      create_pdp_context_fail(ReqKey, Request, _, _, _),
      State, Data).

create_pdp_context_ok(ReqKey, Request, {Cause, SessionOpts},
		      State, #{context := Context, left_tunnel := LeftTunnel,
				bearer := Bearer} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ?LOG(debug, "Cause: ~p~nOpts: ~p~nTunnel: ~p~nBearer: ~p~nContext: ~p~n",
	   [Cause, SessionOpts,  LeftTunnel, Bearer, Context]),
    ResponseIEs = ggsn_gn:create_pdp_context_response(Cause, SessionOpts, Request, LeftTunnel, Bearer, Context),
    Response = ggsn_gn:response(create_pdp_context_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = ggsn_gn:context_idle_action([], Context),
    ?LOG(debug, "C-PDP-CR data: ~p", [Data]),
    {next_state, State#{session := connected}, Data, Actions}.

create_pdp_context_fail(ReqKey, #gtp{type = MsgType, seq_no = SeqNo} = Request,
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

create_pdp_context_fun(#gtp{ie = #{?'Access Point Name' := #access_point_name{apn = APN}} = IEs} = Request,
		       State, Data) ->
    statem_m:run(
      do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	     NodeSelect <- statem_m:get_data(maps:get(node_selection, _)),
	     Services = [{'x-3gpp-upf', 'x-sxb'}],

	     UpSelInfo <-
		 statem_m:lift(ergw_gtp_gsn_lib:connect_upf_candidates(APN, Services, NodeSelect, [])),
	     ergw_gtp_gsn_lib:update_context_from_gtp_req(ggsn_gn, context, Request),
	     ergw_gtp_gsn_lib:update_tunnel_from_gtp_req(ggsn_gn, v1, left, Request),
	     ergw_gtp_gsn_lib:bind_tunnel(left),
	     ergw_gtp_gsn_lib:terminate_colliding_context(),
	     SessionOpts <- ergw_gtp_gsn_lib:init_session(ggsn_gn, IEs),

	     EUA = maps:get(?'End User Address', IEs, undefined),
	     DAF = proplists:get_bool('Dual Address Bearer Flag', gtp_v1_c:get_common_flags(IEs)),

	     ergw_gtp_gsn_lib:create_session_m(
	       APN, ggsn_gn:pdp_alloc(EUA), DAF, UpSelInfo, SessionOpts)
	 ]), State, Data).
