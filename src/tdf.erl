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
-export([ctx_sx_report/2, ctx_pfcp_timer/3, port_message/2, ctx_port_message/4]).

-ifdef(TEST).
-export([test_cmd/2]).
-endif.

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-include_lib("kernel/include/logger.hrl").
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

	       apn,
	       context,
	       pfcp,
	       pcc :: #pcc_ctx{},
	       bearer :: #{Key :: atom() := Value :: #bearer{}}
	      }).

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
    ?LOG(debug, "TDF Options: ~p", [Options]),
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

ctx_sx_report(Server, Report) ->
    gen_statem:call(Server, {sx, Report}).

ctx_pfcp_timer(Server, Time, Evs) ->
    gen_statem:call(Server, {pfcp_timer, Time, Evs}).

port_message(Request, Msg) ->
    %% we currently do not configure DP to CP forwards,
    %% so this should not happen

    ?LOG(error, "Port Message ~p, ~p", [Request, Msg]),
    error(badarg, [Request, Msg]).

ctx_port_message(Server, Request, Msg, Resent) ->
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
    Data = #data{
	      apn     = APN,
	      context = Context,
	      dp_node = Node,
	      session = Session,
	      pcc     = PCC,
	      bearer  = Bearer
	     },

    ?LOG(info, "TDF process started for ~p", [[Node, IP4, IP6]]),
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
	    ?LOG(debug, "TDF Init failed with ~p", [_Error]),
	    {stop, normal}
    end;

handle_event({call, From}, {?TestCmdTag, pfcp_ctx}, _State, #data{pfcp = PCtx}) ->
    {keep_state_and_data, [{reply, From, {ok, PCtx}}]};
handle_event({call, From}, {?TestCmdTag, session}, _State, #data{session = Session}) ->
    {keep_state_and_data, [{reply, From, {ok, Session}}]};
handle_event({call, From}, {?TestCmdTag, pcc_rules}, _State, #data{pcc = PCC}) ->
    {keep_state_and_data, [{reply, From, {ok, PCC#pcc_ctx.rules}}]};

handle_event({call, From}, {sx, #pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{usar = 1},
			      usage_report_srr := UsageReport}} = Report},
	    _State, #data{session = Session, pfcp = PCtx, pcc = PCC}) ->
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

handle_event({call, From}, {sx, Report}, _State, #data{pfcp = PCtx}) ->
    ?LOG(warning, "~w: unhandled Sx report: ~p", [?MODULE, Report]),
    {keep_state_and_data, [{reply, From, {ok, PCtx, 'System failure'}}]};

handle_event({call, From}, {pfcp_timer, Time, Evs} = Info, _State,
	    #{interface := Interface, pfcp := PCtx0} = Data0) ->
    ?LOG(debug, "handle_event ~p:~p", [Interface, Info]),
    gen_statem:reply(From, ok),
    Now = erlang:monotonic_time(),
    PCtx = ergw_pfcp:timer_expired(Time, PCtx0),
    CtxEvs = ergw_gsn_lib:pfcp_to_context_event(Evs),
    Data = maps:fold(handle_charging_event(_, _, Now, _), Data0#data{pfcp = PCtx}, CtxEvs),
    {keep_state, Data};

handle_event({call, From}, _Request, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

handle_event(cast, _Request, _State, _Data) ->
    keep_state_and_data;

handle_event(info, {'DOWN', _MonitorRef, Type, Pid, _Info},
	     State, #data{dp_node = Pid} = Data)
  when Type == process; Type == pfcp ->
    close_pdn_context(upf_failure, State, Data),
    {next_state, shutdown, Data};

handle_event(info, #aaa_request{procedure = {_, 'RAR'}} = Request, shutdown, _Data) ->
    ergw_aaa_session:response(Request, {error, unknown_session}, #{}, #{}),
    keep_state_and_data;

handle_event(info, #aaa_request{procedure = {_, 'ASR'}} = Request, State, Data) ->
    ergw_aaa_session:response(Request, ok, #{}, #{}),
    close_pdn_context(administrative, State, Data),
    {next_state, shutdown, Data};

handle_event(info, #aaa_request{procedure = {gx, 'RAR'},
				events = Events} = Request,
	     _State,
	     #data{context = Context, pfcp = PCtx0,
		   session = Session, pcc = PCC0,
		   bearer = Bearer} = Data) ->
%%% 1. update PCC
%%%    a) calculate PCC rules to be removed
%%%    b) calculate PCC rules to be installed
%%% 2. figure out which Rating-Groups are new or which ones have to be removed
%%%    based on updated PCC rules
%%% 3. remove PCC rules and unsused Rating-Group URRs from UPF
%%% 4. on Gy:
%%%     - report removed URRs/RGs
%%%     - request credits for new URRs/RGs
%%% 5. apply granted quotas to PCC rules, remove PCC rules without quotas
%%% 6. install new PCC rules which have granted quota
%%% 7. report remove and not installed (lack of quota) PCC rules on Gx

    Now = erlang:monotonic_time(),
    ReqOps = #{now => Now},

    RuleBase = ergw_charging:rulebase(),

%%% step 1a:
    {PCC1, _} =
	ergw_pcc_context:gx_events_to_pcc_ctx(Events, remove, RuleBase, PCC0),
%%% step 1b:
    {PCC2, PCCErrors2} =
	ergw_pcc_context:gx_events_to_pcc_ctx(Events, install, RuleBase, PCC1),

%%% step 2
%%% step 3:
    {PCtx1, UsageReport} =
	case ergw_pfcp_context:modify_session(PCC1, [], #{}, Bearer, PCtx0) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context})
	end,

%%% step 4:
    ChargeEv = {online, 'RAR'},   %% made up value, not use anywhere...
    {Online, Offline, Monitor} =
	ergw_pfcp_context:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx1),

    ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),
    GyReqServices = ergw_pcc_context:gy_credit_request(Online, PCC0, PCC2),
    {ok, _, GyEvs} =
	ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOps),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),

%%% step 5:
    {PCC4, PCCErrors4} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, GyEvs, PCC2),

%%% step 6:
    {PCtx, _} =
	case ergw_pfcp_context:modify_session(PCC4, [], #{}, Bearer, PCtx1) of
	    {ok, Result2} -> Result2;
	    {error, Err2} -> throw(Err2#ctx_err{context = Context})
	end,

%%% step 7:
    %% TODO Charging-Rule-Report for successfully installed/removed rules

    GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(PCCErrors2 ++ PCCErrors4),
    ergw_aaa_session:response(Request, ok, GxReport, #{}),
    {keep_state, Data#data{pfcp = PCtx, pcc = PCC4}};

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

handle_event(internal, {session, stop, _Session}, State, Data) ->
    close_pdn_context(normal, State, Data),
    {next_state, shutdown, Data};

handle_event(internal, {session, {update_credits, _} = CreditEv, _}, _State,
	     #data{context = Context, pfcp = PCtx0, pcc = PCC0, bearer = Bearer} = Data) ->
    Now = erlang:monotonic_time(),

    {PCC, _PCCErrors} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, [CreditEv], PCC0),
    {PCtx, _} =
	case ergw_pfcp_context:modify_session(PCC, [], #{}, Bearer, PCtx0) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context})
	end,

    {keep_state, Data#data{pfcp = PCtx, pcc = PCC}};

handle_event(internal, {session, Ev, _}, _State, _Data) ->
    ?LOG(error, "unhandled session event: ~p", [Ev]),
    keep_state_and_data;

handle_event(info, {update_session, Session, Events}, _State, _Data) ->
    ?LOG(debug, "SessionEvents: ~p~n       Events: ~p", [Session, Events]),
    Actions = [{next_event, internal, {session, Ev, Session}} || Ev <- Events],
    {keep_state_and_data, Actions};

handle_event(info, _Info, _State, _Data) ->
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

start_session(#data{apn = APN, context = Context, dp_node = Node,
		    session = Session, pcc = PCC0, bearer = Bearer0} = Data) ->

    {PendingPCtx, NodeCaps} =
	case ergw_sx_node:attach(Node) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context})
	end,

    VRF = ergw_gsn_lib:select_vrf(NodeCaps, APN),
    Bearer1 = maps:update_with(right, _#bearer{vrf = VRF}, Bearer0),

    Now = erlang:monotonic_time(),
    SOpts = #{now => Now},

    SessionOpts = init_session(Data),
    {_, AuthSEvs} =
	case authenticate(Session, SessionOpts) of
	    {ok, Result2} -> Result2;
	    {error, Err2} -> throw({fail, Err2})
	end,

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

    ergw_aaa_session:invoke(Session, #{}, start, SOpts),
    {_, _, RfSEvs} = ergw_aaa_session:invoke(Session, #{}, {rf, 'Initial'}, SOpts),

    {PCC2, PCCErrors2} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, GyEvs, PCC1),
    PCC3 = ergw_pcc_context:session_events_to_pcc_ctx(AuthSEvs, PCC2),
    PCC4 = ergw_pcc_context:session_events_to_pcc_ctx(RfSEvs, PCC3),

    {PCtx, Bearer} =
	case ergw_pfcp_context:create_session(tdf, PCC4, PendingPCtx, Bearer1, Context) of
	    {ok, Result5} -> Result5;
	    {error, Err5} -> throw({fail, Err5})
	end,

    Keys = context2keys(Bearer, Context),
    gtp_context_reg:register(Keys, ?MODULE, self()),

    GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(PCCErrors1 ++ PCCErrors2),
    if map_size(GxReport) /= 0 ->
	    ergw_aaa_session:invoke(Session, GxReport,
				    {gx, 'CCR-Update'}, SOpts#{async => true});
       true ->
	    ok
    end,

    Data#data{context = Context, pfcp = PCtx, pcc = PCC4, bearer = Bearer}.

init_session(#data{context = #tdf_ctx{ms_ip = UeIP}}) ->
    {MCC, MNC} = ergw:get_plmn_id(),
    Opts0 =
	#{'Username'		=> <<"ergw">>,
	  'Password'		=> <<"ergw">>,
	  'Service-Type'	=> 'Framed-User',
	  'Framed-Protocol'	=> 'PPP',
	  '3GPP-GGSN-MCC-MNC'	=> <<MCC/binary, MNC/binary>>
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

close_pdn_context(Reason, run, #data{pfcp = PCtx, session = Session}) ->
    URRs = ergw_pfcp_context:delete_session(Reason, PCtx),

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
	ergw_pfcp_context:usage_report_to_charging_events(URRs, ChargeEv, PCtx),
    ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),
    GyReqServices = ergw_gsn_lib:gy_credit_report(Online),
    ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOpts),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),
    ergw_prometheus:termination_cause(?FUNCTION_NAME, Reason),

    ok;
close_pdn_context(_Reason, _State, _Data) ->
    ok.

query_usage_report(ChargingKeys, PCtx)
  when is_list(ChargingKeys) ->
    ergw_pfcp_context:query_usage_report(ChargingKeys, PCtx);
query_usage_report(_, PCtx) ->
    ergw_pfcp_context:query_usage_report(PCtx).

triggered_charging_event(ChargeEv, Now, Request,
			 #data{pfcp = PCtx, session = Session, pcc = PCC}) ->
    ReqOpts = #{now => Now, async => true},

    case query_usage_report(Request, PCtx) of
	{ok, {_, UsageReport}} ->
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
