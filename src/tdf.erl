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

%% ergw_context callbacks
-export([sx_report/2, port_message/2, port_message/4]).

-ifdef(TEST).
-export([test_cmd/2]).
-endif.

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define(SERVER, ?MODULE).
-define(TestCmdTag, '$TestCmd').

-record(data, {dp_node :: pid(),
		session :: pid(),

		context,
		pfcp}).

%%====================================================================
%% API
%%====================================================================

start_link(Node, VRF, IP4, IP6, SxOpts, GenOpts) ->
    gen_statem:start_link(?MODULE, [Node, VRF, IP4, IP6, SxOpts], GenOpts).

unsolicited_report(Node, VRF, IP4, IP6, SxOpts) ->
    tdf_sup:new(Node, VRF, IP4, IP6, SxOpts).

-ifdef(TEST).

test_cmd(Pid, Cmd) when is_pid(Pid) ->
    gen_statem:call(Pid, {?TestCmdTag, Cmd}).

-endif.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(HandlerDefaults, [{node_selection, undefined},
			  {nodes, undefined},
			  {apn, undefined}]).

validate_options(Options) ->
    lager:debug("TDF Options: ~p", [Options]),
    ergw_config:validate_options(fun validate_option/2, Options, ?HandlerDefaults, map).

validate_option(protocol, ip) ->
    ip;
validate_option(handler, Value) when is_atom(Value) ->
    Value;
validate_option(node_selection, [S|_] = Value)
  when is_atom(S) ->
    Value;
validate_option(nodes, [S|_] = Value)
  when is_list(S) ->
    Value;
validate_option(apn, APN)
  when is_list(APN) ->
    ergw_config:validate_apn_name(APN);
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%====================================================================
%% ergw_context API
%%====================================================================

sx_report(Server, Report) ->
    gen_statem:call(Server, {sx, Report}).

port_message(Request, Msg) ->
    %% we currently do not configure DP to CP forwards,
    %% so this should not happen

    lager:error("Port Message ~p, ~p", [Request, Msg]),
    error(badarg, [Request, Msg]).

port_message(Server, Request, Msg, Resent) ->
    %% we currently do not configure DP to CP forwards,
    %% so this should not happen

    lager:error("Port Message ~p, ~p", [Server, Request, Msg, Resent]),
    error(badarg, [Server, Request, Msg, Resent]).

%%====================================================================
%% gen_statem API
%%====================================================================

callback_mode() -> [handle_event_function, state_enter].

init([Node, InVRF, IP4, IP6, #{apn := APN} = _SxOpts]) ->
    process_flag(trap_exit, true),

    monitor(process, Node),
    %% lager:debug("APN: ~p", [APN]),

    %% {ok, {VRF, VRFOpts}} = ergw:vrf_lookup(APN),
    %% lager:debug("VRF: ~p, Opts: ~p", [VRF, VRFOpts]),

    %% Services = [{"x-3gpp-upf", "x-sxc"}],
    %% {ok, SxPid} = ergw_sx_node:select_sx_node(APN, Services, NodeSelect),
    %% lager:debug("SxPid: ~p", [SxPid]),

    {ok, {OutVrf, _}} = ergw:vrf(APN),
    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),
    Context = #tdf_ctx{
		 in_vrf = InVRF,
		 out_vrf = OutVrf,
		 ms_v4 = {IP4, 32},
		 ms_v6 = {IP6, 128}
		},
    Data = #data{
	       context = Context,
	       dp_node = Node,
	       session = Session
	      },

    lager:info("TDF process started for ~p", [[Node, IP4, IP6]]),
    {ok, init, Data, [{next_event, internal, init}]}.

handle_event(enter, _OldState, shutdown, _Data) ->
    % TODO unregsiter context ....

    %% this makes stop the last message in the inbox and
    %% guarantees that we process any left over messages first
    gen_statem:cast(self(), stop),
    keep_state_and_data;

handle_event(cast, stop, shutdown, _Data) ->
    {stop, normal};

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event(internal, init, init, Data0) ->
    %% start Rf/Gx/Gy interaction
    try
	Data = start_session(Data0),
	{next_state, run, Data}
    catch
	throw:_Error ->
	    lager:debug("TDF Init failed with ~p", [_Error]),
	    {stop, normal}
    end;

handle_event({call, From}, {?TestCmdTag, pfcp_ctx}, _State, #data{pfcp = PCtx}) ->
    {keep_state_and_data, [{reply, From, {ok, PCtx}}]};
handle_event({call, From}, {?TestCmdTag, session}, _State, #data{session = Session}) ->
    {keep_state_and_data, [{reply, From, {ok, Session}}]};
handle_event({call, From}, {?TestCmdTag, pcc_rules}, _State, #data{session = Session}) ->
    SOpts = ergw_aaa_session:get(Session),
    PCR = maps:get('PCC-Rules', SOpts, undefined),
    {keep_state_and_data, [{reply, From, {ok, PCR}}]};

handle_event({call, From}, {sx, #pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{usar = 1},
			      usage_report_srr := UsageReport}} = Report},
	    _State, #data{session = Session, pfcp = PCtx}) ->
    lager:debug("~w: handle_call Sx: ~p", [?MODULE, lager:pr(Report, ?MODULE)]),

    Now = erlang:monotonic_time(),
    ChargeEv = interim,
    {Online, Offline, _} =
	ergw_gsn_lib:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),
    ergw_gsn_lib:process_online_charging_events(ChargeEv, Online, Now, Session),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),

    {keep_state_and_data, [{reply, From, {ok, PCtx}}]};

handle_event({call, From}, {sx, Report}, _State, #data{pfcp = PCtx}) ->
    lager:warning("~w: unhandled Sx report: ~p", [?MODULE, lager:pr(Report, ?MODULE)]),
    {keep_state_and_data, [{reply, From, {ok, PCtx, 'System failure'}}]};

handle_event({call, From}, _Request, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

handle_event(cast, _Request, _State, _Data) ->
    keep_state_and_data;

handle_event(info, {'DOWN', _MonitorRef, Type, Pid, _Info},
	     State, #data{dp_node = Pid} = Data)
  when Type == process; Type == pfcp ->
    close_pdn_context(upf_failure, State, Data),
    {next_state, shutdown, Data};

handle_event(info, stop_from_session, State, Data) ->
    close_pdn_context(normal, State, Data),
    {next_state, shutdown, Data};

handle_event(info, #aaa_request{procedure = {_, 'RAR'}} = Request, shutdown, _Data) ->
    ergw_aaa_session:response(Request, {error, unknown_session}, #{}, #{}),
    keep_state_and_data;

handle_event(info, #aaa_request{procedure = {_, 'ASR'}} = Request, State, Data) ->
    ergw_aaa_session:response(Request, ok, #{}, #{}),
    close_pdn_context(normal, State, Data),
    {next_state, shutdown, Data};

handle_event(info, #aaa_request{procedure = {gx, 'RAR'},
			 session = SessionOpts,
			 events = Events} = Request,
	     _State,
	     #data{context = Context, pfcp = PCtx0, session = Session} = Data) ->
    Now = erlang:monotonic_time(),

    RuleBase = ergw_charging:rulebase(),
    PCCRules0 = maps:get('PCC-Rules', SessionOpts, #{}),
    {PCCRules1, _} =
	ergw_gsn_lib:gx_events_to_pcc_rules(Events, remove, RuleBase, PCCRules0),

    URRActions = [],
    {PCtx1, UsageReport} =
	ergw_gsn_lib:modify_sgi_session(SessionOpts#{'PCC-Rules' => PCCRules1}, [],
					URRActions, #{}, Context, PCtx0),

    {PCCRules2, PCCErrors2} =
	ergw_gsn_lib:gx_events_to_pcc_rules(Events, install, RuleBase, PCCRules1),
    ergw_aaa_session:set(Session, 'PCC-Rules', PCCRules2),

    CreditsOld = ergw_gsn_lib:pcc_rules_to_credit_request(PCCRules1),
    CreditsNew = ergw_gsn_lib:pcc_rules_to_credit_request(PCCRules2),
    Credits = maps:without(maps:keys(CreditsOld), CreditsNew),

    GyReqServices =
	if length(Credits) /= 0 -> #{credits => Credits};
	   true                 -> #{}
	end,
    ReqOps = #{now => Now},

    ChargeEv = {online, 'RAR'},   %% made up value, not use anywhere...
    {Online, Offline, _} =
	ergw_gsn_lib:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx1),
    {ok, FinalSessionOpts, GyEvs} =
	ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Online, Session, ReqOps),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),

    {PCtx, _} =
	ergw_gsn_lib:modify_sgi_session(FinalSessionOpts, GyEvs, URRActions, #{}, Context, PCtx1),

    %% TODO Charging-Rule-Report for successfully installed/removed rules

    GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(PCCErrors2),
    SOpts = #{'PCC-Rules' => PCCRules2},
    ergw_aaa_session:response(Request, ok, GxReport, SOpts),
    {keep_state, Data#data{pfcp = PCtx}};

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

handle_event(info, {update_session, Session, Events} = Us, _State,
	     #data{context = Context, pfcp = PCtx0} = Data) ->
    lager:warning("UpdateSession: ~p", [Us]),
    PCtx =  ergw_gsn_lib:session_events(Session, Events, Context, PCtx0),
    {keep_state, Data#data{pfcp = PCtx}};

handle_event(info, {timeout, TRef, pfcp_timer} = Info, _State,
	     #data{pfcp = PCtx0} = Data0) ->
    Now = erlang:monotonic_time(),
    lager:debug("handle_info TDF:~p", [lager:pr(Info, ?MODULE)]),

    {Evs, PCtx} = ergw_pfcp:timer_expired(TRef, PCtx0),
    CtxEvs = ergw_gsn_lib:pfcp_to_context_event(Evs),
    Data = maps:fold(handle_charging_event(_, _, Now, _), Data0#data{pfcp = PCtx}, CtxEvs),
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

start_session(#data{context = Context, dp_node = Node, session = Session} = Data) ->
    SOpts = #{now => erlang:monotonic_time()},

    SessionOpts = init_session(Data),
    authenticate(Session, SessionOpts),

    GxOpts = #{'Event-Trigger' => ?'DIAMETER_GX_EVENT-TRIGGER_UE_IP_ADDRESS_ALLOCATE',
	       'Bearer-Operation' => ?'DIAMETER_GX_BEARER-OPERATION_ESTABLISHMENT'},

    {ok, _, GxEvents} =
	ccr_initial(Session, gx, GxOpts, SOpts),

    RuleBase = ergw_charging:rulebase(),
    {PCCRules, PCCErrors} =
	ergw_gsn_lib:gx_events_to_pcc_rules(GxEvents, '_', RuleBase, #{}),

    if PCCRules =:= #{} ->
	    throw({fail, authenticate, no_pcc_rules});
       true ->
	    ok
    end,

    Credits = ergw_gsn_lib:pcc_rules_to_credit_request(PCCRules),
    GyReqServices = #{'PCC-Rules' => PCCRules, credits => Credits},

    {ok, GySessionOpts, GyEvs} =
	ccr_initial(Session, gy, GyReqServices, SOpts),
    lager:info("GySessionOpts: ~p", [GySessionOpts]),

    ergw_aaa_session:invoke(Session, #{}, start, SOpts),
    ergw_aaa_session:invoke(Session, #{}, {rf, 'Initial'}, SOpts),
    FinalSessionOpts = ergw_aaa_session:get(Session),

    lager:info("FinalS: ~p", [FinalSessionOpts]),

    {_, PCtx} = ergw_gsn_lib:create_tdf_session(Node, FinalSessionOpts, GyEvs, Context),

    Keys = context2keys(Context),
    gtp_context_reg:register(Keys, ?MODULE, self()),

    GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(PCCErrors),
    if map_size(GxReport) /= 0 ->
	    ergw_aaa_session:invoke(Session, GxReport,
				    {gx, 'CCR-Update'}, SOpts#{async => true});
       true ->
	    ok
    end,

    Data#data{pfcp = PCtx}.

init_session(#data{context = Context}) ->
    {MCC, MNC} = ergw:get_plmn_id(),
    Opts0 =
	#{'Username'		=> <<"ergw">>,
	  'Password'		=> <<"ergw">>,
	  'Service-Type'	=> 'Framed-User',
	  'Framed-Protocol'	=> 'PPP',
	  '3GPP-GGSN-MCC-MNC'	=> <<MCC/binary, MNC/binary>>
	 },
    Opts1 =
	case Context of
	    #tdf_ctx{ms_v4 = {IP4, _}}
	      when is_binary(IP4) ->
		IP4addr = ergw_inet:bin2ip(IP4),
		Opts0#{
		       'Framed-IP-Address' => IP4addr,
		       'Requested-IP-Address' => IP4addr};
	    _ ->
		Opts0
	end,
    case Context of
	#tdf_ctx{ms_v6 = {IP6, _}}
	  when is_binary(IP6) ->
	    IP6addr = ergw_inet:bin2ip(IP6),
	    Opts1#{'Framed-IPv6-Prefix' => IP6addr,
		   'Requested-IPv6-Prefix' => IP6addr};
	_ ->
	    Opts1
    end.


authenticate(Session, SessionOpts) ->
    lager:info("SessionOpts: ~p", [SessionOpts]),
    case ergw_aaa_session:invoke(Session, SessionOpts, authenticate, [inc_session_id]) of
	{ok, NewSOpts, _Events} ->
	    NewSOpts;
	Other ->
	    lager:info("AuthResult: ~p", [Other]),
	    throw({fail, authenticate, Other})
    end.

ccr_initial(Session, API, SessionOpts, ReqOpts) ->
    case ergw_aaa_session:invoke(Session, SessionOpts, {API, 'CCR-Initial'}, ReqOpts) of
	{ok, _, _} = Result ->
	    Result;
	{Fail, _, _} ->
	    throw({fail, 'CCR-Initial', Fail})
    end.

close_pdn_context(Reason, run, #data{context = Context, pfcp = PCtx, session = Session}) ->
    URRs = ergw_gsn_lib:delete_sgi_session(Reason, Context, PCtx),

    TermCause =
	case Reason of
	    upf_failure ->
		?'DIAMETER_BASE_TERMINATION-CAUSE_LINK_BROKEN';
	    _ ->
		?'DIAMETER_BASE_TERMINATION-CAUSE_LOGOUT'
	end,

    %% TODO: Monitors, AAA over SGi

    %%  1. CCR on Gx to get PCC rules
    Now = erlang:monotonic_time(),
    SOpts = #{now => Now},
    case ergw_aaa_session:invoke(Session, #{}, {gx, 'CCR-Terminate'}, SOpts) of
	{ok, _GxSessionOpts, _} ->
	    lager:info("GxSessionOpts: ~p", [_GxSessionOpts]);
	GxOther ->
	    lager:warning("Gx terminate failed with: ~p", [GxOther])
    end,

    ergw_aaa_session:invoke(Session, #{}, stop, SOpts#{async => true}),

    ChargeEv = {terminate, TermCause},
    {Online, Offline, _} =
	ergw_gsn_lib:usage_report_to_charging_events(URRs, ChargeEv, PCtx),
    ergw_gsn_lib:process_online_charging_events(ChargeEv, Online, Now, Session),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),

    ok;
close_pdn_context(_Reason, _State, _Data) ->
    ok.

query_usage_report(ChargingKeys, Context, PCtx)
  when is_list(ChargingKeys) ->
    ergw_gsn_lib:query_usage_report(ChargingKeys, Context, PCtx);
query_usage_report(_, Context, PCtx) ->
    ergw_gsn_lib:query_usage_report(Context, PCtx).

triggered_charging_event(ChargeEv, Now, Request,
			 #data{context = Context, pfcp = PCtx, session = Session}) ->
    try
	{_, UsageReport} =
	    query_usage_report(Request, Context, PCtx),
	{Online, Offline, _} =
	    ergw_gsn_lib:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),
	ergw_gsn_lib:process_online_charging_events(ChargeEv, Online, Now, Session),
	ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session)
    catch
	throw:#ctx_err{} = CtxErr ->
	    lager:error("Triggered Charging Event failed with ~p", [CtxErr])
    end,
    ok.

handle_charging_event(validity_time, ChargingKeys, Now, Data) ->
    triggered_charging_event(validity_time, Now, ChargingKeys, Data),
    Data;
handle_charging_event(Key, Ev, _Now, Data) ->
    lager:debug("TDF: unhandled charging event ~p:~p",[Key, Ev]),
    Data.

%%====================================================================
%% context registry
%%====================================================================

vrf_keys(#tdf_ctx{in_vrf = InVrf, out_vrf = OutVrf}, {IP, _})
  when is_binary(InVrf) andalso is_binary(OutVrf) andalso
       is_binary(IP) andalso (size(IP) == 4 orelse size(IP) == 16) ->
    [{ue, InVrf, IP}, {ue, OutVrf, IP}];
vrf_keys(_, _) ->
    [].

context2keys(#tdf_ctx{ms_v4 = IP4, ms_v6 = IP6} = Ctx) ->
    vrf_keys(Ctx, IP4) ++ vrf_keys(Ctx, IP6).
