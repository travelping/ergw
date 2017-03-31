%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_pgw_test_lib).

-define(ERGW_PGW_NO_IMPORTS, true).

-export([make_echo_request/1,
	 create_session/1, create_session/2,
	 delete_session/2,
	 modify_bearer_tei_update/2,
	 modify_bearer_ra_update/2,
	 change_notification_with_tei/2,
	 change_notification_without_tei/2,
	 suspend_notification/2,
	 resume_notification/2]).

-include("ergw_test_lib.hrl").
-include("ergw_pgw_test_lib.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").

%%%===================================================================
%%% Execute GTPv2-C transactions
%%%===================================================================

create_session(Socket) ->
    create_session(Socket, gtp_context()).

create_session(Socket, GtpC) ->
    execute_request(Socket, GtpC,
		    fun make_create_session_request/1,
		    fun validate_create_session_response/2).

modify_bearer_tei_update(Socket, GtpC0) ->
    GtpC = gtp_context_inc_seq(gtp_context_new_teids(GtpC0)),
    Msg = make_modify_bearer_request_tei_update(GtpC),
    Response = send_recv_pdu(Socket, Msg),

    {validate_modify_bearer_response_tei_update(Response, GtpC), Msg, Response}.

modify_bearer_ra_update(Socket, GtpC) ->
    execute_request(Socket, GtpC,
		    fun make_modify_bearer_request_ra_update/1,
		    fun validate_modify_bearer_response_ra_update/2).

change_notification_with_tei(Socket, GtpC) ->
    execute_request(Socket, GtpC,
		    fun make_change_notification_request_with_tei/1,
		    fun validate_change_notification_response_with_tei/2).

change_notification_without_tei(Socket, GtpC) ->
    execute_request(Socket, GtpC,
		    fun make_change_notification_request_without_tei/1,
		    fun validate_change_notification_response_without_tei/2).

suspend_notification(Socket, GtpC) ->
    execute_request(Socket, GtpC,
		    fun make_suspend_notification/1,
		    fun validate_suspend_acknowledge/2).
resume_notification(Socket, GtpC) ->
    execute_request(Socket, GtpC,
		    fun make_resume_notification/1,
		    fun validate_resume_acknowledge/2).

delete_session(Socket, GtpC) ->
    execute_request(Socket, GtpC,
		    fun make_delete_session_request/1,
		    fun validate_delete_session_response/2).

%%%===================================================================
%%% Create GTPv2-C messages
%%%===================================================================

make_echo_request(#gtpc{restart_counter = RCnt, seq_no = SeqNo}) ->
    IEs = [#v2_recovery{restart_counter = RCnt}],
    #gtp{version = v2, type = echo_request, tei = undefined,
	 seq_no = SeqNo, ie = IEs}.

%%%-------------------------------------------------------------------

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

%%%-------------------------------------------------------------------

make_modify_bearer_request_tei_update(#gtpc{restart_counter = RCnt,
					    seq_no = SeqNo,
					    local_control_tei = LocalCntlTEI,
					    local_data_tei = LocalDataTEI,
					    remote_control_tei = RemoteCntlTEI}) ->

    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_bearer_context{
	      group = [#v2_eps_bearer_id{eps_bearer_id = 5},
		       #v2_fully_qualified_tunnel_endpoint_identifier{
			  instance = 1,
			  interface_type = ?'S5/S8-U SGW',
			  key = LocalDataTEI,
			  ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)}
		      ]},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)}
	  ],

    #gtp{version = v2, type = modify_bearer_request, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs}.

validate_modify_bearer_response_tei_update(Response,
				 #gtpc{local_control_tei =
					   LocalCntlTEI} = GtpC) ->
    ?match(
       #gtp{type = modify_bearer_response,
	    tei = LocalCntlTEI,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
		   {v2_bearer_context,0} :=
		       #v2_bearer_context{
			  group = #{
			    {v2_cause,0} := #v2_cause{v2_cause =
							  request_accepted},
			    {v2_eps_bearer_id, 0} :=
				#v2_eps_bearer_id{eps_bearer_id = 5},
			    {v2_charging_id, 0} := #v2_charging_id{}}}
		  }}, Response),
    GtpC.

%%%-------------------------------------------------------------------

make_modify_bearer_request_ra_update(#gtpc{restart_counter = RCnt,
					   seq_no = SeqNo,
					   local_control_tei = LocalCntlTEI,
					   remote_control_tei = RemoteCntlTEI}) ->

    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_ue_time_zone{timezone = 10, dst = 0},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)}
	  ],

    #gtp{version = v2, type = modify_bearer_request, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs}.

validate_modify_bearer_response_ra_update(Response,
					  #gtpc{local_control_tei =
						    LocalCntlTEI} = GtpC) ->
    ?match(
       #gtp{type = modify_bearer_response,
	    tei = LocalCntlTEI,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	   }, Response),
    #gtp{ie = IEs} = Response,
    ?equal(false, maps:is_key({v2_bearer_context,0}, IEs)),
    GtpC.

%%%-------------------------------------------------------------------

make_change_notification_request_with_tei(#gtpc{restart_counter = RCnt,
						seq_no = SeqNo,
						remote_control_tei =
						    RemoteCntlTEI}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_rat_type{rat_type = 6},
	   #v2_ue_time_zone{timezone = 10, dst = 0},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}
	  ],

    #gtp{version = v2, type = change_notification_request, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs}.

validate_change_notification_response_with_tei(Response,
					       #gtpc{
						  local_control_tei =
						      LocalCntlTEI} = GtpC) ->
    ?match(
       #gtp{type = change_notification_response,
	    tei = LocalCntlTEI,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	   }, Response),
    #gtp{ie = IEs} = Response,
    ?equal(false, maps:is_key({v2_international_mobile_subscriber_identity,0}, IEs)),
    ?equal(false, maps:is_key({v2_mobile_equipment_identity,0}, IEs)),
    GtpC.

%%%-------------------------------------------------------------------

make_change_notification_request_without_tei(#gtpc{restart_counter = RCnt,
						   seq_no = SeqNo}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_rat_type{rat_type = 6},
	   #v2_international_mobile_subscriber_identity{
	      imsi = ?'IMSI'},
	   #v2_mobile_equipment_identity{mei = <<"AAAAAAAA">>},
	   #v2_ue_time_zone{timezone = 10, dst = 0},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}
	  ],

    #gtp{version = v2, type = change_notification_request, tei = 0,
	 seq_no = SeqNo, ie = IEs}.

validate_change_notification_response_without_tei(Response, GtpC) ->
    ?match(
       #gtp{type = change_notification_response,
	    ie = #{{v2_cause,0} :=
		       #v2_cause{v2_cause = request_accepted},
		   {v2_international_mobile_subscriber_identity,0} :=
		       #v2_international_mobile_subscriber_identity{},
		   {v2_mobile_equipment_identity,0} :=
		       #v2_mobile_equipment_identity{}
		  }
	   }, Response),
    GtpC.

%%%-------------------------------------------------------------------

make_suspend_notification(#gtpc{restart_counter = RCnt,
				seq_no = SeqNo,
				remote_control_tei =
				    RemoteCntlTEI}) ->
    IEs = [#v2_recovery{restart_counter = RCnt}],

    #gtp{version = v2, type = suspend_notification, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs}.

validate_suspend_acknowledge(Response,
			     #gtpc{
				local_control_tei =
				    LocalCntlTEI} = GtpC) ->
    ?match(
       #gtp{type = suspend_acknowledge,
	    tei = LocalCntlTEI,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	   }, Response),
    GtpC.

%%%-------------------------------------------------------------------

make_resume_notification(#gtpc{restart_counter = RCnt,
			       seq_no = SeqNo,
			       remote_control_tei =
				   RemoteCntlTEI}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_international_mobile_subscriber_identity{
	      imsi = ?'IMSI'}],

    #gtp{version = v2, type = resume_notification, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs}.

validate_resume_acknowledge(Response,
			    #gtpc{
			       local_control_tei =
				   LocalCntlTEI} = GtpC) ->
    ?match(
       #gtp{type = resume_acknowledge,
	    tei = LocalCntlTEI,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	   }, Response),
    GtpC.

%%%-------------------------------------------------------------------

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

%%%===================================================================
%%% Helper functions
%%%===================================================================

execute_request(Socket, GtpC0, Make, Validate) ->
    GtpC = gtp_context_inc_seq(GtpC0),
    Msg = Make(GtpC),
    Response = send_recv_pdu(Socket, Msg),

    {Validate(Response, GtpC), Msg, Response}.
