%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gsn_lib).

-export([create_sgi_session/1,
	 modify_sgi_session/2,
	 delete_sgi_session/1,
	 query_usage_report/1]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% Sx DP API
%%%===================================================================

create_sgi_session(#context{local_data_tei = SEID} = Ctx) ->
    IEs =
	[#f_seid{seid = SEID}] ++
	lists:foldl(fun create_pdr/2, [], [{1, gtp, Ctx}, {2, sgi, Ctx}]) ++
	lists:foldl(fun create_far/2, [], [{2, gtp, Ctx}, {1, sgi, Ctx}]) ++
	[#create_urr{group =
			 [#urr_id{id = 1}, #measurement_method{volum = 1}]}],
    Req = #pfcp{version = v1, type = session_establishment_request, seid = 0, ie = IEs},
    case ergw_sx:call(Ctx, Req) of
	{ok, Pid} when is_pid(Pid) ->
	    Ctx#context{dp_pid = Pid};
	_ ->
	    Ctx
    end.

modify_sgi_session(#context{local_data_tei = SEID} = Ctx, OldCtx) ->
    IEs =
	lists:foldl(fun update_pdr/2, [], [{1, gtp, Ctx, OldCtx}, {2, sgi, Ctx, OldCtx}]) ++
	lists:foldl(fun update_far/2, [], [{2, gtp, Ctx, OldCtx}, {1, sgi, Ctx, OldCtx}]),
    Req = #pfcp{version = v1, type = session_modification_request, seid = SEID, ie = IEs},
    ergw_sx:call(Ctx, Req).

delete_sgi_session(#context{local_data_tei = SEID} = Ctx) ->
    Req = #pfcp{version = v1, type = session_deletion_request, seid = SEID, ie = []},
    ergw_sx:call(Ctx, Req).

query_usage_report(#context{local_data_tei = SEID} = Ctx) ->
    IEs = [#query_urr{group = [#urr_id{id = 1}]}],
    Req = #pfcp{version = v1, type = session_modification_request,
		seid = SEID, ie = IEs},
    ergw_sx:call(Ctx, Req).

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
    #network_instance{instance = [atom_to_binary(Name, latin1)]}.

create_pdr({RuleId, gtp,
	    #context{
	       data_port = #gtp_port{name = InPortName},
	       local_data_tei = LocalTEI}},
	   PDRs) ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'Access'},
		  network_instance(InPortName),
		  #f_teid{teid = LocalTEI}]
	    },
    PDR = #create_pdr{
	     group =
		 [#pdr_id{id = RuleId},
		  #precedence{precedence = 100},
		  PDI,
		  #outer_header_removal{header = 'GTP-U/UDP/IPv4'},
		  #far_id{id = RuleId},
		  #urr_id{id = 1}]
	    },
    [PDR | PDRs];

create_pdr({RuleId, sgi, #context{vrf = InPortName} = Ctx}, PDRs) ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'Core'},
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
	       data_port = #gtp_port{name = OutPortName},
	       remote_data_ip = PeerIP,
	       remote_data_tei = RemoteTEI}},
	   FARs) ->
    FAR = #create_far{
	     group =
		 [#far_id{id = RuleId},
		  #apply_action{forw = 1},
		  #forwarding_parameters{
		     group =
			 [#destination_interface{interface = 'Access'},
			  network_instance(OutPortName),
			  #outer_header_creation{
			     type = 'GTP-U/UDP/IPv4',
			     teid = RemoteTEI,
			     address = gtp_c_lib:ip2bin(PeerIP)
			    }
			 ]
		    }
		 ]
	    },
    [FAR | FARs];

create_far({RuleId, sgi, #context{vrf = OutPortName}}, FARs) ->
    FAR = #create_far{
	     group =
		 [#far_id{id = RuleId},
		  #apply_action{forw = 1},
		  #forwarding_parameters{
		     group =
			 [#destination_interface{interface = 'Core'},
			  network_instance(OutPortName)]
		    }
		 ]
	    },
    [FAR | FARs].

update_pdr({RuleId, gtp,
	    #context{data_port = #gtp_port{name = InPortName},
		     local_data_tei = LocalTEI},
	    #context{data_port = #gtp_port{name = OldInPortName},
		     local_data_tei = OldLocalTEI}},
	   PDRs)
  when OldInPortName /= InPortName;
       OldLocalTEI /= LocalTEI ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'Access'},
		  network_instance(InPortName),
		  #f_teid{teid = LocalTEI}]
	    },
    PDR = #update_pdr{
	     group =
		 [#pdr_id{id = RuleId},
		  #precedence{precedence = 100},
		  PDI,
		  #outer_header_removal{header = 'GTP-U/UDP/IPv4'},
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
		 [#source_interface{interface = 'Core'},
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
	    #context{version = Version,
		     data_port = #gtp_port{name = OutPortName},
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
			 [#destination_interface{interface = 'Access'},
			  network_instance(OutPortName),
			  #outer_header_creation{
			     type = 'GTP-U/UDP/IPv4',
			     teid = RemoteTEI,
			     address = gtp_c_lib:ip2bin(PeerIP)
			    }
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
			 [#destination_interface{interface = 'Core'},
			  network_instance(OutPortName)]
		    }
		 ]
	    },
    [FAR | FARs];

update_far({_RuleId, _Type, _Out, _OldOut}, FARs) ->
    FARs.
