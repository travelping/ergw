%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn).

-behaviour(gtp_api).

-compile({parse_transform, cut}).

-export([init/2, request_spec/1, handle_request/5, handle_cast/2]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").
-include("include/3gpp.hrl").

%%====================================================================
%% API
%%====================================================================

-record(create_pdp_context_request, {
	  imsi,
	  routeing_area_identity,
	  recovery,
	  selection_mode,
	  tunnel_endpoint_identifier_data_i,
	  tunnel_endpoint_identifier_control_plane,
	  nsapi,
	  linked_nsapi,
	  charging_characteristics,
	  trace_reference,
	  trace_type,
	  end_user_address,
	  apn,
	  pco,
	  sgsn_address_for_signalling,
	  sgsn_address_for_user_traffic,
	  alternative_sgsn_address_for_signalling,
	  alternative_sgsn_address_for_user_traffic,
	  msisdn,
	  quality_of_service_profile,
	  traffic_flow_template,
	  trigger_id,
	  omc_identity,
	  common_flags,
	  apn_restriction,
	  rat_type,
	  user_location_information,
	  ms_time_zone,
	  imei,
	  camel_charging_information_container,
	  additional_trace_info,
	  correlation_id,
	  evolved_allocation_retention_priority_i,
	  extended_common_flags,
	  user_csg_information,
	  ambr,
	  signalling_priority_indication,
	  cn_operator_selection_entity,
	  private_extension,
	  additional_ies
	 }).

-record(update_pdp_context_request, {
	  imsi,
	  routeing_area_identity,
	  recovery,
	  tunnel_endpoint_identifier_data_i,
	  tunnel_endpoint_identifier_control_plane,
	  nsapi,
	  trace_reference,
	  trace_type,
	  pco,
	  sgsn_address_for_signalling,
	  sgsn_address_for_user_traffic,
	  alternative_sgsn_address_for_signalling,
	  alternative_sgsn_address_for_user_traffic,
	  quality_of_service_profile,
	  traffic_flow_template,
	  trigger_id,
	  omc_identity,
	  common_flags,
	  rat_type,
	  user_location_information,
	  ms_time_zone,
	  additional_trace_info,
	  direct_tunnel_flags,
	  evolved_allocation_retention_priority_i,
	  extended_common_flags,
	  user_csg_information,
	  ambr,
	  signalling_priority_indication,
	  cn_operator_selection_entity,
	  private_extension,
	  additional_ies
	 }).

request_spec(create_pdp_context_request) ->
    [{{international_mobile_subscriber_identity, 0},	conditional},
     {{routeing_area_identity, 0},			optional},
     {{recovery, 0},					optional},
     {{selection_mode, 0},				conditional},
     {{tunnel_endpoint_identifier_data_i, 0},		mandatory},
     {{tunnel_endpoint_identifier_control_plane, 0},	conditional},
     {{nsapi, 0},					mandatory},
     {{nsapi, 1},					conditional},
     {{charging_characteristics, 0},			conditional},
     {{trace_reference, 0},				optional},
     {{trace_type, 0},					optional},
     {{end_user_address, 0},				conditional},
     {{access_point_name, 0},				conditional},
     {{protocol_configuration_options, 0},		optional},
     {{gsn_address, 0},					mandatory},
     {{gsn_address, 1},					mandatory},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {{ms_international_pstn_isdn_number, 0},		conditional},
     {{quality_of_service_profile, 0},			mandatory},
     {{traffic_flow_template, 0},			conditional},
     {{trigger_id, 0},					optional},
     {{omc_identity, 0},				optional},
     {{common_flags, 0},				optional},
     {{apn_restriction, 0},				optional},
     {{rat_type, 0},					optional},
     {{user_location_information, 0},			optional},
     {{ms_time_zone, 0},				optional},
     {{imei, 0},					conditional},
     {{camel_charging_information_container, 0},	optional},
     {{additional_trace_info, 0},			optional},
     {{correlation_id, 0},				optional},
     {{evolved_allocation_retention_priority_i, 0},	optional},
     {{extended_common_flags, 0},			optional},
     {{user_csg_information, 0},			optional},
     {{ambr, 0},					optional},
     {{signalling_priority_indication, 0},		optional},
     {{cn_operator_selection_entity, 0},		optional},
     {{private_extension, 0},				optional}];

request_spec(update_pdp_context_request) ->
    [{{international_mobile_subscriber_identity, 0},	optional},
     {{routeing_area_identity, 0},			optional},
     {{recovery, 0},					optional},
     {{tunnel_endpoint_identifier_data_i, 0},		mandatory},
     {{tunnel_endpoint_identifier_control_plane, 0},	conditional},
     {{nsapi, 0},					mandatory},
     {{trace_reference, 0},				optional},
     {{trace_type, 0},					optional},
     {{protocol_configuration_options, 0},		optional},
     {{gsn_address, 0},					mandatory},
     {{gsn_address, 1},					mandatory},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {{quality_of_service_profile, 0},			mandatory},
     {{traffic_flow_template, 0},			conditional},
     {{trigger_id, 0},					optional},
     {{omc_identity, 0},				optional},
     {{common_flags, 0},				optional},
     {{rat_type, 0},					optional},
     {{user_location_information, 0},			optional},
     {{ms_time_zone, 0},				optional},
     {{additional_trace_info, 0},			optional},
     {{direct_tunnel_flags, 0},				optional},
     {{evolved_allocation_retention_priority_i, 0},	optional},
     {{extended_common_flags, 0},			optional},
     {{user_csg_information, 0},			optional},
     {{ambr, 0},					optional},
     {{signalling_priority_indication, 0},		optional},
     {{cn_operator_selection_entity, 0},		optional},
     {{private_extension, 0},				optional}];

request_spec(_) ->
    [].

-record(context_state, {}).

init(_Opts, State) ->
    {ok, Session} = ergw_aaa_session_sup:new_session(self(), #{}),
    {ok, State#{'Session' => Session}}.

handle_cast({path_restart, Path}, #{context := #context{path = Path} = Context} = State) ->
    dp_delete_pdp_context(Context),
    pdp_release_ip(Context),
    {stop, normal, State};
handle_cast({path_restart, _Path}, State) ->
    {noreply, State}.

%% resent request
handle_request(_From, _Msg, _Req, true, State) ->
%% resent request
    {noreply, State};

handle_request(_From,
	       #gtp{type = create_pdp_context_request} = Request,
	       #create_pdp_context_request{
		  quality_of_service_profile = ReqQoSProfile
		 } = Req, _Resent,
	       #{tei := LocalTEI, gtp_port := GtpPort, gtp_dp_port := GtpDP,
		 'Session' := Session} = State) ->

    #create_pdp_context_request{
       recovery = Recovery,
       apn = #access_point_name{apn = APN},
       end_user_address = EUA
      } = Req,

    Context0 = init_context(APN, GtpPort, LocalTEI, GtpDP, LocalTEI),
    Context1 = update_context_from_gtp_req(Request, Context0),
    Context2 = gtp_path:bind(Recovery, Context1),

    SessionOpts0 = init_session(Context2),
    SessionOpts1 = init_session_from_gtp_req(Request, SessionOpts0),
    SessionOpts = init_session_qos(ReqQoSProfile, SessionOpts1),

    lager:info("SessionOpts: ~p", [SessionOpts]),
    case ergw_aaa_session:authenticate(Session, SessionOpts) of
	success ->
	    lager:info("AuthResult: success"),

	    ActiveSessionOpts = ergw_aaa_session:get(Session),
	    Context = assign_ips(ActiveSessionOpts, EUA, Context2),

	    ResponseIEs0 = create_pdp_context_response(ActiveSessionOpts, Req, Context),
	    ResponseIEs = gtp_v1_c:build_recovery(Context, Recovery /= undefined, ResponseIEs0),
	    Reply = {create_pdp_context_response, Context#context.remote_control_tei, ResponseIEs},
	    {reply, Reply, State#{context => Context}};

	Other ->
	    lager:info("AuthResult: ~p", [Other]),

	    ResponseIEs0 = [#cause{value = user_authentication_failed}],
	    ResponseIEs = gtp_v1_c:build_recovery(Context2, Recovery /= undefined, ResponseIEs0),
	    Reply = {create_pdp_context_response, Context2#context.remote_control_tei, ResponseIEs},
	    {stop, Reply, State#{context => Context2}}
    end;

handle_request(_From,
	       #gtp{type = update_pdp_context_request} = Request, Req, _Resent,
	       #{tei := LocalTEI, gtp_port := GtpPort, context := OldContext} = State0) ->

    #update_pdp_context_request{
       recovery = Recovery,
       quality_of_service_profile = QoSProfile
      } = Req,

    RemoteCntlTEI =
	case Req#update_pdp_context_request.tunnel_endpoint_identifier_control_plane of
	    #tunnel_endpoint_identifier_control_plane{tei = ReqCntlTEI} ->
		ReqCntlTEI;
	    _ ->
		OldContext#context.remote_control_tei
	end,

    Context0 = update_context_from_gtp_req(Request, OldContext),
    Context = gtp_path:bind(Recovery, Context0),

    State1 = if Context /= OldContext ->
		     apply_context_change(Context, OldContext, State0);
		true ->
		     State0
	     end,

    #gtp_port{ip = LocalIP} = GtpPort,

    ResponseIEs0 = [#cause{value = request_accepted},
		    #tunnel_endpoint_identifier_data_i{tei = LocalTEI},
		    #charging_id{id = <<0,0,0,1>>},
		    #gsn_address{instance = 0, address = gtp_c_lib:ip2bin(LocalIP)},   %% for Control Plane
		    #gsn_address{instance = 1, address = gtp_c_lib:ip2bin(LocalIP)},   %% for User Traffic
		    QoSProfile],
    ResponseIEs = gtp_v1_c:build_recovery(Context, Recovery /= undefined, ResponseIEs0),
    Reply = {update_pdp_context_response, RemoteCntlTEI, ResponseIEs},
    {reply, Reply, State1};

handle_request(_From,
	       #gtp{type = delete_pdp_context_request, ie = _IEs}, _Req, _Resent,
	       #{context := Context} = State) ->
    #context{remote_control_tei = RemoteCntlTEI} = Context,

    dp_delete_pdp_context(Context),
    pdp_release_ip(Context),

    Reply = {delete_pdp_context_response, RemoteCntlTEI, request_accepted},
    {stop, Reply, State};

handle_request(_From, _Msg, _Req,  _Resent, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#21,
			    pdp_address = Address}) ->
    IP4 = case Address of
	      << >> ->
		  {0,0,0,0};
	      <<_:4/bytes>> ->
		  gtp_c_lib:bin2ip(Address)
	  end,
    {IP4, undefined};

pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#57,
			    pdp_address = Address}) ->
    IP6 = case Address of
	      << >> ->
		  {{0,0,0,0,0,0,0,0},0};
	      <<_:16/bytes>> ->
		  {gtp_c_lib:bin2ip(Address),128}
	  end,
    {undefined, IP6};
pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#8D,
			    pdp_address = Address}) ->
    case Address of
	<< IP4:4/bytes, IP6:16/bytes >> ->
	    {gtp_c_lib:bin2ip(IP4), {gtp_c_lib:bin2ip(IP6), 128}};
	<< IP6:16/bytes >> ->
	    {{0,0,0,0}, {gtp_c_lib:bin2ip(IP6), 128}};
	<< IP4:4/bytes >> ->
	    {gtp_c_lib:bin2ip(IP4), {{0,0,0,0,0,0,0,0},0}};
 	<<  >> ->
	    {{0,0,0,0}, {{0,0,0,0,0,0,0,0},0}}
   end;

pdp_alloc(_) ->
    {undefined, undefined}.

encode_eua(IPv4, undefined) ->
    encode_eua(1, 16#21, gtp_c_lib:ip2bin(IPv4), <<>>);
encode_eua(undefined, {IPv6,_}) ->
    encode_eua(1, 16#57, <<>>, gtp_c_lib:ip2bin(IPv6));
encode_eua(IPv4, {IPv6,_}) ->
    encode_eua(1, 16#8D, gtp_c_lib:ip2bin(IPv4), gtp_c_lib:ip2bin(IPv6)).

encode_eua(Org, Number, IPv4, IPv6) ->
    #end_user_address{pdp_type_organization = Org,
		      pdp_type_number = Number,
		      pdp_address = <<IPv4/binary, IPv6/binary >>}.

pdp_release_ip(#context{apn = APN, ms_v4 = MSv4, ms_v6 = MSv6}) ->
    apn:release_pdp_ip(APN, MSv4, MSv6).

apply_context_change(NewContext0, OldContext, State) ->
    NewContext = gtp_path:bind(NewContext0),
    dp_update_pdp_context(NewContext, OldContext),
    gtp_path:unbind(OldContext),
    State#{context => NewContext}.

init_session(#context{control_port = #gtp_port{
					ip = LocalIP}}) ->
    #{'Username'		=> <<"ergw">>,
      'Password'		=> <<"ergw">>,
      'Service-Type'		=> 'Framed-User',
      'Framed-Protocol'		=> 'GPRS-PDP-Context',
      '3GPP-GGSN-Address'	=> LocalIP
      %%TODO: '3GPP-GGSN-MCC-MNC'
     }.

copy_ppp_to_session({pap, 'PAP-Authentication-Request', _Id, Username, Password}, Session) ->
    Session#{'Username' => Username, 'Password' => Password};
copy_ppp_to_session({chap, 'CHAP-Challenge', _Id, Value, _Name}, Session) ->
    Session#{'CHAP_Challenge' => Value};
copy_ppp_to_session({chap, 'CHAP-Response', _Id, Value, Name}, Session) ->
    Session#{'CHAP_Password' => Value, 'Username' => Name};
copy_ppp_to_session(_, Session) ->
    Session.

copy_to_session(#protocol_configuration_options{config = {0, Options}}, Session) ->
    lists:foldr(fun copy_ppp_to_session/2, Session, Options);
copy_to_session(#access_point_name{apn = APN}, Session) ->
    Session#{'Called-Station-Id' => unicode:characters_to_binary(lists:join($., APN))};
copy_to_session(#ms_international_pstn_isdn_number{
		   msisdn = {isdn_address, _, _, 1, MSISDN}}, Session) ->
    Session#{'Calling-Station-Id' => MSISDN};
copy_to_session(#international_mobile_subscriber_identity{imsi = IMSI}, Session) ->
    case itu_e212:split_imsi(IMSI) of
	{MCC, MNC, _} ->
	    Session#{'3GPP-IMSI' => IMSI,
		     '3GPP-IMSI-MCC-MNC' => <<MCC/binary, MNC/binary>>};
	_ ->
	    Session#{'3GPP-IMSI' => IMSI}
    end;
copy_to_session(#end_user_address{pdp_type_organization = 0,
				  pdp_type_number = 1}, Session) ->
    Session#{'3GPP-PDP-Type' => 'PPP'};
copy_to_session(#end_user_address{pdp_type_organization = 1,
				  pdp_type_number = 16#57,
				  pdp_address = Address}, Session0) ->
    Session = Session0#{'3GPP-PDP-Type' => 'IPv4'},
    case Address of
	<<_:4/bytes>> -> Session#{'Framed-IP-Address' => gtp_c_lib:bin2ip(Address)};
	_             -> Session
    end;
copy_to_session(#end_user_address{pdp_type_organization = 1,
				  pdp_type_number = 16#21,
				  pdp_address = Address}, Session0) ->
    Session = Session0#{'3GPP-PDP-Type' => 'IPv6'},
    case Address of
	<<_:16/bytes>> -> Session#{'Framed-IPv6-Prefix' => {gtp_c_lib:bin2ip(Address), 128}};
	_              -> Session
    end;
copy_to_session(#end_user_address{pdp_type_organization = 1,
				  pdp_type_number = 16#8D,
				  pdp_address = Address}, Session0) ->
    Session = Session0#{'3GPP-PDP-Type' => 'IPv4v6'},
    case Address of
	<< IP4:4/bytes >> ->
	    Session#{'Framed-IP-Address'  => gtp_c_lib:bin2ip(IP4)};
	<< IP6:16/bytes >> ->
	    Session#{'Framed-IPv6-Prefix' => {gtp_c_lib:bin2ip(IP6), 128}};
	<< IP4:4/bytes, IP6:16/bytes >> ->
	    Session#{'Framed-IP-Address'  => gtp_c_lib:bin2ip(IP4),
		     'Framed-IPv6-Prefix' => {gtp_c_lib:bin2ip(IP6), 128}};
	_ ->
	    Session
   end;

copy_to_session(#gsn_address{instance = 0, address = IP}, Session) ->
    Session#{'3GPP-SGSN-Address' => IP};
copy_to_session(#nsapi{instance = 0, nsapi = NSAPI}, Session) ->
    Session#{'3GPP-NSAPI' => NSAPI};
copy_to_session(#selection_mode{mode = Mode}, Session) ->
    Session#{'3GPP-Selection-Mode' => Mode};
copy_to_session(#charging_characteristics{value = Value}, Session) ->
    Session#{'3GPP-Charging-Characteristics' => Value};
copy_to_session(#routeing_area_identity{mcc = MCC, mnc = MNC}, Session) ->
    Session#{'3GPP-SGSN-MCC-MNC' => <<MCC/binary, MNC/binary>>};
copy_to_session(#imei{imei = IMEI}, Session) ->
    Session#{'3GPP-IMEISV' => IMEI};
copy_to_session(#rat_type{rat_type = Type}, Session) ->
    Session#{'3GPP-RAT-Type' => Type};
copy_to_session(#user_location_information{} = IE, Session) ->
    Value = gtp_packet:encode_v1_uli(IE),
    Session#{'3GPP-User-Location-Info' => Value};
copy_to_session(#ms_time_zone{timezone = TZ, dst = DST}, Session) ->
    Session#{'3GPP-MS-TimeZone' => {TZ, DST}};
copy_to_session(_, Session) ->
    Session.

init_session_from_gtp_req(#gtp{ie = IEs}, Session) ->
    lists:foldr(fun copy_to_session/2, Session, IEs).

init_session_qos(#quality_of_service_profile{data = RequestedQoS}, Session) ->
    %% TODO: use config setting to init default class....
    NegotiatedQoS = negotiate_qos(RequestedQoS),
    Session#{'3GPP-GPRS-Negotiated-QoS-Profile' => NegotiatedQoS}.

negotiate_qos(ReqQoSProfileData) ->
    case '3gpp_qos':decode(ReqQoSProfileData) of
	Profile when is_binary(Profile) ->
	    ReqQoSProfileData;
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
	    '3gpp_qos':encode(QoS);
	_ ->
	    ReqQoSProfileData
    end.

init_context(APN, CntlPort, CntlTEI, DataPort, DataTEI) ->
    #context{
       apn               = APN,
       version           = v1,
       control_interface = ?MODULE,
       control_port      = CntlPort,
       local_control_tei = CntlTEI,
       data_port         = DataPort,
       local_data_tei    = DataTEI,
       state             = #context_state{}
      }.

get_context_from_req(#gsn_address{instance = 0, address = CntlIP}, Context) ->
    Context#context{remote_control_ip = gtp_c_lib:bin2ip(CntlIP)};
get_context_from_req(#gsn_address{instance = 1, address = DataIP}, Context) ->
    Context#context{remote_data_ip = gtp_c_lib:bin2ip(DataIP)};
get_context_from_req(#tunnel_endpoint_identifier_data_i{instance = 0, tei = DataTEI}, Context) ->
    Context#context{remote_data_tei = DataTEI};
get_context_from_req(#tunnel_endpoint_identifier_control_plane{instance = 0, tei = CntlTEI}, Context) ->
    Context#context{remote_control_tei = CntlTEI};
%% get_context_from_req(#nsapi{instance = 0, nsapi = NSAPI}, #context{state = State} = Context) ->
%%     Context#context{state = State#context_state{nsapi = NSAPI}};
get_context_from_req(_, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs}, Context) ->
    lists:foldl(fun get_context_from_req/2, Context, IEs).

dp_args(#context{ms_v4 = MSv4}) ->
    MSv4.

dp_create_pdp_context(Context) ->
    Args = dp_args(Context),
    gtp_dp:create_pdp_context(Context, Args).

dp_update_pdp_context(NewContext, OldContext) ->
    %% TODO: only do that if New /= Old
    dp_delete_pdp_context(OldContext),
    dp_create_pdp_context(NewContext).

dp_delete_pdp_context(Context) ->
    Args = dp_args(Context),
    gtp_dp:delete_pdp_context(Context, Args).

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

assign_ips(SessionOps, EUA, #context{apn = APN, local_control_tei = LocalTEI} = Context) ->
    {ReqMSv4, ReqMSv6} = session_ip_alloc(SessionOps, pdp_alloc(EUA)),
    {ok, MSv4, MSv6} = apn:allocate_pdp_ip(APN, LocalTEI, ReqMSv4, ReqMSv6),
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

pdp_ppp_pco(SessionOpts, {pap, 'PAP-Authentication-Request', Id, _Username, _Password}, Opts) ->
    [{pap, 'PAP-Authenticate-Ack', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdp_ppp_pco(SessionOpts, {chap, 'CHAP-Response', Id, _Value, _Name}, Opts) ->
    [{chap, 'CHAP-Success', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdp_ppp_pco(SessionOpts, {ipcp,'CP-Configure-Request', Id, CpReqOpts}, Opts) ->
    CpRespOpts = lists:foldr(ppp_ipcp_conf(SessionOpts, _, _), #{}, CpReqOpts),
    maps:fold(fun(K, V, O) -> [{ipcp, K, Id, V} | O] end, Opts, CpRespOpts);

pdp_ppp_pco(#{'3GPP-IPv6-DNS-Servers' := DNS}, {?'PCO-DNS-Server-IPv6-Address', <<>>}, Opts) ->
    lager:info("Apply IPv6 DNS Servers PCO Opt: ~p", [DNS]),
    Opts;
pdp_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv4-Address', <<>>}, Opts) ->
    lists:foldr(fun(Key, O) ->
			case maps:find(Key, SessionOpts) of
			    {ok, DNS} ->
				[{?'PCO-DNS-Server-IPv4-Address', gtp_c_lib:ip2bin(DNS)} | O];
			    _ ->
				O
			end
		end, Opts, ['MS-Secondary-DNS-Server', 'MS-Primary-DNS-Server']);
pdp_ppp_pco(_SessionOpts, PPPReqOpt, Opts) ->
    lager:info("Apply PPP Opt: ~p", [PPPReqOpt]),
    Opts.

pdp_pco(SessionOpts, #protocol_configuration_options{config = {0, PPPReqOpts}}, IE) ->
    case lists:foldr(pdp_ppp_pco(SessionOpts, _, _), [], PPPReqOpts) of
	[]   -> IE;
	Opts -> [#protocol_configuration_options{config = {0, Opts}} | IE]
    end;
pdp_pco(_SessionOpts, _PCO, IE) ->
    IE.

pdp_qos_profile(#{'3GPP-GPRS-Negotiated-QoS-Profile' := NegotiatedQoS}, IE) ->
    [#quality_of_service_profile{data = NegotiatedQoS} | IE];
pdp_qos_profile(_SessionOpts, IE) ->
    IE.

create_pdp_context_response(SessionOpts,
			    #create_pdp_context_request{
			       pco = ReqProtocolConfigOpts
			      },
			    #context{control_port = #gtp_port{ip = LocalIP},
				     local_control_tei = LocalTEI,
				     ms_v4 = MSv4, ms_v6 = MSv6} = Context) ->
    dp_create_pdp_context(Context),

    IE0 = [#cause{value = request_accepted},
	  #reordering_required{required = no},
	  #tunnel_endpoint_identifier_data_i{tei = LocalTEI},
	  #tunnel_endpoint_identifier_control_plane{tei = LocalTEI},
	  #charging_id{id = <<0,0,0,1>>},
	  encode_eua(MSv4, MSv6),
	  #gsn_address{instance = 0, address = gtp_c_lib:ip2bin(LocalIP)},   %% for Control Plane
	  #gsn_address{instance = 1, address = gtp_c_lib:ip2bin(LocalIP)}],  %% for User Traffic
    IE = pdp_qos_profile(SessionOpts, IE0),
    pdp_pco(SessionOpts, ReqProtocolConfigOpts, IE).
