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
      State, Data).

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
    {next_state, State#{session := connected}, Data, Actions}.

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
    {stop, normal, Data};

create_session_fail(ReqKey, Request, Error, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ct:fail(#{'ReqKey' => ReqKey, 'Request' => Request, 'Error' => Error, 'State' => State, 'Data' => Data}),
    {next_state, shutdown, Data}.

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
	     update_context_from_gtp_req(Request),
	     update_tunnel_from_gtp_req(Request),
	     bind_tunnel(),
	     terminate_colliding_context(),
	     SessionOpts <- init_session(IEs),

	     PAA = maps:get(?'PDN Address Allocation', IEs, undefined),
	     DAF = proplists:get_bool('DAF', gtp_v2_c:get_indication_flags(IEs)),

	     ergw_gtp_gsn_lib:create_session_m(
	       APN, saegw_s11:pdn_alloc(PAA), DAF, UpSelInfo, SessionOpts)
	 ]), State, Data).

update_context_from_gtp_req(Request) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   Context0 <- statem_m:get_data(maps:get(context, _)),
	   Context = saegw_s11:update_context_from_gtp_req(Request, Context0),
	   statem_m:modify_data(_#{context => Context})
       ]).

update_tunnel_from_gtp_req(Request) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{left_tunnel := LeftTunnel0, bearer := #{left := LeftBearer0}} <- statem_m:get_data(),
	   {LeftTunnel, LeftBearer} <-
	       statem_m:lift(saegw_s11:update_tunnel_from_gtp_req(Request, LeftTunnel0, LeftBearer0)),
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

	   SessionOpts0 = pgw_s5s8:init_session(IEs, LeftTunnel, Context, AAAopts),
	   SessionOpts1 =
	       pgw_s5s8:init_session_from_gtp_req(IEs, AAAopts, LeftTunnel, LeftBearer, SessionOpts0),
	   %% SessionOpts = init_session_qos(ReqQoSProfile, SessionOpts1),
	   statem_m:return(SessionOpts1)
       ]).
