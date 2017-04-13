%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_pgw_test_lib).

-define(ERGW_PGW_NO_IMPORTS, true).

-export([make_request/3, make_response/3,
	 create_session/1, create_session/2, create_session/3,
	 delete_session/2, delete_session/3,
	 modify_bearer/3,
	 modify_bearer_command/3,
	 change_notification/3,
	 suspend_notification/3,
	 resume_notification/3]).

-include("ergw_test_lib.hrl").
-include("ergw_pgw_test_lib.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").

%%%===================================================================
%%% Execute GTPv2-C transactions
%%%===================================================================

create_session(Socket) ->
    create_session(simple, Socket, gtp_context()).

create_session(Socket, #gtpc{} = GtpC) ->
    execute_request(create_session_request, simple, Socket, GtpC);
create_session(SubType, Socket) ->
    create_session(SubType, Socket, gtp_context()).

create_session(SubType, Socket, GtpC) ->
    execute_request(create_session_request, SubType, Socket, GtpC).

modify_bearer(SubType, Socket, GtpC0)
  when SubType == tei_update ->
    GtpC = gtp_context_new_teids(GtpC0),
    execute_request(modify_bearer_request, SubType, Socket, GtpC);
modify_bearer(SubType, Socket, GtpC) ->
    execute_request(modify_bearer_request, SubType, Socket, GtpC).

modify_bearer_command(SubType, Socket, GtpC) ->
    execute_command(modify_bearer_command, SubType, Socket, GtpC).

change_notification(SubType, Socket, GtpC) ->
    execute_request(change_notification_request, SubType, Socket, GtpC).

suspend_notification(SubType, Socket, GtpC) ->
    execute_request(suspend_notification, SubType, Socket, GtpC).

resume_notification(SubType, Socket, GtpC) ->
    execute_request(resume_notification, SubType, Socket, GtpC).

delete_session(Socket, GtpC) ->
    execute_request(delete_session_request, simple, Socket, GtpC).

delete_session(SubType, Socket, GtpC) ->
    execute_request(delete_session_request, SubType, Socket, GtpC).

%%%===================================================================
%%% Create GTPv2-C messages
%%%===================================================================

make_pdn_type(ipv6, IEs) ->
    PrefixLen = 64,
    Prefix = gtp_c_lib:ip2bin({0,0,0,0,0,0,0,0}),
    [#v2_pdn_address_allocation{
	type = ipv6,
	address = <<PrefixLen, Prefix/binary>>},
     #v2_pdn_type{pdn_type = ipv6},
     #v2_protocol_configuration_options{
	config = {0, [{1,<<>>}, {3,<<>>}, {10,<<>>}]}}
     | IEs];
make_pdn_type(ipv4v6, IEs) ->
    PrefixLen = 64,
    Prefix = gtp_c_lib:ip2bin({0,0,0,0,0,0,0,0}),
    RequestedIP = gtp_c_lib:ip2bin({0,0,0,0}),
    [#v2_pdn_address_allocation{
	type = ipv4v6,
	address = <<PrefixLen, Prefix/binary, RequestedIP/binary>>},
     #v2_pdn_type{pdn_type = ipv4v6},
     #v2_protocol_configuration_options{
	config = {0, [{ipcp,'CP-Configure-Request',0,
		       [{ms_dns1, <<0,0,0,0>>},
			{ms_dns2, <<0,0,0,0>>}]},
		      {13,<<>>},{10,<<>>},{5,<<>>},
		      {1,<<>>}, {3,<<>>}, {10,<<>>}]}}
     | IEs];
make_pdn_type(_, IEs) ->
    RequestedIP = gtp_c_lib:ip2bin({0,0,0,0}),
    [#v2_pdn_address_allocation{type = ipv4,
				address = RequestedIP},
     #v2_pdn_type{pdn_type = ipv4},
     #v2_protocol_configuration_options{
	config = {0, [{ipcp,'CP-Configure-Request',0,
		       [{ms_dns1, <<0,0,0,0>>},
			{ms_dns2, <<0,0,0,0>>}]},
		      {13,<<>>},{10,<<>>},{5,<<>>}]}}
     | IEs].
%%%-------------------------------------------------------------------

make_request(Type, invalid_teid, GtpC) ->
    Msg = make_request(Type, simple, GtpC),
    Msg#gtp{tei = 16#7fffffff};

make_request(echo_request, _SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo}) ->
    IEs = [#v2_recovery{restart_counter = RCnt}],
    #gtp{version = v2, type = echo_request, tei = undefined,
	 seq_no = SeqNo, ie = IEs};

make_request(create_session_request, missing_ie,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo}) ->
    IEs = [#v2_recovery{restart_counter = RCnt}],
    #gtp{version = v2, type = create_session_request, tei = 0,
	 seq_no = SeqNo, ie = IEs};

make_request(create_session_request, SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_control_tei = LocalCntlTEI,
		   local_data_tei = LocalDataTEI}) ->
    IEs0 =
	[#v2_recovery{restart_counter = RCnt},
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
			ipv4 = gtp_c_lib:ip2bin(?CLIENT_IP)}
		    ]},
	 #v2_fully_qualified_tunnel_endpoint_identifier{
	    interface_type = ?'S5/S8-C SGW',
	    key = LocalCntlTEI,
	    ipv4 = gtp_c_lib:ip2bin(?CLIENT_IP)},
	 #v2_international_mobile_subscriber_identity{
	    imsi = ?'IMSI'},
	 #v2_mobile_equipment_identity{mei = <<"AAAAAAAA">>},
	 #v2_msisdn{msisdn = ?'MSISDN'},
	 #v2_rat_type{rat_type = 6},
	 #v2_selection_mode{mode = 0},
	 #v2_serving_network{mcc = <<"001">>, mnc = <<"001">>},
	 #v2_ue_time_zone{timezone = 10, dst = 0},
	 #v2_user_location_information{tai = <<3,2,22,214,217>>,
				       ecgi = <<3,2,22,8,71,9,92>>}],
    IEs = make_pdn_type(SubType, IEs0),
    #gtp{version = v2, type = create_session_request, tei = 0,
	 seq_no = SeqNo, ie = IEs};

make_request(modify_bearer_request, tei_update,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
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
			  ipv4 = gtp_c_lib:ip2bin(?CLIENT_IP)}
		      ]},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?CLIENT_IP)}
	  ],

    #gtp{version = v2, type = modify_bearer_request, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs};

make_request(modify_bearer_request, SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_control_tei = LocalCntlTEI,
		   remote_control_tei = RemoteCntlTEI})
  when SubType == simple; SubType == ra_update ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_ue_time_zone{timezone = 10, dst = 0},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?CLIENT_IP)}
	  ],

    #gtp{version = v2, type = modify_bearer_request, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs};

make_request(modify_bearer_command, SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_control_tei = LocalCntlTEI,
		   remote_control_tei = RemoteCntlTEI})
  when SubType == simple; SubType == ra_update ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_aggregate_maximum_bit_rate{},
	   #v2_bearer_context{
	      group = [#v2_eps_bearer_id{eps_bearer_id = 5},
		       #v2_bearer_level_quality_of_service{}
		      ]},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?CLIENT_IP)}
	  ],
    #gtp{version = v2, type = modify_bearer_command, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs};

make_request(change_notification_request, simple,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_rat_type{rat_type = 6},
	   #v2_ue_time_zone{timezone = 10, dst = 0},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}
	  ],

    #gtp{version = v2, type = change_notification_request, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs};

make_request(suspend_notification, _SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#v2_recovery{restart_counter = RCnt}],

    #gtp{version = v2, type = suspend_notification, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs};

make_request(resume_notification, _SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_international_mobile_subscriber_identity{
	      imsi = ?'IMSI'}],

    #gtp{version = v2, type = resume_notification, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs};

make_request(change_notification_request, without_tei,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo}) ->
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
	 seq_no = SeqNo, ie = IEs};

make_request(change_notification_request, invalid_imsi, GtpC) ->
    #gtp{ie = IEs} = Msg =
	make_request(change_notification_request, without_tei, GtpC),
    Msg#gtp{ie = lists:keystore(v2_international_mobile_subscriber_identity,
				1, IEs,
				#v2_international_mobile_subscriber_identity{
				   imsi = <<"991111111111111">>})};

make_request(delete_session_request, _SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_control_tei = LocalCntlTEI,
		   remote_control_tei = RemoteCntlTEI}) ->
    IEs = [%%{170,0} => {170,0,<<220,126,139,67>>},
	   #v2_recovery{restart_counter = RCnt},
	   #v2_eps_bearer_id{eps_bearer_id = 5},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?CLIENT_IP)},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}],

    #gtp{version = v2, type = delete_session_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs}.

%%%-------------------------------------------------------------------

make_response(#gtp{type = create_session_request, seq_no = SeqNo},
	      _SubType,
	      #gtpc{restart_counter = RCnt,
		    local_control_tei = LocalCntlTEI,
		    local_data_tei = LocalDataTEI,
		    remote_control_tei = RemoteCntlTEI}) ->
    IEs = #{{v2_cause,0} => #v2_cause{v2_cause = request_accepted},
	    {v2_apn_restriction, 0} =>
		#v2_apn_restriction{restriction_type_value = 0},
	    {v2_bearer_context, 0} =>
		#v2_bearer_context{
		   group =
		       #{{v2_cause, 0} =>
			     #v2_cause{v2_cause = request_accepted},
			 {v2_charging_id, 0} =>
			     #v2_charging_id{id = <<0,0,0,1>>},
			 {v2_bearer_level_quality_of_service, 0} =>
			     #v2_bearer_level_quality_of_service{
				pci = 1, pl = 10, pvi = 0, label = 8,
				maximum_bit_rate_for_uplink      = 0,
				maximum_bit_rate_for_downlink    = 0,
				guaranteed_bit_rate_for_uplink   = 0,
				guaranteed_bit_rate_for_downlink = 0},
			 {v2_eps_bearer_id, 0} =>
			     #v2_eps_bearer_id{eps_bearer_id = 5},
			 {v2_fully_qualified_tunnel_endpoint_identifier, 2} =>
			     #v2_fully_qualified_tunnel_endpoint_identifier{
				instance = 2,
				interface_type = ?'S5/S8-U PGW',
				key = LocalDataTEI,
				ipv4 = gtp_c_lib:ip2bin(?TEST_GSN)}
			}},
	    {v2_fully_qualified_tunnel_endpoint_identifier, 1} =>
		#v2_fully_qualified_tunnel_endpoint_identifier{
		   instance = 1,
		   interface_type = ?'S5/S8-C PGW',
		   key = LocalCntlTEI,
		   ipv4 = gtp_c_lib:ip2bin(?TEST_GSN)},
	    {v2_pdn_address_allocation, 0} =>
		#v2_pdn_address_allocation{
		   type = ipv4,
		   address = gtp_c_lib:ip2bin(?LOCALHOST)},
	    {v2_protocol_configuration_options, 0} =>
		#v2_protocol_configuration_options{
		   config = {0, [{ipcp,'CP-Configure-Nak',0,
				  [{ms_dns1, gtp_c_lib:ip2bin({8,8,8,8})},
				   {ms_dns2, gtp_c_lib:ip2bin({8,8,4,4})}]},
				 {13, gtp_c_lib:ip2bin({8,8,4,4})},
				 {13, gtp_c_lib:ip2bin({8,8,8,8})}]}},
	    {v2_recovery, 0} => #v2_recovery{restart_counter = RCnt}},
    #gtp{version = v2, type = create_session_response,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs};

make_response(#gtp{type = delete_bearer_request, seq_no = SeqNo},
	      _SubType,
	      #gtpc{restart_counter = RCnt,
		    remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_cause{v2_cause = request_accepted}],
    #gtp{version = v2, type = delete_bearer_response,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs}.

%%%-------------------------------------------------------------------

validate_response(_Type, invalid_teid, Response, GtpC) ->
    ?match(
       #gtp{ie = #{{v2_cause,0} := #v2_cause{v2_cause = context_not_found}}
	   }, Response),
    GtpC;

validate_response(create_session_request, missing_ie, Response, GtpC) ->
   ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = mandatory_ie_missing}}},
	  Response),
    GtpC;

validate_response(create_session_request, _SubType, Response,
		  #gtpc{local_control_tei = LocalCntlTEI} = GtpC) ->
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
     };

validate_response(modify_bearer_request, tei_update, Response,
		  #gtpc{local_control_tei = LocalCntlTEI} = GtpC) ->
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
    GtpC;

validate_response(modify_bearer_request, SubType, Response,
		  #gtpc{local_control_tei = LocalCntlTEI} = GtpC)
  when SubType == simple; SubType == ra_update ->
    ?match(
       #gtp{type = modify_bearer_response,
	    tei = LocalCntlTEI,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	   }, Response),
    #gtp{ie = IEs} = Response,
    ?equal(false, maps:is_key({v2_bearer_context,0}, IEs)),
    GtpC;

validate_response(change_notification_request, simple, Response,
		  #gtpc{local_control_tei = LocalCntlTEI} = GtpC) ->
    ?match(
       #gtp{type = change_notification_response,
	    tei = LocalCntlTEI,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	   }, Response),
    #gtp{ie = IEs} = Response,
    ?equal(false, maps:is_key({v2_international_mobile_subscriber_identity,0}, IEs)),
    ?equal(false, maps:is_key({v2_mobile_equipment_identity,0}, IEs)),
    GtpC;

validate_response(change_notification_request, without_tei, Response, GtpC) ->
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
    GtpC;

validate_response(change_notification_request, invalid_imsi, Response, GtpC) ->
    ?match(
       #gtp{ie = #{{v2_cause,0} := #v2_cause{v2_cause = context_not_found}}
	   }, Response),
    GtpC;

validate_response(suspend_notification, _SubType, Response,
		  #gtpc{local_control_tei = LocalCntlTEI} = GtpC) ->
    ?match(
       #gtp{type = suspend_acknowledge,
	    tei = LocalCntlTEI,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	   }, Response),
    GtpC;

validate_response(resume_notification, _SubType, Response,
		  #gtpc{local_control_tei = LocalCntlTEI} = GtpC) ->
    ?match(
       #gtp{type = resume_acknowledge,
	    tei = LocalCntlTEI,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	   }, Response),
    GtpC;

validate_response(delete_session_request, _SubType, Response,
		  #gtpc{local_control_tei = LocalCntlTEI} = GtpC) ->
    ?match(#gtp{type = delete_session_response,
		tei = LocalCntlTEI,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	       }, Response),
    GtpC.

%%%===================================================================
%%% Helper functions
%%%===================================================================

execute_command(MsgType, SubType, Socket, GtpC)
  when SubType == invalid_teid ->
    execute_request(MsgType, SubType, Socket, GtpC);
execute_command(MsgType, SubType, Socket, GtpC0) ->
    GtpC = gtp_context_inc_seq(GtpC0),
    Msg = make_request(MsgType, SubType, GtpC),
    send_pdu(Socket, Msg),

    {GtpC, Msg}.

execute_request(MsgType, SubType, Socket, GtpC0) ->
    GtpC = gtp_context_inc_seq(GtpC0),
    Msg = make_request(MsgType, SubType, GtpC),
    Response = send_recv_pdu(Socket, Msg),

    {validate_response(MsgType, SubType, Response, GtpC), Msg, Response}.
