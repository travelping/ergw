%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(saegw_s11_modify_bearer).

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

-include("saegw_s11.hrl").

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

    ResponseIEs = [#v2_cause{v2_cause = request_accepted},
		   #v2_bearer_context{
		      group=[#v2_cause{v2_cause = request_accepted},
			     EBI]}],
    Response = saegw_s11:response(modify_bearer_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = saegw_s11:context_idle_action([], Context),
    ?LOG(debug, "MBR data: ~p", [Data]),
    {next_state, State, Data, Actions};

modify_bearer_ok(ReqKey, #gtp{type = modify_bearer_request, ie = IEs} = Request,
		 _, State, #{context := Context, left_tunnel := LeftTunnel} = Data)
  when not is_map_key(?'Bearer Contexts to be modified', IEs) ->
    ResponseIEs = [#v2_cause{v2_cause = request_accepted}],
    Response = saegw_s11:response(modify_bearer_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = saegw_s11:context_idle_action([], Context),
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
    {stop, normal, Data};
modify_bearer_fail(ReqKey, Request, Error, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ct:fail(#{'ReqKey' => ReqKey, 'Request' => Request, 'Error' => Error, 'State' => State, 'Data' => Data}),
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
	     update_tunnel_from_gtp_req(Request),
	     update_tunnel_endpoint(LeftTunnelOld),
	     URRActions <- collect_charging_events(IEs),
	     handle_bearer_change(URRActions, LeftTunnelOld, LeftBearerOld)
	 ]), State, Data);

modify_bearer_fun(#gtp{type = modify_bearer_request, ie = IEs} = Request, State, Data)
  when not is_map_key(?'Bearer Contexts to be modified', IEs) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	     process_secondary_rat_usage_data_reports(IEs),
	     #{left_tunnel := LeftTunnelOld} <- statem_m:get_data(),
	     update_tunnel_from_gtp_req(Request),
	     update_tunnel_endpoint(LeftTunnelOld),
	     URRActions <- collect_charging_events(IEs),
	     ergw_gtp_gsn_lib:usage_report_m(URRActions)
	 ]), State, Data).

process_secondary_rat_usage_data_reports(IEs) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{context := Context, 'Session' := Session} <- statem_m:get_data(),

	   %% TODO: this call blocking AAA API, convert to send_request/wait
	   statem_m:lift(pgw_s5s8:process_secondary_rat_usage_data_reports(IEs, Context, Session))
       ]).

%% TBD: almost identical to create_session
update_tunnel_from_gtp_req(Request) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{left_tunnel := LeftTunnel0, bearer := #{left := LeftBearer0}} <- statem_m:get_data(),
	   {LeftTunnel, LeftBearer} <-
	       statem_m:lift(saegw_s11:update_tunnel_from_gtp_req(
			       Request, LeftTunnel0#tunnel{version = v2}, LeftBearer0)),
	   statem_m:modify_data(
	     fun(Data) ->
		     maps:update_with(bearer,
				      maps:put(left, LeftBearer, _),
				      Data#{left_tunnel => LeftTunnel})
	     end)
       ]).

update_tunnel_endpoint(LeftTunnelOld) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   LeftTunnel0 <- statem_m:get_data(maps:get(left_tunnel, _)),
	   LeftTunnel <- statem_m:return(ergw_gtp_gsn_lib:update_tunnel_endpoint(
					   LeftTunnelOld, LeftTunnel0)),
	   statem_m:modify_data(_#{left_tunnel => LeftTunnel})
       ]).

collect_charging_events(IEs) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{'Session' := Session, left_tunnel := LeftTunnel,
	     bearer := #{left := LeftBearer}} <- statem_m:get_data(),
	   {OldSOpts, NewSOpts} =
	       pgw_s5s8:update_session_from_gtp_req(IEs, Session, LeftTunnel, LeftBearer),
	   statem_m:return(gtp_context:collect_charging_events(OldSOpts, NewSOpts))
      ]).

handle_bearer_change(URRActions, _LeftTunnelOld, LeftBearerOld, LeftBearer)
  when LeftBearerOld =:= LeftBearer ->
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
