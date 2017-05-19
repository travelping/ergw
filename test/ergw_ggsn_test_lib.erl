%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_ggsn_test_lib).

-define(ERGW_GGSN_NO_IMPORTS, true).

-export([make_request/3, make_response/3,
	 create_pdp_context/1, create_pdp_context/2, create_pdp_context/3,
	 update_pdp_context/3,
	 ms_info_change_notification/3,
	 delete_pdp_context/2, delete_pdp_context/3]).
-export([ggsn_update_context/2]).

-include("ergw_test_lib.hrl").
-include("ergw_ggsn_test_lib.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("../include/ergw.hrl").

%%%===================================================================
%%% Execute GTPv1-C transactions
%%%===================================================================

create_pdp_context(Socket) ->
    create_pdp_context(Socket, gtp_context()).

create_pdp_context(Socket, #gtpc{} = GtpC) ->
    execute_request(create_pdp_context_request, simple, Socket, GtpC);
create_pdp_context(SubType, Socket) ->
    create_pdp_context(SubType, Socket, gtp_context()).

create_pdp_context(SubType, Socket, GtpC) ->
    execute_request(create_pdp_context_request, SubType, Socket, GtpC).

update_pdp_context(SubType, Socket, GtpC0)
  when SubType == tei_update ->
    GtpC = gtp_context_new_teids(GtpC0),
    execute_request(update_pdp_context_request, SubType, Socket, GtpC);
update_pdp_context(SubType, Socket, GtpC) ->
    execute_request(update_pdp_context_request, SubType, Socket, GtpC).

ms_info_change_notification(SubType, Socket, GtpC) ->
    execute_request(ms_info_change_notification_request, SubType, Socket, GtpC).

delete_pdp_context(Socket, GtpC) ->
    execute_request(delete_pdp_context_request, simple, Socket, GtpC).

delete_pdp_context(SubType, Socket, GtpC) ->
    execute_request(delete_pdp_context_request, SubType, Socket, GtpC).

%%%===================================================================
%%% Create GTPv1-C messages
%%%===================================================================

make_pdp_type(ipv6, IEs) ->
    [#end_user_address{pdp_type_organization = 1,
		       pdp_type_number = 16#57,
		       pdp_address = <<>>},
     #protocol_configuration_options{
	config = {0, [{1,<<>>}, {3,<<>>}, {10,<<>>}]}}
     | IEs];
make_pdp_type(ipv4v6, IEs) ->
    [#end_user_address{pdp_type_organization = 1,
		       pdp_type_number = 16#8d,
		       pdp_address = <<>>},
     #protocol_configuration_options{
	config = {0, [{ipcp,'CP-Configure-Request',1,
		       [{ms_dns1,<<0,0,0,0>>},
			{ms_dns2,<<0,0,0,0>>}]},
		      {1,<<>>}, {3,<<>>}, {10,<<>>}, {13,<<>>}]}}
     | IEs];
make_pdp_type(_, IEs) ->
    [#end_user_address{pdp_type_organization = 1,
		       pdp_type_number = 16#21,
		       pdp_address = <<>>},
     #protocol_configuration_options{
	config = {0, [{ipcp,'CP-Configure-Request',1,
		       [{ms_dns1,<<0,0,0,0>>},
			{ms_dns2,<<0,0,0,0>>}]},
		      {13,<<>>}]}}
     | IEs].

validate_pdp_type(ipv6, IEs) ->
     ?match(#{{end_user_address,0} :=
		 #end_user_address{pdp_type_organization = 1,
				   pdp_type_number = 87}}, IEs);
validate_pdp_type(ipv4v6, IEs) ->
     ?match(#{{end_user_address,0} :=
		 #end_user_address{pdp_type_organization = 1,
				   pdp_type_number = 141},
	      {protocol_configuration_options,0} :=
		  #protocol_configuration_options{
		     config = {0,[{ipcp,'CP-Configure-Nak',1,
				   [{ms_dns1,_},
				    {ms_dns2,_}]},
				  {13, _},
				  {13, _}]}}}, IEs);
validate_pdp_type(_, IEs) ->
    ?match(#{{end_user_address,0} :=
		 #end_user_address{pdp_type_organization = 1,
				   pdp_type_number = 33},
	     {protocol_configuration_options,0} :=
		 #protocol_configuration_options{
		    config = {0,[{ipcp,'CP-Configure-Nak',1,
				  [{ms_dns1,_},
				   {ms_dns2,_}]},
				 {13, _},
				 {13, _}]}}}, IEs).

%%%-------------------------------------------------------------------

make_request(Type, invalid_teid, GtpC) ->
    Msg = make_request(Type, simple, GtpC),
    Msg#gtp{tei = 16#7fffffff};

make_request(echo_request, _SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo}) ->
    IEs = [#recovery{restart_counter = RCnt}],
    #gtp{version = v1, type = echo_request, tei = 0, seq_no = SeqNo, ie = IEs};

make_request(create_pdp_context_request, missing_ie,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo}) ->
    IEs = [#recovery{restart_counter = RCnt}],
    #gtp{version = v1, type = create_pdp_context_request, tei = 0,
	 seq_no = SeqNo, ie = IEs};

make_request(create_pdp_context_request, SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_control_tei = LocalCntlTEI,
		   local_data_tei = LocalDataTEI}) ->
    APN = case SubType of
	      invalid_apn -> [<<"IN", "VA", "LID">>];
	      _           -> ?'APN-EXAMPLE'
	  end,
    IEs0 =
	[#recovery{restart_counter = RCnt},
	 #access_point_name{apn = APN},
	 #gsn_address{instance = 0, address = gtp_c_lib:ip2bin(?CLIENT_IP)},
	 #gsn_address{instance = 1, address = gtp_c_lib:ip2bin(?CLIENT_IP)},
	 #imei{imei = <<"1234567890123456">>},
	 #international_mobile_subscriber_identity{imsi = ?IMSI},
	 #ms_international_pstn_isdn_number{
	    msisdn = {isdn_address,1,1,1, ?'MSISDN'}},
	 #nsapi{nsapi = 5},
	 #quality_of_service_profile{
	    priority = 2,
	    data = <<19,146,31,113,150,254,254,116,250,255,255,0,142,0>>},
	 #rat_type{rat_type = 1},
	 #selection_mode{mode = 0},
	 #tunnel_endpoint_identifier_control_plane{tei = LocalCntlTEI},
	 #tunnel_endpoint_identifier_data_i{tei = LocalDataTEI},
	 #user_location_information{type = 1,
				    mcc = <<"001">>,
				    mnc = <<"001">>,
				    lac = 11,
				    ci  = 0,
				    sac = 20263,
				    rac = 0}],
    IEs = make_pdp_type(SubType, IEs0),

    #gtp{version = v1, type = create_pdp_context_request, tei = 0,
	 seq_no = SeqNo, ie = IEs};

make_request(update_pdp_context_request, _SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_control_tei = LocalCntlTEI,
		   local_data_tei = LocalDataTEI,
		   remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#recovery{restart_counter = RCnt},
	   #gsn_address{instance = 0, address = gtp_c_lib:ip2bin(?CLIENT_IP)},
	   #gsn_address{instance = 1, address = gtp_c_lib:ip2bin(?CLIENT_IP)},
	   #international_mobile_subscriber_identity{imsi = ?IMSI},
	   #nsapi{nsapi = 5},
	   #quality_of_service_profile{
	      priority = 2,
	      data = <<19,146,31,113,150,254,254,116,250,255,255,0,142,0>>},
	   #rat_type{rat_type = 1},
	   #tunnel_endpoint_identifier_control_plane{tei = LocalCntlTEI},
	   #tunnel_endpoint_identifier_data_i{tei = LocalDataTEI},
	   #user_location_information{type = 1,
				      mcc = <<"001">>,
				      mnc = <<"001">>,
				      lac = 11,
				      ci  = 0,
				      sac = 20263,
				      rac = 0}],

    #gtp{version = v1, type = update_pdp_context_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs};

make_request(ms_info_change_notification_request, without_tei,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo}) ->
    IEs = [#recovery{restart_counter = RCnt},
	   #rat_type{rat_type = 1},
	   #imei{imei = <<"1234567890123456">>},
	   #international_mobile_subscriber_identity{imsi = ?IMSI},
	   #user_location_information{type = 1,
				      mcc = <<"001">>,
				      mnc = <<"001">>,
				      lac = 11,
				      ci  = 0,
				      sac = 20263,
				      rac = 0}
	  ],

    #gtp{version = v1, type = ms_info_change_notification_request, tei = 0,
	 seq_no = SeqNo, ie = IEs};

make_request(ms_info_change_notification_request, invalid_imsi,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo}) ->
    IEs = [#recovery{restart_counter = RCnt},
	   #rat_type{rat_type = 1},
	   #international_mobile_subscriber_identity{
	      imsi = <<"991111111111111">>},
	   #user_location_information{type = 1,
				      mcc = <<"001">>,
				      mnc = <<"001">>,
				      lac = 11,
				      ci  = 0,
				      sac = 20263,
				      rac = 0}
	  ],

    #gtp{version = v1, type = ms_info_change_notification_request, tei = 0,
	 seq_no = SeqNo, ie = IEs};

make_request(ms_info_change_notification_request, _SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#recovery{restart_counter = RCnt},
	   #rat_type{rat_type = 1},
	   #user_location_information{type = 1,
				      mcc = <<"001">>,
				      mnc = <<"001">>,
				      lac = 11,
				      ci  = 0,
				      sac = 20263,
				      rac = 0}
	  ],

    #gtp{version = v1, type = ms_info_change_notification_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs};

make_request(delete_pdp_context_request, _SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#recovery{restart_counter = RCnt},
	   #nsapi{nsapi=5},
	   #teardown_ind{value=1}],

    #gtp{version = v1, type = delete_pdp_context_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs}.

%%%-------------------------------------------------------------------

make_response(#gtp{type = update_pdp_context_request, seq_no = SeqNo},
	      _SubType,
	      #gtpc{restart_counter = RCnt,
		    remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#recovery{restart_counter = RCnt},
	   #cause{value = request_accepted}],
    #gtp{version = v1, type = update_pdp_context_response,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs};

make_response(#gtp{type = delete_pdp_context_request, seq_no = SeqNo},
	      _SubType,
	      #gtpc{restart_counter = RCnt,
		    remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#recovery{restart_counter = RCnt},
	   #cause{value = request_accepted}],
    #gtp{version = v1, type = delete_pdp_context_response,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs}.

%%%-------------------------------------------------------------------

validate_response(_Type, invalid_teid, Response, GtpC) ->
    ?match(
       #gtp{ie = #{{cause,0} := #cause{value = non_existent}}
	   }, Response),
    GtpC;

validate_response(create_pdp_context_request, aaa_reject, Response, GtpC) ->
    ?match(#gtp{type = create_pdp_context_response,
		ie = #{{cause,0} := #cause{value = user_authentication_failed}}},
	   Response),
    GtpC;

validate_response(create_pdp_context_request, overload, Response, GtpC) ->
    ?match(#gtp{type = create_pdp_context_response,
		ie = #{{cause,0} := #cause{value = no_resources_available}}},
	   Response),
    GtpC;

validate_response(create_pdp_context_request, invalid_apn, Response, GtpC) ->
    ?match(#gtp{type = create_pdp_context_response,
		ie = #{{cause,0} := #cause{value = missing_or_unknown_apn}}},
	   Response),
    GtpC;

validate_response(create_pdp_context_request, missing_ie, Response, GtpC) ->
    ?match(#gtp{type = create_pdp_context_response,
		ie = #{{cause,0} := #cause{value = mandatory_ie_missing}}},
	   Response),
    GtpC;

validate_response(create_pdp_context_request, invalid_mapping, Response, GtpC) ->
    ?match(#gtp{type = create_pdp_context_response,
		ie = #{{cause,0} := #cause{value = user_authentication_failed}}},
	   Response),
    GtpC;

validate_response(create_pdp_context_request, version_restricted, Response, GtpC) ->
    ?match(#gtp{type = version_not_supported}, Response),
    GtpC;

validate_response(create_pdp_context_request, SubType, Response,
		  #gtpc{local_control_tei = LocalCntlTEI} = GtpC) ->
    ?match(#gtp{type = create_pdp_context_response,
		tei = LocalCntlTEI,
		ie = #{{cause,0} := #cause{value = request_accepted},
		       {charging_id,0} := #charging_id{},
		       {gsn_address,0} := #gsn_address{},
		       {gsn_address,1} := #gsn_address{},
		       {quality_of_service_profile,0} :=
			   #quality_of_service_profile{priority = 2},
		       {reordering_required,0} :=
			   #reordering_required{required = no},
		       {tunnel_endpoint_identifier_control_plane,0} :=
			   #tunnel_endpoint_identifier_control_plane{},
		       {tunnel_endpoint_identifier_data_i,0} :=
			   #tunnel_endpoint_identifier_data_i{}
		      }}, Response),
    validate_pdp_type(SubType, Response#gtp.ie),

    #gtp{ie = #{{tunnel_endpoint_identifier_control_plane,0} :=
		    #tunnel_endpoint_identifier_control_plane{
		       tei = RemoteCntlTEI},
		{tunnel_endpoint_identifier_data_i,0} :=
		    #tunnel_endpoint_identifier_data_i{
		      tei = RemoteDataTEI}
	       }} = Response,

    GtpC#gtpc{
	  remote_control_tei = RemoteCntlTEI,
	  remote_data_tei = RemoteDataTEI
     };

validate_response(update_pdp_context_request, _SubType, Response,
		  #gtpc{local_control_tei = LocalCntlTEI} = GtpC) ->
    ?match(#gtp{type = update_pdp_context_response,
		tei = LocalCntlTEI,
		ie = #{{cause,0} := #cause{value = request_accepted},
		       {charging_id,0} := #charging_id{},
		       {gsn_address,0} := #gsn_address{},
		       {gsn_address,1} := #gsn_address{},
		       {quality_of_service_profile,0} :=
			   #quality_of_service_profile{priority = 2},
		       {tunnel_endpoint_identifier_control_plane,0} :=
			   #tunnel_endpoint_identifier_control_plane{},
		       {tunnel_endpoint_identifier_data_i,0} :=
			   #tunnel_endpoint_identifier_data_i{}
		      }}, Response),

    #gtp{ie = #{{tunnel_endpoint_identifier_control_plane,0} :=
		    #tunnel_endpoint_identifier_control_plane{
		       tei = RemoteCntlTEI},
		{tunnel_endpoint_identifier_data_i,0} :=
		    #tunnel_endpoint_identifier_data_i{
		      tei = RemoteDataTEI}
	       }} = Response,

    GtpC#gtpc{
	  remote_control_tei = RemoteCntlTEI,
	  remote_data_tei = RemoteDataTEI
     };

validate_response(ms_info_change_notification_request, without_tei, Response, GtpC) ->
    ?match(
       #gtp{type = ms_info_change_notification_response,
	    ie = #{{cause,0} :=
		       #cause{value = request_accepted},
		   {international_mobile_subscriber_identity,0} :=
		       #international_mobile_subscriber_identity{},
		   {imei,0} :=
		       #imei{}
		  }
	   }, Response),
    GtpC;

validate_response(ms_info_change_notification_request, invalid_imsi,
		  Response, GtpC) ->
    ?match(
       #gtp{ie = #{{cause,0} := #cause{value = non_existent}}
	   }, Response),
    GtpC;

validate_response(ms_info_change_notification_request, simple, Response,
		  #gtpc{local_control_tei = LocalCntlTEI} = GtpC) ->
    ?match(
       #gtp{type = ms_info_change_notification_response,
	    tei = LocalCntlTEI,
	    ie = #{{cause,0} := #cause{value = request_accepted}}
	   }, Response),
    #gtp{ie = IEs} = Response,
    ?equal(false, maps:is_key({international_mobile_subscriber_identity,0}, IEs)),
    ?equal(false, maps:is_key({imei,0}, IEs)),
    GtpC;

validate_response(delete_pdp_context_request, _SubType, Response,
		  #gtpc{local_control_tei = LocalCntlTEI} = GtpC) ->
    ?match(#gtp{type = delete_pdp_context_response,
		tei = LocalCntlTEI,
		ie = #{{cause,0} := #cause{value = request_accepted}}
	       }, Response),
    GtpC.

%%%===================================================================
%%% Helper functions
%%%===================================================================

execute_request(MsgType, SubType, Socket, GtpC0) ->
    GtpC = gtp_context_inc_seq(GtpC0),
    Msg = make_request(MsgType, SubType, GtpC),
    Response = send_recv_pdu(Socket, Msg),

    {validate_response(MsgType, SubType, Response, GtpC), Msg, Response}.

%%%===================================================================
%%% GGSN injected functions
%%%===================================================================

-define(T3, 10 * 1000).
-define(N3, 5).

ggsn_update_context(From, Context) ->
    NSAPI = 5,
    RequestIEs0 = [#nsapi{nsapi = NSAPI}],
    RequestIEs = gtp_v1_c:build_recovery(Context, false, RequestIEs0),
    ggsn_send_request(Context, ?T3, ?N3, update_pdp_context_request, RequestIEs, From).

ggsn_send_request(#context{control_port = GtpPort,
			  remote_control_tei = RemoteCntlTEI,
			  remote_control_ip = RemoteCntlIP},
		 T3, N3, Type, RequestIEs, ReqId) ->
    Msg = #gtp{version = v1, type = Type, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(GtpPort, RemoteCntlIP, T3, N3, Msg, ReqId).
