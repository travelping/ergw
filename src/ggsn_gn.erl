%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn).

-behaviour(gtp_api).

-export([request_spec/1, handle_request/4]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").
-include("include/3gpp.hrl").

%%====================================================================
%% API
%%====================================================================

-record(create_pdp_context_request, {
	  imsi,
	  routeing_area_identity,
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

handle_request(_SrcGtpPort,
	       #gtp{type = create_pdp_context_request, ie = IEs}, Req,
	       #{tei := LocalTEI, gtp_port := GtpPort} = State0) ->

    #create_pdp_context_request{
       sgsn_address_for_signalling =
	   #gsn_address{address = RemoteCntlIPBin},
       sgsn_address_for_user_traffic =
	   #gsn_address{address = RemoteDataIPBin},
       tunnel_endpoint_identifier_data_i =
	   #tunnel_endpoint_identifier_data_i{tei = RemoteDataTEI},
       tunnel_endpoint_identifier_control_plane =
	   #tunnel_endpoint_identifier_control_plane{tei = RemoteCntlTEI},
       end_user_address = EUA,
       quality_of_service_profile = ReqQoSProfile
      } = Req,

    RemoteCntlIP = gtp_c_lib:bin2ip(RemoteCntlIPBin),
    RemoteDataIP = gtp_c_lib:bin2ip(RemoteDataIPBin),
    {ReqMSv4, ReqMSv6} = pdp_alloc(EUA),

    {ok, MSv4, MSv6} = pdp_alloc_ip(LocalTEI, ReqMSv4, ReqMSv6, State0),
    Context = #context{
		 control_interface = ?MODULE,
		 control_tunnel    = gtp_v1_c,
		 control_ip        = RemoteCntlIP,
		 control_tei       = RemoteCntlTEI,
		 data_tunnel       = gtp_v1_u,
		 data_ip           = RemoteDataIP,
		 data_tei          = RemoteDataTEI,
		 ms_v4             = MSv4,
		 ms_v6             = MSv6},
    State1 = State0#{context => Context},

    #gtp_port{ip = LocalIP} = GtpPort,

    Session0 = #{'IP'           => gtp_c_lib:ip2bin(MSv4),
		 'GGSN-Address' => gtp_c_lib:ip2bin(LocalIP)},
    Session1 = init_session(IEs, Session0),
    lager:debug("Invoking CONTROL: ~p", [Session1]),
    ergw_control:authenticate(Session1),

    {ok, NewGTPcPeer, _NewGTPuPeer} = gtp_v1_c:handle_sgsn(IEs, Context, State1),
    lager:debug("New: ~p, ~p", [NewGTPcPeer, _NewGTPuPeer]),
    gtp_context:setup(Context, State1),

    %% TODO: the QoS profile is too simplistic
    #quality_of_service_profile{data = ReqQoSProfileData} = ReqQoSProfile,
    QoSProfile =
	case '3gpp_qos':decode(ReqQoSProfileData) of
	    Profile when is_binary(Profile) ->
		ReqQoSProfile;
	    #qos{traffic_class = 0} ->			%% MS to Network: Traffic Class: Subscribed
		%% 3GPP TS 24.008, Sect. 10.5.6.5,
		QoS = #qos{
			 delay_class			= 4,		%% best effort
			 reliability_class		= 3,		%% Unacknowledged GTP/LLC,
									%% Ack RLC, Protected data
			 peak_throughput		= 2,		%% 2000 oct/s (2 kBps)
			 precedence_class		= 3,		%% Low priority
			 mean_throughput		= 31,		%% Best effort
			 traffic_class			= 4,		%% Background class
			 delivery_order			= 2,		%% Without delivery order
			 delivery_of_erroneorous_sdu	= 3,		%% Erroneous SDUs are not delivered
			 max_sdu_size			= 1500,		%% 1500 octets
			 max_bit_rate_uplink		= 16,		%% 16 kbps
			 max_bit_rate_downlink		= 16,		%% 16 kbps
			 residual_ber			= 7,		%% 10^-5
			 sdu_error_ratio		= 4,		%% 10^-4
			 transfer_delay			= 300,		%% 300ms
			 traffic_handling_priority	= 3,		%% Priority level 3
			 guaranteed_bit_rate_uplink	= 0,		%% 0 kbps
			 guaranteed_bit_rate_downlink	= 0,		%% 0 kbps
			 signaling_indication		= 0,		%% unknown
			 source_statistics_descriptor	= 0},		%% Not optimised for signalling traffic
		ReqQoSProfile#quality_of_service_profile{data = '3gpp_qos':encode(QoS)};
	    _ ->
		ReqQoSProfile
	end,

    ResponseIEs = [#cause{value = request_accepted},
		   #reordering_required{required = no},
		   #tunnel_endpoint_identifier_data_i{tei = LocalTEI},
		   #tunnel_endpoint_identifier_control_plane{tei = LocalTEI},
		   #charging_id{id = <<0,0,0,1>>},
		   encode_eua(MSv4, MSv6),
		   #protocol_configuration_options{config = {0,
							     [{ipcp,'CP-Configure-Ack',0,
                                                               [{ms_dns1,<<8,8,8,8>>},{ms_dns2,<<0,0,0,0>>}]}]}},
		   #gsn_address{instance = 0, address = gtp_c_lib:ip2bin(LocalIP)},   %% for Control Plane
		   #gsn_address{instance = 1, address = gtp_c_lib:ip2bin(LocalIP)},   %% for User Traffic
		   QoSProfile
		  | gtp_v1_c:build_recovery(GtpPort, NewGTPcPeer)],
    Reply = {create_pdp_context_response, RemoteCntlTEI, ResponseIEs},
    {reply, Reply, State1};

handle_request(_SrcGtpPort,
	       #gtp{type = update_pdp_context_request, ie = IEs}, Req,
	       #{tei := LocalTEI, gtp_port := GtpPort, context := OldContext} = State0) ->

    #update_pdp_context_request{
       sgsn_address_for_signalling =
	   #gsn_address{address = RemoteCntlIPBin},
       sgsn_address_for_user_traffic =
	   #gsn_address{address = RemoteDataIPBin},
       tunnel_endpoint_identifier_data_i =
	   #tunnel_endpoint_identifier_data_i{tei = RemoteDataTEI},
       quality_of_service_profile = QoSProfile
      } = Req,

    RemoteCntlTEI =
	case Req#update_pdp_context_request.tunnel_endpoint_identifier_control_plane of
	    #tunnel_endpoint_identifier_control_plane{tei = ReqCntlTEI} ->
		ReqCntlTEI;
	    _ ->
		OldContext#context.control_tei
	end,

    RemoteCntlIP = gtp_c_lib:bin2ip(RemoteCntlIPBin),
    RemoteDataIP = gtp_c_lib:bin2ip(RemoteDataIPBin),

    Context = OldContext#context{
		control_ip  = RemoteCntlIP,
		control_tei = RemoteCntlTEI,
		data_ip     = RemoteDataIP,
		data_tei    = RemoteDataTEI},

    State1 = if Context /= OldContext ->
		     apply_context_change(Context, OldContext, State0);
		true ->
		     State0
	     end,

    {ok, NewGTPcPeer, _NewGTPuPeer} = gtp_v1_c:handle_sgsn(IEs, Context, State1),
    lager:debug("New: ~p, ~p", [NewGTPcPeer, _NewGTPuPeer]),

    #gtp_port{ip = LocalIP} = GtpPort,

    ResponseIEs = [#cause{value = request_accepted},
		   #tunnel_endpoint_identifier_data_i{tei = LocalTEI},
		   #charging_id{id = <<0,0,0,1>>},
		   #gsn_address{instance = 0, address = gtp_c_lib:ip2bin(LocalIP)},   %% for Control Plane
		   #gsn_address{instance = 1, address = gtp_c_lib:ip2bin(LocalIP)},   %% for User Traffic
		   QoSProfile
		  | gtp_v1_c:build_recovery(GtpPort, NewGTPcPeer)],
    Reply = {update_pdp_context_response, RemoteCntlTEI, ResponseIEs},
    {reply, Reply, State1};

handle_request(_SrcGtpPort,
	       #gtp{type = delete_pdp_context_request, ie = _IEs}, _Req,
	       #{context := Context} = State) ->
    #context{control_tei = RemoteCntlTEI} = Context,

    gtp_context:teardown(Context, State),

    pdp_release_ip(Context, State),
    Reply = {delete_pdp_context_response, RemoteCntlTEI, request_accepted},
    {stop, Reply, State};

handle_request(_SrcGtpPort, _Msg, _Req, State) ->
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

pdp_alloc_ip(TEI, IPv4, IPv6, #{gtp_port := GtpPort}) ->
    apn:allocate_pdp_ip(GtpPort, TEI, IPv4, IPv6).

pdp_release_ip(#context{ms_v4 = MSv4, ms_v6 = MSv6}, #{gtp_port := GtpPort}) ->
    apn:release_pdp_ip(GtpPort, MSv4, MSv6).

apply_context_change(NewContext, OldContext, State) ->
    ok = gtp_context:update(NewContext, OldContext, State),
    State#{context => NewContext}.


init_session(IEs, Session) ->
    lists:foldr(fun copy_to_session/2, Session, IEs).

%% copy_to_session(#international_mobile_subscriber_identity{imsi = IMSI}, Session) ->
%%     Id = [{'Subscription-Id-Type' , 1}, {'Subscription-Id-Data', IMSI}],
%%     Session#{'Subscription-Id' => Id};

copy_to_session(#international_mobile_subscriber_identity{imsi = IMSI}, Session) ->
    Session#{'IMSI' => IMSI};
copy_to_session(#ms_international_pstn_isdn_number{
		   msisdn = {isdn_address, _, _, 1, MSISDN}}, Session) ->
    Session#{'MSISDN' => MSISDN};
copy_to_session(#gsn_address{instance = 0, address = IP}, Session) ->
    Session#{'SGSN-Address' => gtp_c_lib:ip2bin(IP)};
copy_to_session(#rat_type{rat_type = Type}, Session) ->
    Session#{'RAT-Type' => Type};
copy_to_session(#selection_mode{mode = Mode}, Session) ->
    Session#{'Selection-Mode' => Mode};

copy_to_session(_, Session) ->
    Session.
