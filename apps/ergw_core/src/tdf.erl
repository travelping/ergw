%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(tdf).

%%-behaviour(gtp_api).
-behavior(gen_statem).
-behavior(ergw_context).

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

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

%% new style async FSM helpers
-export([next/5, send_request/1]).

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
    gen_statem:start_link(?MODULE, [Node, VRF, IP4, IP6, SxOpts], GenOpts).

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

callback_mode() -> [handle_event_function, state_enter].

maybe_ip(IP, Len) when is_binary(IP) -> ergw_ip_pool:static_ip(IP, Len);
maybe_ip(_,_) -> undefined.

init([Node, InVRF, IP4, IP6, #{apn := APN} = _SxOpts]) ->
    process_flag(trap_exit, true),

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
    Data = #{apn       => APN,
	     context   => Context,
	     dp_node   => Node,
	     'Session' => Session,
	     pcc       => PCC,
	     bearer    => Bearer
	    },

    ?LOG(info, "TDF process started for ~p", [[Node, IP4, IP6]]),
    {ok, ergw_context:init_state(), Data, [{next_event, internal, init}]}.

%%
%% async functions support
%%
handle_event(info, {{'DOWN', ReqId}, _, _, _, Info}, #{async := Async} = State, Data)
  when is_map_key(ReqId, Async) ->
    statem_m_continue(ReqId, {error, Info}, false, State, Data);
handle_event(info, {{'DOWN', _}, _, _, _, _}, _, _) ->
    keep_state_and_data;

handle_event(info, {'DOWN', _, process, ReqId, Info}, #{async := Async} = State, Data)
  when is_map_key(ReqId, Async) ->
    statem_m_continue(ReqId, {error, Info}, false, State, Data);

handle_event(info, {ReqId, Result}, #{async := Async} = State, Data)
  when is_map_key(ReqId, Async) ->
    statem_m_continue(ReqId, Result, false, State, Data);

%% OTP-24 style send_request responses.... WE REALLY SHOULD NOT BE DOING THIS
handle_event(info, {'DOWN', ReqId, _, _, Info}, #{async := Async} = State, Data)
  when is_map_key(ReqId, Async) ->
    statem_m_continue(ReqId, {error, Info}, false, State, Data);
handle_event(info, {[alias|ReqId], Result}, #{async := Async} = State, Data)
  when is_map_key(ReqId, Async) ->
    statem_m_continue(ReqId, Result, true, State, Data);

%% OTP-23 style send_request responses.... WE REALLY SHOULD NOT BE DOING THIS
handle_event(info, {{'$gen_request_id', ReqId}, Result}, #{async := Async} = State, Data)
  when is_map_key(ReqId, Async) ->
    statem_m_continue(ReqId, Result, true, State, Data);

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

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event(internal, init, #{session := init} = State, Data0) ->
    %% start Rf/Gx/Gy interaction
    try
	Data = start_session(Data0),
	{next_state, State#{session := run}, Data}
    catch
	throw:_Error ->
	    ?LOG(debug, "TDF Init failed with ~p", [_Error]),
	    {stop, normal}
    end;

handle_event({call, From}, {sx, #pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{usar = 1},
			      usage_report_srr := UsageReport}} = Report},
	    _State, #{'Session' := Session, pfcp := PCtx, pcc := PCC}) ->
    ?LOG(debug, "~w: handle_call Sx: ~p", [?MODULE, Report]),

    Now = erlang:monotonic_time(),
    ReqOpts = #{now => Now, async => true},

    ChargeEv = interim,
    {Online, Offline, Monitor} =
	ergw_pfcp_context:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),
    ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),
    GyReqServices = ergw_pcc_context:gy_credit_request(Online, PCC),
    ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOpts),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),

    {keep_state_and_data, [{reply, From, {ok, PCtx}}]};

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
    tdf:next(
      gx_rar_fun(Request, _, _),
      gx_rar_ok(Request, _, _, _),
      gx_rar_fail(Request, _, _, _),
      State, Data);

handle_event(info, #aaa_request{procedure = {gy, 'RAR'},
				events = Events} = Request,
	     _State, Data) ->
    ergw_aaa_session:response(Request, ok, #{}, #{}),
    Now = erlang:monotonic_time(),

    %% Triggered CCR.....
    ChargingKeys =
	case proplists:get_value(report_rating_group, Events) of
	    RatingGroups when is_list(RatingGroups) ->
		[{online, RG} || RG <- RatingGroups];
	    _ ->
		undefined
	end,
    triggered_charging_event(interim, Now, ChargingKeys, Data),
    keep_state_and_data;

%% Enable AAA to provide reason for session stop
handle_event(internal, {session, {stop, Reason}, _Session}, State, Data) ->
    close_pdn_context(Reason, State, Data),
    {next_state, State#{session := shutdown}, Data};

handle_event(internal, {session, stop, _Session}, State, Data) ->
    close_pdn_context(normal, State, Data),
    {next_state, State#{session := shutdown}, Data};

handle_event(internal, {session, {update_credits, _} = CreditEv, _}, State, Data) ->
    gtp_context:next(
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

handle_event(info, {timeout, TRef, pfcp_timer} = Info, _State,
	     #{pfcp := PCtx0} = Data0) ->
    Now = erlang:monotonic_time(),
    ?LOG(debug, "handle_info TDF:~p", [Info]),

    {Evs, PCtx} = ergw_pfcp:timer_expired(TRef, PCtx0),
    CtxEvs = ergw_gsn_lib:pfcp_to_context_event(Evs),
    Data = maps:fold(handle_charging_event(_, _, Now, _), Data0#{pfcp => PCtx}, CtxEvs),
    {keep_state, Data};

handle_event(info, _Info, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

start_session(#{apn := APN, context := Context, dp_node := Node,
		'Session' := Session, pcc := PCC0, bearer := Bearer0} = Data) ->

    {PendingPCtx, NodeCaps} =
	case ergw_sx_node:attach(Node) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context})
	end,

    Now = erlang:monotonic_time(),
    SOpts = #{now => Now},

    SessionOpts0 = init_session(Data),
    {SessionOpts1, AuthSEvs} =
	case authenticate(Session, SessionOpts0) of
	    {ok, Result2} -> Result2;
	    {error, Err2} -> throw({fail, Err2})
	end,

    VRF =
	case ergw_gsn_lib:select_vrf(NodeCaps, APN, SessionOpts1) of
	    {ok, SelVRF} -> SelVRF;
	    {error, _} -> Err2a = ?CTX_ERR(?FATAL, system_failure),
			  throw(Err2a#ctx_err{context = Context})
	end,

    Bearer1 = maps:update_with(right, _#bearer{vrf = VRF}, Bearer0),
    Bearer2 = apply_bearer_opts(SessionOpts1, Bearer1),

    %% -----------------------------------------------------------
    %% TBD: maybe reselect VRF based on outcome of authenticate ??
    %% -----------------------------------------------------------

    GxOpts = #{'Event-Trigger' => ?'DIAMETER_GX_EVENT-TRIGGER_UE_IP_ADDRESS_ALLOCATE',
	       'Bearer-Operation' => ?'DIAMETER_GX_BEARER-OPERATION_ESTABLISHMENT'},

    {_, GxEvents} =
	case ccr_initial(Session, gx, GxOpts, SOpts) of
	    {ok, Result3} -> Result3;
	    {error, Err3} -> throw({fail, Err3})
	end,

    RuleBase = ergw_charging:rulebase(),
    {PCC1, PCCErrors1} =
	ergw_pcc_context:gx_events_to_pcc_ctx(GxEvents, '_', RuleBase, PCC0),

    case ergw_pcc_context:pcc_ctx_has_rules(PCC1) of
	true -> ok;
	_    -> throw({fail, {authenticate, no_pcc_rules}})
    end,

    %% TBD............
    CreditsAdd = ergw_pcc_context:pcc_ctx_to_credit_request(PCC1),
    GyReqServices = #{credits => CreditsAdd},

    {GySessionOpts, GyEvs} =
	case ccr_initial(Session, gy, GyReqServices, SOpts) of
	    {ok, Result4} -> Result4;
	    {error, Err4} -> throw({fail, Err4})
	end,

    ?LOG(debug, "GySessionOpts: ~p", [GySessionOpts]),

    {_, _, RfSEvs} = ergw_aaa_session:invoke(Session, #{}, {rf, 'Initial'}, SOpts),

    {PCC2, PCCErrors2} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, GyEvs, PCC1),
    PCC3 = ergw_pcc_context:session_events_to_pcc_ctx(AuthSEvs, PCC2),
    PCC4 = ergw_pcc_context:session_events_to_pcc_ctx(RfSEvs, PCC3),

    {PCtx, Bearer, SessionInfo} =
	case ergw_pfcp_context:create_session(tdf, PCC4, PendingPCtx, Bearer2, Context) of
	    {ok, Result5} -> Result5;
	    {error, Err5} -> throw({fail, Err5})
	end,

    SessionOpts = maps:merge(SessionOpts1, SessionInfo),
    ergw_aaa_session:invoke(Session, SessionOpts, start, SOpts#{async => true}),

    Keys = context2keys(Bearer, Context),
    gtp_context_reg:register(Keys, ?MODULE, self()),

    GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(PCCErrors1 ++ PCCErrors2),
    if map_size(GxReport) /= 0 ->
	    ergw_aaa_session:invoke(Session, GxReport,
				    {gx, 'CCR-Update'}, SOpts#{async => true});
       true ->
	    ok
    end,

    Data#{context => Context, pfcp => PCtx, pcc => PCC4, bearer => Bearer}.

init_session(#{context := #tdf_ctx{ms_ip = UeIP}}) ->
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
    case UeIP of
	#ue_ip{v6 = IP6} when IP6 /= undefined ->
	    IP6addr = ergw_inet:bin2ip(ergw_ip_pool:addr(IP6)),
	    Opts1#{'Framed-IPv6-Prefix' => IP6addr,
		   'Requested-IPv6-Prefix' => IP6addr};
	_ ->
	    Opts1
    end.

apply_bearer_opts('NAT-Pool-Id', Id, #{right := #bearer{local = Local} = Right} = Bearer)
  when is_record(Local, ue_ip) ->
    Bearer#{right => Right#bearer{local = Local#ue_ip{nat = Id}}};
apply_bearer_opts(_, _, Bearer) ->
    Bearer.

apply_bearer_opts(SOpts, Bearer) ->
    maps:fold(fun apply_bearer_opts/3, Bearer, SOpts).

authenticate(Session, SessionOpts) ->
    ?LOG(debug, "SessionOpts: ~p", [SessionOpts]),
    case ergw_aaa_session:invoke(Session, SessionOpts, authenticate, [inc_session_id]) of
	{ok, SOpts, SEvs} ->
	    {ok, {SOpts, SEvs}};
	Other ->
	    ?LOG(debug, "AuthResult: ~p", [Other]),
	    {error, {authenticate, Other}}
    end.

ccr_initial(Session, API, SessionOpts, ReqOpts) ->
    case ergw_aaa_session:invoke(Session, SessionOpts, {API, 'CCR-Initial'}, ReqOpts) of
	{ok, SOpts, SEvs} ->
	    {ok, {SOpts, SEvs}};
	{Fail, _, _} ->
	    %% TBD: replace with sensible mapping
	    {error, {'CCR-Initial', Fail}}
    end.

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
    ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOpts),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),
    ergw_prometheus:termination_cause(API, TermCause),

    ok;
close_pdn_context(_Reason, _State, _Data) ->
    ok.

query_usage_report(ChargingKeys, PCtx)
  when is_list(ChargingKeys) ->
    ergw_pfcp_context:query_usage_report(ChargingKeys, PCtx);
query_usage_report(_, PCtx) ->
    ergw_pfcp_context:query_usage_report(PCtx).

triggered_charging_event(ChargeEv, Now, Request,
			 #{pfcp := PCtx, 'Session' := Session, pcc := PCC}) ->
    ReqOpts = #{now => Now, async => true},

    case query_usage_report(Request, PCtx) of
	{ok, {_, UsageReport, _}} ->
	    {Online, Offline, Monitor} =
		ergw_pfcp_context:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),
	    ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),
	    GyReqServices = ergw_pcc_context:gy_credit_request(Online, PCC),
	    ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOpts),
	    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session);
	{error, CtxErr} ->
	    ?LOG(error, "Triggered Charging Event failed with ~p", [CtxErr])
    end,
    ok.

handle_charging_event(validity_time, ChargingKeys, Now, Data) ->
    triggered_charging_event(validity_time, Now, ChargingKeys, Data),
    Data;
handle_charging_event(Key, Ev, _Now, Data) ->
    ?LOG(debug, "TDF: unhandled charging event ~p:~p",[Key, Ev]),
    Data.

%%%===================================================================
%%% Monadic Function Implementations
%%%===================================================================

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
			  gtp_context:send_request(
			    fun() ->
				    ergw_gsn_lib:process_online_charging_events(
				      ChargeEv, GyReqServices, Session, #{now => Now})
			    end)),
	     {ok, _, GyEvs} <- statem_m:wait(GyReqId),

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
    {next_state, State, Data}.

%%%===================================================================
%%% Monadic Function Helpers and Wrappers
%%%===================================================================

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

%%====================================================================
%% new style async FSM helpers
%%====================================================================

%% tdf_ok(_, State, Data) ->
%%     {next_state, State, Data}.

%% tdf_fail(#ctx_err{reply = Cause}, State, Data) ->
%%     close_pdn_context(Cause, State, Data),
%%     {next_state, State#{session := shutdown}, Data};
%% tdf_fail(_, State, Data) ->
%%     %% TBD: clean shutdown ???
%%     {next_state, State#{session := shutdown}, Data}.

%% next(StateFun, State, Data) ->
%%     next(StateFun, fun tdf_ok/3, fun tdf_fail/3, State, Data).

next(StateFun, OkF, FailF, State0, Data0)
  when is_function(StateFun, 2),
       is_function(OkF, 3),
       is_function(FailF, 3) ->
    {Result, State, Data} = StateFun(State0, Data0),
    next(Result, OkF, FailF, State, Data);

next(ok, Fun, _, State, Data)
  when is_function(Fun, 3) ->
    Fun(ok, State, Data);
next({ok, Result}, Fun, _, State, Data)
  when is_function(Fun, 3) ->
    Fun(Result, State, Data);
next({error, Result}, _, Fun, State, Data)
  when is_function(Fun, 3) ->
    Fun(Result, State, Data);
next({wait, ReqId, Q}, OkF, FailF, #{async := Async} = State, Data)
  when (is_reference(ReqId) orelse is_pid(ReqId)),
       is_list(Q),
       is_function(OkF, 3),
       is_function(FailF, 3) ->
    Req = {ReqId, Q, OkF, FailF},
    {next_state, State#{async := maps:put(ReqId, Req, Async)}, Data}.

statem_m_continue(ReqId, Result, DeMonitor, #{async := Async0} = State, Data) ->
    {{Mref, Q, OkF, FailF}, Async} = maps:take(ReqId, Async0),
    case DeMonitor of
	true -> demonitor(Mref, [flush]);
	_ -> ok
    end,
    ?LOG(debug, "Result: ~p~n", [Result]),
    next(statem_m:response(Q, Result, _, _), OkF, FailF, State#{async := Async}, Data).

-if(?OTP_RELEASE =< 23).

send_request(Fun) when is_function(Fun, 0) ->
    Owner = self(),
    {Pid, _} = spawn_opt(fun() -> Owner ! {self(), Fun()} end, [monitor]),
    Pid.

-else.

send_request(Fun) when is_function(Fun, 0) ->
    Owner = self(),
    ReqId = make_ref(),
    Opts = [{monitor, [{tag, {'DOWN', ReqId}}]}],
    spawn_opt(fun() -> Owner ! {ReqId, Fun()} end, Opts),
    ReqId.

-endif.
