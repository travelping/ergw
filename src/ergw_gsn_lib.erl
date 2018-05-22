%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gsn_lib).

-export([create_sgi_session/2,
	 modify_sgi_session/2,
	 delete_sgi_session/1,
	 query_usage_report/1,
	 send_sx_response/3,
	 choose_context_ip/3,
	 ip_pdu/2]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% Sx DP API
%%%===================================================================

create_sgi_session(Candidates, Ctx0) ->
    Ctx1 = ergw_sx_node:select_sx_node(Candidates, Ctx0),
    Ctx = ergw_pfcp:assign_data_teid(Ctx1, control),
    SEID = ergw_sx_socket:seid(),
    {ok, #node{node = _Node, ip = IP}, _} = ergw_sx_socket:id(),

    IEs =
	[ergw_pfcp:f_seid(SEID, IP),
	 create_dp_to_cp_far(access, 1000, Ctx)] ++
	lists:foldl(fun create_pdr/2, [], [{1, 'Access', Ctx}, {2, 'SGi-LAN', Ctx}]) ++
	lists:foldl(fun create_far/2, [], [{2, 'Access', Ctx}, {1, 'SGi-LAN', Ctx}]) ++
	[create_ipv6_mcast_pdr(1000, 1000, Ctx) || Ctx#context.ms_v6 /= undefined] ++
	[#create_urr{group =
			 [#urr_id{id = 1}, #measurement_method{volum = 1}]}],
    Req = #pfcp{version = v1, type = session_establishment_request, seid = 0, ie = IEs},
    case ergw_sx_node:call(Ctx, Req) of
	#pfcp{version = v1, type = session_establishment_response,
	      %% seid = SEID, TODO: fix DP
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'},
		     f_seid := #f_seid{seid = DataPathSEID}} = _RespIEs} ->
	    Ctx#context{cp_seid = SEID, dp_seid = DataPathSEID};
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, Ctx))
    end.

modify_sgi_session(#context{dp_seid = SEID} = Ctx, OldCtx) ->
    IEs =
	lists:foldl(fun update_pdr/2, [], [{1, 'Access', Ctx, OldCtx}, {2, 'SGi-LAN', Ctx, OldCtx}]) ++
	lists:foldl(fun update_far/2, [], [{2, 'Access', Ctx, OldCtx}, {1, 'SGi-LAN', Ctx, OldCtx}]),
    Req = #pfcp{version = v1, type = session_modification_request, seid = SEID, ie = IEs},

    case ergw_sx_node:call(Ctx, Req) of
	#pfcp{version = v1, type = session_modification_response,
	      %% seid = SEID, TODO: fix DP
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} = _RespIEs} ->
	    Ctx;
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, Ctx))
    end.

delete_sgi_session(#context{dp_seid = SEID} = Ctx) ->
    Req = #pfcp{version = v1, type = session_deletion_request, seid = SEID, ie = []},
    ergw_sx_node:call(Ctx, Req).

query_usage_report(#context{dp_seid = SEID} = Ctx) ->
    IEs = [#query_urr{group = [#urr_id{id = 1}]}],
    Req = #pfcp{version = v1, type = session_modification_request,
		seid = SEID, ie = IEs},
    ergw_sx_node:call(Ctx, Req).

send_sx_response(ReqKey, #context{dp_seid = SEID}, Msg) ->
    ergw_sx_socket:send_response(ReqKey, Msg#pfcp{seid = SEID}, true).

%%%===================================================================
%%% Helper functions
%%%===================================================================

create_ipv6_mcast_pdr(PdrId, FarId,
		      #context{
			 data_port = #gtp_port{ip = IP} = DataPort,
			 local_data_tei = LocalTEI}) ->
    #create_pdr{
       group =
	   [#pdr_id{id = PdrId},
	    #precedence{precedence = 100},
	    #pdi{
	       group =
		   [#source_interface{interface = 'Access'},
		    ergw_pfcp:network_instance(DataPort),
		    ergw_pfcp:f_teid(LocalTEI, IP),
		    #sdf_filter{
		       flow_description =
			   <<"permit out 58 from any to ff00::/8">>}
		   ]},
	    #far_id{id = FarId},
	    #urr_id{id = 1}]
      }.

create_dp_to_cp_far(access, FarId,
		    #context{cp_port = #gtp_port{ip = CpIP} = CpPort, cp_tei = CpTEI}) ->
    #create_far{
       group =
	   [#far_id{id = FarId},
	    #apply_action{forw = 1},
	    #forwarding_parameters{
	       group =
		   [#destination_interface{interface = 'CP-function'},
		    ergw_pfcp:network_instance(CpPort),
		    ergw_pfcp:outer_header_creation(#fq_teid{ip = CpIP, teid = CpTEI})
		   ]
	      }
	   ]
      }.

create_pdr({RuleId, 'Access',
	    #context{
	       data_port = #gtp_port{ip = IP} = DataPort,
	       local_data_tei = LocalTEI} = Ctx},
	   PDRs) ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'Access'},
		  ergw_pfcp:network_instance(DataPort),
		  ergw_pfcp:f_teid(LocalTEI, IP),
		  ergw_pfcp:ue_ip_address(src, Ctx)]
	    },
    PDR = #create_pdr{
	     group =
		 [#pdr_id{id = RuleId},
		  #precedence{precedence = 100},
		  PDI,
		  ergw_pfcp:outer_header_removal(IP),
		  #far_id{id = RuleId},
		  #urr_id{id = 1}]
	    },
    [PDR | PDRs];

create_pdr({RuleId, 'SGi-LAN', Ctx}, PDRs) ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'SGi-LAN'},
		  ergw_pfcp:network_instance(Ctx),
		  ergw_pfcp:ue_ip_address(dst, Ctx)]
	     },
    PDR = #create_pdr{
	     group =
		 [#pdr_id{id = RuleId},
		  #precedence{precedence = 100},
		  PDI,
		  #far_id{id = RuleId},
		  #urr_id{id = 1}]
	    },
    [PDR | PDRs].

create_far({RuleId, 'Access',
	    #context{
	       data_port = DataPort,
	       remote_data_teid = PeerTEID}},
	   FARs)
  when PeerTEID /= undefined ->
    FAR = #create_far{
	     group =
		 [#far_id{id = RuleId},
		  #apply_action{forw = 1},
		  #forwarding_parameters{
		     group =
			 [#destination_interface{interface = 'Access'},
			  ergw_pfcp:network_instance(DataPort),
			  ergw_pfcp:outer_header_creation(PeerTEID)
			 ]
		    }
		 ]
	    },
    [FAR | FARs];

create_far({RuleId, 'SGi-LAN', Ctx}, FARs) ->
    FAR = #create_far{
	     group =
		 [#far_id{id = RuleId},
		  #apply_action{forw = 1},
		  #forwarding_parameters{
		     group =
			 [#destination_interface{interface = 'SGi-LAN'},
			  ergw_pfcp:network_instance(Ctx)]
		    }
		 ]
	    },
    [FAR | FARs];

create_far({_RuleId, _Intf, _Out}, FARs) ->
    FARs.

update_pdr({RuleId, 'Access',
	    #context{data_port = #gtp_port{name = InPortName, ip = IP} = DataPort,
		     local_data_tei = LocalTEI},
	    #context{data_port = #gtp_port{name = OldInPortName},
		     local_data_tei = OldLocalTEI}},
	   PDRs)
  when OldInPortName /= InPortName;
       OldLocalTEI /= LocalTEI ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'Access'},
		  ergw_pfcp:network_instance(DataPort),
		  ergw_pfcp:f_teid(LocalTEI, IP)]
	    },
    PDR = #update_pdr{
	     group =
		 [#pdr_id{id = RuleId},
		  #precedence{precedence = 100},
		  PDI,
		  ergw_pfcp:outer_header_removal(IP),
		  #far_id{id = RuleId},
		  #urr_id{id = 1}]
	    },
    [PDR | PDRs];

update_pdr({RuleId, 'SGi-LAN',
	    #context{vrf = VRF, ms_v4 = MSv4, ms_v6 = MSv6} = Ctx,
	    #context{vrf = OldVRF, ms_v4 = OldMSv4, ms_v6 = OldMSv6}},
	   PDRs)
  when OldVRF /= VRF;
       OldMSv4 /= MSv4;
       OldMSv6 /= MSv6 ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'SGi-LAN'},
		  ergw_pfcp:network_instance(Ctx),
		  ergw_pfcp:ue_ip_address(dst, Ctx)]
	     },
    PDR = #update_pdr{
	     group =
		 [#pdr_id{id = RuleId},
		  #precedence{precedence = 100},
		  PDI,
		  #far_id{id = RuleId},
		  #urr_id{id = 1}]
	    },
    [PDR | PDRs];

update_pdr({_RuleId, _Type, _In, _OldIn}, PDRs) ->
    PDRs.

update_far({RuleId, 'Access',
	    #context{remote_data_teid = PeerTEID} = Context,
	    #context{remote_data_teid = OldPeerTEID}},
	   FARs)
  when (OldPeerTEID =:= undefined andalso PeerTEID /= undefined) ->
    create_far({RuleId, 'Access', Context}, FARs);

update_far({RuleId, 'Access',
	    #context{remote_data_teid = PeerTEID},
	    #context{remote_data_teid = OldPeerTEID} = Context},
	   FARs)
  when (OldPeerTEID /= undefined andalso PeerTEID =:= undefined) ->
    remove_far({RuleId, 'Access', Context}, FARs);

update_far({RuleId, 'Access',
	    #context{version = Version,
		     data_port = #gtp_port{name = OutPortName} = DataPort,
		     remote_data_teid = PeerTEID},
	    #context{version = OldVersion,
		     data_port = #gtp_port{name = OldOutPortName},
		     remote_data_teid = OldPeerTEID}},
	   FARs)
  when OldOutPortName /= OutPortName;
       OldPeerTEID /= PeerTEID ->
    FAR = #update_far{
	     group =
		 [#far_id{id = RuleId},
		  #apply_action{forw = 1},
		  #update_forwarding_parameters{
		     group =
			 [#destination_interface{interface = 'Access'},
			  ergw_pfcp:network_instance(DataPort),
			  ergw_pfcp:outer_header_creation(PeerTEID)
			  | [#sxsmreq_flags{sndem = 1} ||
				v2 =:= Version andalso v2 =:= OldVersion]
			 ]
		    }
		 ]
	    },
    [FAR | FARs];

update_far({RuleId, 'SGi-LAN', #context{vrf = VRF} = Ctx, #context{vrf = OldVRF}}, FARs)
  when OldVRF /= VRF ->
    FAR = #update_far{
	     group =
		 [#far_id{id = RuleId},
		  #apply_action{forw = 1},
		  #update_forwarding_parameters{
		     group =
			 [#destination_interface{interface = 'SGi-LAN'},
			  ergw_pfcp:network_instance(Ctx)]
		    }
		 ]
	    },
    [FAR | FARs];

update_far({_RuleId, _Type, _Out, _OldOut}, FARs) ->
    FARs.

remove_far({RuleId, 'Access', #context{remote_data_teid = PeerTEID}}, FARs)
  when PeerTEID /= undefined ->
    [#remove_far{group = [#far_id{id = RuleId}]} | FARs];
remove_far({_RuleId, _Type, _Context}, FARs) ->
    FARs.

%% use additional information from the Context to prefre V4 or V6....
choose_context_ip(IP4, _IP6, _Context)
  when is_binary(IP4) ->
    IP4;
choose_context_ip(_IP4, IP6, _Context)
  when is_binary(IP6) ->
    IP6.

%%%===================================================================
%%% T-PDU functions
%%%===================================================================

-define('ICMPv6', 58).

-define('IPv6 All Nodes LL',   <<255,2,0,0,0,0,0,0,0,0,0,0,0,0,0,1>>).
-define('IPv6 All Routers LL', <<255,2,0,0,0,0,0,0,0,0,0,0,0,0,0,2>>).
-define('ICMPv6 Router Solicitation',  133).
-define('ICMPv6 Router Advertisement', 134).

-define(NULL_INTERFACE_ID, {0,0,0,0,0,0,0,0}).
-define('Our LL IP', <<254,128,0,0,0,0,0,0,0,0,0,0,0,0,0,2>>).

-define('RA Prefix Information', 3).
-define('RDNSS', 25).

%% ICMPv6
ip_pdu(<<6:4, TC:8, FlowLabel:20, Length:16, ?ICMPv6:8,
	     _HopLimit:8, SrcAddr:16/bytes, DstAddr:16/bytes,
	     PayLoad:Length/bytes, _/binary>>, Context) ->
    icmpv6(TC, FlowLabel, SrcAddr, DstAddr, PayLoad, Context);
ip_pdu(Data, _Context) ->
    lager:warning("unhandled T-PDU: ~p", [Data]),
    ok.

%% IPv6 Router Solicitation
icmpv6(TC, FlowLabel, _SrcAddr, ?'IPv6 All Routers LL',
       <<?'ICMPv6 Router Solicitation':8, _Code:8, _CSum:16, _/binary>>,
       #context{data_port = #gtp_port{ip = DpGtpIP, vrf = VRF},
		remote_data_teid = #fq_teid{ip = GtpIP, teid = TEID},
		ms_v6 = MSv6, dns_v6 = DNSv6} = Context) ->
    {Prefix, PLen} = ergw_inet:ipv6_interface_id(MSv6, ?NULL_INTERFACE_ID),

    OnLink = 1,
    AutoAddrCnf = 1,
    ValidLifeTime = 2592000,
    PreferredLifeTime = 604800,
    PrefixInformation = <<?'RA Prefix Information':8, 4:8,
			  PLen:8, OnLink:1, AutoAddrCnf:1, 0:6,
			  ValidLifeTime:32, PreferredLifeTime:32, 0:32,
			  (ergw_inet:ip2bin(Prefix))/binary>>,

    DNSCnt = length(DNSv6),
    DNSSrvOpt =
	if (DNSCnt /= 0) ->
		<<?'RDNSS', (1 + DNSCnt * 2):8, 0:16, 16#ffffffff:32,
		  << <<(ergw_inet:ip2bin(DNS))/binary>> || DNS <- DNSv6 >>/binary >>;
	   true ->
		<<>>
	end,

    TTL = 255,
    Managed = 0,
    OtherCnf = 0,
    LifeTime = 1800,
    ReachableTime = 0,
    RetransTime = 0,
    RAOpts = <<TTL:8, Managed:1, OtherCnf:1, 0:6, LifeTime:16,
	       ReachableTime:32, RetransTime:32,
	       PrefixInformation/binary,
	       DNSSrvOpt/binary>>,

    NwSrc = ?'Our LL IP',
    NwDst = ?'IPv6 All Nodes LL',
    ICMPLength = 4 + size(RAOpts),

    CSum = ergw_inet:ip_csum(<<NwSrc:16/bytes-unit:8, NwDst:16/bytes-unit:8,
				  ICMPLength:32, 0:24, ?ICMPv6:8,
				  ?'ICMPv6 Router Advertisement':8, 0:8, 0:16,
				  RAOpts/binary>>),
    ICMPv6 = <<6:4, TC:8, FlowLabel:20, ICMPLength:16, ?ICMPv6:8, TTL:8,
	       NwSrc:16/bytes, NwDst:16/bytes,
	       ?'ICMPv6 Router Advertisement':8, 0:8, CSum:16, RAOpts/binary>>,
    GTP = #gtp{version =v1, type = g_pdu, tei = TEID, ie = ICMPv6},
    PayLoad = gtp_packet:encode(GTP),
    UDP = ergw_inet:make_udp(
	    ergw_inet:ip2bin(DpGtpIP), ergw_inet:ip2bin(GtpIP),
	    ?GTP1u_PORT, ?GTP1u_PORT, PayLoad),
    ergw_sx_node:send(Context, 'Access', VRF, UDP),
    ok;

icmpv6(_TC, _FlowLabel, _SrcAddr, _DstAddr, _PayLoad, _Context) ->
    lager:warning("unhandeld ICMPv6 from ~p to ~p: ~p", [_SrcAddr, _DstAddr, _PayLoad]),
    ok.
