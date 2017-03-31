%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_ggsn_test_lib).

-define(ERGW_GGSN_NO_IMPORTS, true).

-export([make_echo_request/1,
	 create_pdp_context/1, create_pdp_context/2,
	 make_create_pdp_context_request/1,
	 validate_create_pdp_context_response/2,
	 delete_pdp_context/2,
	 make_delete_pdp_context_request/1,
	 validate_delete_pdp_context_response/2]).

-include("ergw_test_lib.hrl").
-include("ergw_ggsn_test_lib.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").

%%%===================================================================
%%% Execute GTPv1-C transactions
%%%===================================================================

create_pdp_context(Socket) ->
    create_pdp_context(Socket, gtp_context()).

create_pdp_context(Socket, GtpC) ->
    execute_request(Socket, GtpC,
		    fun make_create_pdp_context_request/1,
		    fun validate_create_pdp_context_response/2).

delete_pdp_context(Socket, GtpC) ->
    execute_request(Socket, GtpC,
		    fun make_delete_pdp_context_request/1,
		    fun validate_delete_pdp_context_response/2).

%%%===================================================================
%%% Create GTPv1-C messages
%%%===================================================================

make_echo_request(#gtpc{restart_counter = RCnt, seq_no = SeqNo}) ->
    IEs = [#recovery{restart_counter = RCnt}],
    #gtp{version = v1, type = echo_request, tei = 0, seq_no = SeqNo, ie = IEs}.

make_create_pdp_context_request(#gtpc{restart_counter = RCnt,
				      seq_no = SeqNo,
				      local_control_tei = LocalCntlTEI,
				      local_data_tei = LocalDataTEI}) ->
    IEs = [#recovery{restart_counter = RCnt},
	   #access_point_name{apn = ?'APN-EXAMPLE'},
	   #end_user_address{pdp_type_organization = 1,
			     pdp_type_number = 16#21,
			     pdp_address = <<>>},
	   #gsn_address{instance = 0, address = gtp_c_lib:ip2bin(?LOCALHOST)},
	   #gsn_address{instance = 1, address = gtp_c_lib:ip2bin(?LOCALHOST)},
	   #imei{imei = <<"1234567890123456">>},
	   #international_mobile_subscriber_identity{imsi = ?IMSI},
	   #ms_international_pstn_isdn_number{
	      msisdn = {isdn_address,1,1,1, ?'MSISDN'}},
	   #nsapi{nsapi = 5},
	   #protocol_configuration_options{
	      config = {0, [{ipcp,'CP-Configure-Request',1,
			     [{ms_dns1,<<0,0,0,0>>},
			      {ms_dns2,<<0,0,0,0>>}]},
			    {13,<<>>}]}},
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

    #gtp{version = v1, type = create_pdp_context_request, tei = 0,
	 seq_no = SeqNo, ie = IEs}.

validate_create_pdp_context_response(Response,
				     #gtpc{local_control_tei =
					       LocalCntlTEI} = GtpC) ->
    ?match(#gtp{type = create_pdp_context_response,
		tei = LocalCntlTEI,
		ie = #{{cause,0} := #cause{value = request_accepted},
		       {charging_id,0} := #charging_id{},
		       {end_user_address,0} :=
			   #end_user_address{pdp_type_organization = 1,
					     pdp_type_number = 33},
		       {gsn_address,0} := #gsn_address{},
		       {gsn_address,1} := #gsn_address{},
		       {protocol_configuration_options,0} :=
			   #protocol_configuration_options{
			      config = {0,[{ipcp,'CP-Configure-Nak',1,
					    [{ms_dns1,_},
					     {ms_dns2,_}]},
					   {13, _},
					   {13, _}]}},
		       {quality_of_service_profile,0} :=
			   #quality_of_service_profile{priority = 2},
		       {reordering_required,0} :=
			   #reordering_required{required = no},
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
     }.

make_delete_pdp_context_request(#gtpc{restart_counter = RCnt,
				      seq_no = SeqNo,
				      remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#recovery{restart_counter = RCnt},
	   #nsapi{nsapi=5},
	   #teardown_ind{value=1}],

    #gtp{version = v1, type = delete_pdp_context_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs}.

validate_delete_pdp_context_response(Response,
				 #gtpc{local_control_tei =
					   LocalCntlTEI} = GtpC) ->
    ?match(#gtp{type = delete_pdp_context_response,
		tei = LocalCntlTEI,
		ie = #{{cause,0} := #cause{value = request_accepted}}
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
