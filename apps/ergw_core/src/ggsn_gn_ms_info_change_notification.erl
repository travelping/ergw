%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn_ms_info_change_notification).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([ms_info_change_notification/5]).

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

ms_info_change_notification(ReqKey, Request, _Resent, State, Data) ->
    ergw_context_statem:next(
      ms_info_change_notification_fun(Request, _, _),
      ms_info_change_notification_ok(ReqKey, Request, _, _, _),
      ms_info_change_notification_fail(ReqKey, Request, _, _, _),
      State, Data).

ms_info_change_notification_ok(ReqKey, #gtp{ie = IEs} = Request, _, State,
			       #{context := Context, left_tunnel := LeftTunnel} = Data) ->
    ResponseIEs0 = [#cause{value = request_accepted}],
    ResponseIEs = ggsn_gn:copy_ies_to_response(IEs, ResponseIEs0, [?'IMSI', ?'IMEI']),
    Response = ggsn_gn:response(ms_info_change_notification_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = ggsn_gn:context_idle_action([], Context),
    {next_state, State, Data, Actions}.

ms_info_change_notification_fail(ReqKey, #gtp{type = MsgType, seq_no = SeqNo} = Request,
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

ms_info_change_notification_fun(#gtp{ie = IEs}, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	     URRActions <- collect_charging_events(IEs),
	     ergw_gtp_gsn_lib:usage_report_m(URRActions)
	 ]), State, Data).

collect_charging_events(IEs) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{'Session' := Session, left_tunnel := LeftTunnel,
	     bearer := #{left := LeftBearer}} <- statem_m:get_data(),
	   {OldSOpts, NewSOpts} =
	       ggsn_gn:update_session_from_gtp_req(IEs, Session, LeftTunnel, LeftBearer),
	   statem_m:return(gtp_context:collect_charging_events(OldSOpts, NewSOpts))
      ]).
