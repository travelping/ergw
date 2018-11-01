%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(saegw_s11).

-behaviour(gtp_api).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([validate_options/1, init/2, request_spec/3,
	 handle_pdu/3, handle_sx_report/3, session_events/3,
	 handle_request/4, handle_response/4,
	 handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2]).

%% shared API's
-export([init_session/3, init_session_from_gtp_req/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define(GTP_v1_Interface, ggsn_gn).
-define(T3, 10 * 1000).
-define(N3, 5).

%%====================================================================
%% API
%%====================================================================

-define('Cause',					{v2_cause, 0}).
-define('Recovery',					{v2_recovery, 0}).
-define('IMSI',						{v2_international_mobile_subscriber_identity, 0}).
-define('MSISDN',					{v2_msisdn, 0}).
-define('PDN Address Allocation',			{v2_pdn_address_allocation, 0}).
-define('RAT Type',					{v2_rat_type, 0}).
-define('Sender F-TEID for Control Plane',		{v2_fully_qualified_tunnel_endpoint_identifier, 0}).
-define('Access Point Name',				{v2_access_point_name, 0}).
-define('Bearer Contexts to be created',		{v2_bearer_context, 0}).
-define('Bearer Contexts to be modified',		{v2_bearer_context, 0}).
-define('Protocol Configuration Options',		{v2_protocol_configuration_options, 0}).
-define('ME Identity',					{v2_mobile_equipment_identity, 0}).
-define('APN-AMBR',					{v2_aggregate_maximum_bit_rate, 0}).
-define('Bearer Level QoS',				{v2_bearer_level_quality_of_service, 0}).
-define('EPS Bearer ID',                                {v2_eps_bearer_id, 0}).

-define('S1-U eNode-B', 0).
-define('S1-U SGW',     1).
-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).
-define('S11-C MME',    10).
-define('S11/S4-C SGW', 11).

-define(CAUSE_OK(Cause), (Cause =:= request_accepted orelse
			  Cause =:= request_accepted_partially orelse
			  Cause =:= new_pdp_type_due_to_network_preference orelse
			  Cause =:= new_pdp_type_due_to_single_address_bearer_only)).

request_spec(v1, Type, Cause) ->
    ?GTP_v1_Interface:request_spec(v1, Type, Cause);
request_spec(v2, _Type, Cause)
  when Cause /= undefined andalso not ?CAUSE_OK(Cause) ->
    [];
request_spec(v2, create_session_request, _) ->
    [{?'RAT Type',						mandatory},
     {?'Sender F-TEID for Control Plane',			mandatory},
     {?'Access Point Name',					mandatory},
     {?'Bearer Contexts to be created',				mandatory}];
request_spec(v2, delete_session_request, _) ->
    [];
request_spec(v2, modify_bearer_request, _) ->
    [];
request_spec(v2, modify_bearer_command, _) ->
    [{?'APN-AMBR' ,						mandatory},
     {?'Bearer Contexts to be modified',			mandatory}];
request_spec(v2, _, _) ->
    [].

validate_options(Options) ->
    lager:debug("SAEGW S11 Options: ~p", [Options]),
    gtp_context:validate_options(fun validate_option/2, Options, []).

validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

init(_Opts, State) ->
    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),
    {ok, State#{'Session' => Session}}.

handle_call(query_usage_report, _From,
	    #{context := Context} = State) ->
    Reply = ergw_gsn_lib:query_usage_report(Context),
    {reply, Reply, State};

handle_call(delete_context, From, #{context := Context} = State) ->
    delete_context(From, Context),
    {noreply, State};

handle_call(terminate_context, _From, State) ->
    close_pdn_context(normal, State),
    {stop, normal, ok, State};

handle_call({path_restart, Path}, _From,
	    #{context := #context{path = Path}} = State) ->
    close_pdn_context(normal, State),
    {stop, normal, ok, State};
handle_call({path_restart, _Path}, _From, State) ->
    {reply, ok, State}.

handle_cast({packet_in, _GtpPort, _IP, _Port, _Msg}, State) ->
    lager:warning("packet_in not handled (yet): ~p", [_Msg]),
    {noreply, State}.

handle_info({'DOWN', _MonitorRef, process, Pid, _Info},
	    #{context := #context{dp_node = Pid}} = State) ->
    close_pdn_context(upf_failure, State),
    {noreply, State};

%% ===========================================================================

handle_info(#aaa_request{procedure = {_, 'ASR'}},
	    #{context := Context, 'Session' := Session} = State) ->
    ergw_aaa_session:response(Session, ok, #{}),
    delete_context(undefined, Context),
    {noreply, State};

handle_info(#aaa_request{procedure = {gy, 'RAR'}, request = Request},
	    #{context := Context, 'Session' := Session} = State) ->
    ergw_aaa_session:response(Session, ok, #{}),

    %% Triggered CCR.....

    case query_usage_report(Request, Context) of
	#pfcp{type = session_modification_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'},
		     usage_report_smr := UsageReport}} ->

	    GyUpdate = (catch ergw_gsn_lib:usage_report_to_credit_report(UsageReport, Context)),
	    GyReqServices = #{'used_credits' => GyUpdate},
	    ergw_aaa_session:invoke(Session, GyReqServices, {gy, 'CCR-Update'}, #{async => true});
	_ ->
	    ok
    end,
    {noreply, State};

%% ===========================================================================

handle_info(_Info, State) ->
    {noreply, State}.

handle_sx_report(#pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{erir = 1}}},
	    _From, State) ->
    close_pdn_context(normal, State),
    {stop, State};

%% ===========================================================================

handle_sx_report(#pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{usar = 1},
			      usage_report_srr := UsageReport}},
		 _From, #{context := Context, 'Session' := Session} = State) ->

    SOpts = #{now => erlang:monotonic_time(), async => true},
    case ergw_gsn_lib:usage_report_to_credit_report(UsageReport, Context) of
	GyUpdate when length(GyUpdate) /= 0 ->
	    GyReqServices = #{'used_credits' => GyUpdate},
	    ergw_aaa_session:invoke(Session, GyReqServices, {gy, 'CCR-Update'}, SOpts);
	_ ->
	    ok
    end,

    case ergw_gsn_lib:usage_report_to_monitoring_report(UsageReport, Context) of
	Interim when map_size(Interim) /= 0 ->
	    InterimReq = #{'monitors' => Interim},
	    ergw_aaa_session:invoke(Session, InterimReq, interim, SOpts);
	_ ->
	    ok
    end,

    {ok, State};

%% ===========================================================================

handle_sx_report(_, _From, State) ->
    {error, 'System failure', State}.

session_events(Session, Events, State) ->
    ergw_gsn_lib:session_events(Session, Events, State).

handle_pdu(ReqKey, #gtp{ie = Data} = Msg, #{context := Context} = State) ->
    lager:debug("GTP-U SAE-GW: ~p, ~p", [lager:pr(ReqKey, ?MODULE), gtp_c_lib:fmt_gtp(Msg)]),

    ergw_gsn_lib:ip_pdu(Data, Context),
    {noreply, State}.

handle_request(ReqKey, #gtp{version = v1} = Msg, Resent, State) ->
    ?GTP_v1_Interface:handle_request(ReqKey, Msg, Resent, State);

handle_request(_ReqKey, _Msg, true, State) ->
%% resent request
    {noreply, State};

handle_request(_ReqKey,
	       #gtp{type = create_session_request,
		    ie = #{?'Sender F-TEID for Control Plane' := FqCntlTEID,
			   ?'Access Point Name' := #v2_access_point_name{apn = APN},
			   ?'Bearer Contexts to be created' :=
			       #v2_bearer_context{
				  group = #{
				    ?'EPS Bearer ID'     := EBI
				   } = BearerGroup}
			  } = IEs} = Request,
	       _Resent,
	       #{context := Context0, aaa_opts := AAAopts, node_selection := NodeSelect,
		 'Session' := Session} = State) ->

    PAA = maps:get(?'PDN Address Allocation', IEs, undefined),

    FqDataTEID =
	case BearerGroup of
	    #{{v2_fully_qualified_tunnel_endpoint_identifier, 0} :=
		  #v2_fully_qualified_tunnel_endpoint_identifier{
		     interface_type = ?'S1-U eNode-B'} = TEID} ->
		TEID;
	    _ ->
		undefined
	end,

    Context1 = update_context_tunnel_ids(FqCntlTEID, FqDataTEID, Context0),
    Context2 = update_context_from_gtp_req(Request, Context1),
    ContextPreAuth = gtp_path:bind(Request, Context2),

    gtp_context:terminate_colliding_context(ContextPreAuth),

    SessionOpts0 = init_session(IEs, ContextPreAuth, AAAopts),
    SessionOpts = init_session_from_gtp_req(IEs, AAAopts, SessionOpts0),
    %% SessionOpts = init_session_qos(ReqQoSProfile, SessionOpts1),

    {ok, ActiveSessionOpts0, _SessionEvents} =
	authenticate(ContextPreAuth, Session, SessionOpts, Request),
    {ContextVRF, VRFOpts} = select_vrf(ContextPreAuth),

    ActiveSessionOpts = apply_vrf_session_defaults(VRFOpts, ActiveSessionOpts0),
    lager:info("ActiveSessionOpts: ~p", [ActiveSessionOpts]),

    {SessionIPs, ContextPending0} = assign_ips(ActiveSessionOpts, PAA, ContextVRF),
    ContextPending = session_to_context(ActiveSessionOpts, ContextPending0),

    APN_FQDN = ergw_node_selection:apn_to_fqdn(APN),
    Services = [{"x-3gpp-upf", "x-sxb"}],
    Candidates = ergw_node_selection:candidates(APN_FQDN, Services, NodeSelect),

    %% ContextPending = ergw_gsn_lib:session_events(SessionEvents, ContextPending1),

    %% ===========================================================================

    %% Gx/Gy interaction
    %%  1. CCR on Gx to get PCC rules
    %%  2. extraxt all rating groups
    %%  3. CCR on Gy to get charging information for rating groups

    %%  1. CCR on Gx to get PCC rules
    SOpts = #{now => erlang:monotonic_time()},
    {ok, GxSessionOpts, _} =
	ergw_aaa_session:invoke(Session, #{}, {gx, 'CCR-Initial'}, SOpts),
    GxRules = maps:get(rules, GxSessionOpts, #{}),

    Credits = ergw_gsn_lib:pcc_rules_to_credit_request(GxRules),
    GyReqServices = #{credits => Credits},
    {ok, GySessionOpts, _} =
	ergw_aaa_session:invoke(Session, GyReqServices, {gy, 'CCR-Initial'}, SOpts),
    lager:info("GySessionOpts: ~p", [GySessionOpts]),

    {ok, FinalSessionOpts, _} =
	ergw_aaa_session:invoke(Session, SessionIPs, start, SOpts),

    %% ===========================================================================

    Context = ergw_gsn_lib:create_sgi_session(Candidates, FinalSessionOpts, ContextPending),
    gtp_context:remote_context_register_new(Context),

    ResponseIEs = create_session_response(ActiveSessionOpts, IEs, EBI, Context),
    Response = response(create_session_response, Context, ResponseIEs, Request),

    {reply, Response, State#{context => Context}};

handle_request(_ReqKey,
	       #gtp{type = modify_bearer_request,
		    ie = #{?'Bearer Contexts to be modified' :=
			       #v2_bearer_context{
				  group = #{
				    ?'EPS Bearer ID' := EBI,
				    {v2_fully_qualified_tunnel_endpoint_identifier, 0} :=
					%% S1-U eNode-B interface
					#v2_fully_qualified_tunnel_endpoint_identifier{interface_type = ?'S1-U eNode-B'} =
					FqDataTEID
				   }}
			  } = IEs} = Request,
	       _Resent,
	       #{context := OldContext} = State0) ->

    FqCntlTEID = maps:get(?'Sender F-TEID for Control Plane', IEs, undefined),

    Context0 = update_context_tunnel_ids(FqCntlTEID, FqDataTEID, OldContext),
    Context1 = update_context_from_gtp_req(Request, Context0),
    Context = gtp_path:bind(Request, Context1),

    State1 = if Context /= OldContext ->
		     gtp_context:remote_context_update(OldContext, Context),
		     apply_context_change(Context, OldContext, State0);
		true ->
		     State0
	     end,

    ResponseIEs = [#v2_cause{v2_cause = request_accepted},
		    #v2_bearer_context{
		       group=[#v2_cause{v2_cause = request_accepted},
			      EBI]}],
    Response = response(modify_bearer_response, Context, ResponseIEs, Request),
    {reply, Response, State1};

handle_request(_ReqKey,
	       #gtp{type = modify_bearer_request} = Request,
	       _Resent, #{context := OldContext} = State) ->

    Context = update_context_from_gtp_req(Request, OldContext),

    ResponseIEs = [#v2_cause{v2_cause = request_accepted}],
    Response = response(modify_bearer_response, Context, ResponseIEs, Request),
    {reply, Response, State#{context => Context}};

handle_request(#request{gtp_port = GtpPort, ip = SrcIP, port = SrcPort} = ReqKey,
	       #gtp{type = modify_bearer_command,
		    seq_no = SeqNo,
		    ie = #{?'APN-AMBR' := AMBR,
			   ?'Bearer Contexts to be modified' :=
			        #v2_bearer_context{
				   group = #{?'EPS Bearer ID' := EBI} = Bearer}}},
	       _Resent, #{context := Context} = State) ->
    gtp_context:request_finished(ReqKey),

    RequestIEs0 = [AMBR,
		   #v2_bearer_context{
		      group = copy_ies_to_response(Bearer, [EBI], [?'Bearer Level QoS'])}],
    RequestIEs = gtp_v2_c:build_recovery(Context, false, RequestIEs0),
    Msg = msg(Context, update_bearer_request, RequestIEs),
    send_request(GtpPort, SrcIP, SrcPort, ?T3, ?N3, Msg#gtp{seq_no = SeqNo}, undefined),

    {noreply, State};

handle_request(_ReqKey,
	       #gtp{type = release_access_bearers_request} = Request, _Resent,
	       #{'Session' := Session, context := OldContext} = State) ->
    ModifyOpts = #{send_end_marker => true},
    SessionOpts = ergw_aaa_session:get(Session),
    NewContext = OldContext#context{
		   remote_data_teid = undefined
		  },
    gtp_context:remote_context_update(OldContext, NewContext),
    Context = ergw_gsn_lib:modify_sgi_session(SessionOpts, ModifyOpts, NewContext),

    ResponseIEs = [#v2_cause{v2_cause = request_accepted}],
    Response = response(release_access_bearers_response, Context, ResponseIEs, Request),
    {reply, Response, State#{context => Context}};

handle_request(_ReqKey,
	       #gtp{type = delete_session_request, ie = IEs}, _Resent,
	       #{context := Context} = State0) ->

    FqTEI = maps:get(?'Sender F-TEID for Control Plane', IEs, undefined),

    Result =
	do([error_m ||
	       match_context(?'S11-C MME', Context, FqTEI),
	       return({request_accepted, State0})
	   ]),

    case Result of
	{ok, {ReplyIEs, State}} ->
	    close_pdn_context(normal, State),
	    Reply = response(delete_session_response, Context, ReplyIEs),
	    {stop, Reply, State};

	{error, ReplyIEs} ->
	    Response = response(delete_session_response, Context, ReplyIEs),
	    {reply, Response, State0}
    end;

handle_request(ReqKey, _Msg, _Resent, State) ->
    gtp_context:request_finished(ReqKey),
    {noreply, State}.

handle_response(ReqInfo, #gtp{version = v1} = Msg, Request, State) ->
    ?GTP_v1_Interface:handle_response(ReqInfo, Msg, Request, State);

handle_response(_,
		#gtp{type = update_bearer_response,
		     ie = #{?'Cause' := #v2_cause{v2_cause = Cause},
			    ?'Bearer Contexts to be modified' :=
			        #v2_bearer_context{
				   group = #{?'Cause' := #v2_cause{v2_cause = BearerCause}}
				  }}} = Response,
		_Request, #{context := Context0} = State) ->
    Context = gtp_path:bind(Response, Context0),

    if Cause =:= request_accepted andalso BearerCause =:= request_accepted ->
	    {noreply, State};
       true ->
	    lager:error("Update Bearer Request failed with ~p/~p",
			[Cause, BearerCause]),
	    delete_context(undefined, Context),
	    {noreply, State}
    end;

handle_response(_, timeout, #gtp{type = update_bearer_request},
		#{context := Context} = State) ->
    lager:error("Update Bearer Request failed with timeout"),
    delete_context(undefined, Context),
    {noreply, State};

handle_response(From, timeout, #gtp{type = delete_bearer_request}, State) ->
    close_pdn_context(normal, State),
    if is_tuple(From) -> gen_server:reply(From, {error, timeout});
       true -> ok
    end,
    {stop, State};

handle_response(From,
		#gtp{type = delete_bearer_response,
		     ie = #{?'Cause' := #v2_cause{v2_cause = Cause}}} = Response,
		_Request,
		#{context := Context0} = State) ->
    Context = gtp_path:bind(Response, Context0),
    close_pdn_context(normal, State),
    if is_tuple(From) -> gen_server:reply(From, {ok, Cause});
       true -> ok
    end,
    {stop, State#{context := Context}}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Helper functions
%%%===================================================================
ip2prefix({IP, Prefix}) ->
    <<Prefix:8, (ergw_inet:ip2bin(IP))/binary>>.

response(Cmd, #context{remote_control_teid = #fq_teid{teid = TEID}}, Response) ->
    {Cmd, TEID, Response}.

response(Cmd, Context, IEs0, #gtp{ie = #{?'Recovery' := Recovery}}) ->
    IEs = gtp_v2_c:build_recovery(Context, Recovery /= undefined, IEs0),
    response(Cmd, Context, IEs).

authenticate(Context, Session, SessionOpts, Request) ->
    lager:info("SessionOpts: ~p", [SessionOpts]),

    case ergw_aaa_session:invoke(Session, SessionOpts, authenticate, [inc_session_id]) of
	{ok, _Session, _Events} = Result ->
	    lager:info("AuthResult: success"),
	    Result;

	Other ->
	    lager:info("AuthResult: ~p", [Other]),

	    Reply1 = response(create_session_response, Context,
			      [#v2_cause{v2_cause = user_authentication_failed}], Request),
	    throw(?CTX_ERR(?FATAL, Reply1, Context))
    end.

match_context(_Type, _Context, undefined) ->
    error_m:return(ok);
match_context(Type,
	      #context{
		 remote_control_teid =
		     #fq_teid{
			ip  = RemoteCntlIP,
			teid = RemoteCntlTEI
		       }} = Context,
	      #v2_fully_qualified_tunnel_endpoint_identifier{
		 instance       = 0,
		 interface_type = Type,
		 key            = RemoteCntlTEI,
		 ipv4           = RemoteCntlIP4,
		 ipv6           = RemoteCntlIP6} = IE) ->
    case ergw_inet:ip2bin(RemoteCntlIP) of
	RemoteCntlIP4 ->
	    error_m:return(ok);
	RemoteCntlIP6 ->
	    error_m:return(ok);
	_ ->
	    lager:error("match_context: IP address mismatch, ~p, ~p, ~p",
			[Type, lager:pr(Context, ?MODULE), lager:pr(IE, ?MODULE)]),
	    error_m:fail([#v2_cause{v2_cause = context_not_found}])
    end;
match_context(Type, Context, IE) ->
    lager:error("match_context: context not found, ~p, ~p, ~p",
		[Type, lager:pr(Context, ?MODULE), lager:pr(IE, ?MODULE)]),
    error_m:fail([#v2_cause{v2_cause = context_not_found}]).

pdn_alloc(#v2_pdn_address_allocation{type = ipv4v6,
				     address = << IP6PrefixLen:8, IP6Prefix:16/binary, IP4:4/binary>>}) ->
    {ergw_inet:bin2ip(IP4), {ergw_inet:bin2ip(IP6Prefix), IP6PrefixLen}};
pdn_alloc(#v2_pdn_address_allocation{type = ipv4,
				     address = << IP4:4/binary>>}) ->
    {ergw_inet:bin2ip(IP4), undefined};
pdn_alloc(#v2_pdn_address_allocation{type = ipv6,
				     address = << IP6PrefixLen:8, IP6Prefix:16/binary>>}) ->
    {undefined, {ergw_inet:bin2ip(IP6Prefix), IP6PrefixLen}}.

encode_paa({IPv4,_}, undefined) ->
    encode_paa(ipv4, ergw_inet:ip2bin(IPv4), <<>>);
encode_paa(undefined, IPv6) ->
    encode_paa(ipv6, <<>>, ip2prefix(IPv6));
encode_paa({IPv4,_}, IPv6) ->
    encode_paa(ipv4v6, ergw_inet:ip2bin(IPv4), ip2prefix(IPv6)).

encode_paa(Type, IPv4, IPv6) ->
    #v2_pdn_address_allocation{type = Type, address = <<IPv6/binary, IPv4/binary>>}.

pdn_release_ip(#context{vrf = VRF, ms_v4 = MSv4, ms_v6 = MSv6}) ->
    vrf:release_pdp_ip(VRF, MSv4, MSv6).

close_pdn_context(Reason, #{context := Context, 'Session' := Session}) ->
    URRs = ergw_gsn_lib:delete_sgi_session(Reason, Context),

    %% ===========================================================================

    TermCause =
	case Reason of
	    upf_failure ->
		?'DIAMETER_BASE_TERMINATION-CAUSE_LINK_BROKEN';
	    _ ->
		?'DIAMETER_BASE_TERMINATION-CAUSE_LOGOUT'
	end,

    %%  1. CCR on Gx to get PCC rules
    SOpts = #{now => erlang:monotonic_time()},
    case ergw_aaa_session:invoke(Session, #{}, {gx, 'CCR-Terminate'}, SOpts) of
	{ok, _GxSessionOpts, _} ->
	    lager:info("GxSessionOpts: ~p", [_GxSessionOpts]);
	GxOther ->
	    lager:warning("Gx terminate failed with: ~p", [GxOther])
    end,

    Report = ergw_gsn_lib:usage_report_to_credit_report(URRs, Context),
    lager:info("URR: ~p~n", [URRs]),
    lager:info("Report: ~p~n", [Report]),
    GyReqServices = #{'Termination-Cause' => TermCause,
		      used_credits => Report},
    case ergw_aaa_session:invoke(Session, GyReqServices, {gy, 'CCR-Terminate'}, SOpts) of
	{ok, GySessionOpts, _} ->
	    lager:debug("GySessionOpts: ~p", [GySessionOpts]);
	GyOther ->
	    lager:warning("Gy terminate failed with: ~p", [GyOther])
    end,

    case ergw_gsn_lib:usage_report_to_monitoring_report(URRs, Context) of
       Final when map_size(Final) /= 0 ->
	    FinalReq = #{'monitors' => Final},
	    ergw_aaa_session:invoke(Session, FinalReq, stop, SOpts#{async => true});
	_ ->
	    ok
    end,

    %% ===========================================================================

    pdn_release_ip(Context).

query_usage_report(#{'Rating-Group' := [RatingGroup]}, Context) ->
    ergw_gsn_lib:query_usage_report(RatingGroup, Context);
query_usage_report(_, Context) ->
    ergw_gsn_lib:query_usage_report(Context).

apply_context_change(NewContext0, OldContext, #{'Session' := Session} = State) ->
    ModifyOpts = #{send_end_marker => true},
    SessionOpts = ergw_aaa_session:get(Session),
    NewContextPending = gtp_path:bind(NewContext0),
    NewContext = ergw_gsn_lib:modify_sgi_session(SessionOpts, ModifyOpts, NewContextPending),
    gtp_path:unbind(OldContext),
    State#{context => NewContext}.

select_vrf(#context{apn = APN} = Context) ->
    case ergw:vrf(APN) of
	{ok, {VRF, VRFOpts}} ->
	    {Context#context{vrf = VRF}, VRFOpts};
	_ ->
	    throw(?CTX_ERR(?FATAL, missing_or_unknown_apn, Context))
    end.

copy_vrf_session_defaults(K, Value, Opts)
    when K =:= 'MS-Primary-DNS-Server';
	 K =:= 'MS-Secondary-DNS-Server';
	 K =:= 'MS-Primary-NBNS-Server';
	 K =:= 'MS-Secondary-NBNS-Server' ->
    Opts#{K => ergw_inet:ip2bin(Value)};
copy_vrf_session_defaults(K, Value, Opts)
  when K =:= 'DNS-Server-IPv6-Address';
       K =:= '3GPP-IPv6-DNS-Servers' ->
    Opts#{K => Value};
copy_vrf_session_defaults(_K, _V, Opts) ->
    Opts.

apply_vrf_session_defaults(VRFOpts, Session) ->
    Defaults = maps:fold(fun copy_vrf_session_defaults/3, #{}, VRFOpts),
    maps:merge(Defaults, Session).

map_attr('APN', #{?'Access Point Name' := #v2_access_point_name{apn = APN}}) ->
    unicode:characters_to_binary(lists:join($., APN));
map_attr('IMSI', #{?'IMSI' := #v2_international_mobile_subscriber_identity{imsi = IMSI}}) ->
    IMSI;
map_attr('IMEI', #{?'ME Identity' := #v2_mobile_equipment_identity{mei = IMEI}}) ->
    IMEI;
map_attr('MSISDN', #{?'MSISDN' := #v2_msisdn{msisdn = MSISDN}}) ->
    MSISDN;
map_attr(Value, _) when is_binary(Value); is_list(Value) ->
    Value;
map_attr(Value, _) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
map_attr(Value, _) ->
    io_lib:format("~w", [Value]).

map_username(_IEs, Username, _) when is_binary(Username) ->
    Username;
map_username(_IEs, [], Acc) ->
    iolist_to_binary(lists:reverse(Acc));
map_username(IEs, [H | Rest], Acc) ->
    Part = map_attr(H, IEs),
    map_username(IEs, Rest, [Part | Acc]).

init_session(IEs,
	     #context{control_port = #gtp_port{ip = LocalIP},
		      charging_identifier = ChargingId},
	     #{'Username' := #{default := Username},
	       'Password' := #{default := Password}}) ->
    MappedUsername = map_username(IEs, Username, []),
    {MCC, MNC} = ergw:get_plmn_id(),
    #{'Username'		=> MappedUsername,
      'Password'		=> Password,
      'Service-Type'		=> 'Framed-User',
      'Framed-Protocol'		=> 'GPRS-PDP-Context',
      '3GPP-GGSN-MCC-MNC'	=> <<MCC/binary, MNC/binary>>,
      '3GPP-GGSN-Address'	=> LocalIP,
      '3GPP-Charging-Id'	=> ChargingId
     }.

copy_optional_binary_ie('3GPP-SGSN-Address' = Key, IP, Session) 
  when IP /= undefined ->
    Session#{Key => ergw_inet:bin2ip(IP)};
copy_optional_binary_ie('3GPP-SGSN-IPv6-Address' = Key, IP, Session) 
  when IP /= undefined ->
    Session#{Key => ergw_inet:bin2ip(IP)};
copy_optional_binary_ie(Key, Value, Session) when is_binary(Value) ->
    Session#{Key => Value};
copy_optional_binary_ie(_Key, _Value, Session) ->
    Session.

copy_ppp_to_session({pap, 'PAP-Authentication-Request', _Id, Username, Password}, Session0) ->
    Session = Session0#{'Username' => Username, 'Password' => Password},
    maps:without(['CHAP-Challenge', 'CHAP_Password'], Session);
copy_ppp_to_session({chap, 'CHAP-Challenge', _Id, Value, _Name}, Session) ->
    Session#{'CHAP_Challenge' => Value};
copy_ppp_to_session({chap, 'CHAP-Response', _Id, Value, Name}, Session0) ->
    Session = Session0#{'CHAP_Password' => Value, 'Username' => Name},
    maps:without(['Password'], Session);
copy_ppp_to_session(_, Session) ->
    Session.

copy_to_session(_, #v2_protocol_configuration_options{config = {0, Options}},
		#{'Username' := #{from_protocol_opts := true}}, Session) ->
    lists:foldr(fun copy_ppp_to_session/2, Session, Options);
copy_to_session(_, #v2_access_point_name{apn = APN}, _AAAopts, Session) ->
    Session#{
      'Called-Station-Id' =>
	  unicode:characters_to_binary(
	    lists:join($., gtp_c_lib:apn_strip_oi(APN)))
     };
copy_to_session(_, #v2_msisdn{msisdn = MSISDN}, _AAAopts, Session) ->
    Session#{'Calling-Station-Id' => MSISDN, '3GPP-MSISDN' => MSISDN};
copy_to_session(_, #v2_international_mobile_subscriber_identity{imsi = IMSI}, _AAAopts, Session) ->
    case itu_e212:split_imsi(IMSI) of
	{MCC, MNC, _} ->
	    Session#{'3GPP-IMSI' => IMSI,
		     '3GPP-IMSI-MCC-MNC' => <<MCC/binary, MNC/binary>>};
	_ ->
	    Session#{'3GPP-IMSI' => IMSI}
    end;

copy_to_session(_, #v2_pdn_address_allocation{type = ipv4,
					      address = IP4}, _AAAopts, Session) ->
    IP4addr = ergw_inet:bin2ip(IP4),
    Session#{'3GPP-PDP-Type' => 'IPv4',
	     'Framed-IP-Address' => IP4addr,
	     'Requested-IP-Address' => IP4addr};
copy_to_session(_, #v2_pdn_address_allocation{type = ipv6,
					      address = <<IP6PrefixLen:8,
							  IP6Prefix:16/binary>>},
		_AAAopts, Session) ->
    IP6addr = {ergw_inet:bin2ip(IP6Prefix), IP6PrefixLen},
    Session#{'3GPP-PDP-Type' => 'IPv6',
	     'Framed-IPv6-Prefix' => IP6addr,
	     'Requested-IPv6-Prefix' => IP6addr};
copy_to_session(_, #v2_pdn_address_allocation{type = ipv4v6,
					      address = <<IP6PrefixLen:8,
							  IP6Prefix:16/binary,
							  IP4:4/binary>>},
		_AAAopts, Session) ->
    IP4addr = ergw_inet:bin2ip(IP4),
    IP6addr = {ergw_inet:bin2ip(IP6Prefix), IP6PrefixLen},
    Session#{'3GPP-PDP-Type' => 'IPv4v6',
	     'Framed-IP-Address' => IP4addr,
	     'Framed-IPv6-Prefix' => IP6addr,
	     'Requested-IP-Address' => IP4addr,
	     'Requested-IPv6-Prefix' => IP6addr};

%% let pdn_type overwrite PAA
copy_to_session(_, #v2_pdn_type{pdn_type = ipv4}, _AAAopts, Session) ->
    Session#{'3GPP-PDP-Type' => 'IPv4'};
copy_to_session(_, #v2_pdn_type{pdn_type = ipv6}, _AAAopts, Session) ->
    Session#{'3GPP-PDP-Type' => 'IPv6'};
copy_to_session(_, #v2_pdn_type{pdn_type = ipv4v6}, _AAAopts, Session) ->
    Session#{'3GPP-PDP-Type' => 'IPv4v6'};
copy_to_session(_, #v2_pdn_type{pdn_type = non_ip}, _AAAopts, Session) ->
    Session#{'3GPP-PDP-Type' => 'Non-IP'};

copy_to_session(?'Sender F-TEID for Control Plane',
		#v2_fully_qualified_tunnel_endpoint_identifier{ipv4 = IP4, ipv6 = IP6},
		_AAAopts, Session0) ->
    Session1 = copy_optional_binary_ie('3GPP-SGSN-Address', IP4, Session0),
    copy_optional_binary_ie('3GPP-SGSN-IPv6-Address', IP6, Session1);

copy_to_session(?'Bearer Contexts to be created',
		#v2_bearer_context{group = #{?'EPS Bearer ID' :=
						 #v2_eps_bearer_id{eps_bearer_id = EBI}}},
		_AAAopts, Session) ->
    Session#{'3GPP-NSAPI' => EBI};
copy_to_session(_, #v2_selection_mode{mode = Mode}, _AAAopts, Session) ->
    Session#{'3GPP-Selection-Mode' => Mode};
copy_to_session(_, #v2_charging_characteristics{value = Value}, _AAAopts, Session) ->
    Session#{'3GPP-Charging-Characteristics' => Value};

copy_to_session(_, #v2_serving_network{mcc = MCC, mnc = MNC}, _AAAopts, Session) ->
    Session#{'3GPP-SGSN-MCC-MNC' => <<MCC/binary, MNC/binary>>};
copy_to_session(_, #v2_mobile_equipment_identity{mei = IMEI}, _AAAopts, Session) ->
    Session#{'3GPP-IMEISV' => IMEI};
copy_to_session(_, #v2_rat_type{rat_type = Type}, _AAAopts, Session) ->
    Session#{'3GPP-RAT-Type' => Type};

%% 0        CGI
%% 1        SAI
%% 2        RAI
%% 3-127    Spare for future use
%% 128      TAI
%% 129      ECGI
%% 130      TAI and ECGI
%% 131-255  Spare for future use

copy_to_session(_, #v2_user_location_information{tai = TAI, ecgi = ECGI}, _AAAopts, Session)
  when is_binary(TAI), is_binary(ECGI) ->
    Value = <<130, TAI/binary, ECGI/binary>>,
    Session#{'3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{ecgi = ECGI}, _AAAopts, Session)
  when is_binary(ECGI) ->
    Value = <<129, ECGI/binary>>,
    Session#{'3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{tai = TAI}, _AAAopts, Session)
  when is_binary(TAI) ->
    Value = <<129, TAI/binary>>,
    Session#{'3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{rai = RAI}, _AAAopts, Session)
  when is_binary(RAI) ->
    Value = <<2, RAI/binary>>,
    Session#{'3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{sai = SAI}, _AAAopts, Session)
  when is_binary(SAI) ->
    Value = <<1, SAI/binary>>,
    Session#{'3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{cgi = CGI}, _AAAopts, Session)
  when is_binary(CGI) ->
    Value = <<0, CGI/binary>>,
    Session#{'3GPP-User-Location-Info' => Value};

copy_to_session(_, #v2_ue_time_zone{timezone = TZ, dst = DST}, _AAAopts, Session) ->
    Session#{'3GPP-MS-TimeZone' => {TZ, DST}};
copy_to_session(_, _, _AAAopts, Session) ->
    Session.

init_session_from_gtp_req(IEs, AAAopts, Session) ->
    maps:fold(copy_to_session(_, _, AAAopts, _), Session, IEs).

%% use additional information from the Context to prefre V4 or V6....
choose_context_ip(IP4, _IP6, _Context)
  when is_binary(IP4) ->
    IP4;
choose_context_ip(_IP4, IP6, _Context)
  when is_binary(IP6) ->
    IP6.

update_context_cntl_ids(#v2_fully_qualified_tunnel_endpoint_identifier{
			   key = TEI, ipv4 = IP4, ipv6 = IP6}, Context) ->
    IP = choose_context_ip(IP4, IP6, Context),
    Context#context{
      remote_control_teid = #fq_teid{ip = ergw_inet:bin2ip(IP), teid = TEI}
     };
update_context_cntl_ids(_ , Context) ->
    Context.

update_context_data_ids(#v2_fully_qualified_tunnel_endpoint_identifier{
			   key = TEI, ipv4 = IP4, ipv6 = IP6}, Context) ->
    IP = choose_context_ip(IP4, IP6, Context),
    Context#context{
      remote_data_teid = #fq_teid{ip = ergw_inet:bin2ip(IP), teid = TEI}
     };
update_context_data_ids(_ , Context) ->
    Context.

update_context_tunnel_ids(Cntl, Data, Context0) ->
    Context1 = update_context_cntl_ids(Cntl, Context0),
    update_context_data_ids(Data, Context1).

get_context_from_req(?'Access Point Name', #v2_access_point_name{apn = APN}, Context) ->
    Context#context{apn = APN};
get_context_from_req(?'IMSI', #v2_international_mobile_subscriber_identity{imsi = IMSI}, Context) ->
    Context#context{imsi = IMSI};
get_context_from_req(?'ME Identity', #v2_mobile_equipment_identity{mei = IMEI}, Context) ->
    Context#context{imei = IMEI};
get_context_from_req(?'MSISDN', #v2_msisdn{msisdn = MSISDN}, Context) ->
    Context#context{msisdn = MSISDN};
get_context_from_req(_, _, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs} = Req, Context0) ->
    Context1 = gtp_v2_c:update_context_id(Req, Context0),
    maps:fold(fun get_context_from_req/3, Context1, IEs).

enter_ie(_Key, Value, IEs)
  when is_list(IEs) ->
    [Value|IEs].
%% enter_ie(Key, Value, IEs)
%%   when is_map(IEs) ->
%%     IEs#{Key := Value}.

copy_ies_to_response(_, ResponseIEs, []) ->
    ResponseIEs;
copy_ies_to_response(RequestIEs, ResponseIEs0, [H|T]) ->
    ResponseIEs =
	case RequestIEs of
	    #{H := Value} ->
		enter_ie(H, Value, ResponseIEs0);
	    _ ->
		ResponseIEs0
	end,
    copy_ies_to_response(RequestIEs, ResponseIEs, T).


msg(#context{remote_control_teid = #fq_teid{teid = RemoteCntlTEI}}, Type, RequestIEs) ->
    #gtp{version = v2, type = Type, tei = RemoteCntlTEI, ie = RequestIEs}.


send_request(GtpPort, DstIP, DstPort, T3, N3, Msg, ReqInfo) ->
    gtp_context:send_request(GtpPort, DstIP, DstPort, T3, N3, Msg, ReqInfo).

send_request(#context{control_port = GtpPort,
		      remote_control_teid = #fq_teid{ip = RemoteCntlIP}},
	     T3, N3, Msg, ReqInfo) ->
    send_request(GtpPort, RemoteCntlIP, ?GTP2c_PORT, T3, N3, Msg, ReqInfo).

send_request(Context, T3, N3, Type, RequestIEs, ReqInfo) ->
    send_request(Context, T3, N3, msg(Context, Type, RequestIEs), ReqInfo).

%% delete_context(From, #context_state{ebi = EBI} = Context) ->
delete_context(From, Context) ->
    EBI = 5,
    RequestIEs0 = [#v2_cause{v2_cause = reactivation_requested},
		   #v2_eps_bearer_id{eps_bearer_id = EBI}],
    RequestIEs = gtp_v2_c:build_recovery(Context, false, RequestIEs0),
    send_request(Context, ?T3, ?N3, delete_bearer_request, RequestIEs, From).

session_ipv4_alloc(#{'Framed-IP-Address' := {255,255,255,255}}, ReqMSv4) ->
    ReqMSv4;
session_ipv4_alloc(#{'Framed-IP-Address' := {255,255,255,254}}, _ReqMSv4) ->
    {0,0,0,0};
session_ipv4_alloc(#{'Framed-IP-Address' := {_,_,_,_} = IPv4}, _ReqMSv4) ->
    IPv4;
session_ipv4_alloc(_SessionOpts, ReqMSv4) ->
    ReqMSv4.

session_ipv6_alloc(#{'Framed-IPv6-Prefix' := {{_,_,_,_,_,_,_,_}, _} = IPv6}, _ReqMSv6) ->
    IPv6;
session_ipv6_alloc(_SessionOpts, ReqMSv6) ->
    ReqMSv6.

session_ip_alloc(SessionOpts, {ReqMSv4, ReqMSv6}) ->
    MSv4 = session_ipv4_alloc(SessionOpts, ReqMSv4),
    MSv6 = session_ipv6_alloc(SessionOpts, ReqMSv6),
    {MSv4, MSv6}.

maybe_ip(Key, {{_,_,_,_} = IPv4, _}, SessionIP) ->
    SessionIP#{Key => IPv4};
maybe_ip(Key, {{_,_,_,_,_,_,_,_},_} = IPv6, SessionIP) ->
    SessionIP#{Key => IPv6};
maybe_ip(_, _, SessionIP) ->
    SessionIP.

assign_ips(SessionOps, PAA, #context{vrf = VRF, local_control_tei = LocalTEI} = Context) ->
    {ReqMSv4, ReqMSv6} = session_ip_alloc(SessionOps, pdn_alloc(PAA)),
    {ok, MSv4, MSv6} = vrf:allocate_pdp_ip(VRF, LocalTEI, ReqMSv4, ReqMSv6),
    SessionIP4 = maybe_ip('Framed-IP-Address', MSv4, #{}),
    SessionIP = maybe_ip('Framed-IPv6-Prefix', MSv6, SessionIP4),
    {SessionIP, Context#context{ms_v4 = MSv4, ms_v6 = MSv6}}.

session_to_context(SessionOpts, Context) ->
    %% RFC 6911
    DNS0 = maps:get('DNS-Server-IPv6-Address', SessionOpts, []),
    %% 3GPP
    DNS1 = maps:get('3GPP-IPv6-DNS-Servers', SessionOpts, []),
    Context#context{dns_v6 = DNS0 ++ DNS1}.

ppp_ipcp_conf_resp(Verdict, Opt, IPCP) ->
    maps:update_with(Verdict, fun(O) -> [Opt|O] end, [Opt], IPCP).

ppp_ipcp_conf(#{'MS-Primary-DNS-Server' := DNS}, {ms_dns1, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_dns1, ergw_inet:ip2bin(DNS)}, IPCP);
ppp_ipcp_conf(#{'MS-Secondary-DNS-Server' := DNS}, {ms_dns2, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_dns2, ergw_inet:ip2bin(DNS)}, IPCP);
ppp_ipcp_conf(#{'MS-Primary-NBNS-Server' := DNS}, {ms_wins1, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_wins1, ergw_inet:ip2bin(DNS)}, IPCP);
ppp_ipcp_conf(#{'MS-Secondary-NBNS-Server' := DNS}, {ms_wins2, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_wins2, ergw_inet:ip2bin(DNS)}, IPCP);

ppp_ipcp_conf(_SessionOpts, Opt, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Reject', Opt, IPCP).

pdn_ppp_pco(SessionOpts, {pap, 'PAP-Authentication-Request', Id, _Username, _Password}, Opts) ->
    [{pap, 'PAP-Authenticate-Ack', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdn_ppp_pco(SessionOpts, {chap, 'CHAP-Response', Id, _Value, _Name}, Opts) ->
    [{chap, 'CHAP-Success', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdn_ppp_pco(SessionOpts, {ipcp,'CP-Configure-Request', Id, CpReqOpts}, Opts) ->
    CpRespOpts = lists:foldr(ppp_ipcp_conf(SessionOpts, _, _), #{}, CpReqOpts),
    maps:fold(fun(K, V, O) -> [{ipcp, K, Id, V} | O] end, Opts, CpRespOpts);

pdn_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv6-Address', <<>>}, Opts) ->
    [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
     || DNS <- maps:get('DNS-Server-IPv6-Address', SessionOpts, [])]
	++ [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
	    || DNS <- maps:get('3GPP-IPv6-DNS-Servers', SessionOpts, [])]
	++ Opts;
pdn_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv4-Address', <<>>}, Opts) ->
    lists:foldr(fun(Key, O) ->
			case maps:find(Key, SessionOpts) of
			    {ok, DNS} ->
				[{?'PCO-DNS-Server-IPv4-Address', ergw_inet:ip2bin(DNS)} | O];
			    _ ->
				O
			end
		end, Opts, ['MS-Secondary-DNS-Server', 'MS-Primary-DNS-Server']);
pdn_ppp_pco(_SessionOpts, PPPReqOpt, Opts) ->
    lager:info("Apply PPP Opt: ~p", [PPPReqOpt]),
    Opts.

pdn_pco(SessionOpts, #{?'Protocol Configuration Options' :=
			   #v2_protocol_configuration_options{config = {0, PPPReqOpts}}}, IE) ->
    case lists:foldr(pdn_ppp_pco(SessionOpts, _, _), [], PPPReqOpts) of
	[]   -> IE;
	Opts -> [#v2_protocol_configuration_options{config = {0, Opts}} | IE]
    end;
pdn_pco(_SessionOpts, _RequestIEs, IE) ->
    IE.

bearer_context(EBI, Context, IEs) ->
    IE = #v2_bearer_context{
	    group=[#v2_cause{v2_cause = request_accepted},
		   EBI,
		   #v2_bearer_level_quality_of_service{
		      pl=15,
		      pvi=0,
		      label=9,maximum_bit_rate_for_uplink=0,
		      maximum_bit_rate_for_downlink=0,
		      guaranteed_bit_rate_for_uplink=0,
		      guaranteed_bit_rate_for_downlink=0},
		   %% F-TEID for S1-U SGW GTP-U ???
		   s1_sgw_gtp_u_tei(Context),
		   s5s8_pgw_gtp_u_tei(Context)]},
    [IE | IEs].

fq_teid(Instance, Type, TEI, {_,_,_,_} = IP) ->
    #v2_fully_qualified_tunnel_endpoint_identifier{
       instance = Instance, interface_type = Type,
       key = TEI, ipv4 = ergw_inet:ip2bin(IP)};
fq_teid(Instance, Type, TEI, {_,_,_,_,_,_,_,_} = IP) ->
    #v2_fully_qualified_tunnel_endpoint_identifier{
       instance = Instance, interface_type = Type,
       key = TEI, ipv6 = ergw_inet:ip2bin(IP)}.

s11_sender_f_teid(#context{control_port = #gtp_port{ip = IP}, local_control_tei = TEI}) ->
    fq_teid(0, ?'S11/S4-C SGW', TEI, IP).

s1_sgw_gtp_u_tei(#context{data_port = #gtp_port{ip = IP}, local_data_tei = TEI}) ->
    fq_teid(0, ?'S1-U SGW', TEI, IP).

s5s8_pgw_gtp_c_tei(#context{control_port = #gtp_port{ip = IP}, local_control_tei = TEI}) ->
    %% PGW S5/S8/ S2a/S2b F-TEID for PMIP based interface
    %% or for GTP based Control Plane interface
    fq_teid(1, ?'S5/S8-C PGW', TEI, IP).

s5s8_pgw_gtp_u_tei(#context{data_port = #gtp_port{ip = IP}, local_data_tei = TEI}) ->
    %% S5/S8 F-TEI Instance
    fq_teid(2, ?'S5/S8-U PGW', TEI, IP).

create_session_response(SessionOpts, RequestIEs, EBI,
			#context{ms_v4 = MSv4, ms_v6 = MSv6} = Context) ->

    IE0 = bearer_context(EBI, Context, []),
    IE1 = pdn_pco(SessionOpts, RequestIEs, IE0),

    [#v2_cause{v2_cause = request_accepted},
     #v2_change_reporting_action{action = start_reporting_tai_and_ecgi},
     %% Sender F-TEID for Control Plane
     s11_sender_f_teid(Context),
     s5s8_pgw_gtp_c_tei(Context),
     #v2_apn_restriction{restriction_type_value = 0},
     encode_paa(MSv4, MSv6) | IE1].
