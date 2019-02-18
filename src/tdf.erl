%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(tdf).

%%-behaviour(gtp_api).
-behaviour(gen_server).
-behavior(ergw_context).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([start_link/6, validate_options/1, unsolicited_report/5]).

%% ergw_context callbacks
-export([sx_report/2, port_message/2, port_message/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define(SERVER, ?MODULE).

-record(state, {dp_node :: pid(),
		session :: pid(),

		context,
		pfcp}).

%%====================================================================
%% API
%%====================================================================

start_link(Node, VRF, IP4, IP6, SxOpts, GenOpts) ->
    gen_server:start_link(?MODULE, [Node, VRF, IP4, IP6, SxOpts], GenOpts).

unsolicited_report(Node, VRF, IP4, IP6, SxOpts) ->
    tdf_sup:new(Node, VRF, IP4, IP6, SxOpts).

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

sx_report(_Server, Report) ->
    lager:error("TDF Sx Report: ~p", [Report]),
    ok.

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
%% gen_server API
%%====================================================================

init([Node, InVRF, IP4, IP6, #{apn := APN} = SxOpts]) ->
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
    State = #state{
	       context = Context,
	       dp_node = Node,
	       session = Session
	      },

    gen_server:cast(self(), init),
    lager:info("TDF process started for ~p", [[Node, IP4, IP6]]),
    {ok, State}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.


handle_cast(init, State) ->
    %% start Rf/Gx/Gy interaction
    try
	State1 = start_session(State),
	{noreply, State1}
    catch
	throw:_Error ->
	    lager:debug("TDF Init failed with ~p", [_Error]),
	    {stop, normal, State}
    end;
handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({'DOWN', _MonitorRef, Type, Pid, _Info},
	    #state{dp_node = Pid} = State)
  when Type == process; Type == pfcp ->
    close_pdn_context(upf_failure, State),
    {stop, normal, State};

handle_info(stop_from_session, State) ->
    close_pdn_context(undefined, State),
    {stop, normal, State};

handle_info(#aaa_request{procedure = {_, 'ASR'}},
	    #state{session = Session} = State) ->
    ergw_aaa_session:response(Session, ok, #{}),
    close_pdn_context(undefined, State),
    {stop, normal, State};
handle_info(#aaa_request{procedure = {gy, 'RAR'}, request = Request},
	    #state{session = Session} = State) ->
    ergw_aaa_session:response(Session, ok, #{}),
    Now = erlang:monotonic_time(),

    %% Triggered CCR.....
    triggered_charging_event(interim, Now, Request, State),
    {noreply, State};

handle_info({update_session, Session, Events} = Us,
	    #state{context = Context, pfcp = PCtx0} = State) ->
    lager:warning("UpdateSession: ~p", [Us]),
    PCtx =  ergw_gsn_lib:session_events(Session, Events, Context, PCtx0),
    {noreply, State#state{pfcp = PCtx}};

handle_info({timeout, TRef, pfcp_timer} = Info,
	    #state{pfcp = PCtx0} = State0) ->
    Now = erlang:monotonic_time(),
    lager:debug("handle_info TDF:~p", [lager:pr(Info, ?MODULE)]),

    {Evs, PCtx} = ergw_pfcp:timer_expired(TRef, PCtx0),
    CtxEvs = ergw_gsn_lib:pfcp_to_context_event(Evs),
    State = maps:fold(handle_charging_event(_, _, Now, _), State0#state{pfcp = PCtx}, CtxEvs),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

start_session(#state{context = Context, dp_node = Node, session = Session} = State) ->
    SOpts = #{now => erlang:monotonic_time()},

    SessionOpts = init_session(State),
    authenticate(Session, SessionOpts),

    GxOpts = #{'Event-Trigger' => ?'DIAMETER_GX_EVENT-TRIGGER_UE_IP_ADDRESS_ALLOCATE',
	       'Bearer-Operation' => ?'DIAMETER_GX_BEARER-OPERATION_ESTABLISHMENT'},

    {ok, _, GxEvents} =
	ccr_initial(Session, gx, GxOpts, SOpts),

    RuleBase = ergw_charging:rulebase(),
    {PCCRules, _PCCErrors} =
	ergw_gsn_lib:gx_events_to_pcc_rules(GxEvents, RuleBase, #{}),

    if PCCRules =:= #{} ->
	    throw({fail, authenticate, no_pcc_rules});
       true ->
	    ok
    end,

    %% TODO: handle PCCErrors

    Credits = ergw_gsn_lib:pcc_rules_to_credit_request(PCCRules),
    GyReqServices = #{'PCC-Rules' => PCCRules, credits => Credits},

    {ok, GySessionOpts, _} =
	ccr_initial(Session, gy, GyReqServices, SOpts),
    lager:info("GySessionOpts: ~p", [GySessionOpts]),

    ergw_aaa_session:invoke(Session, #{}, start, SOpts),
    ergw_aaa_session:invoke(Session, #{}, {rf, 'Initial'}, SOpts),
    FinalSessionOpts = ergw_aaa_session:get(Session),

    lager:info("FinalS: ~p", [FinalSessionOpts]),

    PCtx = ergw_gsn_lib:create_tdf_session(Node, FinalSessionOpts, Context),

    Keys = context2keys(Context),
    gtp_context_reg:register(Keys, ?MODULE, self()),

    State#state{pfcp = PCtx}.

init_session(#state{context = Context}) ->
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

close_pdn_context(Reason, #state{context = Context, pfcp = PCtx, session = Session}) ->
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

    ok.

query_usage_report(#{'Rating-Group' := [RatingGroup]}, Context, PCtx) ->
    ChargingKeys = [{online, RatingGroup}],
    ergw_gsn_lib:query_usage_report(ChargingKeys, Context, PCtx);
query_usage_report(ChargingKeys, Context, PCtx)
  when is_list(ChargingKeys) ->
    ergw_gsn_lib:query_usage_report(ChargingKeys, Context, PCtx);
query_usage_report(_, Context, PCtx) ->
    ergw_gsn_lib:query_usage_report(Context, PCtx).

triggered_charging_event(ChargeEv, Now, Request,
			 #state{context = Context, pfcp = PCtx, session = Session}) ->
    case query_usage_report(Request, Context, PCtx) of
	#pfcp{type = session_modification_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} = IEs} ->

	    UsageReport = maps:get(usage_report_smr, IEs, undefined),
	    {Online, Offline, _} =
		ergw_gsn_lib:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),
	    ergw_gsn_lib:process_online_charging_events(ChargeEv, Online, Now, Session),
	    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),
	    ok;
	_ ->
	    ok
    end.

handle_charging_event(validity_time, ChargingKeys, Now, State) ->
    triggered_charging_event(validity_time, Now, ChargingKeys, State),
    State;
handle_charging_event(Key, Ev, _Now, State) ->
    lager:debug("TDF: unhandled charging event ~p:~p",[Key, Ev]),
    State.

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
