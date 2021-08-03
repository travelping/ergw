%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8_change_notification).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([change_notification/5]).

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

change_notification(ReqKey, Request, _Resent, State, Data) ->
    gtp_context:next(
      change_notification_fun(Request, _, _),
      change_notification_ok(ReqKey, Request, _, _, _),
      change_notification_fail(ReqKey, Request, _, _, _),
      State, Data).

change_notification_ok(ReqKey, #gtp{ie = IEs} = Request, _,
		       State, #{context := Context, left_tunnel := LeftTunnel} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ?LOG(debug, "IEs: ~p~nTunnel: ~p~nContext: ~p~n", [IEs, LeftTunnel, Context]),

    ResponseIEs0 = [#v2_cause{v2_cause = request_accepted}],
    ResponseIEs = pgw_s5s8:copy_ies_to_response(IEs, ResponseIEs0, [?'IMSI', ?'ME Identity']),
    Response = pgw_s5s8:response(change_notification_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = pgw_s5s8:context_idle_action([], Context),
    {next_state, State#{session := connected}, Data, Actions}.

change_notification_fail(ReqKey, #gtp{type = MsgType, seq_no = SeqNo} = Request,
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
change_notification_fail(ReqKey, Request, Error, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ct:fail(#{'ReqKey' => ReqKey, 'Request' => Request, 'Error' => Error, 'State' => State, 'Data' => Data}),
    {stop, normal, Data}.

change_notification_fun(#gtp{type = change_notification_request, ie = IEs}, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	     pgw_s5s8:process_secondary_rat_usage_data_reports(IEs),
	     URRActions <- collect_charging_events(IEs),
	     trigger_usage_report(URRActions)
	 ]), State, Data).

collect_charging_events(IEs) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	   #{'Session' := Session, left_tunnel := LeftTunnel,
	     bearer := #{left := LeftBearer}} <- statem_m:get_data(),
	   {OldSOpts, NewSOpts} =
	       pgw_s5s8:update_session_from_gtp_req(IEs, Session, LeftTunnel, LeftBearer),
	   statem_m:return(gtp_context:collect_charging_events(OldSOpts, NewSOpts))
      ]).

trigger_usage_report(URRActions) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	   PCtx <- statem_m:get_data(maps:get(pfcp, _)),
	   statem_m:return(gtp_context:trigger_usage_report(self(), URRActions, PCtx))
       ]).
