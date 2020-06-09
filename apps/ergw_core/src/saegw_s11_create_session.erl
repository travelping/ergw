%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(saegw_s11_create_session).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([create_session/5]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-include("saegw_s11.hrl").

%%====================================================================
%% Impl.
%%====================================================================

create_session(ReqKey, Request, _Resent, State, Data) ->
    ergw_context_statem:next(
      create_session_fun(Request, _, _),
      create_session_ok(ReqKey, Request, _, _, _),
      create_session_fail(ReqKey, Request, _, _, _),
      State#{fsm := busy}, Data).

create_session_ok(ReqKey,
		 #gtp{ie = #{?'Bearer Contexts to be created' :=
				 #v2_bearer_context{group = #{?'EPS Bearer ID' := EBI}}
			    } = IEs} = Request,
		 {Cause, SessionOpts},
		 State, #{context := Context, left_tunnel := LeftTunnel,
			  bearer := Bearer} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ?LOG(debug, "Cause: ~p~nOpts: ~p~nIEs: ~p~nEBI: ~p~nTunnel: ~p~nBearer: ~p~nContext: ~p~n",
	   [Cause, SessionOpts, IEs, EBI, LeftTunnel, Bearer, Context]),
    ResponseIEs = saegw_s11:create_session_response(Cause, SessionOpts, IEs, EBI, LeftTunnel, Bearer, Context),
    Response = saegw_s11:response(create_session_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = saegw_s11:context_idle_action([], Context),
    ?LOG(debug, "CSR data: ~p", [Data]),
    {next_state, State#{session := connected, fsm := idle}, Data, Actions}.

create_session_fail(ReqKey, #gtp{type = MsgType, seq_no = SeqNo} = Request,
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

create_session_fun(#gtp{ie = #{?'Access Point Name' := #v2_access_point_name{apn = APN}} = IEs} = Request,
		   State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	     NodeSelect <- statem_m:get_data(maps:get(node_selection, _)),
	     Services = [{'x-3gpp-upf', 'x-sxb'}],

	     %% async call, want to wait for the result later...
	     UpSelInfo <-
		 statem_m:lift(ergw_gtp_gsn_lib:connect_upf_candidates(APN, Services, NodeSelect, [])),
	     ergw_gtp_gsn_lib:update_context_from_gtp_req(saegw_s11, context, Request),
	     ergw_gtp_gsn_lib:update_tunnel_from_gtp_req(saegw_s11, v2, left, Request),
	     ergw_gtp_gsn_lib:bind_tunnel(left),
	     ergw_gtp_gsn_lib:terminate_colliding_context(),
	     SessionOpts <- ergw_gtp_gsn_lib:init_session(pgw_s5s8, IEs),

	     PAA = maps:get(?'PDN Address Allocation', IEs, undefined),
	     DAF = proplists:get_bool('DAF', gtp_v2_c:get_indication_flags(IEs)),

	     ergw_gtp_gsn_lib:create_session_m(
	       APN, saegw_s11:pdn_alloc(PAA), DAF, UpSelInfo, SessionOpts)
	 ]), State, Data).
