%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_pgw_test_lib).

-define(ERGW_PGW_NO_IMPORTS, true).

-export([make_request/3, make_response/3, validate_response/4,
	 create_session/1, create_session/2,
	 create_deterministic_session/3,
	 delete_session/1, delete_session/2,
	 modify_bearer/2,
	 modify_bearer_command/2,
	 change_notification/2,
	 suspend_notification/2,
	 resume_notification/2]).
-export([pgw_update_context/2]).

-include("ergw_test_lib.hrl").
-include("ergw_pgw_test_lib.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("../include/ergw.hrl").

-define(IS_IP4(X), (is_binary(X) andalso size(X) == 4)).
-define(IS_IP6(X), (is_binary(X) andalso size(X) == 16)).

%%%===================================================================
%%% Execute GTPv2-C transactions
%%%===================================================================

create_session(#gtpc{} = GtpC) ->
    create_session(simple, GtpC);
create_session(Config) ->
    create_session(simple, Config).

create_session(SubType, #gtpc{} = GtpC0) ->
    GtpC = gtp_context_new_teids(GtpC0),
    execute_request(create_session_request, SubType, GtpC);

create_session(SubType, Config) ->
    execute_request(create_session_request, SubType, gtp_context(Config)).

create_deterministic_session(Base, N, #gtpc{} = GtpC0) ->
    GtpC1 = ergw_test_lib:gtp_context_new_teids(Base, N, GtpC0),
    GtpC = gtp_context_inc_seq(GtpC1),
    Msg = create_session_request(Base, N, GtpC),
    Response = send_recv_pdu(GtpC, Msg, 20000),
    {validate_response(create_session_request, simple, Response, GtpC), Msg, Response}.

modify_bearer(SubType, GtpC0)
  when SubType == tei_update ->
    GtpC = gtp_context_new_teids(GtpC0),
    execute_request(modify_bearer_request, SubType, GtpC);
modify_bearer(SubType, GtpC)
  when SubType == sgw_change ->
    execute_request(modify_bearer_request, SubType, GtpC);
modify_bearer(SubType, GtpC) ->
    execute_request(modify_bearer_request, SubType, GtpC).

modify_bearer_command(SubType, GtpC) ->
    execute_command(modify_bearer_command, SubType, GtpC).

change_notification(SubType, GtpC) ->
    execute_request(change_notification_request, SubType, GtpC).

suspend_notification(SubType, GtpC) ->
    execute_request(suspend_notification, SubType, GtpC).

resume_notification(SubType, GtpC) ->
    execute_request(resume_notification, SubType, GtpC).

delete_session(GtpC) ->
    execute_request(delete_session_request, simple, GtpC).

delete_session(SubType, GtpC) ->
    execute_request(delete_session_request, SubType, GtpC).

%%%===================================================================
%%% Create GTPv2-C messages
%%%===================================================================

fq_teid(Instance, Type, TEI, {_,_,_,_} = IP) ->
    #v2_fully_qualified_tunnel_endpoint_identifier{
       instance = Instance, interface_type = Type,
       key = TEI, ipv4 = ergw_inet:ip2bin(IP)};
fq_teid(Instance, Type, TEI, {_,_,_,_,_,_,_,_} = IP) ->
    #v2_fully_qualified_tunnel_endpoint_identifier{
       instance = Instance, interface_type = Type,
       key = TEI, ipv6 = ergw_inet:ip2bin(IP)}.

paa({_,_,_,_} = IP) ->
    #v2_pdn_address_allocation{
       type = ipv4,
       address = ergw_inet:ip2bin(IP)
      };
paa({_,_,_,_,_,_,_,_} = IP) ->
    #v2_pdn_address_allocation{
       type = ipv6,
       address = <<64:8, (ergw_inet:ip2bin(IP))/binary>>
      };
paa({{_,_,_,_,_,_,_,_} = IP, PrefixLen}) ->
    #v2_pdn_address_allocation{
       type = ipv6,
       address = <<PrefixLen:8, (ergw_inet:ip2bin(IP))/binary>>
      }.

set_indication_flag(Flag, IEs) ->
    Fs =
	case lists:keyfind(v2_indication, 1, IEs) of
	    #v2_indication{flags = Flags} ->
		Flags;
	    _ ->
		[]
	end,
    lists:keystore(v2_indication, 1, IEs, #v2_indication{flags = [Flag|Fs]}).

make_indication(crsi, IEs) ->
    set_indication_flag('CRSI', IEs);
make_indication(_SubType, IEs) ->
    IEs.

validate_indication(crsi, IEs) ->
    ?equal(true, maps:is_key({v2_change_reporting_action,0}, IEs));
validate_indication(_SubType, IEs) ->
    ?equal(false, maps:is_key({v2_change_reporting_action,0}, IEs)).

make_pdn_type({Type, DABF, _}, IEs) ->
    case DABF of
	true  -> make_pdn_addr_cfg(Type, set_indication_flag('DAF', IEs));
	false -> make_pdn_addr_cfg(Type, IEs)
    end;
make_pdn_type(Type, IEs)
  when Type =:= ipv4; Type =:= static_ipv4;
       Type =:= ipv6; Type =:= static_ipv6;
       Type =:= static_host_ipv6 ->
    make_pdn_addr_cfg(Type, IEs);
make_pdn_type(_, IEs) ->
    make_pdn_type({ipv4v6, true, default}, IEs).

make_pdn_addr_cfg(static_ipv4, IEs) ->
    RequestedIP = ergw_inet:ip2bin(?IPv4StaticIP),
    [#v2_pdn_address_allocation{type = ipv4,
				address = RequestedIP},
     #v2_pdn_type{pdn_type = ipv4},
     #v2_protocol_configuration_options{
	config = {0, [{ipcp,'CP-Configure-Request',0,
		       [{ms_dns1, <<0,0,0,0>>},
			{ms_dns2, <<0,0,0,0>>}]},
		      {?'PCO-DNS-Server-IPv4-Address', <<>>},
		      {?'PCO-IP-Address-Allocation-Via-NAS-Signalling', <<>>},
		      {?'PCO-Bearer-Control-Mode', <<>>}]}}
     | IEs];

make_pdn_addr_cfg(static_ipv6, IEs) ->
    PrefixLen = 64,
    Prefix = ergw_inet:ip2bin(?IPv6StaticIP),
    [#v2_pdn_address_allocation{
	type = ipv6,
	address = <<PrefixLen, Prefix/binary>>},
     #v2_pdn_type{pdn_type = ipv6},
     #v2_protocol_configuration_options{
	config = {0, [{?'PCO-P-CSCF-IPv6-Address', <<>>},
		      {?'PCO-DNS-Server-IPv6-Address', <<>>},
		      {?'PCO-IP-Address-Allocation-Via-NAS-Signalling',<<>>}]}}
     | IEs];

make_pdn_addr_cfg(static_host_ipv6, IEs) ->
    PrefixLen = 128,
    Prefix = ergw_inet:ip2bin(?IPv6StaticHostIP),
    [#v2_pdn_address_allocation{
	type = ipv6,
	address = <<PrefixLen, Prefix/binary>>},
     #v2_pdn_type{pdn_type = ipv6},
     #v2_protocol_configuration_options{
	config = {0, [{?'PCO-P-CSCF-IPv6-Address', <<>>},
		      {?'PCO-DNS-Server-IPv6-Address', <<>>},
		      {?'PCO-IP-Address-Allocation-Via-NAS-Signalling',<<>>}]}}
     | IEs];

make_pdn_addr_cfg(ipv4, IEs) ->
    RequestedIP = ergw_inet:ip2bin({0,0,0,0}),
    [#v2_pdn_address_allocation{type = ipv4,
				address = RequestedIP},
     #v2_pdn_type{pdn_type = ipv4},
     #v2_protocol_configuration_options{
	config = {0, [{ipcp,'CP-Configure-Request',0,
		       [{ms_dns1, <<0,0,0,0>>},
			{ms_dns2, <<0,0,0,0>>}]},
		      {?'PCO-DNS-Server-IPv4-Address', <<>>},
		      {?'PCO-IP-Address-Allocation-Via-NAS-Signalling', <<>>},
		      {?'PCO-Bearer-Control-Mode', <<>>}]}}
     | IEs];
make_pdn_addr_cfg(ipv6, IEs) ->
    PrefixLen = 0,
    Prefix = ergw_inet:ip2bin({0,0,0,0,0,0,0,0}),
    [#v2_pdn_address_allocation{
	type = ipv6,
	address = <<PrefixLen, Prefix/binary>>},
     #v2_pdn_type{pdn_type = ipv6},
     #v2_protocol_configuration_options{
	config = {0, [{?'PCO-P-CSCF-IPv6-Address', <<>>},
		      {?'PCO-DNS-Server-IPv6-Address', <<>>},
		      {?'PCO-IP-Address-Allocation-Via-NAS-Signalling',<<>>}]}}
     | IEs];
make_pdn_addr_cfg(ipv4v6, IEs) ->
    PrefixLen = 0,
    Prefix = ergw_inet:ip2bin({0,0,0,0,0,0,0,0}),
    RequestedIP = ergw_inet:ip2bin({0,0,0,0}),
    [#v2_pdn_address_allocation{
	type = ipv4v6,
	address = <<PrefixLen, Prefix/binary, RequestedIP/binary>>},
     #v2_pdn_type{pdn_type = ipv4v6},
     #v2_protocol_configuration_options{
	config = {0, [{ipcp,'CP-Configure-Request',0,
		       [{ms_dns1, <<0,0,0,0>>},
			{ms_dns2, <<0,0,0,0>>}]},
		      {?'PCO-DNS-Server-IPv4-Address', <<>>},
		      {?'PCO-IP-Address-Allocation-Via-NAS-Signalling', <<>>},
		      {?'PCO-Bearer-Control-Mode', <<>>},
		      {?'PCO-P-CSCF-IPv6-Address', <<>>},
		      {?'PCO-DNS-Server-IPv6-Address', <<>>},
		      {?'PCO-IP-Address-Allocation-Via-NAS-Signalling', <<>>}]}}
     | IEs].

validate_pdn_addr_cfg(Type, IEs) ->
    ?match_map(
       #{{v2_pdn_address_allocation,0} =>
	     #v2_pdn_address_allocation{type = Type, _ = '_'}},
       IEs).

validate_pdn_protocol_opts(ipv4, ipv4, IEs) ->
    ?match_map(
       #{{v2_protocol_configuration_options,0} =>
	     #v2_protocol_configuration_options{
		config = {0,[{ipcp,'CP-Configure-Nak',0,
			      [{ms_dns1, '_'},
			       {ms_dns2, '_'}]},
			     {?'PCO-DNS-Server-IPv4-Address', '_'},
			     {?'PCO-DNS-Server-IPv4-Address', '_'}]},
		_ = '_'}},
       IEs);
validate_pdn_protocol_opts(ipv6, ipv6, IEs) ->
    ?match_map(
       #{{v2_protocol_configuration_options,0} =>
	     #v2_protocol_configuration_options{
		config = {0,[{?'PCO-DNS-Server-IPv6-Address', '_'},
			     {?'PCO-DNS-Server-IPv6-Address', '_'}]},
		_ = '_'}},
       IEs);
validate_pdn_protocol_opts(ipv4v6, ipv4, IEs) ->
    ?match_map(
       #{{v2_protocol_configuration_options,0} =>
	     #v2_protocol_configuration_options{
		config = {0,[{ipcp,'CP-Configure-Nak',0,
			      [{ms_dns1, '_'},
			       {ms_dns2, '_'}]},
			     {?'PCO-DNS-Server-IPv4-Address', '_'},
			     {?'PCO-DNS-Server-IPv4-Address', '_'}]},
		_ = '_'}},
       IEs);
validate_pdn_protocol_opts(ipv4v6, ipv6, IEs) ->
    ?match_map(
       #{{v2_protocol_configuration_options,0} =>
	     #v2_protocol_configuration_options{
		config = {0,[{ipcp,'CP-Configure-Reject',0,
			      [{ms_dns1, '_'},
			       {ms_dns2, '_'}]},
			     {?'PCO-DNS-Server-IPv6-Address', '_'},
			     {?'PCO-DNS-Server-IPv6-Address', '_'}]},
		_ = '_'}},
       IEs);
validate_pdn_protocol_opts(ipv4v6, ipv4v6, IEs) ->
    ?match_map(
       #{{v2_protocol_configuration_options,0} =>
	     #v2_protocol_configuration_options{
		config = {0,[{ipcp,'CP-Configure-Nak',0,
			      [{ms_dns1, '_'},
			       {ms_dns2, '_'}]},
			     {?'PCO-DNS-Server-IPv4-Address', '_'},
			     {?'PCO-DNS-Server-IPv4-Address', '_'},
			     {?'PCO-DNS-Server-IPv6-Address', '_'},
			     {?'PCO-DNS-Server-IPv6-Address', '_'}]},
		_ = '_'}},
       IEs).

validate_pdn_cfg(Requested, Expected, IEs) ->
    validate_pdn_addr_cfg(Expected, IEs),
    validate_pdn_protocol_opts(Requested, Expected, IEs).

validate_pdn_type({Req = ipv4,   false, default}, IEs) -> validate_pdn_cfg(Req, Req, IEs);
validate_pdn_type({Req = ipv6,   false, default}, IEs) -> validate_pdn_cfg(Req, Req, IEs);
validate_pdn_type({Req = ipv4v6, true,  default}, IEs) -> validate_pdn_cfg(Req, Req, IEs);
validate_pdn_type({Req = ipv4v6, true,  v4only},  IEs) -> validate_pdn_cfg(Req, ipv4, IEs);
validate_pdn_type({Req = ipv4v6, true,  v6only},  IEs) -> validate_pdn_cfg(Req, ipv6, IEs);
validate_pdn_type({Req = ipv4,   false, prefV4},  IEs) -> validate_pdn_cfg(Req, Req, IEs);
validate_pdn_type({Req = ipv4,   false, prefV6},  IEs) -> validate_pdn_cfg(Req, Req, IEs);
validate_pdn_type({Req = ipv6,   false, prefV4},  IEs) -> validate_pdn_cfg(Req, Req, IEs);
validate_pdn_type({Req = ipv6,   false, prefV6},  IEs) -> validate_pdn_cfg(Req, Req, IEs);
validate_pdn_type({Req = ipv4v6, false, v4only},  IEs) -> validate_pdn_cfg(Req, ipv4, IEs);
validate_pdn_type({Req = ipv4v6, false, v6only},  IEs) -> validate_pdn_cfg(Req, ipv6, IEs);
validate_pdn_type({Req = ipv4v6, false, prefV4},  IEs) -> validate_pdn_cfg(Req, ipv4, IEs);
validate_pdn_type({Req = ipv4v6, false, prefV6},  IEs) -> validate_pdn_cfg(Req, ipv6, IEs);

validate_pdn_type(ipv4, IEs)                        -> validate_pdn_cfg(ipv4, ipv4, IEs);
validate_pdn_type(ipv6, IEs)                        -> validate_pdn_cfg(ipv6, ipv6, IEs);
validate_pdn_type({default, static_ipv6}, IEs)      -> validate_pdn_cfg(ipv6, ipv6, IEs);
validate_pdn_type({default, static_host_ipv6}, IEs) -> validate_pdn_cfg(ipv6, ipv6, IEs);

validate_pdn_type(_Type, IEs) ->
    validate_pdn_cfg(ipv4v6, ipv4v6, IEs).

update_ue_ip(#{{v2_pdn_address_allocation,0} :=
		    #v2_pdn_address_allocation{
		       type = ipv4, address = <<IP4:4/binary>>}}, GtpC) ->
     GtpC#gtpc{ue_ip = {{IP4, 32}, undefined}};
update_ue_ip(#{{v2_pdn_address_allocation,0} :=
		    #v2_pdn_address_allocation{
		       type = ipv6,
		       address = <<IP6PrefixLen:8, IP6Prefix:16/binary>>}}, GtpC) ->
    GtpC#gtpc{ue_ip = {undefined, {IP6Prefix, IP6PrefixLen}}};
update_ue_ip(#{{v2_pdn_address_allocation,0} :=
		    #v2_pdn_address_allocation{
		       type = ipv4v6,
		       address = <<IP6PrefixLen:8, IP6Prefix:16/binary,
				   IP4:4/binary>>}}, GtpC) ->
    GtpC#gtpc{ue_ip = {{IP4, 32}, {IP6Prefix, IP6PrefixLen}}}.

%%%-------------------------------------------------------------------

create_session_request(Base, N,
		       #gtpc{restart_counter = RCnt, seq_no = SeqNo,
			     local_ip = LocalIP,
			     local_control_tei = LocalCntlTEI,
			     local_data_tei = LocalDataTEI,
			     rat_type = RAT}) ->
    IMSI = integer_to_binary(700000000000000 + Base + N),
    IMEI = integer_to_binary(70000000 + Base + N),
    MSISDN = integer_to_binary(440000000000 + Base + N),

    IEs0 =
	[#v2_recovery{restart_counter = RCnt},
	 #v2_access_point_name{apn = apn(simple)},
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
		     fq_teid(2, ?'S5/S8-U SGW', LocalDataTEI, LocalIP)
		    ]},
	 fq_teid(0, ?'S5/S8-C SGW', LocalCntlTEI, LocalIP),
	 #v2_international_mobile_subscriber_identity{imsi = IMSI},
	 #v2_mobile_equipment_identity{mei = IMEI},
	 #v2_msisdn{msisdn = MSISDN},
	 #v2_rat_type{rat_type = RAT},
	 #v2_selection_mode{mode = 0},
	 #v2_serving_network{mcc = <<"001">>, mnc = <<"001">>},
	 #v2_ue_time_zone{timezone = 10, dst = 0},
	 #v2_user_location_information{tai = <<3,2,22,214,217>>,
				       ecgi = <<3,2,22,8,71,9,92>>}],
    IEs = make_pdn_type(simple, IEs0),
    #gtp{version = v2, type = create_session_request, tei = 0,
	 seq_no = SeqNo, ie = IEs}.

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
		   local_ip = LocalIP,
		   local_control_tei = LocalCntlTEI,
		   local_data_tei = LocalDataTEI,
		   rat_type = RAT}) ->
    IEs0 =
	[#v2_recovery{restart_counter = RCnt},
	 #v2_access_point_name{apn = apn(SubType)},
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
		     fq_teid(2, ?'S5/S8-U SGW', LocalDataTEI, LocalIP)
		    ]},
	 fq_teid(0, ?'S5/S8-C SGW', LocalCntlTEI, LocalIP),
	 #v2_indication{flags = []},
	 #v2_international_mobile_subscriber_identity{
	    imsi = imsi(SubType, LocalCntlTEI)},
	 #v2_mobile_equipment_identity{mei = imei(SubType, LocalCntlTEI)},
	 #v2_msisdn{msisdn = ?'MSISDN'},
	 #v2_rat_type{rat_type = RAT},
	 #v2_selection_mode{mode = 0},
	 #v2_serving_network{mcc = <<"001">>, mnc = <<"001">>},
	 #v2_ue_time_zone{timezone = 10, dst = 0},
	 #v2_user_location_information{tai = <<3,2,22,214,217>>,
				       ecgi = <<3,2,22,8,71,9,92>>}],
    IEs1 = make_pdn_type(SubType, IEs0),
    IEs = make_indication(SubType, IEs1),
    #gtp{version = v2, type = create_session_request, tei = 0,
	 seq_no = SeqNo, ie = IEs};

make_request(modify_bearer_request, SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_ip = LocalIP,
		   local_control_tei = LocalCntlTEI,
		   local_data_tei = LocalDataTEI,
		   remote_control_tei = RemoteCntlTEI})
  when SubType == tei_update; SubType == sgw_change ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_bearer_context{
	      group = [#v2_eps_bearer_id{eps_bearer_id = 5},
		       fq_teid(1, ?'S5/S8-U SGW', LocalDataTEI, LocalIP)
		      ]},
	   fq_teid(0, ?'S5/S8-C SGW', LocalCntlTEI, LocalIP)
	  ],

    #gtp{version = v2, type = modify_bearer_request, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs};

make_request(modify_bearer_request, secondary_rat_usage_data_report,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_ip = LocalIP,
		   local_control_tei = LocalCntlTEI,
		   remote_control_tei = RemoteCntlTEI,
		   rat_type = RAT}) ->
    MCCMNC = <<16#00, 16#11, 16#00>>,       %% MCC => 001, MNC => 001
    ULI = #v2_user_location_information{
	     tai  = <<MCCMNC/binary, 20263:16>>,
	     ecgi = <<MCCMNC/binary, 0:4, 138873180:28>>},
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_ue_time_zone{timezone = 10, dst = 0},
	   ULI,
	   #v2_rat_type{rat_type = RAT},
	   fq_teid(0, ?'S5/S8-C SGW', LocalCntlTEI, LocalIP),
	   #v2_secondary_rat_usage_data_report{
	      irpgw = true, rat_type = 0, ebi = 5,
	      start_time = 101234, end_time = 104567,
	      dl = 10, ul = 11
	     },
	   #v2_secondary_rat_usage_data_report{
	      irpgw = true, rat_type = 0, ebi = 5,
	      start_time = 201234, end_time = 204567,
	      dl = 20, ul = 21
	     },
	   #v2_secondary_rat_usage_data_report{
	      irpgw = true, rat_type = 0, ebi = 5,
	      start_time = 301234, end_time = 304567,
	      dl = 30, ul = 31
	     }
	  ],
    #gtp{version = v2, type = modify_bearer_request, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs};

make_request(modify_bearer_request, SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_ip = LocalIP,
		   local_control_tei = LocalCntlTEI,
		   remote_control_tei = RemoteCntlTEI,
		   rat_type = RAT})
  when SubType == simple; SubType == ra_update ->
    MCCMNC = <<16#00, 16#11, 16#00>>,       %% MCC => 001, MNC => 001
    ULI =
	case SubType of
	    ra_update ->
		#v2_user_location_information{
		   tai  = <<MCCMNC/binary, (SeqNo band 16#ffff):16>>,
		   ecgi = <<MCCMNC/binary, 0:4, 138873180:28>>};
	    _ ->
		#v2_user_location_information{
		   tai  = <<MCCMNC/binary, 20263:16>>,
		   ecgi = <<MCCMNC/binary, 0:4, 138873180:28>>}
	end,
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_ue_time_zone{timezone = 10, dst = 0},
	   ULI,
	   #v2_rat_type{rat_type = RAT},
	   fq_teid(0, ?'S5/S8-C SGW', LocalCntlTEI, LocalIP)
	  ],

    #gtp{version = v2, type = modify_bearer_request, tei = RemoteCntlTEI,
	 seq_no = SeqNo, ie = IEs};

make_request(modify_bearer_command, SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_ip = LocalIP,
		   local_control_tei = LocalCntlTEI,
		   remote_control_tei = RemoteCntlTEI})
  when SubType == simple; SubType == ra_update ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_aggregate_maximum_bit_rate{},
	   #v2_bearer_context{
	      group = [#v2_eps_bearer_id{eps_bearer_id = 5},
		       #v2_bearer_level_quality_of_service{}
		      ]},
	   fq_teid(0, ?'S5/S8-C SGW',LocalCntlTEI, LocalIP)
	  ],
    #gtp{version = v2, type = modify_bearer_command, tei = RemoteCntlTEI,
	 seq_no = SeqNo bor 16#800000, ie = IEs};

make_request(change_notification_request, simple,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   remote_control_tei = RemoteCntlTEI,
		   rat_type = RAT}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_rat_type{rat_type = RAT},
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
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   rat_type = RAT}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_rat_type{rat_type = RAT},
	   #v2_international_mobile_subscriber_identity{
	      imsi = ?'IMSI'},
	   #v2_mobile_equipment_identity{mei = ?IMEISV},
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

make_request(delete_session_request, fq_teid,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_ip = LocalIP,
		   local_control_tei = LocalCntlTEI,
		   remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_eps_bearer_id{eps_bearer_id = 5},
	   fq_teid(0, ?'S5/S8-C SGW', LocalCntlTEI, LocalIP),
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}],

    #gtp{version = v2, type = delete_session_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs};

make_request(delete_session_request, SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   local_ip = LocalIP,
		   local_control_tei = LocalCntlTEI,
		   remote_control_tei = RemoteCntlTEI})
  when SubType == invalid_peer_teid;
       SubType == invalid_peer_ip ->
    FqTEID =
	case SubType of
	      invalid_peer_teid ->
		fq_teid(0, ?'S5/S8-C SGW', LocalCntlTEI + 1000, LocalIP);
	    invalid_peer_ip ->
		fq_teid(0, ?'S5/S8-C SGW', LocalCntlTEI, {1,1,1,1})
	end,

    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_eps_bearer_id{eps_bearer_id = 5},
	   FqTEID,
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}],

    #gtp{version = v2, type = delete_session_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs};

make_request(delete_session_request, secondary_rat_usage_data_report,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_eps_bearer_id{eps_bearer_id = 5},
	   #v2_secondary_rat_usage_data_report{
	      irpgw = true, rat_type = 0, ebi = 5,
	      start_time = 101234, end_time = 104567,
	      dl = 10, ul = 11
	     },
	   #v2_secondary_rat_usage_data_report{
	      irpgw = true, rat_type = 0, ebi = 5,
	      start_time = 201234, end_time = 204567,
	      dl = 20, ul = 21
	     },
	   #v2_secondary_rat_usage_data_report{
	      irpgw = true, rat_type = 0, ebi = 5,
	      start_time = 301234, end_time = 304567,
	      dl = 30, ul = 31
	     }
	  ],

    #gtp{version = v2, type = delete_session_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs};

make_request(delete_session_request, _SubType,
	     #gtpc{restart_counter = RCnt, seq_no = SeqNo,
		   remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_eps_bearer_id{eps_bearer_id = 5}],

    #gtp{version = v2, type = delete_session_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs};

make_request(unsupported, _SubType,
	     #gtpc{seq_no = SeqNo, remote_control_tei = RemoteCntlTEI}) ->
    #gtp{version = v2, type = mbms_session_stop_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = []}.

%%%-------------------------------------------------------------------

make_response(#gtp{type = create_session_request,
		   ie = #{{v2_fully_qualified_tunnel_endpoint_identifier, 0} :=
			      #v2_fully_qualified_tunnel_endpoint_identifier{
				 key = RemoteCntlTEI
				}}},
	      SubType, _)
  when SubType =:= overload;
       SubType =:= no_resources_available ->
    IEs = [#v2_cause{v2_cause = no_resources_available}],
    {create_session_response, RemoteCntlTEI, IEs};

make_response(#gtp{type = create_session_request, seq_no = SeqNo},
	      _SubType,
	      #gtpc{restart_counter = RCnt, ue_ip = UE_IP,
		    local_control_tei = LocalCntlTEI,
		    local_data_tei = LocalDataTEI,
		    remote_ip = RemoteIP,
		    remote_control_tei = RemoteCntlTEI}) ->
    IEs = #{{v2_cause,0} => #v2_cause{v2_cause = request_accepted},
	    {v2_apn_restriction, 0} =>
		#v2_apn_restriction{restriction_type_value = 0},
	    {v2_charging_id, 0} =>
		#v2_charging_id{id = <<0,0,0,1>>},
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
			     fq_teid(2, ?'S5/S8-U PGW',LocalDataTEI, RemoteIP)
			}},
	    {v2_fully_qualified_tunnel_endpoint_identifier, 1} =>
		fq_teid(1, ?'S5/S8-C PGW', LocalCntlTEI, RemoteIP),
	    {v2_pdn_address_allocation, 0} => paa(UE_IP),
	    {v2_protocol_configuration_options, 0} =>
		#v2_protocol_configuration_options{
		   config = {0, [{ipcp,'CP-Configure-Nak',0,
				  [{ms_dns1, ergw_inet:ip2bin({8,8,8,8})},
				   {ms_dns2, ergw_inet:ip2bin({8,8,4,4})}]},
				 {13, ergw_inet:ip2bin({8,8,4,4})},
				 {13, ergw_inet:ip2bin({8,8,8,8})}]}},
	    {v2_recovery, 0} => #v2_recovery{restart_counter = RCnt}},
    #gtp{version = v2, type = create_session_response,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs};

make_response(#gtp{type = update_bearer_request, seq_no = SeqNo},
	      SubType,
	      #gtpc{restart_counter = RCnt,
		    remote_control_tei = RemoteCntlTEI}) ->
    {Cause, BearerCause} =
	case SubType of
	    invalid_teid ->
		{context_not_found, request_accepted};
	    apn_congestion ->
		{request_accepted, apn_congestion};
	    _ ->
		{request_accepted, request_accepted}
	end,
    EBI = 5,
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_cause{v2_cause = Cause},
	   #v2_bearer_context{
	      group = [#v2_eps_bearer_id{eps_bearer_id = EBI},
		       #v2_cause{v2_cause = BearerCause}]}],
    #gtp{version = v2, type = update_bearer_response,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs};

make_response(#gtp{type = delete_bearer_request, seq_no = SeqNo},
	      invalid_teid,
	      #gtpc{restart_counter = RCnt,
		    remote_control_tei = _}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_cause{v2_cause = context_not_found}],
    #gtp{version = v2, type = delete_bearer_response,
	 tei = 0, seq_no = SeqNo, ie = IEs};

make_response(#gtp{type = delete_bearer_request, seq_no = SeqNo},
	      _SubType,
	      #gtpc{restart_counter = RCnt,
		    remote_control_tei = RemoteCntlTEI}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_cause{v2_cause = request_accepted}],
    #gtp{version = v2, type = delete_bearer_response,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs}.

%%%-------------------------------------------------------------------

validate_cause(_Type, {_, _, _} = SubType,
	       #gtp{ie = #{{v2_cause,0} := #v2_cause{v2_cause = Cause}}}) ->
    CauseList =
	[{{ipv4,   false, default}, request_accepted},
	 {{ipv6,   false, default}, request_accepted},
	 {{ipv4v6, true,  default}, request_accepted},
	 {{ipv4v6, true,  v4only},  new_pdn_type_due_to_network_preference},
	 {{ipv4v6, true,  v6only},  new_pdn_type_due_to_network_preference},
	 {{ipv4,   false, prefV4},  request_accepted},
	 {{ipv4,   false, prefV6},  request_accepted},
	 {{ipv6,   false, prefV4},  request_accepted},
	 {{ipv6,   false, prefV6},  request_accepted},
	 {{ipv4v6, false, v4only},  new_pdn_type_due_to_network_preference},
	 {{ipv4v6, false, v6only},  new_pdn_type_due_to_network_preference},
	 {{ipv4v6, false, prefV4},  new_pdn_type_due_to_single_address_bearer_only},
	 {{ipv4v6, false, prefV6},  new_pdn_type_due_to_single_address_bearer_only}
	 ],
    ExpectedCause = proplists:get_value(SubType, CauseList),
    ?equal(ExpectedCause, Cause);

validate_cause(_Type, _SubType, Response) ->
    ?match(#gtp{ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}}, Response).

validate_seq_no(#gtp{seq_no = SeqNo}, #gtpc{seq_no = GtpCSeqNo}) ->
    ?equal(GtpCSeqNo, SeqNo);
validate_seq_no(#gtp{seq_no = SeqNo}, ExpectedSeqNo) ->
    ?equal(ExpectedSeqNo, SeqNo).

validate_teid(#gtp{tei = TEID}, #gtpc{local_control_tei = GtpCTEID}) ->
    ?equal(GtpCTEID, TEID);
validate_teid(#gtp{tei = TEID}, ExpectedTEID) ->
    ?equal(ExpectedTEID, TEID).

validate_response(_Type, system_failure, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    ?match(
       #gtp{ie = #{{v2_cause,0} := #v2_cause{v2_cause = system_failure}}
	   }, Response),
    GtpC;

validate_response(modify_bearer_command, invalid_teid, Response, GtpC) ->
    validate_seq_no(Response, GtpC#gtpc.seq_no bor 16#800000),
    validate_teid(Response, 0),
    ?match(
       #gtp{ie = #{{v2_cause,0} := #v2_cause{v2_cause = context_not_found}}
	   }, Response),
    GtpC;

validate_response(_Type, invalid_teid, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, 0),
    ?match(
       #gtp{ie = #{{v2_cause,0} := #v2_cause{v2_cause = context_not_found}}
	   }, Response),
    GtpC;

validate_response(create_session_request, missing_ie, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, 0),
    ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = mandatory_ie_missing}}},
	   Response),
    GtpC;

validate_response(create_session_request, aaa_reject, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = user_authentication_failed}}},
	   Response),
    GtpC;

validate_response(create_session_request, gx_fail, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
   ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = system_failure}}},
	  Response),
    GtpC;

validate_response(create_session_request, gy_fail, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = system_failure}}},
	   Response),
    GtpC;

validate_response(create_session_request, overload, Response, GtpC) ->
    validate_seq_no(Response, GtpC),

    %% this is debatable, but decoding the request would require even more resources.
    %% validate_teid(Response, GtpC),
    validate_teid(Response, 0),

   ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = no_resources_available}}},
	  Response),
    GtpC;

validate_response(create_session_request, no_resources_available, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),

   ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = no_resources_available}}},
	  Response),
    GtpC;

validate_response(create_session_request, invalid_apn, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
   ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = missing_or_unknown_apn}}},
	  Response),
    GtpC;

validate_response(create_session_request, pool_exhausted, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
   ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = all_dynamic_addresses_are_occupied}}},
	  Response),
    GtpC;

validate_response(create_session_request, invalid_mapping, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
   ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = user_authentication_failed}}},
	  Response),
    GtpC;

validate_response(create_session_request, version_restricted, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, undefined),
    ?match(#gtp{type = version_not_supported}, Response),
    GtpC;

validate_response(create_session_request, static_ipv6, Response, GtpC0) ->
    GtpC = validate_response(create_session_request, {default, static_ipv6}, Response, GtpC0),
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    #gtp{ie = #{
	   {v2_pdn_address_allocation,0} :=
	       #v2_pdn_address_allocation{
		  type = ipv6, address = <<PrefixLen:8, IPv6/binary>>}}} = Response,
    ?equal(64, PrefixLen),
    ?equal(?IPv6StaticIP, ergw_inet:bin2ip(IPv6)),
    GtpC;

validate_response(create_session_request, static_host_ipv6, Response, GtpC0) ->
    GtpC = validate_response(create_session_request, {default, static_host_ipv6}, Response, GtpC0),
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    #gtp{ie = #{
	   {v2_pdn_address_allocation,0} :=
	       #v2_pdn_address_allocation{
		  type = ipv6, address = <<PrefixLen:8, IPv6/binary>>}}} = Response,
    ?equal(128, PrefixLen),
    ?equal(?IPv6StaticHostIP, ergw_inet:bin2ip(IPv6)),
    GtpC;

validate_response(create_session_request, {ipv4, _, v6only}, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = preferred_pdn_type_not_supported}}},
	   Response),
    GtpC;
validate_response(create_session_request, {ipv6, _, v4only}, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = preferred_pdn_type_not_supported}}},
	   Response),
    GtpC;

validate_response(create_session_request, SubType, Response,
		  #gtpc{local_ip = LocalIP,
			local_control_tei = LocalCntlTEI} = GtpC0) ->
    validate_cause(create_session_request, SubType, Response),
    validate_seq_no(Response, GtpC0),
    validate_teid(Response, GtpC0),
    ?match(
       #gtp{type = create_session_response,
	    tei = LocalCntlTEI,
	    ie = #{{v2_fully_qualified_tunnel_endpoint_identifier,1} :=
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
    validate_pdn_type(SubType, Response#gtp.ie),
    validate_indication(SubType, Response#gtp.ie),
    GtpC = update_ue_ip(Response#gtp.ie, GtpC0),

    #gtp{ie = #{{v2_fully_qualified_tunnel_endpoint_identifier,1} :=
		    #v2_fully_qualified_tunnel_endpoint_identifier{
		       key = RemoteCntlTEI,
		       ipv4 = RemoteCntlIP4,
		       ipv6 = RemoteCntlIP6},
		{v2_bearer_context,0} :=
		    #v2_bearer_context{
		       group = #{
			 {v2_fully_qualified_tunnel_endpoint_identifier,2} :=
			     #v2_fully_qualified_tunnel_endpoint_identifier{
				key = RemoteDataTEI,
				ipv4 = RemoteDataIP4,
				ipv6 = RemoteDataIP6}}}
	       }} = Response,

    if size(LocalIP) == 4 ->
	    if ?IS_IP4(RemoteCntlIP4) andalso ?IS_IP4(RemoteDataIP4) ->
		    ok;
	       true ->
		    ct:pal("Local IPv4, remote V4 C: ~w, U: ~w, V6 C: ~w, U: ~w",
			   [RemoteCntlIP4, RemoteDataIP4,
			    RemoteCntlIP6, RemoteDataIP6]),
		    error(invalid_ip)
	    end;
       size(LocalIP) == 8 ->
	    if ?IS_IP6(RemoteCntlIP6) andalso ?IS_IP6(RemoteDataIP6) ->
		    ok;
	       true ->
		    ct:pal("Local IPv6, remote V4 C: ~w, U: ~w, V6 C: ~w, U: ~w",
			   [RemoteCntlIP4, RemoteDataIP4,
			    RemoteCntlIP6, RemoteDataIP6]),
		    error(invalid_ip)
	    end
    end,

    GtpC#gtpc{
	  remote_control_tei = RemoteCntlTEI,
	  remote_data_tei = RemoteDataTEI
     };

validate_response(modify_bearer_request, SubType, Response, GtpC)
  when SubType == tei_update; SubType == sgw_change ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    ?match(#gtp{type = modify_bearer_response}, Response),
    ?match(
       #gtp{type = modify_bearer_response,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
		   {v2_apn_restriction,0} := _,
		   {v2_msisdn,0} := _,
		   {v2_eps_bearer_id, 0} := _,
		   {v2_charging_id, 0} := #v2_charging_id{},
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

validate_response(modify_bearer_request, SubType, Response, GtpC)
  when SubType == simple; SubType == ra_update; SubType == secondary_rat_usage_data_report ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    ?match(
       #gtp{type = modify_bearer_response,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	   }, Response),
    #gtp{ie = IEs} = Response,
    ?equal(false, maps:is_key({v2_bearer_context,0}, IEs)),
    ?equal(false, maps:is_key({v2_change_reporting_action,0}, IEs)),
    GtpC;

validate_response(modify_bearer_command, _SubType, Response, #gtpc{seq_no = SeqNo} = GtpC) ->
    validate_teid(Response, GtpC),
    CmdSeqNo = SeqNo bor 16#800000,
    ?match(
       #gtp{type = update_bearer_request,
	    seq_no = CmdSeqNo,
	    ie = #{{v2_aggregate_maximum_bit_rate,0} := #v2_aggregate_maximum_bit_rate{},
		   {v2_bearer_context,0} :=
		       #v2_bearer_context{
			  group =
			      #{{v2_bearer_level_quality_of_service,0} :=
				    #v2_bearer_level_quality_of_service{},
				{v2_eps_bearer_id,0} := #v2_eps_bearer_id{}}}}
	   }, Response),
    GtpC;

validate_response(change_notification_request, simple, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    ?match(
       #gtp{type = change_notification_response,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	   }, Response),
    #gtp{ie = IEs} = Response,
    ?equal(false, maps:is_key({v2_international_mobile_subscriber_identity,0}, IEs)),
    ?equal(false, maps:is_key({v2_mobile_equipment_identity,0}, IEs)),
    GtpC;

validate_response(change_notification_request, without_tei, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
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
    validate_seq_no(Response, GtpC),
    validate_teid(Response, 0),
    ?match(
       #gtp{ie = #{{v2_cause,0} := #v2_cause{v2_cause = context_not_found}}
	   }, Response),
    GtpC;

validate_response(suspend_notification, _SubType, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    ?match(
       #gtp{type = suspend_acknowledge,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	   }, Response),
    GtpC;

validate_response(resume_notification, _SubType, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    ?match(
       #gtp{type = resume_acknowledge,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	   }, Response),
    GtpC;

validate_response(delete_session_request, not_found, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, 0),
    ?match(
       #gtp{type = delete_session_response,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = context_not_found}}
	   }, Response),
    GtpC;

validate_response(delete_session_request, SubType, Response, GtpC)
  when SubType == invalid_peer_teid;
       SubType == invalid_peer_ip ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    ?match(
       #gtp{type = delete_session_response,
	    ie = #{{v2_cause,0} := #v2_cause{v2_cause = invalid_peer}}
	   }, Response),
    GtpC;

validate_response(delete_session_request, _SubType, Response, GtpC) ->
    validate_seq_no(Response, GtpC),
    validate_teid(Response, GtpC),
    ?match(#gtp{type = delete_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	       }, Response),
    GtpC.

%%%===================================================================
%%% Helper functions
%%%===================================================================

execute_command(MsgType, SubType, GtpC)
  when SubType == invalid_teid ->
    execute_request(MsgType, SubType, GtpC);
execute_command(MsgType, SubType, GtpC0) ->
    GtpC = gtp_context_inc_seq(GtpC0),
    Msg = make_request(MsgType, SubType, GtpC),
    send_pdu(GtpC, Msg),

    {GtpC, Msg}.

execute_request(MsgType, SubType, GtpC0) ->
    GtpC = gtp_context_inc_seq(GtpC0),
    Msg = make_request(MsgType, SubType, GtpC),
    Response = send_recv_pdu(GtpC, Msg),

    {validate_response(MsgType, SubType, Response, GtpC), Msg, Response}.

apn(M) when is_map(M) ->
    apn(maps:get(apn, M, default));
apn(invalid_apn) -> [<<"IN", "VA", "LID">>];
apn(dotted_apn)  -> ?'APN-EXA.MPLE';
apn(proxy_apn)   -> ?'APN-PROXY';
apn(async_sx)    -> [<<"async-sx">>];
apn({_, _, APN})
  when APN =:= v4only; APN =:= prefV4;
       APN =:= v6only; APN =:= prefV6 ->
    [atom_to_binary(APN, latin1)];
apn([Label|_] = APN) when is_binary(Label) -> APN;
apn(_)           -> ?'APN-ExAmPlE'.

imsi(M, TEI) when is_map(M) ->
    imsi(maps:get(imsi, M, random), TEI);
imsi('2nd', _) ->
    <<"454545454545452">>;
imsi(random, TEI) ->
    integer_to_binary(700000000000000 + TEI);
imsi(_, _) ->
    ?IMSI.

imei(M, TEI) when is_map(M) ->
    imei(maps:get(imei, M, random), TEI);
imei('2nd', _) ->
    <<"490154203237518">>;
imei(random, TEI) ->
    integer_to_binary(700000000000000 + TEI);
imei(_, _)     ->
    ?IMEISV.

%%%===================================================================
%%% PGW injected functions
%%%===================================================================

-define(T3, 10 * 1000).
-define(N3, 5).

pgw_update_context(From, Context) ->
    Type = update_bearer_request,
    EBI = 5,
    RequestIEs0 =
	[#v2_bearer_context{
	    group = [#v2_eps_bearer_id{eps_bearer_id = EBI},
		     #v2_bearer_level_quality_of_service{}
		    ]},
	 #v2_aggregate_maximum_bit_rate{uplink = 48128, downlink = 1704125}],
    RequestIEs = gtp_v2_c:build_recovery(Type, Context, false, RequestIEs0),
    pgw_send_request(Context, ?T3, ?N3, Type, RequestIEs, From).

pgw_send_request(Context, T3, N3, Type, RequestIEs, From) ->
    #tunnel{remote = #fq_teid{ip = RemoteCntlIP, teid = RemoteCntlTEI}} = Tunnel =
	ergw_gsn_lib:tunnel(left, Context),
    Msg = #gtp{version = v2, type = Type, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(Tunnel, RemoteCntlIP, ?GTP2c_PORT, T3, N3, Msg, From).
