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
	 choose_context_ip/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% Sx DP API
%%%===================================================================

create_sgi_session(Candidates, Ctx0) ->
    Ctx1 = ergw_sx_node:select_sx_node(Candidates, Ctx0),
    {ok, NWIs} = ergw_sx_node:get_network_instances(Ctx1),
    Ctx = assign_data_teid(Ctx1, get_context_nwi(Ctx1, NWIs)),
    SEID = ergw_sx_socket:seid(),
    {ok, #node{node = _Node, ip = IP}, _} = ergw_sx_socket:id(),

    IEs =
	[f_seid(SEID, IP)] ++
	lists:foldl(fun create_pdr/2, [], [{1, gtp, Ctx}, {2, sgi, Ctx}]) ++
	lists:foldl(fun create_far/2, [], [{2, gtp, Ctx}, {1, sgi, Ctx}]) ++
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
	lists:foldl(fun update_pdr/2, [], [{1, gtp, Ctx, OldCtx}, {2, sgi, Ctx, OldCtx}]) ++
	lists:foldl(fun update_far/2, [], [{2, gtp, Ctx, OldCtx}, {1, sgi, Ctx, OldCtx}]),
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

ue_ip_address(Direction, #context{ms_v4 = {MSv4,_}, ms_v6 = {MSv6,_}}) ->
    #ue_ip_address{type = Direction, ipv4 = gtp_c_lib:ip2bin(MSv4),
		   ipv6 = gtp_c_lib:ip2bin(MSv6)};
ue_ip_address(Direction, #context{ms_v4 = {MSv4,_}}) ->
    #ue_ip_address{type = Direction, ipv4 = gtp_c_lib:ip2bin(MSv4)};
ue_ip_address(Direction, #context{ms_v6 = {MSv6,_}}) ->
    #ue_ip_address{type = Direction, ipv6 = gtp_c_lib:ip2bin(MSv6)}.

network_instance(Name) when is_atom(Name) ->
    #network_instance{instance = [atom_to_binary(Name, latin1)]};
network_instance(#gtp_port{network_instance = Name}) ->
    #network_instance{instance = Name}.

f_seid(SEID, {_,_,_,_} = IP) ->
    #f_seid{seid = SEID, ipv4 = gtp_c_lib:ip2bin(IP)};
f_seid(SEID, {_,_,_,_,_,_,_,_} = IP) ->
    #f_seid{seid = SEID, ipv6 = gtp_c_lib:ip2bin(IP)}.

f_teid(TEID, {_,_,_,_} = IP) ->
    #f_teid{teid = TEID, ipv4 = gtp_c_lib:ip2bin(IP)};
f_teid(TEID, {_,_,_,_,_,_,_,_} = IP) ->
    #f_teid{teid = TEID, ipv6 = gtp_c_lib:ip2bin(IP)}.

gtp_u_peer(TEID, {_,_,_,_} = IP) ->
    #outer_header_creation{type = 'GTP-U', teid = TEID, ipv4 = gtp_c_lib:ip2bin(IP)};
gtp_u_peer(TEID,  {_,_,_,_,_,_,_,_} = IP) ->
    #outer_header_creation{type = 'GTP-U', teid = TEID, ipv6 = gtp_c_lib:ip2bin(IP)}.

outer_header_removal({_,_,_,_}) ->
    #outer_header_removal{header = 'GTP-U/UDP/IPv4'};
outer_header_removal({_,_,_,_,_,_,_,_}) ->
    #outer_header_removal{header = 'GTP-U/UDP/IPv6'}.

create_pdr({RuleId, gtp,
	    #context{
	       data_port = #gtp_port{ip = IP} = DataPort,
	       local_data_tei = LocalTEI} = Ctx},
	   PDRs) ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'Access'},
		  network_instance(DataPort),
		  f_teid(LocalTEI, IP),
		  ue_ip_address(src, Ctx)]
	    },
    PDR = #create_pdr{
	     group =
		 [#pdr_id{id = RuleId},
		  #precedence{precedence = 100},
		  PDI,
		  outer_header_removal(IP),
		  #far_id{id = RuleId},
		  #urr_id{id = 1}]
	    },
    [PDR | PDRs];

create_pdr({RuleId, sgi, #context{vrf = InPortName} = Ctx}, PDRs) ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'SGi-LAN'},
		  network_instance(InPortName),
		  ue_ip_address(dst, Ctx)]
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

create_far({RuleId, gtp,
	    #context{
	       data_port = DataPort,
	       remote_data_ip = PeerIP,
	       remote_data_tei = RemoteTEI}},
	   FARs)
  when PeerIP /= undefined ->
    FAR = #create_far{
	     group =
		 [#far_id{id = RuleId},
		  #apply_action{forw = 1},
		  #forwarding_parameters{
		     group =
			 [#destination_interface{interface = 'Access'},
			  network_instance(DataPort),
			  gtp_u_peer(RemoteTEI, PeerIP)
			 ]
		    }
		 ]
	    },
    [FAR | FARs];

create_far({RuleId, sgi, #context{vrf = VRF}}, FARs) ->
    FAR = #create_far{
	     group =
		 [#far_id{id = RuleId},
		  #apply_action{forw = 1},
		  #forwarding_parameters{
		     group =
			 [#destination_interface{interface = 'SGi-LAN'},
			  network_instance(VRF)]
		    }
		 ]
	    },
    [FAR | FARs];

create_far({_RuleId, _Intf, _Out}, FARs) ->
    FARs.

update_pdr({RuleId, gtp,
	    #context{data_port = #gtp_port{name = InPortName, ip = IP} = DataPort,
		     local_data_tei = LocalTEI},
	    #context{data_port = #gtp_port{name = OldInPortName},
		     local_data_tei = OldLocalTEI}},
	   PDRs)
  when OldInPortName /= InPortName;
       OldLocalTEI /= LocalTEI ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'Core'},
		  network_instance(DataPort),
		  f_teid(LocalTEI, IP)]
	    },
    PDR = #update_pdr{
	     group =
		 [#pdr_id{id = RuleId},
		  #precedence{precedence = 100},
		  PDI,
		  outer_header_removal(IP),
		  #far_id{id = RuleId},
		  #urr_id{id = 1}]
	    },
    [PDR | PDRs];

update_pdr({RuleId, sgi,
	    #context{vrf = InPortName, ms_v4 = MSv4, ms_v6 = MSv6} = Ctx,
	    #context{vrf = OldInPortName, ms_v4 = OldMSv4, ms_v6 = OldMSv6}},
	   PDRs)
  when OldInPortName /= InPortName;
       OldMSv4 /= MSv4;
       OldMSv6 /= MSv6 ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'SGi-LAN'},
		  network_instance(InPortName),
		  ue_ip_address(dst, Ctx)]
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

update_far({RuleId, gtp,
	    #context{remote_data_ip = PeerIP} = Context,
	    #context{remote_data_ip = OldPeerIP}},
	   FARs)
  when (OldPeerIP =:= undefined andalso PeerIP /= undefined) ->
    create_far({RuleId, gtp, Context}, FARs);

update_far({RuleId, gtp,
	    #context{version = Version,
		     data_port = #gtp_port{name = OutPortName} = DataPort,
		     remote_data_ip = PeerIP,
		     remote_data_tei = RemoteTEI},
	    #context{version = OldVersion,
		     data_port = #gtp_port{name = OldOutPortName},
		     remote_data_ip = OldPeerIP,
		     remote_data_tei = OldRemoteTEI}},
	   FARs)
  when OldOutPortName /= OutPortName;
       OldPeerIP /= PeerIP;
       OldRemoteTEI /= RemoteTEI ->
    FAR = #update_far{
	     group =
		 [#far_id{id = RuleId},
		  #apply_action{forw = 1},
		  #update_forwarding_parameters{
		     group =
			 [#destination_interface{interface = 'Core'},
			  network_instance(DataPort),
			  gtp_u_peer(RemoteTEI, PeerIP)
			  | [#sxsmreq_flags{sndem = 1} ||
				v2 =:= Version andalso v2 =:= OldVersion]
			 ]
		    }
		 ]
	    },
    [FAR | FARs];

update_far({RuleId, sgi,
	    #context{vrf = OutPortName},
	    #context{vrf = OldOutPortName}},
	   FARs)
  when OldOutPortName /= OutPortName ->
    FAR = #update_far{
	     group =
		 [#far_id{id = RuleId},
		  #apply_action{forw = 1},
		  #update_forwarding_parameters{
		     group =
			 [#destination_interface{interface = 'SGi-LAN'},
			  network_instance(OutPortName)]
		    }
		 ]
	    },
    [FAR | FARs];

update_far({_RuleId, _Type, _Out, _OldOut}, FARs) ->
    FARs.

get_context_nwi(#context{control_port = #gtp_port{name = Name}}, NWIs) ->
    maps:get(Name, NWIs).

%% use additional information from the Context to prefre V4 or V6....
choose_context_ip(IP4, _IP6, _Context)
  when is_binary(IP4) ->
    IP4;
choose_context_ip(_IP4, IP6, _Context)
  when is_binary(IP6) ->
    IP6.

assign_data_teid(#context{data_port = DataPort} = Context,
		 #user_plane_ip_resource_information{
		    ipv4 = IP4, ipv6 = IP6, network_instance = NWInst}) ->
    {ok, DataTEI} = gtp_context_reg:alloc_tei(DataPort),
    IP = choose_context_ip(IP4, IP6, Context),
    Context#context{
      data_port = DataPort#gtp_port{ip = gtp_c_lib:bin2ip(IP), network_instance = NWInst},
      local_data_tei = DataTEI
     }.
