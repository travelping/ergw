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
    gtp_context:next(
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
	     update_context_from_gtp_req(Request),
	     update_tunnel_from_gtp_req(Request),
	     bind_tunnel(),
	     terminate_colliding_context(),
	     SessionOpts <- init_session(IEs),

	     EUA = maps:get(?'End User Address', IEs, undefined),
	     DAF = proplists:get_bool('Dual Address Bearer Flag', gtp_v1_c:get_common_flags(IEs)),

	     ergw_gtp_gsn_lib:create_session_m(
	       APN, ggsn_gn:pdp_alloc(EUA), DAF, UpSelInfo, SessionOpts)
	 ]), State, Data).

update_context_from_gtp_req(Request) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   Context0 <- statem_m:get_data(maps:get(context, _)),
	   Context = ggsn_gn:update_context_from_gtp_req(Request, Context0),
	   statem_m:modify_data(_#{context => Context})
       ]).

update_tunnel_from_gtp_req(Request) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{left_tunnel := LeftTunnel0, bearer := #{left := LeftBearer0}} <- statem_m:get_data(),
	   {LeftTunnel, LeftBearer} <-
	       statem_m:lift(ggsn_gn:update_tunnel_from_gtp_req(Request, LeftTunnel0, LeftBearer0)),
	   statem_m:modify_data(
	     fun(Data) ->
		     maps:update_with(bearer,
				      maps:put(left, LeftBearer, _),
				      Data#{left_tunnel => LeftTunnel})
	     end)
       ]).

bind_tunnel() ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   LeftTunnel0 <- statem_m:get_data(maps:get(left_tunnel, _)),
	   LeftTunnel <- statem_m:lift(gtp_path:bind_tunnel(LeftTunnel0)),
	   statem_m:modify_data(_#{left_tunnel => LeftTunnel})
       ]).

terminate_colliding_context() ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{left_tunnel := LeftTunnel, context := Context} <- statem_m:get_data(),
	   statem_m:return(gtp_context:terminate_colliding_context(LeftTunnel, Context))
       ]).

init_session(IEs) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{left_tunnel := LeftTunnel, bearer := #{left := LeftBearer},
	     context := Context, aaa_opts := AAAopts} <- statem_m:get_data(),

	   SessionOpts0 = ggsn_gn:init_session(IEs, LeftTunnel, Context, AAAopts),
	   SessionOpts1 =
	       ggsn_gn:init_session_from_gtp_req(IEs, AAAopts, LeftTunnel, LeftBearer, SessionOpts0),
	   SessionOpts = ggsn_gn:init_session_qos(IEs, SessionOpts1),
	   statem_m:return(SessionOpts)
       ]).
