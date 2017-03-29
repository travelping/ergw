%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_pgw_test_lib).

-define(ERGW_PGW_NO_IMPORTS, true).

-export([make_echo_request/1,
	 create_session/1, create_session/2,
	 make_create_session_request/1,
	 validate_create_session_response/2,
	 delete_session/2,
	 make_delete_session_request/1,
	 validate_delete_session_response/2]).

-include("ergw_test_lib.hrl").
-include("ergw_pgw_test_lib.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").

%%%===================================================================
%%% Create GTPv2-C messages
%%%===================================================================

make_echo_request(#gtpc{restart_counter = RCnt, seq_no = SeqNo}) ->
    IEs = [#v2_recovery{restart_counter = RCnt}],
    #gtp{version = v2, type = echo_request, tei = undefined,
	 seq_no = SeqNo, ie = IEs}.

create_session(Socket) ->
    create_session(Socket, gtp_context()).

create_session(Socket, GtpC0) ->
    GtpC = gtp_context_inc_seq(GtpC0),
    Msg = make_create_session_request(GtpC),
    Response = send_recv_pdu(Socket, Msg),

    {validate_create_session_response(Response, GtpC), Msg, Response}.

make_create_session_request(#gtpc{restart_counter = RCnt,
				  seq_no = SeqNo,
				  local_control_tei = LocalCntlTEI,
				  local_data_tei = LocalDataTEI}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_access_point_name{apn = ?'APN-EXAMPLE'},
	   #v2_aggregate_maximum_bit_rate{uplink = 48128, downlink = 1704125},
	   #v2_apn_restriction{restriction_type_value = 0},
	   #v2_bearer_context{
	      group = [#v2_bearer_level_quality_of_service{
			  pci = 1, pl = 10, pvi = 0, label = 8,
			  maximum_bit_rate_for_uplink      = 0,
			  maximum_bit_rate_for_downlink    = 0,
			  guaranteed_bit_rate_for_uplink   = 0,
			  guaranteed_bit_rate_for_downlink = 0},
		       #v2_eps_bearer_id{eps_bearer_id = 5},
		       #v2_fully_qualified_tunnel_endpoint_identifier{
			  instance = 2,
			  interface_type = ?'S5/S8-U SGW',
			  key = LocalDataTEI,
			  ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)}
		      ]},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)},
	   #v2_international_mobile_subscriber_identity{
	      imsi = ?'IMSI'},
	   #v2_mobile_equipment_identity{mei = <<"AAAAAAAA">>},
	   #v2_msisdn{msisdn = ?'MSISDN'},
	   #v2_pdn_address_allocation{type = ipv4,
				      address = <<0,0,0,0>>},
	   #v2_pdn_type{pdn_type = ipv4},
	   #v2_protocol_configuration_options{
	      config = {0, [{ipcp,'CP-Configure-Request',0,
			     [{ms_dns1,<<0,0,0,0>>},
			      {ms_dns2,<<0,0,0,0>>}]},
			    {13,<<>>},{10,<<>>},{5,<<>>}]}},
	   #v2_rat_type{rat_type = 6},
	   #v2_selection_mode{mode = 0},
	   #v2_serving_network{mcc = <<"001">>, mnc = <<"001">>},
	   #v2_ue_time_zone{timezone = 10, dst = 0},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}],

    #gtp{version = v2, type = create_session_request, tei = 0,
	 seq_no = SeqNo, ie = IEs}.

validate_create_session_response(Response,
				 #gtpc{local_control_tei
				       = LocalCntlTEI} = GtpC) ->
    ?match(
       #gtp{type = create_session_response,
	    tei = LocalCntlTEI,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
		   {v2_fully_qualified_tunnel_endpoint_identifier,1} :=
		       #v2_fully_qualified_tunnel_endpoint_identifier{
			  interface_type = ?'S5/S8-C PGW'},
		   {v2_bearer_context,0} :=
		       #v2_bearer_context{
			  group = #{
			    {v2_cause,0} := #v2_cause{v2_cause =
							  request_accepted},
			    {v2_fully_qualified_tunnel_endpoint_identifier,2} :=
				#v2_fully_qualified_tunnel_endpoint_identifier{
				   interface_type = ?'S5/S8-U PGW'}}}
		  }}, Response),

    #gtp{ie = #{{v2_fully_qualified_tunnel_endpoint_identifier,1} :=
		    #v2_fully_qualified_tunnel_endpoint_identifier{
		       key = RemoteCntlTEI},
		{v2_bearer_context,0} :=
		    #v2_bearer_context{
		       group = #{
			 {v2_fully_qualified_tunnel_endpoint_identifier,2} :=
			     #v2_fully_qualified_tunnel_endpoint_identifier{
				key = RemoteDataTEI}}}
	       }} = Response,

    GtpC#gtpc{
	  remote_control_tei = RemoteCntlTEI,
	  remote_data_tei = RemoteDataTEI
     }.

delete_session(Socket, GtpC0) ->
    GtpC = gtp_context_inc_seq(GtpC0),
    Msg = make_delete_session_request(GtpC),
    Response = send_recv_pdu(Socket, Msg),

    {validate_delete_session_response(Response, GtpC), Msg, Response}.

make_delete_session_request(#gtpc{restart_counter = RCnt,
				  seq_no = SeqNo,
				  local_control_tei = LocalCntlTEI,
				  remote_control_tei = RemoteCntlTEI}) ->
    IEs = [%%{170,0} => {170,0,<<220,126,139,67>>},
	   #v2_recovery{restart_counter = RCnt},
	   #v2_eps_bearer_id{eps_bearer_id = 5},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}],

    #gtp{version = v2, type = delete_session_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs}.

validate_delete_session_response(Response,
				 #gtpc{local_control_tei =
					   LocalCntlTEI} = GtpC) ->
    ?match(#gtp{type = delete_session_response,
		tei = LocalCntlTEI,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	       }, Response),
    GtpC.
