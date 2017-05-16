%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8).

-behaviour(gtp_api).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([validate_options/1, init/2, request_spec/3,
	 handle_request/4, handle_response/4,
	 handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2]).

%% shared API's
-export([init_session/3, init_session_from_gtp_req/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
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

-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).

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
request_spec(v2, resume_notification, _) ->
    [{?'IMSI',							mandatory}];
request_spec(v2, _, _) ->
    [].

validate_options(Options) ->
    lager:debug("GGSN S5/S8 Options: ~p", [Options]),
    gtp_context:validate_options(fun validate_option/2, Options, []).

validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

init(_Opts, State) ->
    SessionOpts = [{'Accouting-Update-Fun', fun accounting_update/2}],
    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session(SessionOpts)),
    {ok, State#{'Session' => Session}}.

handle_call(query_usage_report, _From,
	    #{context := Context} = State) ->
    Reply = ergw_gsn_lib:query_usage_report(Context),
    {reply, Reply, State};

handle_call(delete_context, From, #{context := Context} = State) ->
    delete_context(From, Context),
    {noreply, State};

handle_call(terminate_context, _From, State) ->
    close_pdn_context(State),
    {stop, normal, ok, State};

handle_call({path_restart, Path}, _From,
	    #{context := #context{path = Path}} = State) ->
    close_pdn_context(State),
    {stop, normal, ok, State};
handle_call({path_restart, _Path}, _From, State) ->
    {reply, ok, State}.

handle_cast({packet_in, _GtpPort, _IP, _Port, _Msg}, State) ->
    lager:warning("packet_in not handled (yet): ~p", [_Msg]),
    {noreply, State}.

handle_info({_, session_report_request, #{report_type := [error_indication_report]}}, State) ->
    close_pdn_context(State),
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

%% API Message Matrix:
%%
%% SGSN/MME/ TWAN/ePDG to PGW (S4/S11, S5/S8, S2a, S2b)
%%
%%   Create Session Request/Response
%%   Delete Session Request/Response
%%
%% SGSN/MME/ePDG to PGW (S4/S11, S5/S8, S2b)
%%
%%   Modify Bearer Request/Response
%%
%% SGSN/MME to PGW (S4/S11, S5/S8)
%%
%%   Change Notification Request/Response
%%   Resume Notification/Acknowledge

handle_request(ReqKey, #gtp{version = v1} = Msg, Resent, State) ->
    ?GTP_v1_Interface:handle_request(ReqKey, Msg, Resent, State);

handle_request(_ReqKey, _Msg, true, State) ->
%% resent request
    {noreply, State};

handle_request(_ReqKey,
	       #gtp{type = create_session_request,
		    ie = #{?'Sender F-TEID for Control Plane' := FqCntlTEID,
			   ?'Bearer Contexts to be created' :=
			       #v2_bearer_context{
				  group = #{
				    ?'EPS Bearer ID'     := EBI,
				    {v2_fully_qualified_tunnel_endpoint_identifier, 2} :=
					%% S5/S8 SGW GTP-U Interface
					#v2_fully_qualified_tunnel_endpoint_identifier{interface_type = ?'S5/S8-U SGW'} =
					FqDataTEID
				   }}
			  } = IEs} = Request,
	       _Resent,
	       #{context := Context0, aaa_opts := AAAopts, 'Session' := Session} = State) ->

    PAA = maps:get(?'PDN Address Allocation', IEs, undefined),

    Context1 = update_context_tunnel_ids(FqCntlTEID, FqDataTEID, Context0),
    Context2 = update_context_from_gtp_req(Request, Context1),
    ContextPreAuth = gtp_path:bind(Request, Context2),

    gtp_context:terminate_colliding_context(ContextPreAuth),

    SessionOpts0 = init_session(IEs, ContextPreAuth, AAAopts),
    SessionOpts = init_session_from_gtp_req(IEs, AAAopts, SessionOpts0),
    %% SessionOpts = init_session_qos(ReqQoSProfile, SessionOpts1),

    authenticate(ContextPreAuth, Session, SessionOpts, Request),
    {ContextVRF, VRFOpts} = select_vrf(ContextPreAuth),

    ActiveSessionOpts0 = ergw_aaa_session:get(Session),
    ActiveSessionOpts = apply_vrf_session_defaults(VRFOpts, ActiveSessionOpts0),
    lager:info("ActiveSessionOpts: ~p", [ActiveSessionOpts]),

    ContextPending = assign_ips(ActiveSessionOpts, PAA, ContextVRF),

    gtp_context:remote_context_register_new(ContextPending),
    Context = ergw_gsn_lib:create_sgi_session(ContextPending),

    ResponseIEs = create_session_response(ActiveSessionOpts, IEs, EBI, Context),
    Response = response(create_session_response, Context, ResponseIEs, Request),

    ergw_aaa_session:start(Session, #{}),

    {reply, Response, State#{context => Context}};

handle_request(_ReqKey,
	       #gtp{type = modify_bearer_request,
		    ie = #{?'Bearer Contexts to be modified' :=
			       #v2_bearer_context{
				  group = #{
				    ?'EPS Bearer ID' := EBI,
				    {v2_fully_qualified_tunnel_endpoint_identifier, 1} :=
					%% S5/S8 SGW GTP-U Interface
					#v2_fully_qualified_tunnel_endpoint_identifier{interface_type = ?'S5/S8-U SGW'} =
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

    ResponseIEs0 =
	if FqCntlTEID /= undefined ->
		%% take the presens of the FQ-TEID element as SGW change indication
		%%
		%% 3GPP TS 29.274, Sect. 7.2.7 Modify Bearer Request says that we should
		%% consider the content as well, but in practice that is not stable enough
		%% in the presense of middle boxes between the SGW and the PGW
		%%
		[EBI,				%% Linked EPS Bearer ID
		 #v2_apn_restriction{restriction_type_value = 0} |
		 [#v2_msisdn{msisdn = Context#context.msisdn} || Context#context.msisdn /= undefined]];
	   true ->
		[]
	end,

    ResponseIEs = [#v2_cause{v2_cause = request_accepted},
		    #v2_bearer_context{
		       group=[#v2_cause{v2_cause = request_accepted},
			      #v2_charging_id{id = <<0,0,0,1>>},
			      EBI]} |
		    ResponseIEs0],
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
	       #gtp{type = change_notification_request, ie = IEs} = Request,
	       _Resent, #{context := OldContext} = State) ->

    Context = update_context_from_gtp_req(Request, OldContext),

    ResponseIEs0 = [#v2_cause{v2_cause = request_accepted}],
    ResponseIEs = copy_ies_to_response(IEs, ResponseIEs0, [?'IMSI', ?'ME Identity']),
    Response = response(change_notification_response, Context, ResponseIEs, Request),
    {reply, Response, State#{context => Context}};

handle_request(_ReqKey,
	       #gtp{type = suspend_notification} = Request,
	       _Resent, #{context := Context} = State) ->

    %% don't do anything special for now

    ResponseIEs = [#v2_cause{v2_cause = request_accepted}],
    Response = response(suspend_acknowledge, Context, ResponseIEs, Request),
    {reply, Response, State#{context => Context}};

handle_request(_ReqKey,
	       #gtp{type = resume_notification} = Request,
	       _Resent, #{context := Context} = State) ->

    %% don't do anything special for now

    ResponseIEs = [#v2_cause{v2_cause = request_accepted}],
    Response = response(resume_acknowledge, Context, ResponseIEs, Request),
    {reply, Response, State#{context => Context}};

handle_request(_ReqKey,
	       #gtp{type = delete_session_request, ie = IEs}, _Resent,
	       #{context := Context} = State0) ->

    FqTEI = maps:get(?'Sender F-TEID for Control Plane', IEs, undefined),

    Result =
	do([error_m ||
	       match_context(?'S5/S8-C SGW', Context, FqTEI),
	       return({request_accepted, State0})
	   ]),

    case Result of
	{ok, {ReplyIEs, State}} ->
	    close_pdn_context(State),
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
    close_pdn_context(State),
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
    close_pdn_context(State),
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
    <<Prefix:8, (gtp_c_lib:ip2bin(IP))/binary>>.

response(Cmd, #context{remote_control_tei = TEID}, Response) ->
    {Cmd, TEID, Response}.

response(Cmd, Context, IEs0, #gtp{ie = #{?'Recovery' := Recovery}}) ->
    IEs = gtp_v2_c:build_recovery(Context, Recovery /= undefined, IEs0),
    response(Cmd, Context, IEs).

authenticate(Context, Session, SessionOpts, Request) ->
    lager:info("SessionOpts: ~p", [SessionOpts]),

    case ergw_aaa_session:authenticate(Session, SessionOpts) of
	success ->
	    lager:info("AuthResult: success"),
	    ok;

	Other ->
	    lager:info("AuthResult: ~p", [Other]),

	    Reply1 = response(create_session_response, Context,
			      [#v2_cause{v2_cause = user_authentication_failed}], Request),
	    throw(#ctx_err{level = ?FATAL,
			   reply = Reply1,
			   context = Context})
    end.

usage_report_to_accounting([#{volume :=
				  #{dl := {SendBytes, SendPkts},
				    ul := {RcvdBytes, RcvdPkts}
				   }}]) ->
    [{'InPackets',  RcvdPkts},
     {'OutPackets', SendPkts},
     {'InOctets',   RcvdBytes},
     {'OutOctets',  SendBytes}].

sx_response_to_accounting(#{usage_report := UR}) ->
    to_session(usage_report_to_accounting(UR));
sx_response_to_accounting(_) ->
    to_session([]).

accounting_update(GTP, SessionOpts) ->
    case gen_server:call(GTP, query_usage_report) of
	{ok, Response} ->
	    Acc = sx_response_to_accounting(Response),
	    ergw_aaa_session:merge(SessionOpts, Acc);
	_Other ->
	    lager:warning("got unexpected Query response: ~p", [_Other]),
	    to_session([])
    end.

match_context(_Type, _Context, undefined) ->
    error_m:return(ok);
match_context(Type,
	      #context{
		 remote_control_ip  = RemoteCntlIP,
		 remote_control_tei = RemoteCntlTEI} = Context,
	      #v2_fully_qualified_tunnel_endpoint_identifier{
		 instance       = 0,
		 interface_type = Type,
		 key            = RemoteCntlTEI,
		 ipv4           = RemoteCntlIPBin} = IE) ->
    case gtp_c_lib:bin2ip(RemoteCntlIPBin) of
	RemoteCntlIP ->
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
    {gtp_c_lib:bin2ip(IP4), {gtp_c_lib:bin2ip(IP6Prefix), IP6PrefixLen}};
pdn_alloc(#v2_pdn_address_allocation{type = ipv4,
				     address = << IP4:4/binary>>}) ->
    {gtp_c_lib:bin2ip(IP4), undefined};
pdn_alloc(#v2_pdn_address_allocation{type = ipv6,
				     address = << IP6PrefixLen:8, IP6Prefix:16/binary>>}) ->
    {undefined, {gtp_c_lib:bin2ip(IP6Prefix), IP6PrefixLen}}.

encode_paa({IPv4,_}, undefined) ->
    encode_paa(ipv4, gtp_c_lib:ip2bin(IPv4), <<>>);
encode_paa(undefined, IPv6) ->
    encode_paa(ipv6, <<>>, ip2prefix(IPv6));
encode_paa({IPv4,_}, IPv6) ->
    encode_paa(ipv4v6, gtp_c_lib:ip2bin(IPv4), ip2prefix(IPv6)).

encode_paa(Type, IPv4, IPv6) ->
    #v2_pdn_address_allocation{type = Type, address = <<IPv6/binary, IPv4/binary>>}.

pdn_release_ip(#context{vrf = VRF, ms_v4 = MSv4, ms_v6 = MSv6}) ->
    vrf:release_pdp_ip(VRF, MSv4, MSv6).

close_pdn_context(#{context := Context, 'Session' := Session}) ->
    SessionOpts =
	case ergw_gsn_lib:delete_sgi_session(Context) of
	    {ok, Response} ->
		sx_response_to_accounting(Response);
	    Other ->
		lager:warning("Session Deletion failed with ~p", [Other]),
		to_session([])
	end,
    lager:debug("Accounting Opts: ~p", [SessionOpts]),
    ergw_aaa_session:stop(Session, SessionOpts),
    pdn_release_ip(Context).

apply_context_change(NewContext0, OldContext, State) ->
    NewContextPending = gtp_path:bind(NewContext0),
    NewContext = ergw_gsn_lib:modify_sgi_session(NewContextPending, OldContext),
    gtp_path:unbind(OldContext),
    State#{context => NewContext}.

select_vrf(#context{apn = APN} = Context) ->
    case ergw:vrf(APN) of
	{ok, {VRF, VRFOpts}} ->
	    {Context#context{vrf = VRF}, VRFOpts};
	_ ->
	    throw(#ctx_err{level = ?FATAL,
			   reply = missing_or_unknown_apn,
			   context = Context})
    end.

copy_vrf_session_defaults(K, Value, Opts)
    when K =:= 'MS-Primary-DNS-Server';
	 K =:= 'MS-Secondary-DNS-Server';
	 K =:= 'MS-Primary-NBNS-Server';
	 K =:= 'MS-Secondary-NBNS-Server' ->
    Opts#{K => gtp_c_lib:ip2bin(Value)};
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
	     #context{control_port = #gtp_port{ip = LocalIP}},
	     #{'Username' := #{default := Username},
	       'Password' := #{default := Password}}) ->
    MappedUsername = map_username(IEs, Username, []),
    #{'Username'		=> MappedUsername,
      'Password'		=> Password,
      'Service-Type'		=> 'Framed-User',
      'Framed-Protocol'		=> 'GPRS-PDP-Context',
      '3GPP-GGSN-Address'	=> LocalIP
     }.

copy_optional_binary_ie('3GPP-SGSN-Address' = Key, IP, Session) 
  when IP /= undefined ->
    Session#{Key => gtp_c_lib:bin2ip(IP)};
copy_optional_binary_ie('3GPP-SGSN-IPv6-Address' = Key, IP, Session) 
  when IP /= undefined ->
    Session#{Key => gtp_c_lib:bin2ip(IP)};
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
    Session#{'Called-Station-Id' => unicode:characters_to_binary(lists:join($., APN))};
copy_to_session(_, #v2_msisdn{msisdn = MSISDN}, _AAAopts, Session) ->
    Session#{'Calling-Station-Id' => MSISDN};
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
    Session#{'3GPP-PDP-Type'     => 'IPv4',
	     'Framed-IP-Address' => gtp_c_lib:bin2ip(IP4)};
copy_to_session(_, #v2_pdn_address_allocation{type = ipv6,
					      address = <<IP6PrefixLen:8,
							  IP6Prefix:16/binary>>},
		_AAAopts, Session) ->
    Session#{'3GPP-PDP-Type'      => 'IPv6',
	     'Framed-IPv6-Prefix' => {gtp_c_lib:bin2ip(IP6Prefix), IP6PrefixLen}};
copy_to_session(_, #v2_pdn_address_allocation{type = ipv4v6,
					      address = <<IP6PrefixLen:8,
							  IP6Prefix:16/binary,
							  IP4:4/binary>>},
		_AAAopts, Session) ->
    Session#{'3GPP-PDP-Type' => 'IPv4v6',
	     'Framed-IP-Address'  => gtp_c_lib:bin2ip(IP4),
	     'Framed-IPv6-Prefix' => {gtp_c_lib:bin2ip(IP6Prefix), IP6PrefixLen}};

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
%% copy_to_session(_, #v2_charging_characteristics{value = Value}, _AAAopts, Session) ->
%%     Session#{'3GPP-Charging-Characteristics' => Value};

copy_to_session(_, #v2_serving_network{mcc = MCC, mnc = MNC}, _AAAopts, Session) ->
    Session#{'3GPP-SGSN-MCC-MNC' => <<MCC/binary, MNC/binary>>};
copy_to_session(_, #v2_mobile_equipment_identity{mei = IMEI}, _AAAopts, Session) ->
    Session#{'3GPP-IMEISV' => IMEI};
copy_to_session(_, #v2_rat_type{rat_type = Type}, _AAAopts, Session) ->
    Session#{'3GPP-RAT-Type' => Type};
copy_to_session(_, #v2_user_location_information{} = IE, _AAAopts, Session) ->
    Value = gtp_packet:encode_v2_user_location_information(IE),
    Session#{'3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_ue_time_zone{timezone = TZ, dst = DST}, _AAAopts, Session) ->
    Session#{'3GPP-MS-TimeZone' => {TZ, DST}};
copy_to_session(_, _, _AAAopts, Session) ->
    Session.

init_session_from_gtp_req(IEs, AAAopts, Session) ->
    maps:fold(copy_to_session(_, _, AAAopts, _), Session, IEs).

update_context_cntl_ids(#v2_fully_qualified_tunnel_endpoint_identifier{
			     key  = RemoteCntlTEI,
			     ipv4 = RemoteCntlIP}, Context) ->
    Context#context{
      remote_control_ip  = gtp_c_lib:bin2ip(RemoteCntlIP),
      remote_control_tei = RemoteCntlTEI
     };
update_context_cntl_ids(_ , Context) ->
    Context.

update_context_data_ids(#v2_fully_qualified_tunnel_endpoint_identifier{
			     key  = RemoteDataTEI,
			     ipv4 = RemoteDataIP
			    }, Context) ->
    Context#context{
      remote_data_ip     = gtp_c_lib:bin2ip(RemoteDataIP),
      remote_data_tei    = RemoteDataTEI
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


msg(#context{remote_control_tei = RemoteCntlTEI}, Type, RequestIEs) ->
    #gtp{version = v2, type = Type, tei = RemoteCntlTEI, ie = RequestIEs}.


send_request(GtpPort, DstIP, DstPort, T3, N3, Msg, ReqInfo) ->
    gtp_context:send_request(GtpPort, DstIP, DstPort, T3, N3, Msg, ReqInfo).

send_request(#context{control_port = GtpPort, remote_control_ip = RemoteCntlIP},
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

assign_ips(SessionOps, PAA, #context{vrf = VRF, local_control_tei = LocalTEI} = Context) ->
    {ReqMSv4, ReqMSv6} = session_ip_alloc(SessionOps, pdn_alloc(PAA)),
    {ok, MSv4, MSv6} = vrf:allocate_pdp_ip(VRF, LocalTEI, ReqMSv4, ReqMSv6),
    Context#context{ms_v4 = MSv4, ms_v6 = MSv6}.

ppp_ipcp_conf_resp(Verdict, Opt, IPCP) ->
    maps:update_with(Verdict, fun(O) -> [Opt|O] end, [Opt], IPCP).

ppp_ipcp_conf(#{'MS-Primary-DNS-Server' := DNS}, {ms_dns1, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_dns1, gtp_c_lib:ip2bin(DNS)}, IPCP);
ppp_ipcp_conf(#{'MS-Secondary-DNS-Server' := DNS}, {ms_dns2, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_dns2, gtp_c_lib:ip2bin(DNS)}, IPCP);
ppp_ipcp_conf(#{'MS-Primary-NBNS-Server' := DNS}, {ms_wins1, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_wins1, gtp_c_lib:ip2bin(DNS)}, IPCP);
ppp_ipcp_conf(#{'MS-Secondary-NBNS-Server' := DNS}, {ms_wins2, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_wins2, gtp_c_lib:ip2bin(DNS)}, IPCP);

ppp_ipcp_conf(_SessionOpts, Opt, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Reject', Opt, IPCP).

pdn_ppp_pco(SessionOpts, {pap, 'PAP-Authentication-Request', Id, _Username, _Password}, Opts) ->
    [{pap, 'PAP-Authenticate-Ack', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdn_ppp_pco(SessionOpts, {chap, 'CHAP-Response', Id, _Value, _Name}, Opts) ->
    [{chap, 'CHAP-Success', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdn_ppp_pco(SessionOpts, {ipcp,'CP-Configure-Request', Id, CpReqOpts}, Opts) ->
    CpRespOpts = lists:foldr(ppp_ipcp_conf(SessionOpts, _, _), #{}, CpReqOpts),
    maps:fold(fun(K, V, O) -> [{ipcp, K, Id, V} | O] end, Opts, CpRespOpts);

pdn_ppp_pco(#{'3GPP-IPv6-DNS-Servers' := DNS}, {?'PCO-DNS-Server-IPv6-Address', <<>>}, Opts) ->
    lager:info("Apply IPv6 DNS Servers PCO Opt: ~p", [DNS]),
    Opts;
pdn_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv4-Address', <<>>}, Opts) ->
    lists:foldr(fun(Key, O) ->
			case maps:find(Key, SessionOpts) of
			    {ok, DNS} ->
				[{?'PCO-DNS-Server-IPv4-Address', gtp_c_lib:ip2bin(DNS)} | O];
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
		   #v2_charging_id{id = <<0,0,0,1>>},
		   EBI,
		   #v2_bearer_level_quality_of_service{
		      pl=15,
		      pvi=0,
		      label=9,maximum_bit_rate_for_uplink=0,
		      maximum_bit_rate_for_downlink=0,
		      guaranteed_bit_rate_for_uplink=0,
		      guaranteed_bit_rate_for_downlink=0},
		   s5s8_pgw_gtp_u_tei(Context)]},
    [IE | IEs].

s5s8_pgw_gtp_c_tei(#context{control_port = #gtp_port{ip = LocalCntlIP},
			    local_control_tei = LocalCntlTEI}) ->
    #v2_fully_qualified_tunnel_endpoint_identifier{
       instance = 1,		%% PGW S5/S8/ S2a/S2b F-TEID for PMIP based interface
				%% or for GTP based Control Plane interface
       interface_type = ?'S5/S8-C PGW',
       key = LocalCntlTEI,
       ipv4 = gtp_c_lib:ip2bin(LocalCntlIP)}.

s5s8_pgw_gtp_u_tei(#context{data_port = #gtp_port{ip = LocalDataIP},
			    local_data_tei = LocalDataTEI}) ->
    #v2_fully_qualified_tunnel_endpoint_identifier{
       instance = 2,		%% S5/S8 F-TEI Instance
       interface_type = ?'S5/S8-U PGW',
       key = LocalDataTEI,
       ipv4 = gtp_c_lib:ip2bin(LocalDataIP)}.

create_session_response(SessionOpts, RequestIEs, EBI,
			#context{ms_v4 = MSv4, ms_v6 = MSv6} = Context) ->

    IE0 = bearer_context(EBI, Context, []),
    IE1 = pdn_pco(SessionOpts, RequestIEs, IE0),

    [#v2_cause{v2_cause = request_accepted},
     #v2_apn_restriction{restriction_type_value = 0},
     s5s8_pgw_gtp_c_tei(Context),
     encode_paa(MSv4, MSv6) | IE1].
