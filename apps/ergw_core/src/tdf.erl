%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(tdf).

%%-behaviour(gtp_api).
-behavior(ergw_context).
-behavior(ergw_context_statem).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([start_link/6, validate_options/1, unsolicited_report/5]).

-ignore_xref([start_link/6]).

%% TBD: use a PFCP or handler behavior?
-ignore_xref([start_link/6, validate_options/1, unsolicited_report/5]).

%% ergw_context callbacks
-export([sx_report/2, port_message/2, port_message/4]).

-ifdef(TEST).
-export([ctx_test_cmd/2]).
-endif.

%% ergw_context_statem callbacks
-export([init/2, handle_event/4, terminate/3, code_change/4]).

-include_lib("kernel/include/logger.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define(API, tdf).
-define(SERVER, ?MODULE).
-define(TestCmdTag, '$TestCmd').

%%====================================================================
%% API
%%====================================================================

start_link(Node, VRF, IP4, IP6, SxOpts, GenOpts) ->
    ergw_context_statem:start_link(?MODULE, [Node, VRF, IP4, IP6, SxOpts], GenOpts).

unsolicited_report(Node, VRF, IP4, IP6, SxOpts) ->
    tdf_sup:new(Node, VRF, IP4, IP6, SxOpts).

-ifdef(TEST).

ctx_test_cmd(Id, is_alive) ->
    with_context(Id, fun(Pid, _) -> is_pid(Pid) end, undefined);
ctx_test_cmd(Id, whereis) ->
    with_context(Id, fun(Pid, _) -> {?MODULE, Pid} end, undefined);
ctx_test_cmd(Id, stop_session) ->
    with_context(Id, fun(Pid, _) -> Pid ! {update_session, #{}, [stop]} end, undefined);
ctx_test_cmd(Id, {send, Msg}) ->
    with_context(Id, info, Msg);
ctx_test_cmd(Id, Cmd) ->
    with_context(Id, call, {?TestCmdTag, Cmd}).

with_context(Pid, EventType, EventContent) when is_pid(Pid) ->
    with_context_srv(Pid, EventType, EventContent).

with_context_srv(Server, cast, EventContent) ->
    gen_statem:cast(Server, EventContent);
with_context_srv(Server, call, EventContent) ->
    gen_statem:call(Server, EventContent);
with_context_srv(Server, info, EventContent) ->
    Server ! EventContent;
with_context_srv(Server, Fun, EventContent) when is_function(Fun) ->
    Fun(Server, EventContent).

-endif.

%%%===================================================================
%%% Options Validation
%%%===================================================================

validate_options(Opts) ->
    ?LOG(debug, "TDF Options: ~p", [Opts]),
    ergw_core_config:mandatory_keys([protocol, node_selection, nodes, apn], Opts),
    ergw_core_config:validate_options(fun validate_option/2, Opts, []).

validate_option(protocol, ip) ->
    ip;
validate_option(handler, Value) when is_atom(Value) ->
    Value;
validate_option(node_selection, Value) when length(Value) /= 0 ->
    Value;
validate_option(nodes, Value) when length(Value) /= 0 ->
    Value;
validate_option(apn, APN)
  when is_list(APN) ->
    ergw_apn:validate_apn_name(APN);
validate_option(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

%%====================================================================
%% ergw_context API
%%====================================================================

sx_report(Server, Report) ->
    gen_statem:call(Server, {sx, Report}).

port_message(Request, Msg) ->
    %% we currently do not configure DP to CP forwards,
    %% so this should not happen

    ?LOG(error, "Port Message ~p, ~p", [Request, Msg]),
    error(badarg, [Request, Msg]).

port_message(Server, Request, Msg, Resent) ->
    %% we currently do not configure DP to CP forwards,
    %% so this should not happen

    ?LOG(error, "Port Message ~p, ~p", [Server, Request, Msg, Resent]),
    error(badarg, [Server, Request, Msg, Resent]).

%%====================================================================
%% gen_statem API
%%====================================================================

maybe_ip(IP, Len) when is_binary(IP) -> ergw_ip_pool:static_ip(IP, Len);
maybe_ip(_,_) -> undefined.

init([Node, InVRF, IP4, IP6, #{apn := APN} = _SxOpts], Data0) ->
    UeIP = #ue_ip{v4 = maybe_ip(IP4, 32), v6 = maybe_ip(IP6, 128)},
    Context = #tdf_ctx{
		  ms_ip = UeIP
		 },
    LeftBearer = #bearer{
		    interface = 'Access',
		    vrf = InVRF,
		    remote = UeIP
		   },
    RightBearer = #bearer{
		     interface = 'SGi-LAN',
		     local = UeIP,
		     remote = default
		    },

    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),
    SessionOpts = ergw_aaa_session:get(Session),
    OCPcfg = maps:get('Offline-Charging-Profile', SessionOpts, #{}),
    PCC = #pcc_ctx{offline_charging_profile = OCPcfg},
    Bearer = #{left => LeftBearer, right => RightBearer},
    Data = Data0#{
      apn       => APN,
      context   => Context,
      dp_node   => Node,
      'Session' => Session,
      pcc       => PCC,
      bearer    => Bearer},

    ?LOG(info, "TDF process started for ~p", [[Node, IP4, IP6]]),
    {ok, ergw_context:init_state(), Data, [{next_event, internal, init}]}.

%%
%% non-blocking handlers
%%

handle_event({call, From}, {?TestCmdTag, pfcp_ctx}, _State, #{pfcp := PCtx}) ->
    {keep_state_and_data, [{reply, From, {ok, PCtx}}]};
handle_event({call, From}, {?TestCmdTag, session}, _State, #{'Session' := Session}) ->
    {keep_state_and_data, [{reply, From, {ok, Session}}]};
handle_event({call, From}, {?TestCmdTag, pcc_rules}, _State, #{pcc := PCC}) ->
    {keep_state_and_data, [{reply, From, {ok, PCC#pcc_ctx.rules}}]};

handle_event(enter, _OldState, #{session := shutdown} = _State, _Data) ->
    % TODO unregsiter context ....

    %% this makes stop the last message in the inbox and
    %% guarantees that we process any left over messages first
    gen_statem:cast(self(), stop),
    keep_state_and_data;

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

%% block all (other) calls, casts and infos while waiting
%%  for the result of an asynchronous action
handle_event({call, _}, _, #{async := Async}, _) when map_size(Async) /= 0 ->
    {keep_state_and_data, [postpone]};
handle_event(cast, _, #{async := Async}, _) when map_size(Async) /= 0 ->
    {keep_state_and_data, [postpone]};
handle_event(info, _, #{async := Async}, _) when map_size(Async) /= 0 ->
    {keep_state_and_data, [postpone]};

handle_event(cast, stop, #{session := shutdown} = _State, _Data) ->
    {stop, normal};

handle_event(internal, init, #{session := init} = State, Data) ->
    ergw_context_statem:next(
      fun start_session_fun/2,
      fun start_session_ok/3,
      fun start_session_fail/3,
      State, Data);

%% Usage Report
handle_event({call, From},
	     {sx, #pfcp{type = session_report_request,
			ie = #{report_type := #report_type{usar = 1},
			       usage_report_srr := UsageReport}}},
	     State, Data) ->
    ergw_context_statem:next(
      session_report_fun(UsageReport, _, _),
      session_report_ok(From, _, _, _),
      session_report_fail(From, _, _, _),
      State, Data);

handle_event({call, From}, {sx, Report}, _State, #{pfcp := PCtx}) ->
    ?LOG(warning, "~w: unhandled Sx report: ~p", [?MODULE, Report]),
    {keep_state_and_data, [{reply, From, {ok, PCtx, 'System failure'}}]};

handle_event({call, From}, _Request, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

handle_event(cast, _Request, _State, _Data) ->
    keep_state_and_data;

handle_event(info, {'DOWN', _MonitorRef, Type, Pid, _Info},
	     State, #{dp_node := Pid} = Data)
  when Type == process; Type == pfcp ->
    close_pdn_context(upf_failure, State, Data),
    {next_state, State#{session := shutdown}, Data};

handle_event(info, #aaa_request{procedure = {_, 'RAR'}} = Request, #{session := shutdown} = _State, _Data) ->
    ergw_aaa_session:response(Request, {error, unknown_session}, #{}, #{}),
    keep_state_and_data;

handle_event(info, #aaa_request{procedure = {_, 'ASR'} = Procedure} = Request, State, Data) ->
    ergw_aaa_session:response(Request, ok, #{}, #{}),
    close_pdn_context(Procedure, State, Data),
    {next_state, State#{session := shutdown}, Data};

handle_event(info, #aaa_request{procedure = {gx, 'RAR'}} = Request, State, Data) ->
    ergw_context_statem:next(
      gx_rar_fun(Request, _, _),
      gx_rar_ok(Request, _, _, _),
      gx_rar_fail(Request, _, _, _),
      State, Data);

handle_event(info, #aaa_request{procedure = {gy, 'RAR'},
				events = Events} = Request,
	     State, Data) ->
    ergw_aaa_session:response(Request, ok, #{}, #{}),

    %% Triggered CCR.....
    ChargingKeys =
	case proplists:get_value(report_rating_group, Events) of
	    RatingGroups when is_list(RatingGroups) ->
		[{online, RG} || RG <- RatingGroups];
	    _ ->
		undefined
	end,
    ergw_context_statem:next(
      triggered_charging_event_fun(interim, ChargingKeys, _, _),
      triggered_charging_event_ok(_, _, _),
      triggered_charging_event_fail(_, _, _),
      State, Data);

%% Enable AAA to provide reason for session stop
handle_event(internal, {session, {stop, Reason}, _Session}, State, Data) ->
    close_pdn_context(Reason, State, Data),
    {next_state, State#{session := shutdown}, Data};

handle_event(internal, {session, stop, _Session}, State, Data) ->
    close_pdn_context(normal, State, Data),
    {next_state, State#{session := shutdown}, Data};

handle_event(internal, {session, {update_credits, _} = CreditEv, _}, State, Data) ->
    ergw_context_statem:next(
      update_credits_fun(CreditEv, _, _),
      update_credits_ok(_, _, _),
      update_credits_fail(_, _, _),
      State, Data);

handle_event(internal, {session, Ev, _}, _State, _Data) ->
    ?LOG(error, "unhandled session event: ~p", [Ev]),
    keep_state_and_data;

handle_event(info, {update_session, Session, Events}, _State, _Data) ->
    ?LOG(debug, "SessionEvents: ~p~n       Events: ~p", [Session, Events]),
    Actions = [{next_event, internal, {session, Ev, Session}} || Ev <- Events],
    {keep_state_and_data, Actions};

handle_event(info, {timeout, TRef, pfcp_timer} = Info, State, #{pfcp := PCtx0} = Data0) ->
    ?LOG(debug, "handle_info TDF:~p", [Info]),
    {Evs, PCtx} = ergw_pfcp:timer_expired(TRef, PCtx0),
    Data = Data0#{pfcp => PCtx},
    #{validity_time := ChargingKeys} = ergw_gsn_lib:pfcp_to_context_event(Evs),

    ergw_context_statem:next(
      triggered_charging_event_fun(validity_time, ChargingKeys, _, _),
      triggered_charging_event_ok(_, _, _),
      triggered_charging_event_fail(_, _, _),
      State, Data);

handle_event(info, _Info, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

apply_bearer_opts('NAT-Pool-Id', Id, #{right := #bearer{local = Local} = Right} = Bearer)
  when is_record(Local, ue_ip) ->
    Bearer#{right => Right#bearer{local = Local#ue_ip{nat = Id}}};
apply_bearer_opts(_, _, Bearer) ->
    Bearer.

apply_bearer_opts(SOpts, Bearer) ->
    maps:fold(fun apply_bearer_opts/3, Bearer, SOpts).

init_tdf_bearer(VRF, SessionOpts, Bearer0) ->
    Bearer = maps:update_with(right, _#bearer{vrf = VRF}, Bearer0),
    apply_bearer_opts(SessionOpts, Bearer).

close_pdn_context(Reason, State, Data) when is_atom(Reason) ->
    close_pdn_context({?API, Reason}, State, Data);
close_pdn_context({API, TermCause}, #{session := run}, #{pfcp := PCtx, 'Session' := Session}) ->
    URRs = ergw_pfcp_context:delete_session(TermCause, PCtx),

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

    ChargeEv = {terminate, TermCause},
    {Online, Offline, Monitor} =
	ergw_pfcp_context:usage_report_to_charging_events(URRs, ChargeEv, PCtx),
    ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),
    GyReqServices = ergw_gsn_lib:gy_credit_report(Online),
    ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Now, Session),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),
    ergw_prometheus:termination_cause(API, TermCause),

    ok;
close_pdn_context(_Reason, _State, _Data) ->
    ok.

session_report_fun(UsageReport, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	     Now = erlang:monotonic_time(),
	     ChargeEv = interim,

	     ergw_gtp_gsn_lib:usage_report_m3(ChargeEv, Now, UsageReport)
	 ]), State, Data).

session_report_ok(From, _, State, #{pfcp := PCtx} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    {next_state, State, Data, [{reply, From, {ok, PCtx}}]}.

session_report_fail(From, Reason, State, #{pfcp := PCtx} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    gen_statem:reply(From, {ok, PCtx}),
    close_pdn_context(Reason, State, Data),
    {next_state, State#{session := shutdown}, Data}.

triggered_charging_event_fun(ChargeEv, ChargingKeys, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	     Now = erlang:monotonic_time(),
	     ergw_gtp_gsn_lib:triggered_charging_event_m(ChargeEv, Now, ChargingKeys)
	 ]), State, Data).

triggered_charging_event_ok(_, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    {next_state, State, Data}.

triggered_charging_event_fail(Reason, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    close_pdn_context(Reason, State, Data),
    {next_state, State#{session := shutdown}, Data}.

%%%===================================================================
%%% Monadic Function Implementations
%%%===================================================================

start_session_fun(State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	     Now = erlang:monotonic_time(),

	     NodeCaps <- sx_node_attach(),

	     init_session(_, _),
	     AuthSEvs <- authenticate(),
	     select_vrf(NodeCaps),

	     PCCErrors0 <- gx_ccr_i(Now),
	     pcc_ctx_has_rules(),
	     {GySessionOpts, GyEvs} <- gy_ccr_i(Now),
	     statem_m:return(
	       begin
		   ?LOG(debug, "GySessionOpts: ~p", [GySessionOpts]),
		   ?LOG(debug, "Initial GyEvs: ~p", [GyEvs])
	       end),
	     RfSEvs <- rf_i(Now),
	     _ = ?LOG(debug, "RfSEvs: ~p", [RfSEvs]),
	     PCCErrors <- pfcp_create_session(Now, GyEvs, AuthSEvs, RfSEvs, PCCErrors0),
	     aaa_start(Now),
	     gx_error_report(Now, PCCErrors),
	     context_register()
	 ]), State, Data).

start_session_ok(_Result, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    {next_state, State#{session := run}, Data}.

start_session_fail(Error, _State, _Data) ->
    _ = ?LOG(debug, "~s: ~p", [?FUNCTION_NAME, Error]),

    ?LOG(debug, "TDF Init failed with ~p", [Error]),
    {stop, normal}.

%% TBD: check how far these functions are identical to gtp_context

gx_rar_fun(#aaa_request{events = Events}, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	     Now = erlang:monotonic_time(),
	     RuleBase = ergw_charging:rulebase(),

	     %% remove PCC rules
	     gx_events_to_pcc_ctx(Events, remove, RuleBase, _, _),
	     {_, UsageReport, _} <- pfcp_session_modification(),

	     %% collect charging data from remove rules
	     ChargeEv = {online, 'RAR'},   %% made up value, not use anywhere...
	     {Online, Offline, Monitor} <-
		 usage_report_to_charging_events(UsageReport, ChargeEv),

	     Session <- statem_m:get_data(maps:get('Session', _)),
	     _ = ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),

	     %% install new PCC rules
	     PCCErrors1 <- gx_events_to_pcc_ctx(Events, install, RuleBase, _, _),

	     GyReqServices <- gy_credit_request(Online, Data, _, _),

	     GyReqId <- statem_m:return(
			  ergw_context_statem:send_request(
			    fun() ->
				    ergw_gsn_lib:process_online_charging_events_sync(
				      ChargeEv, GyReqServices, Now, Session)
			    end)),
	     GyResult <- statem_m:wait(GyReqId),
	     GyEvs <- statem_m:lift(GyResult),

	     _ = ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),

	     %% install the new rules, collect any errors
	     PCCErrors2 <- gy_events_to_pcc_ctx(Now, GyEvs, _, _),
	     pfcp_session_modification(),

	     %% TODO Charging-Rule-Report for successfully installed/removed rules

	     %% return all PCC errors to be include the RAA
	     return(PCCErrors1 ++ PCCErrors2)
	 ]), State, Data).

gx_rar_ok(Request, Errors, State, Data) ->
    ?LOG(debug, "~s: ~p", [?FUNCTION_NAME, Errors]),

    GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(Errors),
    ergw_aaa_session:response(Request, ok, GxReport, #{}),
    {next_state, State, Data}.

gx_rar_fail(_Request, Error, State, Data) ->
    ?LOG(error, "gx_rar failed with ~p", [Error]),
    ct:fail(fail),

    %% TBD: Gx RAR Error reply
    {next_state, State, Data}.

update_credits_fun(CreditEv, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     Now = erlang:monotonic_time(),

	     _PCCErrors <- gy_events_to_pcc_ctx(Now, [CreditEv], _, _),
	     pfcp_session_modification()
	 ]), State, Data).

update_credits_ok(_Res, State, Data) ->
    ?LOG(debug, "~s: ~p", [?FUNCTION_NAME, _Res]),
    {next_state, State, Data}.
update_credits_fail(Error, State, Data) ->
    ?LOG(error, "update_credits failed with ~p", [Error]),
    ct:fail(fail),
    {next_state, State, Data}.

%%%===================================================================
%%% Monadic Function Helpers and Wrappers
%%%===================================================================

sx_node_attach() ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	   Node <- statem_m:get_data(maps:get(dp_node, _)),
	   {PCtx, NodeCaps} <- statem_m:lift(ergw_sx_node:attach(Node)),
	   statem_m:modify_data(_#{pctx => PCtx}),
	   return(NodeCaps)
       ]).

init_session(State, #{context := #tdf_ctx{ms_ip = UeIP}} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

    {MCC, MNC} = ergw_core:get_plmn_id(),
    Opts0 =
	#{'Username'		=> <<"ergw">>,
	  'Password'		=> <<"ergw">>,
	  'Service-Type'	=> 'Framed-User',
	  'Framed-Protocol'	=> 'PPP',
	  '3GPP-GGSN-MCC-MNC'	=> {MCC, MNC}
	 },
    Opts1 =
	case UeIP of
	    #ue_ip{v4 = IP4} when IP4 /= undefined ->
		IP4addr = ergw_inet:bin2ip(ergw_ip_pool:addr(IP4)),
		Opts0#{
		       'Framed-IP-Address' => IP4addr,
		       'Requested-IP-Address' => IP4addr};
	    _ ->
		Opts0
	end,
    Opts =
	case UeIP of
	    #ue_ip{v6 = IP6} when IP6 /= undefined ->
		IP6addr = ergw_inet:bin2ip(ergw_ip_pool:addr(IP6)),
		Opts1#{'Framed-IPv6-Prefix' => IP6addr,
		       'Requested-IPv6-Prefix' => IP6addr};
	    _ ->
		Opts1
	end,
    statem_m:return(Opts, State, Data#{session_opts => Opts}).

authenticate() ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	   #{'Session' := Session, session_opts := SessionOpts0} <- statem_m:get_data(),
	   ReqId <- statem_m:return(
		      ergw_context_statem:send_request(
			fun() -> ergw_gtp_gsn_session:authenticate(Session, SessionOpts0) end)),
	   Response <- statem_m:wait(ReqId),
	   {SessionOpts, AuthSEvs} <- statem_m:lift(Response),
	   _ = ?LOG(debug, "SessionOpts: ~p~nAuthSEvs: ~pn", [SessionOpts, AuthSEvs]),
	   statem_m:modify_data(_#{session_opts => SessionOpts}),
	   return(AuthSEvs)
       ]).

select_vrf(NodeCaps, APN, SessionOpts) ->
    case ergw_gsn_lib:select_vrf(NodeCaps, APN, SessionOpts) of
	{ok, _} = Result ->
	    Result;
	{error, _} ->
	    {error, ?CTX_ERR(?FATAL, system_failure)}
    end.

select_vrf(NodeCaps) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{apn := APN, session_opts := SessionOpts} <- statem_m:get_data(),
	   VRF <- statem_m:lift(select_vrf(NodeCaps, APN, SessionOpts)),

	   statem_m:modify_data(
	     maps:update_with(bearer, init_tdf_bearer(VRF, SessionOpts, _), _))
       ]).

gx_ccr_i(Now) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{session_opts := SessionOpts, 'Session' := Session, pcc := PCC0} <- statem_m:get_data(),
	   _ = ergw_aaa_session:set(Session, SessionOpts),
	   GxOpts = #{'Event-Trigger' => ?'DIAMETER_GX_EVENT-TRIGGER_UE_IP_ADDRESS_ALLOCATE',
		      'Bearer-Operation' => ?'DIAMETER_GX_BEARER-OPERATION_ESTABLISHMENT'},
	   ReqId <- statem_m:return(
		      ergw_context_statem:send_request(
			fun() -> ergw_gtp_gsn_session:ccr_initial(Session, gx, GxOpts, #{now => Now}) end)),
	   Response <- statem_m:wait(ReqId),
	   _ = ?LOG(debug, "Gx CCR-I Response: ~p", [Response]),
	   {_, GxEvents} <- statem_m:lift(Response),
	   RuleBase = ergw_charging:rulebase(),
	   {PCC, PCCErrors} = ergw_pcc_context:gx_events_to_pcc_ctx(GxEvents, '_', RuleBase, PCC0),
	   statem_m:modify_data(_#{pcc => PCC}),
	   statem_m:return(PCCErrors)
       ]).

pcc_ctx_has_rules() ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   PCC <- statem_m:get_data(maps:get(pcc, _)),
	   case ergw_pcc_context:pcc_ctx_has_rules(PCC) of
	       true ->
		   statem_m:return();
	       _ ->
		   statem_m:fail(user_authentication_failed)
	   end
       ]).

gy_ccr_i(Now) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{'Session' := Session, pcc := PCC} <- statem_m:get_data(),

	   %% TBD............
	   CreditsAdd = ergw_pcc_context:pcc_ctx_to_credit_request(PCC),
	   GyReqServices = #{credits => CreditsAdd},

	   ReqId <- statem_m:return(
		      ergw_context_statem:send_request(
			fun() -> ergw_gtp_gsn_session:ccr_initial(Session, gy, GyReqServices, #{now => Now}) end)),
	   Response <- statem_m:wait(ReqId),
	   _ = ?LOG(debug, "Gy CCR-I Response: ~p", [Response]),
	   statem_m:lift(Response)
       ]).

rf_i(Now) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{'Session' := Session} <- statem_m:get_data(),
	   {_, _, RfSEvs} = ergw_aaa_session:invoke(Session, #{}, {rf, 'Initial'}, #{now => Now}),
	   _ = ?LOG(debug, "RfSEvs: ~p", [RfSEvs]),
	   statem_m:return(RfSEvs)
       ]).

pfcp_create_session(Now, GyEvs, AuthSEvs, RfSEvs, PCCErrors0) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{context := Context, bearer := Bearer, pctx := PCtx0, pcc := PCC0}
	       <- statem_m:get_data(),
	   {PCC2, PCCErrors1} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, GyEvs, PCC0),
	   PCC3 = ergw_pcc_context:session_events_to_pcc_ctx(AuthSEvs, PCC2),
	   PCC4 = ergw_pcc_context:session_events_to_pcc_ctx(RfSEvs, PCC3),
	   statem_m:modify_data(_#{pcc => PCC4}),
	   {ReqId, PCtx} <-
	       statem_m:return(
		 ergw_pfcp_context:send_session_establishment_request(
		   tdf, PCC4, PCtx0, Bearer, Context)),
	   statem_m:modify_data(_#{pfcp => PCtx, mark => set}),

	   Response <- statem_m:wait(ReqId),
	   pfcp_create_session_response(Response),

	   statem_m:return(PCCErrors0 ++ PCCErrors1)
       ]).

pfcp_create_session_response(Response) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{bearer := Bearer0, pfcp := PCtx0} <- statem_m:get_data(),
	   {PCtx, Bearer, SessionInfo} <-
	       statem_m:lift(ergw_pfcp_context:receive_session_establishment_response(Response, tdf, PCtx0, Bearer0)),
	   statem_m:modify_data(
	     fun(Data) -> maps:update_with(
			    session_opts, maps:merge(_, SessionInfo),
			    Data#{bearer => Bearer, pfcp => PCtx})
	     end)
       ]).

aaa_start(Now) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{'Session' := Session, session_opts := SessionOpts} <- statem_m:get_data(),
	   statem_m:return(ergw_aaa_session:invoke(Session, SessionOpts, start, #{now => Now, async => true}))
       ]).

gx_error_report(Now, PCCErrors) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{'Session' := Session} <- statem_m:get_data(),
	   statem_m:return(
	     begin
		 GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(PCCErrors),
		 if map_size(GxReport) /= 0 ->
			 ergw_aaa_session:invoke(Session, GxReport,
						 {gx, 'CCR-Update'}, #{now => Now, async => true});
		    true ->
			 ok
		 end
	     end)
       ]).

context_register() ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{context := Context, bearer := Bearer} <- statem_m:get_data(),
	   Keys = context2keys(Bearer, Context),
	   statem_m:lift(gtp_context_reg:register(Keys, ?MODULE, self()))
       ]).

pfcp_session_modification() ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	   #{pfcp := PCtx0, pcc := PCC, bearer := Bearer} <- statem_m:get_data(),
	   {PCtx, ReqId} <-
	       statem_m:return(
		 ergw_pfcp_context:send_session_modification_request(
		   PCC, [], #{}, Bearer, PCtx0)),
	   statem_m:modify_data(_#{pfcp => PCtx}),
	   Response <- statem_m:wait(ReqId),

	   PCtx1 <- statem_m:get_data(maps:get(pfcp, _)),
	   statem_m:lift(
	     ergw_pfcp_context:receive_session_modification_response(PCtx1, Response))
       ]).

gx_events_to_pcc_ctx(Evs, Filter, RuleBase, State, #{pcc := PCC0} = Data) ->
    {PCC, Errors} = ergw_pcc_context:gx_events_to_pcc_ctx(Evs, Filter, RuleBase, PCC0),
    statem_m:return(Errors, State, Data#{pcc => PCC}).

gy_events_to_pcc_ctx(Now, Evs, State, #{pcc := PCC0} = Data) ->
    {PCC, Errors} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, Evs, PCC0),
    statem_m:return(Errors, State, Data#{pcc => PCC}).

usage_report_to_charging_events(UsageReport, ChargeEv) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   PCtx <- statem_m:get_data(maps:get(pfcp, _)),
	   return(
	     ergw_pfcp_context:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx))
       ]).

gy_credit_request(Online, #{pcc := PCC0}, State, #{pcc := PCC2} = Data) ->
    GyReqServices = ergw_pcc_context:gy_credit_request(Online, PCC0, PCC2),
    statem_m:return(GyReqServices, State, Data).

%%====================================================================
%% context registry
%%====================================================================

vrf_keys(#{left := #bearer{vrf = InVrf}, right := #bearer{vrf = OutVrf}}, IP)
  when is_binary(InVrf), is_binary(OutVrf), IP /= undefined ->
    Addr = ergw_ip_pool:addr(IP),
    [{ue, InVrf, Addr}, {ue, OutVrf, Addr}];
vrf_keys(_, _) ->
    [].

context2keys(Bearer, #tdf_ctx{ms_ip = #ue_ip{v4 = IP4, v6 = IP6}}) ->
    vrf_keys(Bearer, IP4) ++
	vrf_keys(Bearer, IP6).
