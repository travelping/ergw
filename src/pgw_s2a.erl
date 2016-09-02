%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s2a).

-behaviour(gtp_api).

-compile({parse_transform, do}).

-export([init/2, request_spec/1, handle_request/4]).

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
	  serving_network,
	  rat_type,
	  indication,
	  sender_f_teid_for_control_plane,
	  apn,
	  selection_mode,
	  paa,
	  apn_ambr,
	  trusted_wlan_mode_indication,
	  pco,
	  bearer_context_to_be_created,
	  bearer_context_to_be_removed,
	  trace_information,
	  twan_fq_csid,
	  ue_time_zone,
	  charging_characteristics,
	  twan_ldn,
	  apco,
	  twan_identifier,
	  additional_ies
	 }).

-record(delete_session_request, {
	  linked_eps_bearer_id,
	  pco,
	  sender_f_teid_for_control_plane,
	  ue_time_zone,
	  twan_identifier,
	  twan_identifier_timestamp
	 }).

request_spec(create_session_request) ->
    [{{v2_international_mobile_subscriber_identity, 0},		mandatory},
     {{v2_msisdn, 0},						conditional},
     {{v2_serving_network, 0},					optional},
     {{v2_rat_type, 0},						mandatory},
     {{v2_indication, 0},					optional},
     {{v2_fully_qualified_tunnel_endpoint_identifier, 0},	mandatory},
     {{v2_access_point_name, 0},				mandatory},
     {{v2_selection_mode, 0},					conditional},
     {{v2_pdn_address_allocation, 0},				conditional},
     {{v2_aggregate_maximum_bit_rate, 0},			conditional},
     {{v2_trusted_wlan_mode_indication, 0},			optional},
     {{v2_protocol_configuration_options, 0},			optional},
     {{v2_bearer_context, 0},					mandatory},
     {{v2_bearer_context, 1},					conditional},
     {{v2_trace_information, 0},				conditional},
     {{v2_fully_qualified_pdn_connection_set_identifier, 3},	mandatory},
     {{v2_ue_time_zone, 0},					mandatory},
     {{v2_charging_characteristics, 0},				conditional},
     {{v2_local_distinguished_name, 3},				optional},
     {{v2_additional_protocol_configuration_options, 0},	optional},
     {{v2_twan_identifier, 0},					optional}];
request_spec(delete_session_request) ->
    [{{v2_eps_bearer_id, 0},					conditional},
     {{v2_protocol_configuration_options, 0},			optional},
     {{v2_fully_qualified_tunnel_endpoint_identifier, 0},	optional},
     {{v2_ue_time_zone, 0},					conditional},
     {{v2_twan_identifier, 0},					optional},
     {{v2_twan_identifier_timestamp, 0},			optional}];
request_spec(_) ->
    [].

init(_Opts, State) ->
    {ok, State}.

handle_request(_SrcGtpPort,
	       #gtp{type = create_session_request, ie = IEs}, Req,
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

    #v2_fully_qualified_tunnel_endpoint_identifier{instance = 6,                  %% S2a TEI Instance
						   key = RemoteDataTEI,
						   ipv4 = RemoteDataIP} =
	lists:keyfind(v2_fully_qualified_tunnel_endpoint_identifier, 1, BearerCreate),

    {ReqMSv4, ReqMSv6} = pdn_alloc(PAA),

    {ok, MSv4, MSv6} = pdn_alloc_ip(LocalTEI, ReqMSv4, ReqMSv6, State0),
    Context = #context{
		 control_interface = ?MODULE,
		 control_tunnel    = gtp_v1_c,
		 control_ip        = gtp_c_lib:bin2ip(RemoteCntlIP),
		 control_tei       = RemoteCntlTEI,
		 data_tunnel       = gtp_v1_u,
		 data_ip           = gtp_c_lib:bin2ip(RemoteDataIP),
		 data_tei          = RemoteDataTEI,
		 ms_v4             = MSv4,
		 ms_v6             = MSv6},
    State1 = State0#{context => Context},

    {ok, NewPeer} = gtp_v2_c:handle_sgsn(IEs, Context, State1),
    lager:debug("New: ~p, ~p", [NewPeer]),
    ok = gtp_context:setup(Context, State1),

    #gtp_port{ip = LocalIP} = GtpPort,

    ResponseIEs = [#v2_cause{v2_cause = request_accepted},
		   #v2_fully_qualified_tunnel_endpoint_identifier{
		      instance = 1,
		      interface_type = 36,          %% S2a PGW GTP-C
		      key = LocalTEI,
		      ipv4 = gtp_c_lib:ip2bin(LocalIP)
		     },
		   encode_paa(MSv4, MSv6),
		   %% #v2_protocol_configuration_options{config = {0,
		   %% 						[{ipcp,'CP-Configure-Ack',0,
		   %% 						  [{ms_dns1,<<8,8,8,8>>},{ms_dns2,<<0,0,0,0>>}]}]}},
		   #v2_bearer_context{group=[#v2_cause{v2_cause = request_accepted},
					     #v2_eps_bearer_id{eps_bearer_id=15,data = <<>>},
					     #v2_bearer_level_quality_of_service{pl=15,
										 pvi=0,
										 label=9,maximum_bit_rate_for_uplink=0,
										 maximum_bit_rate_for_downlink=0,
										 guaranteed_bit_rate_for_uplink=0,
										 guaranteed_bit_rate_for_downlink=0,
										 data = <<0,0,0,0>>},
					     #v2_fully_qualified_tunnel_endpoint_identifier{instance = 5,                  %% S2a TEI Instance
											    interface_type = 37,           %% S2a PGW GTP-U
											    key = LocalTEI,
											    ipv4 = gtp_c_lib:ip2bin(LocalIP)}]}
		   | gtp_v2_c:build_recovery(GtpPort, NewPeer)],
    Response = {create_session_response, RemoteCntlTEI, ResponseIEs},
    {ok, Response, State1};

handle_request(_SrcGtpPort,
	       #gtp{type = delete_session_request, tei = LocalTEI}, Req,
	       #{gtp_port := GtpPort, context := Context} = State0) ->

    #delete_session_request{
       %% according to 3GPP TS 29.274, the F-TEID is not part of the Delete Session Request
       %% on S2a. However, Cisco iWAG on CSR 1000v does include it. Since we get it, lets
       %% validate it for now.
       sender_f_teid_for_control_plane = FqTEI
      } = Req,

    Result =
	do([error_m ||
	       {RemoteCntlTEI, MS, RemoteDataIP, RemoteDataTEI} <- match_context(35, Context, FqTEI),
	       pdn_release_ip(Context, State0),
	       gtp_dp:delete_pdp_context(GtpPort, 1, RemoteDataIP, MS, LocalTEI, RemoteDataTEI),
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

handle_request(_SrcGtpPort, _Msg, _Req, State) ->
    {noreply, State}.

%%%===================================================================
%%% Helper functions
%%%===================================================================
ip2prefix({IP, Prefix}) ->
    <<Prefix:8, (gtp_c_lib:ip2bin(IP))/binary>>.

match_context(_Type,
	      #context{
		 control_tei = RemoteCntlTEI,
		 data_ip     = RemoteDataIP,
		 data_tei    = RemoteDataTEI,
		 ms_v4       = MS},
	      undefined) ->
    error_m:return({RemoteCntlTEI, MS, RemoteDataIP, RemoteDataTEI});
match_context(Type,
	      #context{
		 control_ip  = RemoteCntlIP,
		 control_tei = RemoteCntlTEI,
		 data_ip     = RemoteDataIP,
		 data_tei    = RemoteDataTEI,
		 ms_v4       = MS},
	      #v2_fully_qualified_tunnel_endpoint_identifier{instance       = 0,
							     interface_type = Type,
							     key            = RemoteCntlTEI,
							     ipv4           = RemoteCntlIP}) ->
    error_m:return({RemoteCntlTEI, MS, RemoteDataIP, RemoteDataTEI});
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

