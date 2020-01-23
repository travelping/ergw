%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_ggsn_test_lib).

-define(ERGW_GGSN_NO_IMPORTS, true).

-export([make_request/3, make_response/3, validate_response/4,
	 create_pdp_context/1, create_pdp_context/2,
	 update_pdp_context/2,
	 ms_info_change_notification/2,
	 delete_pdp_context/1, delete_pdp_context/2]).
-export([ggsn_update_context/2]).

-include("ergw_test_lib.hrl").
-include("ergw_ggsn_test_lib.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("../include/ergw.hrl").

%%%===================================================================
%%% Execute GTPv1-C transactions
%%%===================================================================

create_pdp_context(#gtpc{} = GtpC) ->
    create_pdp_context(simple, GtpC);

create_pdp_context(Config) ->
    create_pdp_context(simple, Config).

create_pdp_context(SubType, #gtpc{} = GtpC0) ->
    GtpC = gtp_context_new_teids(GtpC0),
    execute_request(create_pdp_context_request, SubType, GtpC);

create_pdp_context(SubType, Config) ->
    execute_request(create_pdp_context_request, SubType, gtp_context(Config)).

update_pdp_context(SubType, GtpC0)
  when SubType == tei_update ->
    GtpC = gtp_context_new_teids(GtpC0),
    execute_request(update_pdp_context_request, SubType, GtpC);
update_pdp_context(SubType, GtpC) ->
    execute_request(update_pdp_context_request, SubType, GtpC).

ms_info_change_notification(SubType, GtpC) ->
    execute_request(ms_info_change_notification_request, SubType, GtpC).

delete_pdp_context(GtpC) ->
    execute_request(delete_pdp_context_request, simple, GtpC).

delete_pdp_context(SubType, GtpC) ->
    execute_request(delete_pdp_context_request, SubType, GtpC).

%%%===================================================================
%%% Create GTPv1-C messages
%%%===================================================================

make_pdp_type({Type, DABF, _}, IEs) ->
    [#common_flags{flags = ['Dual Address Bearer Flag']} || DABF] ++
	make_pdp_addr_cfg(Type, IEs);
make_pdp_type(_, IEs) ->
    make_pdp_type({ipv4v6, true, default}, IEs).

make_pdp_addr_cfg(ipv6, IEs) ->
    [#end_user_address{pdp_type_organization = 1,
		       pdp_type_number = 16#57,
		       pdp_address = <<>>},
     #protocol_configuration_options{
	config = {0, [{?'PCO-P-CSCF-IPv6-Address',<<>>},
		      {?'PCO-DNS-Server-IPv6-Address',<<>>},
		      {?'PCO-IP-Address-Allocation-Via-NAS-Signalling',<<>>}]}}
     | IEs];
make_pdp_addr_cfg(ipv4v6, IEs) ->
    [#end_user_address{pdp_type_organization = 1,
		       pdp_type_number = 16#8d,
		       pdp_address = <<>>},
     #protocol_configuration_options{
	config = {0, [{ipcp,'CP-Configure-Request',1,
		       [{ms_dns1,<<0,0,0,0>>},
			{ms_dns2,<<0,0,0,0>>}]},
		      {?'PCO-P-CSCF-IPv6-Address',<<>>},
		      {?'PCO-DNS-Server-IPv6-Address',<<>>},
		      {?'PCO-IP-Address-Allocation-Via-NAS-Signalling',<<>>},
		      {?'PCO-DNS-Server-IPv4-Address',<<>>}]}}
     | IEs];
make_pdp_addr_cfg(ipv4, IEs) ->
    [#end_user_address{pdp_type_organization = 1,
		       pdp_type_number = 16#21,
		       pdp_address = <<>>},
     #protocol_configuration_options{
	config = {0, [{ipcp,'CP-Configure-Request',1,
		       [{ms_dns1,<<0,0,0,0>>},
			{ms_dns2,<<0,0,0,0>>}]},
		      {?'PCO-DNS-Server-IPv4-Address',<<>>}]}}
     | IEs].

validate_pdp_addr_cfg(ipv4, IEs) ->
    ?match_map(
       #{{end_user_address,0} =>
	     #end_user_address{pdp_type_organization = 1, pdp_type_number = 33, _ = '_'}},
       IEs);
validate_pdp_addr_cfg(ipv6, IEs) ->
    ?match_map(
       #{{end_user_address,0} =>
	     #end_user_address{pdp_type_organization = 1, pdp_type_number = 87, _ = '_'}},
       IEs);
validate_pdp_addr_cfg(ipv4v6, IEs) ->
    ?match_map(
       #{{end_user_address,0} =>
	     #end_user_address{pdp_type_organization = 1, pdp_type_number = 141, _ = '_'}},
       IEs).

validate_pdp_protocol_opts(ipv4, ipv4, IEs) ->
    ?match_map(
       #{{protocol_configuration_options,0} =>
	     #protocol_configuration_options{
		config = {0,[{ipcp,'CP-Configure-Nak',1,
			      [{ms_dns1, '_'},
			       {ms_dns2, '_'}]},
			     {?'PCO-DNS-Server-IPv4-Address', '_'},
			     {?'PCO-DNS-Server-IPv4-Address', '_'}]},
		_ = '_'}},
       IEs);
validate_pdp_protocol_opts(ipv6, ipv6, IEs) ->
    ?match_map(
       #{{protocol_configuration_options,0} =>
	     #protocol_configuration_options{
		config = {0,[{?'PCO-DNS-Server-IPv6-Address', '_'},
			     {?'PCO-DNS-Server-IPv6-Address', '_'}]},
		_ = '_'}},
       IEs);
validate_pdp_protocol_opts(ipv4v6, ipv4, IEs) ->
    ?match_map(
       #{{protocol_configuration_options,0} =>
	     #protocol_configuration_options{
		config = {0,[{ipcp,'CP-Configure-Nak',1,
			      [{ms_dns1, '_'},
			       {ms_dns2, '_'}]},
			     {?'PCO-DNS-Server-IPv4-Address', '_'},
			     {?'PCO-DNS-Server-IPv4-Address', '_'}]},
		_ = '_'}},
       IEs);
validate_pdp_protocol_opts(ipv4v6, ipv6, IEs) ->
    ?match_map(
       #{{protocol_configuration_options,0} =>
	     #protocol_configuration_options{
		config = {0,[{ipcp,'CP-Configure-Reject',1,
			      [{ms_dns1, '_'},
			       {ms_dns2, '_'}]},
			     {?'PCO-DNS-Server-IPv6-Address', '_'},
			     {?'PCO-DNS-Server-IPv6-Address', '_'}]},
		_ = '_'}},
       IEs);
validate_pdp_protocol_opts(ipv4v6, ipv4v6, IEs) ->
    ?match_map(
       #{{protocol_configuration_options,0} =>
	     #protocol_configuration_options{
		config = {0,[{ipcp,'CP-Configure-Nak',1,
			      [{ms_dns1, '_'},
			       {ms_dns2, '_'}]},
			     {?'PCO-DNS-Server-IPv6-Address', '_'},
			     {?'PCO-DNS-Server-IPv6-Address', '_'},
			     {?'PCO-DNS-Server-IPv4-Address', '_'},
			     {?'PCO-DNS-Server-IPv4-Address', '_'}]},
		_ = '_'}},
       IEs).

validate_pdp_cfg(Requested, Expected, IEs) ->
    validate_pdp_addr_cfg(Expected, IEs),
    validate_pdp_protocol_opts(Requested, Expected, IEs).

validate_pdp_type({Req = ipv4,   false, default}, IEs) -> validate_pdp_cfg(Req, Req, IEs);
validate_pdp_type({Req = ipv6,   false, default}, IEs) -> validate_pdp_cfg(Req, Req, IEs);
validate_pdp_type({Req = ipv4v6, true,  default}, IEs) -> validate_pdp_cfg(Req, Req, IEs);
validate_pdp_type({Req = ipv4v6, true,  v4only},  IEs) -> validate_pdp_cfg(Req, ipv4, IEs);
validate_pdp_type({Req = ipv4v6, true,  v6only},  IEs) -> validate_pdp_cfg(Req, ipv6, IEs);
validate_pdp_type({Req = ipv4,   false, prefV4},  IEs) -> validate_pdp_cfg(Req, Req, IEs);
validate_pdp_type({Req = ipv4,   false, prefV6},  IEs) -> validate_pdp_cfg(Req, Req, IEs);
validate_pdp_type({Req = ipv6,   false, prefV4},  IEs) -> validate_pdp_cfg(Req, Req, IEs);
validate_pdp_type({Req = ipv6,   false, prefV6},  IEs) -> validate_pdp_cfg(Req, Req, IEs);
validate_pdp_type({Req = ipv4v6, false, v4only},  IEs) -> validate_pdp_cfg(Req, ipv4, IEs);
validate_pdp_type({Req = ipv4v6, false, v6only},  IEs) -> validate_pdp_cfg(Req, ipv6, IEs);
validate_pdp_type({Req = ipv4v6, false, prefV4},  IEs) -> validate_pdp_cfg(Req, ipv4, IEs);
validate_pdp_type({Req = ipv4v6, false, prefV6},  IEs) -> validate_pdp_cfg(Req, ipv6, IEs);
validate_pdp_type({Req = ipv4,   false, _},       IEs) -> validate_pdp_cfg(Req, ipv4, IEs);
validate_pdp_type({Req = ipv6,   false, _},       IEs) -> validate_pdp_cfg(Req, ipv6, IEs);

validate_pdp_type(_Type, IEs) ->
    validate_pdp_cfg(ipv4v6, ipv4v6, IEs).

update_ue_ip(#{{end_user_address, 0} :=
		   #end_user_address{pdp_type_organization = 1,
				     pdp_type_number = 16#21,
				     pdp_address = <<IP4:4/bytes>>}}, GtpC) ->
    GtpC#gtpc{ue_ip = {{IP4, 32}, undefined}};
update_ue_ip(#{{end_user_address, 0} :=
		   #end_user_address{pdp_type_organization = 1,
				     pdp_type_number = 16#57,
				     pdp_address = <<IP6:16/bytes>>}}, GtpC) ->
    GtpC#gtpc{ue_ip = {undefined, {IP6, 64}}};
update_ue_ip(#{{end_user_address, 0} :=
		   #end_user_address{pdp_type_organization = 1,
				     pdp_type_number = 16#8D,
				     pdp_address = <<IP4:4/bytes, IP6:16/bytes>>}}, GtpC) ->
    GtpC#gtpc{ue_ip = {{IP4, 32}, {IP6, 64}}}.

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
		   local_ip = IP,
		   local_control_tei = LocalCntlTEI,
		   local_data_tei = LocalDataTEI,
		   rat_type = RAT}) ->
    IEs0 =
	[#recovery{restart_counter = RCnt},
	 #access_point_name{apn = apn(SubType)},
	 #gsn_address{instance = 0, address = ergw_inet:ip2bin(IP)},
	 #gsn_address{instance = 1, address = ergw_inet:ip2bin(IP)},
	 #imei{imei = imei(SubType, LocalCntlTEI)},
	 #international_mobile_subscriber_identity{imsi = imsi(SubType, LocalCntlTEI)},
	 #ms_international_pstn_isdn_number{
	    msisdn = {isdn_address,1,1,1, ?'MSISDN'}},
	 #nsapi{nsapi = 5},
	 #quality_of_service_profile{
	    priority = 2,
	    data = <<19,146,31,113,150,254,254,116,250,255,255,0,142,0>>},
	 #rat_type{rat_type = RAT},
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

make_request(update_pdp_context_request, SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_ip = IP,
		   local_control_tei = LocalCntlTEI,
		   local_data_tei = LocalDataTEI,
		   remote_control_tei = RemoteCntlTEI,
		   rat_type = RAT}) ->
    ULI =
	case SubType of
	    ra_update ->
		#user_location_information
		    {type = 1, mcc = <<"001">>, mnc = <<"001">>,
		     lac = 11, ci  = 0, sac = SeqNo band 16#ffff, rac = 0};
	    _ ->
		#user_location_information
		    {type = 1, mcc = <<"001">>, mnc = <<"001">>,
		     lac = 11, ci  = 0, sac = 20263, rac = 0}
	end,

    IEs = [#recovery{restart_counter = RCnt},
	   #gsn_address{instance = 0, address = ergw_inet:ip2bin(IP)},
	   #gsn_address{instance = 1, address = ergw_inet:ip2bin(IP)},
	   #international_mobile_subscriber_identity{imsi = ?IMSI},
	   #nsapi{nsapi = 5},
	   #quality_of_service_profile{
	      priority = 2,
	      data = <<19,146,31,113,150,254,254,116,250,255,255,0,142,0>>},
	   #rat_type{rat_type = RAT},
	   #tunnel_endpoint_identifier_control_plane{tei = LocalCntlTEI},
	   #tunnel_endpoint_identifier_data_i{tei = LocalDataTEI},
	   ULI],

    #gtp{version = v1, type = update_pdp_context_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs};

make_request(ms_info_change_notification_request, without_tei,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   rat_type = RAT}) ->
    IEs = [#recovery{restart_counter = RCnt},
	   #rat_type{rat_type = RAT},
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
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   rat_type = RAT}) ->
    IEs = [#recovery{restart_counter = RCnt},
	   #rat_type{rat_type = RAT},
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
		   remote_control_tei = RemoteCntlTEI,
		   rat_type = RAT}) ->
    IEs = [#recovery{restart_counter = RCnt},
	   #rat_type{rat_type = RAT},
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
	     #gtpc{seq_no = SeqNo, remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#nsapi{nsapi=5},
	   #teardown_ind{value=1}],

    #gtp{version = v1, type = delete_pdp_context_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs};

make_request(unsupported, _SubType,
	     #gtpc{seq_no = SeqNo, remote_control_tei = RemoteCntlTEI}) ->
    #gtp{version = v1, type = data_record_transfer_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = []}.

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
	      invalid_teid,
	      #gtpc{remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#cause{value = context_not_found}],
    #gtp{version = v1, type = delete_pdp_context_response,
	 tei = 0, seq_no = SeqNo, ie = IEs};

make_response(#gtp{type = delete_pdp_context_request, seq_no = SeqNo},
	      _SubType,
	      #gtpc{remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#cause{value = request_accepted}],
    #gtp{version = v1, type = delete_pdp_context_response,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs}.

%%%-------------------------------------------------------------------

validate_cause(_Type, {_, _, _} = SubType, #gtp{ie = #{{cause,0} := #cause{value = Cause}}}) ->
    CauseList =
	[{{ipv4,   false, default}, request_accepted},
	 {{ipv6,   false, default}, request_accepted},
	 {{ipv4v6, true,  default}, request_accepted},
	 {{ipv4v6, true,  v4only},  new_pdp_type_due_to_network_preference},
	 {{ipv4v6, true,  v6only},  new_pdp_type_due_to_network_preference},
	 {{ipv4,   false, prefV4},  request_accepted},
	 {{ipv4,   false, prefV6},  request_accepted},
	 {{ipv6,   false, prefV4},  request_accepted},
	 {{ipv6,   false, prefV6},  request_accepted},
	 {{ipv4v6, false, v4only},  new_pdp_type_due_to_network_preference},
	 {{ipv4v6, false, v6only},  new_pdp_type_due_to_network_preference},
	 {{ipv4v6, false, prefV4},  new_pdp_type_due_to_single_address_bearer_only},
	 {{ipv4v6, false, prefV6},  new_pdp_type_due_to_single_address_bearer_only},
	 {{ipv6,   false, sgsnemu}, request_accepted}
	 ],
    ExpectedCause = proplists:get_value(SubType, CauseList),
    ?equal(ExpectedCause, Cause);

validate_cause(_Type, _SubType, Response) ->
    ?match(#gtp{ie = #{{cause,0} := #cause{value = request_accepted}}}, Response).

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

validate_response(create_pdp_context_request, gx_fail, Response, GtpC) ->
    ?match(#gtp{type = create_pdp_context_response,
		ie = #{{cause,0} := #cause{value = system_failure}}},
	   Response),
    GtpC;

validate_response(create_pdp_context_request, gy_fail, Response, GtpC) ->
    ?match(#gtp{type = create_pdp_context_response,
		ie = #{{cause,0} := #cause{value = system_failure}}},
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

validate_response(create_pdp_context_request, pool_exhausted, Response, GtpC) ->
    ?match(#gtp{type = create_pdp_context_response,
		ie = #{{cause,0} := #cause{value = all_dynamic_pdp_addresses_are_occupied}}},
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

validate_response(create_pdp_context_request, {ipv4, _, v6only}, Response, GtpC) ->
    ?match(#gtp{type = create_pdp_context_response,
		ie = #{{cause,0} := #cause{value = unknown_pdp_address_or_pdp_type}}},
	   Response),
    GtpC;
validate_response(create_pdp_context_request, {ipv6, _, v4only}, Response, GtpC) ->
    ?match(#gtp{type = create_pdp_context_response,
		ie = #{{cause,0} := #cause{value = unknown_pdp_address_or_pdp_type}}},
	   Response),
    GtpC;

validate_response(create_pdp_context_request, SubType, Response,
		  #gtpc{local_control_tei = LocalCntlTEI} = GtpC0) ->
    validate_cause(create_pdp_context_request, SubType, Response),
    ?match(#gtp{type = create_pdp_context_response,
		tei = LocalCntlTEI,
		ie = #{{charging_id,0} := #charging_id{},
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
    GtpC = update_ue_ip(Response#gtp.ie, GtpC0),

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

validate_response(delete_pdp_context_request, not_found, Response, GtpC) ->
    ?match(#gtp{type = delete_pdp_context_response,
		tei = 0,
		ie = #{{cause,0} := #cause{value = non_existent}}
	       }, Response),
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

execute_request(MsgType, SubType, GtpC0) ->
    GtpC = gtp_context_inc_seq(GtpC0),
    Msg = make_request(MsgType, SubType, GtpC),
    Response = send_recv_pdu(GtpC, Msg),

    {validate_response(MsgType, SubType, Response, GtpC), Msg, Response}.

apn(invalid_apn) -> [<<"IN", "VA", "LID">>];
apn(dotted_apn)  -> ?'APN-EXA.MPLE';
apn(async_sx)    -> [<<"async-sx">>];
apn({_, _, APN})
  when APN =:= v4only; APN =:= prefV4;
       APN =:= v6only; APN =:= prefV6;
       APN =:= sgsnemu ->
    [atom_to_binary(APN, latin1)];
apn(_)           -> ?'APN-EXAMPLE'.

imsi('2nd', _) ->
    <<"454545454545452">>;
imsi(random, TEI) ->
    integer_to_binary(700000000000000 + TEI);
imsi(_, _) ->
    ?IMSI.

imei('2nd', _) ->
    <<"6543210987654321">>;
imei(random, TEI) ->
    integer_to_binary(7000000000000000 + TEI);
imei(_, _) ->
 <<"1234567890123456">>.

%%%===================================================================
%%% GGSN injected functions
%%%===================================================================

-define(T3, 10 * 1000).
-define(N3, 5).

ggsn_update_context(From, Context) ->
    Type = update_pdp_context_request,
    NSAPI = 5,
    RequestIEs0 = [#nsapi{nsapi = NSAPI}],
    RequestIEs = gtp_v1_c:build_recovery(Type, Context, false, RequestIEs0),
    ggsn_send_request(Context, ?T3, ?N3, Type, RequestIEs, From).

ggsn_send_request(#context{control_port = GtpPort,
			   remote_control_teid =
			       #fq_teid{ip = RemoteCntlIP, teid = RemoteCntlTEI}
			  },
		  T3, N3, Type, RequestIEs, From) ->
    Msg = #gtp{version = v1, type = Type, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(GtpPort, RemoteCntlIP, ?GTP1c_PORT, T3, N3, Msg, From).
