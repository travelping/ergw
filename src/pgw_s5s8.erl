%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8).

-behaviour(gtp_api).

-compile({parse_transform, do}).

-export([init/2, request_spec/1, handle_request/5]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

%%====================================================================
%% API
%%====================================================================

%% TODO: the records and matching request spec's should be
%%       generated from a common source.....
-record(create_session_request, {
	  imsi,
	  msisdn,
	  user_location_information,
	  serving_network,
	  rat_type,
	  indication,
	  sender_f_teid_for_control_plane,
	  apn,
	  selection_mode,
	  pdn_tye,
	  paa,
	  apn_restriction,
	  apn_ambr,
	  pco,
	  bearer_context_to_be_created,
	  bearer_context_to_be_removed,
	  trace_information,
	  mme_fq_csid,
	  sgw_fq_csid,
	  ue_time_zone,
	  charging_characteristics,
	  sgw_ldn,
	  signalling_priority_indication,
	  henb_local_ip_address,
	  s4_sgsn_identifier,
	  additional_ies
	 }).

-record(delete_session_request, {
	  cause,
	  linked_eps_bearer_id,
	  user_location_information,
	  indication,
	  pco,
	  sender_f_teid_for_control_plane,
	  ue_time_zone,
	  uli_timestamp,
	  additional_ies
	 }).

-record(modify_bearer_request, {
	  mei,
	  user_location_information,
	  serving_network,
	  rat_type,
	  indication,
	  sender_f_teid_for_control_plane,
	  bearer_context_to_be_modified,
	  bearer_context_to_be_removed,
	  mme_fq_csid,
	  sgw_fq_csid,
	  user_csg_information,
	  sgw_ldn,
	  henb_local_ip_address,
	  henb_local_ip_port,
	  s4_sgsn_identifier,
	  presence_reporting_area_information,
	  additional_ies
	 }).

request_spec(create_session_request) ->
    [{{v2_international_mobile_subscriber_identity, 0},		conditional},
     {{v2_msisdn, 0},						conditional},
     {{v2_mobile_equipment_identity, 0},			conditional},
     {{v2_user_location_information, 0},			conditional},
     {{v2_serving_network, 0},					optional},
     {{v2_rat_type, 0},						mandatory},
     {{v2_indication, 0},					optional},
     {{v2_fully_qualified_tunnel_endpoint_identifier, 0},	mandatory},
     {{v2_access_point_name, 0},				mandatory},
     {{v2_selection_mode, 0},					conditional},
     {{v2_pdn_type, 0},						conditional},
     {{v2_pdn_address_allocation, 0},				conditional},
     {{v2_apn_restriction, 0},					conditional},
     {{v2_aggregate_maximum_bit_rate, 0},			conditional},
     {{v2_protocol_configuration_options, 0},			optional},
     {{v2_bearer_context, 0},					mandatory},
     {{v2_bearer_context, 1},					conditional},
     {{v2_trace_information, 0},				conditional},
     {{v2_fully_qualified_pdn_connection_set_identifier, 0},	conditional},
     {{v2_fully_qualified_pdn_connection_set_identifier, 1},	conditional},
     {{v2_ue_time_zone, 0},					conditional},
     {{v2_charging_characteristics, 0},				conditional},
     {{v2_local_distinguished_name, 1},				optional},
     {{v2_signalling_priority_indication, 0},			conditional},
     {{v2_ip_address, 1},					optional},
     {{v2_ip_address, 2},					optional}];
request_spec(delete_session_request) ->
    [{{v2_cause, 0},						conditional},
     {{v2_eps_bearer_id, 0},					conditional},
     {{v2_user_location_information, 0},			conditional},
     {{v2_indication, 0},					conditional},
     {{v2_protocol_configuration_options, 0},			conditional},
     {{v2_fully_qualified_tunnel_endpoint_identifier, 0},	optional},
     {{v2_ue_time_zone, 0},					conditional},
     {{v2_uli_timestamp, 0},					conditional}];
request_spec(modify_bearer_request) ->
    [{{v2_mobile_equipment_identity, 0},			conditional},
     {{v2_user_location_information, 0},			conditional},
     {{v2_serving_network, 0},					optional},
     {{v2_rat_type, 0},						mandatory},
     {{v2_indication, 0},					optional},
     {{v2_fully_qualified_tunnel_endpoint_identifier, 0},	conditional},
     {{v2_bearer_context, 0},					conditional},
     {{v2_bearer_context, 1},					conditional},
     {{v2_ue_time_zone, 0},					conditional},
     {{v2_fully_qualified_pdn_connection_set_identifier, 0},	conditional},
     {{v2_fully_qualified_pdn_connection_set_identifier, 1},	conditional},
     {{v2_user_csg_information, 0},				conditional},
     {{v2_local_distinguished_name, 1},				optional},
     {{v2_ip_address, 0},					conditional},
     {{v2_port_number, 0},					conditional},
     {{v2_ip_address, 2},					optional},
     {{v2_presence_reporting_area_information, 0},		conditional}];
request_spec(_) ->
    [].

init(_Opts, State) ->
    {ok, State}.

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

handle_request(_From, _Msg, _Req, true, State) ->
%% resent request
    {noreply, State};

handle_request(_From,
	       #gtp{type = create_session_request, ie = IEs}, Req, _Resent,
	       #{tei := LocalTEI, gtp_port := GtpPort} = State0) ->

    #create_session_request{
       sender_f_teid_for_control_plane =
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      key  = RemoteCntlTEI,
	      ipv4 = RemoteCntlIP},
       paa = PAA,
       bearer_context_to_be_created =
	   #v2_bearer_context{group = BearerCreate}
      } = Req,

    #v2_fully_qualified_tunnel_endpoint_identifier{instance = 2,
						   interface_type = 4,                  %% S5/S8 SGW GTP-U Interface
						   key = RemoteDataTEI,
						   ipv4 = RemoteDataIP} =
	lists:keyfind(v2_fully_qualified_tunnel_endpoint_identifier, 1, BearerCreate),
    EBI = lists:keyfind(v2_eps_bearer_id, 1, BearerCreate),

    {ReqMSv4, ReqMSv6} = pdn_alloc(PAA),

    {ok, MSv4, MSv6} = pdn_alloc_ip(LocalTEI, ReqMSv4, ReqMSv6, State0),
    Context = #context{
		 version            = v2,
		 control_interface  = ?MODULE,
		 control_port       = GtpPort,
		 local_control_tei  = LocalTEI,
		 remote_control_ip  = gtp_c_lib:bin2ip(RemoteCntlIP),
		 remote_control_tei = RemoteCntlTEI,
		 data_port          = GtpPort,
		 local_data_tei     = LocalTEI,
		 remote_data_ip     = gtp_c_lib:bin2ip(RemoteDataIP),
		 remote_data_tei    = RemoteDataTEI,
		 ms_v4              = MSv4,
		 ms_v6              = MSv6},
    State1 = State0#{context => Context},

    {ok, NewPeer} = gtp_v2_c:handle_sgsn(IEs, Context),
    lager:debug("New: ~p", [NewPeer]),
    ok = gtp_context:setup(Context),

    #gtp_port{ip = LocalIP} = GtpPort,

    ResponseIEs = [#v2_cause{v2_cause = request_accepted},
		   #v2_fully_qualified_tunnel_endpoint_identifier{
		      instance = 1,
		      interface_type = 7,          %% S5/S8 PGW GTP-C Interface
		      key = LocalTEI,
		      ipv4 = gtp_c_lib:ip2bin(LocalIP)
		     },
		   encode_paa(MSv4, MSv6),
		   %% #v2_protocol_configuration_options{config = {0,
		   %% 						[{ipcp,'CP-Configure-Ack',0,
		   %% 						  [{ms_dns1,<<8,8,8,8>>},{ms_dns2,<<0,0,0,0>>}]}]}},
		   #v2_bearer_context{group=[#v2_cause{v2_cause = request_accepted},
					     EBI,
					     #v2_apn_restriction{restriction_type_value = 0},
					     #v2_bearer_level_quality_of_service{pl=15,
										 pvi=0,
										 label=9,maximum_bit_rate_for_uplink=0,
										 maximum_bit_rate_for_downlink=0,
										 guaranteed_bit_rate_for_uplink=0,
										 guaranteed_bit_rate_for_downlink=0,
										 data = <<0,0,0,0>>},
					     #v2_fully_qualified_tunnel_endpoint_identifier{instance = 5,                  %% S5/S8 F-TEI Instance
											    interface_type = 5,            %% S5/S8 PGW GTP-U Interface
											    key = LocalTEI,
											    ipv4 = gtp_c_lib:ip2bin(LocalIP)}]}
		   | gtp_v2_c:build_recovery(GtpPort, NewPeer)],
    Response = {create_session_response, RemoteCntlTEI, ResponseIEs},
    {ok, Response, State1};

handle_request(_From,
	       #gtp{type = modify_bearer_request, tei = LocalTEI, ie = IEs}, Req, _Resent,
	       #{gtp_port := GtpPort, context := OldContext} = State0) ->

    #modify_bearer_request{
       sender_f_teid_for_control_plane =
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      key  = RemoteCntlTEI,
	      ipv4 = RemoteCntlIP},
       bearer_context_to_be_modified =
	   #v2_bearer_context{group = BearerCreate}
      } = Req,

    #v2_fully_qualified_tunnel_endpoint_identifier{instance = 2,
						   interface_type = 4,                  %% S5/S8 SGW GTP-U Interface
						   key = RemoteDataTEI,
						   ipv4 = RemoteDataIP} =
	lists:keyfind(v2_fully_qualified_tunnel_endpoint_identifier, 1, BearerCreate),
    EBI = lists:keyfind(v2_eps_bearer_id, 1, BearerCreate),

    Context = OldContext#context{
		   remote_control_ip  = gtp_c_lib:bin2ip(RemoteCntlIP),
		   remote_control_tei = RemoteCntlTEI,
		   remote_data_ip     = gtp_c_lib:bin2ip(RemoteDataIP),
		   remote_data_tei    = RemoteDataTEI},

    State1 = if Context /= OldContext ->
		     apply_context_change(Context, OldContext, State0);
		true ->
		     State0
	     end,

    {ok, NewPeer} = gtp_v2_c:handle_sgsn(IEs, Context),
    lager:debug("New: ~p, ~p", [NewPeer]),

    #gtp_port{ip = LocalIP} = GtpPort,

    ResponseIEs = [#v2_cause{v2_cause = request_accepted},
		   #v2_bearer_context{group=[#v2_cause{v2_cause = request_accepted},
					     EBI,
					     #v2_fully_qualified_tunnel_endpoint_identifier{instance = 5,                  %% S5/S8 F-TEI Instance
											    interface_type = 5,            %% S5/S8 PGW GTP-U Interface
											    key = LocalTEI,
											    ipv4 = gtp_c_lib:ip2bin(LocalIP)}]}
		   | gtp_v2_c:build_recovery(GtpPort, NewPeer)],
    Response = {modify_bearer_response, RemoteCntlTEI, ResponseIEs},
    {ok, Response, State1};

handle_request(_From,
	       #gtp{type = delete_session_request}, Req, _Resent,
	       #{context := Context} = State0) ->

    #delete_session_request{
       %% according to 3GPP TS 29.274, the F-TEID is not part of the Delete Session Request
       %% on S2a. However, Cisco iWAG on CSR 1000v does include it. Since we get it, lets
       %% validate it for now.
       sender_f_teid_for_control_plane = FqTEI
      } = Req,

    #context{remote_control_tei = RemoteCntlTEI} = Context,

    Result =
	do([error_m ||
	       match_context(35, Context, FqTEI),
	       pdn_release_ip(Context, State0),
	       gtp_context:teardown(Context),
	       return({RemoteCntlTEI, request_accepted, State0})
	   ]),

    case Result of
	{ok, {ReplyTEI, ReplyIEs, State}} ->
	    Reply = {delete_session_response, ReplyTEI, ReplyIEs},
	    {stop, Reply, State};

	{error, {ReplyTEI, ReplyIEs}} ->
	    Response = {delete_session_response, ReplyTEI, ReplyIEs},
	    {reply, Response, State0};

	{error, ReplyIEs} ->
	    Response = {delete_session_response, 0, ReplyIEs},
	    {reply, Response, State0}
    end;

handle_request(_From, _Msg, _Req, _Resent, State) ->
    {noreply, State}.

%%%===================================================================
%%% Helper functions
%%%===================================================================
ip2prefix({IP, Prefix}) ->
    <<Prefix:8, (gtp_c_lib:ip2bin(IP))/binary>>.

match_context(_Type, _Context, undefined) ->
    error_m:return(ok);
match_context(Type,
	      #context{
		 remote_control_ip  = RemoteCntlIP,
		 remote_control_tei = RemoteCntlTEI},
	      #v2_fully_qualified_tunnel_endpoint_identifier{instance       = 0,
							     interface_type = Type,
							     key            = RemoteCntlTEI,
							     ipv4           = RemoteCntlIP}) ->
    error_m:return(ok);
match_context(Type, Context, IE) ->
    lager:error("match_context: context not found, ~p, ~p, ~p", [Type, Context, lager:pr(IE, ?MODULE)]),
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

encode_paa(IPv4, undefined) ->
    encode_paa(ipv4, gtp_c_lib:ip2bin(IPv4), <<>>);
encode_paa(undefined, IPv6) ->
    encode_paa(ipv6, <<>>, ip2prefix(IPv6));
encode_paa(IPv4, IPv6) ->
    encode_paa(ipv4v6, gtp_c_lib:ip2bin(IPv4), ip2prefix(IPv6)).

encode_paa(Type, IPv4, IPv6) ->
    #v2_pdn_address_allocation{type = Type, address = <<IPv6/binary, IPv4/binary>>}.

pdn_alloc_ip(TEI, IPv4, IPv6, #{gtp_port := GtpPort}) ->
    apn:allocate_pdp_ip(GtpPort, TEI, IPv4, IPv6).

pdn_release_ip(#context{ms_v4 = MSv4, ms_v6 = MSv6}, #{gtp_port := GtpPort}) ->
    apn:release_pdp_ip(GtpPort, MSv4, MSv6).

apply_context_change(NewContext, OldContext, State) ->
    ok = gtp_context:update(NewContext, OldContext),
    State#{context => NewContext}.
