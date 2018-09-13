%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn).

-behaviour(gtp_api).

-compile({parse_transform, cut}).

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
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").
-include("include/3gpp.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define(T3, 10 * 1000).
-define(N3, 5).

%%====================================================================
%% API
%%====================================================================

-define('Cause',					{cause, 0}).
-define('IMSI',						{international_mobile_subscriber_identity, 0}).
-define('Recovery',					{recovery, 0}).
-define('Tunnel Endpoint Identifier Data I',		{tunnel_endpoint_identifier_data_i, 0}).
-define('Tunnel Endpoint Identifier Control Plane',	{tunnel_endpoint_identifier_control_plane, 0}).
-define('NSAPI',					{nsapi, 0}).
-define('End User Address',				{end_user_address, 0}).
-define('Access Point Name',				{access_point_name, 0}).
-define('Protocol Configuration Options',		{protocol_configuration_options, 0}).
-define('SGSN Address for signalling',			{gsn_address, 0}).
-define('SGSN Address for user traffic',		{gsn_address, 1}).
-define('MSISDN',					{ms_international_pstn_isdn_number, 0}).
-define('Quality of Service Profile',			{quality_of_service_profile, 0}).
-define('IMEI',						{imei, 0}).

-define(CAUSE_OK(Cause), (Cause =:= request_accepted orelse
			  Cause =:= new_pdp_type_due_to_network_preference orelse
			  Cause =:= new_pdp_type_due_to_single_address_bearer_only)).

request_spec(v1, _Type, Cause)
  when Cause /= undefined andalso not ?CAUSE_OK(Cause) ->
    [];

request_spec(v1, create_pdp_context_request, _) ->
    [{?'Tunnel Endpoint Identifier Data I',		mandatory},
     {?'NSAPI',						mandatory},
     {?'SGSN Address for signalling',			mandatory},
     {?'SGSN Address for user traffic',			mandatory},
     {?'Quality of Service Profile',			mandatory}];

request_spec(v1, update_pdp_context_request, _) ->
    [{?'Tunnel Endpoint Identifier Data I',		mandatory},
     {?'NSAPI',						mandatory},
     {?'SGSN Address for signalling',			mandatory},
     {?'SGSN Address for user traffic',			mandatory},
     {?'Quality of Service Profile',			mandatory}];

request_spec(v1, _, _) ->
    [].

validate_options(Options) ->
    lager:debug("GGSN Gn/Gp Options: ~p", [Options]),
    gtp_context:validate_options(fun validate_option/2, Options, []).

validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

init(_Opts, State) ->
    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),
    {ok, State#{'Version' => v1, 'Session' => Session}}.

handle_call(query_usage_report, _From,
	    #{context := Context} = State) ->
    Reply = ergw_gsn_lib:query_usage_report(Context),
    {reply, Reply, State};

handle_call(delete_context, From, #{context := Context} = State) ->
    delete_context(From, Context),
    {noreply, State};

handle_call(terminate_context, _From, State) ->
    close_pdp_context(normal, State),
    {stop, normal, ok, State};

handle_call({path_restart, Path}, _From,
	    #{context := #context{path = Path}} = State) ->
    close_pdp_context(normal, State),
    {stop, normal, ok, State};
handle_call({path_restart, _Path}, _From, State) ->
    {reply, ok, State}.

handle_cast({packet_in, _GtpPort, _IP, _Port, _Msg}, State) ->
    lager:warning("packet_in not handled (yet): ~p", [_Msg]),
    {noreply, State}.

handle_info({'DOWN', _MonitorRef, Type, Pid, _Info} = _I,
	    #{context := #context{dp_node = Pid}} = State)
  when Type == process; Type == pfcp ->
    lager:info("~p, handle_info(~p, ~p)", [?MODULE, _I, State]),
    close_pdp_context(upf_failure, State),
    {noreply, State};

%% ===========================================================================

handle_info(#aaa_request{procedure = {diameter, 'ASR'}},
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
	    lager:info("RAR UsageReport: ~p", [UsageReport]),

	    GyUpdate = (catch ergw_gsn_lib:usage_report_to_credit_report(UsageReport, Context)),
	    lager:info("RAR GyUpdate: ~p", [GyUpdate]),

	    GyReqServices = #{'used_credits' => GyUpdate},
	    lager:info("GyReqServices: ~p", [GyReqServices]),
	    R1 =
		ergw_aaa_session:invoke(Session, GyReqServices, {gy, 'CCR-Update'}, #{async => true}),
	    lager:info("R: ~p", [R1]),
	    ok;
	_ ->
	    ok
    end,
    {noreply, State};

%% ===========================================================================

handle_info(_Info, State) ->
    lager:warning("~p, handle_info(~p, ~p)", [?MODULE, _Info, State]),
    {noreply, State}.

handle_pdu(ReqKey, #gtp{ie = Data} = Msg, #{context := Context} = State) ->
    lager:debug("GTP-U GGSN: ~p, ~p", [lager:pr(ReqKey, ?MODULE), gtp_c_lib:fmt_gtp(Msg)]),

    ergw_gsn_lib:ip_pdu(Data, Context),
    {noreply, State}.

handle_sx_report(#pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{erir = 1}}},
	    _From, State) ->
    close_pdp_context(normal, State),
    {stop, State};

%% ===========================================================================

handle_sx_report(#pfcp{type = session_report_request,
		       ie = #{report_type := #report_type{usar = 1},
			      usage_report_srr := UsageReport}},
		 _From, #{context := Context, 'Session' := Session} = State) ->

    SOpts = #{now => erlang:monotonic_time(), async => true},
    case ergw_gsn_lib:usage_report_to_credit_report(UsageReport, Context) of
	GyUpdate when length(GyUpdate) /= 0 ->
	    lager:info("GyUpdate: ~p", [GyUpdate]),

	    GyReqServices = #{'used_credits' => GyUpdate},
	    lager:info("GyReqServices: ~p", [GyReqServices]),
	    R1 =
		ergw_aaa_session:invoke(Session, GyReqServices, {gy, 'CCR-Update'}, SOpts),
	    lager:info("R: ~p", [R1]);
	_ ->
	    ok
    end,

    case ergw_gsn_lib:usage_report_to_monitoring_report(UsageReport, Context) of
	Interim when map_size(Interim) /= 0 ->
	    lager:info("Interim: ~p", [Interim]),

	    InterimReq = #{'monitors' => Interim},
	    lager:info("InterimReq: ~p", [InterimReq]),
	    R2 =
		ergw_aaa_session:invoke(Session, InterimReq, interim, SOpts),
	    lager:info("R: ~p", [R2]);
	_ ->
	    ok
    end,

    {ok, State};

%% ===========================================================================

handle_sx_report(_, _From, State) ->
    {error, 'System failure', State}.

session_events(Session, Events, State) ->
    ergw_gsn_lib:session_events(Session, Events, State).

%% resent request
handle_request(_ReqKey, _Msg, true, State) ->
%% resent request
    {noreply, State};

handle_request(_ReqKey,
	       #gtp{type = create_pdp_context_request,
		    ie = #{
		      ?'Access Point Name' := #access_point_name{apn = APN},
		      ?'Quality of Service Profile' := ReqQoSProfile
		     } = IEs} = Request, _Resent,
	       #{context := Context0, aaa_opts := AAAopts, node_selection := NodeSelect,
		 'Session' := Session} = State) ->

    EUA = maps:get(?'End User Address', IEs, undefined),

    Context1 = update_context_from_gtp_req(Request, Context0),
    ContextPreAuth = gtp_path:bind(Request, Context1),

    gtp_context:terminate_colliding_context(ContextPreAuth),

    SessionOpts0 = init_session(IEs, ContextPreAuth, AAAopts),
    SessionOpts1 = init_session_from_gtp_req(IEs, AAAopts, SessionOpts0),
    SessionOpts = init_session_qos(ReqQoSProfile, SessionOpts1),

    {ok, ActiveSessionOpts0, _SessionEvents} =
	authenticate(ContextPreAuth, Session, SessionOpts, Request),
    {ContextVRF, VRFOpts} = select_vrf(ContextPreAuth),

    ActiveSessionOpts = apply_vrf_session_defaults(VRFOpts, ActiveSessionOpts0),
    lager:info("ActiveSessionOpts: ~p", [ActiveSessionOpts]),

    {SessionIPs, ContextPending0} = assign_ips(ActiveSessionOpts, EUA, ContextVRF),
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

    ResponseIEs = create_pdp_context_response(ActiveSessionOpts, IEs, Context),
    Reply = response(create_pdp_context_response, Context, ResponseIEs, Request),

    {reply, Reply, State#{context => Context}};

handle_request(_ReqKey,
	       #gtp{type = update_pdp_context_request,
		    ie = #{?'Quality of Service Profile' := ReqQoSProfile}} = Request,
	       _Resent, #{context := OldContext} = State0) ->

    Context0 = update_context_from_gtp_req(Request, OldContext),
    Context = gtp_path:bind(Request, Context0),

    State1 = if Context /= OldContext ->
		     gtp_context:remote_context_update(OldContext, Context),
		     apply_context_change(Context, OldContext, State0);
		true ->
		     State0
	     end,

    ResponseIEs0 = [#cause{value = request_accepted},
		    context_charging_id(Context),
		    ReqQoSProfile],
    ResponseIEs = tunnel_endpoint_elements(Context, ResponseIEs0),
    Reply = response(update_pdp_context_response, Context, ResponseIEs, Request),
    {reply, Reply, State1};

handle_request(_ReqKey,
	       #gtp{type = ms_info_change_notification_request, ie = IEs} = Request,
	       _Resent, #{context := OldContext} = State) ->

    Context = update_context_from_gtp_req(Request, OldContext),

    ResponseIEs0 = [#cause{value = request_accepted}],
    ResponseIEs = copy_ies_to_response(IEs, ResponseIEs0, [?'IMSI', ?'IMEI']),
    Response = response(ms_info_change_notification_response, Context, ResponseIEs, Request),
    {reply, Response, State#{context => Context}};

handle_request(_ReqKey,
	       #gtp{type = delete_pdp_context_request, ie = _IEs}, _Resent,
	       #{context := Context} = State) ->
    close_pdp_context(normal, State),
    Reply = response(delete_pdp_context_response, Context, request_accepted),
    {stop, Reply, State};

handle_request(ReqKey, _Msg, _Resent, State) ->
    gtp_context:request_finished(ReqKey),
    {noreply, State}.

handle_response(From, timeout, #gtp{type = delete_pdp_context_request}, State) ->
    close_pdp_context(normal, State),
    if is_tuple(From) -> gen_server:reply(From, {error, timeout});
       true -> ok
    end,
    {stop, State};

handle_response(From,
		#gtp{type = delete_pdp_context_response,
		     ie = #{?'Cause' := #cause{value = Cause}}} = Response,
		_Request,
		#{context := Context0} = State) ->
    Context = gtp_path:bind(Response, Context0),
    close_pdp_context(normal, State),
    if is_tuple(From) -> gen_server:reply(From, {ok, Cause});
       true -> ok
    end,
    {stop, State#{context := Context}}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

response(Cmd, #context{remote_control_teid = #fq_teid{teid = TEID}}, Response) ->
    {Cmd, TEID, Response}.

response(Cmd, Context, IEs0, #gtp{ie = #{?'Recovery' := Recovery}}) ->
    IEs = gtp_v1_c:build_recovery(Context, Recovery /= undefined, IEs0),
    response(Cmd, Context, IEs).

authenticate(Context, Session0, SessionOpts, Request) ->
    lager:info("SessionOpts: ~p", [SessionOpts]),

    case ergw_aaa_session:invoke(Session0, SessionOpts, authenticate, [inc_session_id]) of
	{ok, _Session, _Events} = Result ->
	    lager:info("AuthResult: success"),
	    Result;

	Other ->
	    lager:info("AuthResult: ~p", [Other]),

	    Reply1 = response(create_pdp_context_response, Context,
			      [#cause{value = user_authentication_failed}], Request),
	    throw(?CTX_ERR(?FATAL, Reply1, Context))
    end.

pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#21,
			    pdp_address = Address}) ->
    IP4 = case Address of
	      << >> ->
		  {0,0,0,0};
	      <<_:4/bytes>> ->
		  ergw_inet:bin2ip(Address)
	  end,
    {IP4, undefined};

pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#57,
			    pdp_address = Address}) ->
    IP6 = case Address of
	      << >> ->
		  {{0,0,0,0,0,0,0,0},64};
	      <<_:16/bytes>> ->
		  {ergw_inet:bin2ip(Address),128}
	  end,
    {undefined, IP6};
pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#8D,
			    pdp_address = Address}) ->
    case Address of
	<< IP4:4/bytes, IP6:16/bytes >> ->
	    {ergw_inet:bin2ip(IP4), {ergw_inet:bin2ip(IP6), 128}};
	<< IP6:16/bytes >> ->
	    {{0,0,0,0}, {ergw_inet:bin2ip(IP6), 128}};
	<< IP4:4/bytes >> ->
	    {ergw_inet:bin2ip(IP4), {{0,0,0,0,0,0,0,0},64}};
 	<<  >> ->
	    {{0,0,0,0}, {{0,0,0,0,0,0,0,0},64}}
   end;

pdp_alloc(_) ->
    {undefined, undefined}.

encode_eua({IPv4,_}, undefined) ->
    encode_eua(1, 16#21, ergw_inet:ip2bin(IPv4), <<>>);
encode_eua(undefined, {IPv6,_}) ->
    encode_eua(1, 16#57, <<>>, ergw_inet:ip2bin(IPv6));
encode_eua({IPv4,_}, {IPv6,_}) ->
    encode_eua(1, 16#8D, ergw_inet:ip2bin(IPv4), ergw_inet:ip2bin(IPv6)).

encode_eua(Org, Number, IPv4, IPv6) ->
    #end_user_address{pdp_type_organization = Org,
		      pdp_type_number = Number,
		      pdp_address = <<IPv4/binary, IPv6/binary >>}.

pdp_release_ip(#context{vrf = VRF, ms_v4 = MSv4, ms_v6 = MSv6}) ->
    vrf:release_pdp_ip(VRF, MSv4, MSv6).

close_pdp_context(Reason, #{context := Context, 'Session' := Session}) ->
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
	    lager:info("Final: ~p", [Final]),

	    FinalReq = #{'monitors' => Final},
	    lager:info("FinalReq: ~p", [FinalReq]),
	    R2 =
		ergw_aaa_session:invoke(Session, FinalReq, stop, SOpts#{async => true}),
	    lager:info("R: ~p", [R2]);
	_ ->
	    ok
    end,

    %% ===========================================================================

    pdp_release_ip(Context).

query_usage_report(#{'Rating-Group' := [RatingGroup]}, Context) ->
    ergw_gsn_lib:query_usage_report(RatingGroup, Context);
query_usage_report(_, Context) ->
    ergw_gsn_lib:query_usage_report(Context).


apply_context_change(NewContext0, OldContext, #{'Session' := Session} = State) ->
    SessionOpts = ergw_aaa_session:get(Session),
    NewContextPending = gtp_path:bind(NewContext0),
    NewContext = ergw_gsn_lib:modify_sgi_session(SessionOpts, #{}, NewContextPending),
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

map_attr('APN', #{?'Access Point Name' := #access_point_name{apn = APN}}) ->
    unicode:characters_to_binary(lists:join($., APN));
map_attr('IMSI', #{?'IMSI' := #international_mobile_subscriber_identity{imsi = IMSI}}) ->
    IMSI;
map_attr('IMEI', #{?'IMEI' := #imei{imei = IMEI}}) ->
    IMEI;
map_attr('MSISDN', #{?'MSISDN' := #ms_international_pstn_isdn_number{
				     msisdn = {isdn_address, _, _, 1, MSISDN}}}) ->
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
      '3GPP-Charging-Id'	=> ChargingId,
      'PDP-Context-Type'	=> primary
     }.

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

copy_to_session(_, #protocol_configuration_options{config = {0, Options}},
		#{'Username' := #{from_protocol_opts := true}}, Session) ->
    lists:foldr(fun copy_ppp_to_session/2, Session, Options);
copy_to_session(_, #access_point_name{apn = APN}, _AAAopts, Session) ->
    Session#{
      'Called-Station-Id' =>
	  unicode:characters_to_binary(
	    lists:join($., gtp_c_lib:apn_strip_oi(APN)))
     };
copy_to_session(_, #ms_international_pstn_isdn_number{
		   msisdn = {isdn_address, _, _, 1, MSISDN}}, _AAAopts, Session) ->
    Session#{'Calling-Station-Id' => MSISDN, '3GPP-MSISDN' => MSISDN};
copy_to_session(_, #international_mobile_subscriber_identity{imsi = IMSI}, _AAAopts, Session) ->
    case itu_e212:split_imsi(IMSI) of
	{MCC, MNC, _} ->
	    Session#{'3GPP-IMSI' => IMSI,
		     '3GPP-IMSI-MCC-MNC' => <<MCC/binary, MNC/binary>>};
	_ ->
	    Session#{'3GPP-IMSI' => IMSI}
    end;
copy_to_session(_, #end_user_address{pdp_type_organization = 0,
				     pdp_type_number = 1}, _AAAopts, Session) ->
    Session#{'3GPP-PDP-Type' => 'PPP'};
copy_to_session(_, #end_user_address{pdp_type_organization = 0,
				     pdp_type_number = 2}, _AAAopts, Session) ->
    Session#{'3GPP-PDP-Type' => 'Non-IP'};
copy_to_session(_, #end_user_address{pdp_type_organization = 1,
				     pdp_type_number = 16#21,
				     pdp_address = Address}, _AAAopts, Session0) ->
    Session = Session0#{'3GPP-PDP-Type' => 'IPv4'},
    case Address of
	<<_:4/bytes>> ->
	    IP4 = ergw_inet:bin2ip(Address),
	    Session#{'Framed-IP-Address' => IP4,
		     'Requested-IP-Address' => IP4};
	_ ->
	    Session
    end;
copy_to_session(_, #end_user_address{pdp_type_organization = 1,
				     pdp_type_number = 16#57,
				     pdp_address = Address}, _AAAopts, Session0) ->
    Session = Session0#{'3GPP-PDP-Type' => 'IPv6'},
    case Address of
	<<_:16/bytes>> ->
	    IP6 = {ergw_inet:bin2ip(Address), 128},
	    Session#{'Framed-IPv6-Prefix' => IP6,
		     'Requested-IPv6-Prefix' => IP6};
	_ ->
	    Session
    end;
copy_to_session(_, #end_user_address{pdp_type_organization = 1,
				     pdp_type_number = 16#8D,
				     pdp_address = Address}, _AAAopts, Session0) ->
    Session = Session0#{'3GPP-PDP-Type' => 'IPv4v6'},
    case Address of
	<< IP4:4/bytes >> ->
	    IP4addr = ergw_inet:bin2ip(IP4),
	    Session#{'Framed-IP-Address' => IP4addr,
		     'Requested-IP-Address' => IP4addr};
	<< IP6:16/bytes >> ->
	    IP6addr = {ergw_inet:bin2ip(IP6), 128},
	    Session#{'Framed-IPv6-Prefix' => IP6addr,
		     'Requested-IPv6-Prefix' => IP6addr};
	<< IP4:4/bytes, IP6:16/bytes >> ->
	    IP4addr = ergw_inet:bin2ip(IP4),
	    IP6addr = {ergw_inet:bin2ip(IP6), 128},
	    Session#{'Framed-IP-Address' => IP4addr,
		     'Framed-IPv6-Prefix' => IP6addr,
		     'Requested-IP-Address' => IP4addr,
		     'Requested-IPv6-Prefix' => IP6addr};
	_ ->
	    Session
   end;

copy_to_session(_, #gsn_address{instance = 0, address = IP}, _AAAopts, Session) ->
    Session#{'3GPP-SGSN-Address' => ergw_inet:bin2ip(IP)};
copy_to_session(_, #nsapi{instance = 0, nsapi = NSAPI}, _AAAopts, Session) ->
    Session#{'3GPP-NSAPI' => NSAPI};
copy_to_session(_, #selection_mode{mode = Mode}, _AAAopts, Session) ->
    Session#{'3GPP-Selection-Mode' => Mode};
copy_to_session(_, #charging_characteristics{value = Value}, _AAAopts, Session) ->
    Session#{'3GPP-Charging-Characteristics' => Value};
copy_to_session(_, #routeing_area_identity{mcc = MCC, mnc = MNC}, _AAAopts, Session) ->
    Session#{'3GPP-SGSN-MCC-MNC' => <<MCC/binary, MNC/binary>>};
copy_to_session(_, #imei{imei = IMEI}, _AAAopts, Session) ->
    Session#{'3GPP-IMEISV' => IMEI};
copy_to_session(_, #rat_type{rat_type = Type}, _AAAopts, Session) ->
    Session#{'3GPP-RAT-Type' => Type};
copy_to_session(_, #user_location_information{} = IE, _AAAopts, Session) ->
    Value = gtp_packet:encode_v1_uli(IE),
    Session#{'3GPP-User-Location-Info' => Value};
copy_to_session(_, #ms_time_zone{timezone = TZ, dst = DST}, _AAAopts, Session) ->
    Session#{'3GPP-MS-TimeZone' => {TZ, DST}};
copy_to_session(_, _, _AAAopts, Session) ->
    Session.

init_session_from_gtp_req(IEs, AAAopts, Session) ->
    maps:fold(copy_to_session(_, _, AAAopts, _), Session, IEs).

init_session_qos(#quality_of_service_profile{
		    priority = RequestedPriority,
		    data = RequestedQoS}, Session) ->
    %% TODO: use config setting to init default class....
    {NegotiatedPriority, NegotiatedQoS} = negotiate_qos(RequestedPriority, RequestedQoS),
    Session#{'3GPP-Allocation-Retention-Priority' => NegotiatedPriority,
	     '3GPP-GPRS-Negotiated-QoS-Profile'   => NegotiatedQoS}.

negotiate_qos_prio(X) when X > 0 andalso X =< 3 ->
    X;
negotiate_qos_prio(_) ->
    2.

negotiate_qos(ReqPriority, ReqQoSProfileData) ->
    NegPriority = negotiate_qos_prio(ReqPriority),
    case '3gpp_qos':decode(ReqQoSProfileData) of
	Profile when is_binary(Profile) ->
	    {NegPriority, ReqQoSProfileData};
	#qos{traffic_class = 0} ->			%% MS to Network: Traffic Class: Subscribed
	    %% 3GPP TS 24.008, Sect. 10.5.6.5,
	    QoS = #qos{
		     delay_class			= 4,		%% best effort
		     reliability_class			= 3,		%% Unacknowledged GTP/LLC,
		     %% Ack RLC, Protected data
		     peak_throughput			= 2,		%% 2000 oct/s (2 kBps)
		     precedence_class			= 3,		%% Low priority
		     mean_throughput			= 31,		%% Best effort
		     traffic_class			= 4,		%% Background class
		     delivery_order			= 2,		%% Without delivery order
		     delivery_of_erroneorous_sdu	= 3,		%% Erroneous SDUs are not delivered
		     max_sdu_size			= 1500,		%% 1500 octets
		     max_bit_rate_uplink		= 16,		%% 16 kbps
		     max_bit_rate_downlink		= 16,		%% 16 kbps
		     residual_ber			= 7,		%% 10^-5
		     sdu_error_ratio			= 4,		%% 10^-4
		     transfer_delay			= 300,		%% 300ms
		     traffic_handling_priority		= 3,		%% Priority level 3
		     guaranteed_bit_rate_uplink		= 0,		%% 0 kbps
		     guaranteed_bit_rate_downlink	= 0,		%% 0 kbps
		     signaling_indication		= 0,		%% unknown
		     source_statistics_descriptor	= 0},		%% Not optimised for signalling traffic
	    {NegPriority, '3gpp_qos':encode(QoS)};
	_ ->
	    {NegPriority, ReqQoSProfileData}
    end.

set_fq_teid(Id, undefined, Value) ->
    set_fq_teid(Id, #fq_teid{}, Value);
set_fq_teid(ip, TEID, Value) ->
    TEID#fq_teid{ip = ergw_inet:bin2ip(Value)};
set_fq_teid(teid, TEID, Value) ->
    TEID#fq_teid{teid = Value}.

set_fq_teid(Id, Field, Context, Value) ->
    setelement(Field, Context, set_fq_teid(Id, element(Field, Context), Value)).

get_context_from_req(_, #gsn_address{instance = 0, address = CntlIP}, Context) ->
    set_fq_teid(ip, #context.remote_control_teid, Context, CntlIP);
get_context_from_req(_, #gsn_address{instance = 1, address = DataIP}, Context) ->
    set_fq_teid(ip, #context.remote_data_teid, Context, DataIP);
get_context_from_req(_, #tunnel_endpoint_identifier_data_i{instance = 0, tei = DataTEI}, Context) ->
    set_fq_teid(teid, #context.remote_data_teid, Context, DataTEI);
get_context_from_req(_, #tunnel_endpoint_identifier_control_plane{instance = 0, tei = CntlTEI}, Context) ->
    set_fq_teid(teid, #context.remote_control_teid, Context, CntlTEI);
get_context_from_req(?'Access Point Name', #access_point_name{apn = APN}, Context) ->
    Context#context{apn = APN};
get_context_from_req(?'IMSI', #international_mobile_subscriber_identity{imsi = IMSI}, Context) ->
    Context#context{imsi = IMSI};
get_context_from_req(?'IMEI', #imei{imei = IMEI}, Context) ->
    Context#context{imei = IMEI};
get_context_from_req(?'MSISDN', #ms_international_pstn_isdn_number{
				   msisdn = {isdn_address, _, _, 1, MSISDN}}, Context) ->
    Context#context{msisdn = MSISDN};
%% get_context_from_req(#nsapi{instance = 0, nsapi = NSAPI}, #context{state = State} = Context) ->
%%     Context#context{state = State#context_state{nsapi = NSAPI}};
get_context_from_req(_, _, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs} = Req, Context0) ->
    Context1 = gtp_v1_c:update_context_id(Req, Context0),
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

send_request(#context{control_port = GtpPort,
		      remote_control_teid =
			  #fq_teid{
			     ip = RemoteCntlIP,
			     teid = RemoteCntlTEI}
		     },
	     T3, N3, Type, RequestIEs, ReqInfo) ->
    Msg = #gtp{version = v1, type = Type, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(GtpPort, RemoteCntlIP, ?GTP1c_PORT, T3, N3, Msg, ReqInfo).

%% delete_context(From, #context_state{nsapi = NSAPI} = Context) ->
delete_context(From, Context) ->
    NSAPI = 5,
    RequestIEs0 = [#nsapi{nsapi = NSAPI},
		   #teardown_ind{value = 1}],
    RequestIEs = gtp_v1_c:build_recovery(Context, false, RequestIEs0),
    send_request(Context, ?T3, ?N3, delete_pdp_context_request, RequestIEs, From).

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

assign_ips(SessionOps, EUA, #context{vrf = VRF, local_control_tei = LocalTEI} = Context) ->
    {ReqMSv4, ReqMSv6} = session_ip_alloc(SessionOps, pdp_alloc(EUA)),
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

pdp_ppp_pco(SessionOpts, {pap, 'PAP-Authentication-Request', Id, _Username, _Password}, Opts) ->
    [{pap, 'PAP-Authenticate-Ack', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdp_ppp_pco(SessionOpts, {chap, 'CHAP-Response', Id, _Value, _Name}, Opts) ->
    [{chap, 'CHAP-Success', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdp_ppp_pco(SessionOpts, {ipcp,'CP-Configure-Request', Id, CpReqOpts}, Opts) ->
    CpRespOpts = lists:foldr(ppp_ipcp_conf(SessionOpts, _, _), #{}, CpReqOpts),
    maps:fold(fun(K, V, O) -> [{ipcp, K, Id, V} | O] end, Opts, CpRespOpts);

pdp_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv6-Address', <<>>}, Opts) ->
    [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
     || DNS <- maps:get('DNS-Server-IPv6-Address', SessionOpts, [])]
	++ [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
	    || DNS <- maps:get('3GPP-IPv6-DNS-Servers', SessionOpts, [])]
	++ Opts;
pdp_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv4-Address', <<>>}, Opts) ->
    lists:foldr(fun(Key, O) ->
			case maps:find(Key, SessionOpts) of
			    {ok, DNS} ->
				[{?'PCO-DNS-Server-IPv4-Address', ergw_inet:ip2bin(DNS)} | O];
			    _ ->
				O
			end
		end, Opts, ['MS-Secondary-DNS-Server', 'MS-Primary-DNS-Server']);
pdp_ppp_pco(_SessionOpts, PPPReqOpt, Opts) ->
    lager:info("Apply PPP Opt: ~p", [PPPReqOpt]),
    Opts.

pdp_pco(SessionOpts, #{?'Protocol Configuration Options' :=
			   #protocol_configuration_options{config = {0, PPPReqOpts}}}, IE) ->
    case lists:foldr(pdp_ppp_pco(SessionOpts, _, _), [], PPPReqOpts) of
	[]   -> IE;
	Opts -> [#protocol_configuration_options{config = {0, Opts}} | IE]
    end;
pdp_pco(_SessionOpts, _RequestIEs, IE) ->
    IE.

pdp_qos_profile(#{'3GPP-Allocation-Retention-Priority' := NegotiatedPriority,
		  '3GPP-GPRS-Negotiated-QoS-Profile'   := NegotiatedQoS}, IE) ->
    [#quality_of_service_profile{priority = NegotiatedPriority, data = NegotiatedQoS} | IE];
pdp_qos_profile(_SessionOpts, IE) ->
    IE.

tunnel_endpoint_elements(#context{control_port = #gtp_port{ip = CntlIP},
				  local_control_tei = CntlTEI,
				  data_port = #gtp_port{ip = DataIP},
				  local_data_tei = DataTEI}, IEs) ->
    [#tunnel_endpoint_identifier_data_i{tei = DataTEI},
     #tunnel_endpoint_identifier_control_plane{tei = CntlTEI},
     #gsn_address{instance = 0, address = ergw_inet:ip2bin(CntlIP)},   %% for Control Plane
     #gsn_address{instance = 1, address = ergw_inet:ip2bin(DataIP)}    %% for User Traffic
     | IEs].

context_charging_id(#context{charging_identifier = ChargingId}) ->
    #charging_id{id = <<ChargingId:32>>}.

create_pdp_context_response(SessionOpts, RequestIEs,
			    #context{ms_v4 = MSv4, ms_v6 = MSv6} = Context) ->
    IE0 = [#cause{value = request_accepted},
	   #reordering_required{required = no},
	   context_charging_id(Context),
	   encode_eua(MSv4, MSv6)],
    IE1 = pdp_qos_profile(SessionOpts, IE0),
    IE2 = pdp_pco(SessionOpts, RequestIEs, IE1),
    tunnel_endpoint_elements(Context, IE2).
