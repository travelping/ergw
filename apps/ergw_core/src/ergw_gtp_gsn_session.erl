%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gtp_gsn_session).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([authenticate/2,
	 ccr_initial/4,
	 usage_report/4,
	 close_context/4]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

authenticate(Session, SessionOpts) ->
    ?LOG(debug, "SessionOpts: ~p", [SessionOpts]),
    case ergw_aaa_session:invoke(Session, SessionOpts, authenticate, [inc_session_id]) of
	{ok, SOpts, SEvs} ->
	    {ok, {SOpts, SEvs}};
	Other ->
	    ?LOG(debug, "AuthResult: ~p", [Other]),
	    {error, ?CTX_ERR(?FATAL, user_authentication_failed)}
    end.

ccr_initial(Session, API, SessionOpts, ReqOpts) ->
    case ergw_aaa_session:invoke(Session, SessionOpts, {API, 'CCR-Initial'}, ReqOpts) of
	{ok, SOpts, SEvs} ->
	    {ok, {SOpts, SEvs}};
	{_Fail, _, _} ->
	    %% TBD: replace with sensible mapping
	    {error, ?CTX_ERR(?FATAL, system_failure)}
    end.


usage_report(URRActions, UsageReport, PCtx, Session) ->
    Now = erlang:monotonic_time(),
    case proplists:get_value(offline, URRActions) of
	{ChargeEv, OldS} ->
	    {_Online, Offline, _} =
		ergw_pfcp_context:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),
	    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, OldS, Session);
	_ ->
	    ok
    end.

close_context(Reason, UsageReport, PCtx, Session) ->
    %% TODO: Monitors, AAA over SGi

    %%  1. CCR on Gx to get PCC rules
    Now = erlang:monotonic_time(),
    ReqOpts = #{now => Now, async => true},
    case ergw_aaa_session:invoke(Session, #{}, {gx, 'CCR-Terminate'}, ReqOpts#{async => false}) of
	{ok, _GxSessionOpts, _} ->
	    ?LOG(debug, "GxSessionOpts: ~p", [_GxSessionOpts]);
	GxOther ->
	    ?LOG(warning, "Gx terminate failed with: ~p", [GxOther])
    end,

    ChargeEv = {terminate, Reason},
    {Online, Offline, Monitor} =
	ergw_pfcp_context:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),
    ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),
    GyReqServices = ergw_gsn_lib:gy_credit_report(Online),
    ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Now, Session),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),
    ok.
