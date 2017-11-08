%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gsn_lib).

-export([create_sgi_session/1,
	 modify_sgi_session/2,
	 delete_sgi_session/1]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% Sx DP API
%%%===================================================================

create_sgi_session(#context{local_data_tei = SEID} = Ctx) ->
    Req = #{
      cp_f_seid  => SEID,
      create_pdr => lists:foldl(fun create_pdr/2, [],
				[{1, gtp, Ctx}, {2, sgi, Ctx}]),
      create_far => lists:foldl(fun create_far/2, [],
				[{2, gtp, Ctx}, {1, sgi, Ctx}])
     },
    ergw_sx:call(Ctx, session_establishment_request, Req).

modify_sgi_session(#context{local_data_tei = SEID} = Ctx, OldCtx) ->
    Req = #{
      cp_f_seid => SEID,
      update_pdr => lists:foldl(fun update_pdr/2, [],
				[{1, gtp, Ctx, OldCtx}, {2, sgi, Ctx, OldCtx}]),
      update_far => lists:foldl(fun update_far/2, [],
				[{2, gtp, Ctx, OldCtx}, {1, sgi, Ctx, OldCtx}])
     },
    ergw_sx:call(Ctx, session_modification_request, Req).

delete_sgi_session(Ctx) ->
    ergw_sx:call(Ctx, session_deletion_request, #{}).

%%%===================================================================
%%% Helper functions
%%%===================================================================

ue_ip_address(Direction, #context{ms_v4 = {MSv4,_}, ms_v6 = {MSv6,_}}) ->
    {Direction, MSv4, MSv6};
ue_ip_address(Direction, #context{ms_v4 = {MSv4,_}}) ->
    {Direction, MSv4};
ue_ip_address(Direction, #context{ms_v6 = {MSv6,_}}) ->
    {Direction, MSv6};
ue_ip_address(_, _) ->
    undefined.

create_pdr({RuleId, gtp,
	    #context{
	       data_port = #gtp_port{name = InPortName},
	       local_data_tei = LocalTEI}},
	   PDRs) ->
    PDI = #{
      source_interface => access,
      network_instance => InPortName,
      local_f_teid => #f_teid{teid = LocalTEI}
     },
    PDR = #{
      pdr_id => RuleId,
      precedence => 100,
      pdi => PDI,
      outer_header_removal => true,
      far_id => RuleId
     },
    [PDR | PDRs];

create_pdr({RuleId, sgi, #context{vrf = InPortName} = Ctx}, PDRs) ->
    PDI = #{
      source_interface => core,
      network_instance => InPortName,
      ue_ip_address => ue_ip_address(dst, Ctx)
     },
    PDR = #{
      pdr_id => RuleId,
      precedence => 100,
      pdi => PDI,
      outer_header_removal => false,
      far_id => RuleId
     },
    [PDR | PDRs].

create_far({RuleId, gtp,
	    #context{
	       data_port = #gtp_port{name = OutPortName},
	       remote_data_ip = PeerIP,
	       remote_data_tei = RemoteTEI}},
	   FARs) ->
    FAR = #{
      far_id => RuleId,
      apply_action => [forward],
      forwarding_parameters => #{
	destination_interface => access,
	network_instance => OutPortName,
	outer_header_creation => #f_teid{ipv4 = PeerIP, teid = RemoteTEI}
       }
     },
    [FAR | FARs];

create_far({RuleId, sgi, #context{vrf = OutPortName}}, FARs) ->
    FAR = #{
      far_id => RuleId,
      apply_action => [forward],
      forwarding_parameters => #{
	destination_interface => core,
	network_instance => OutPortName
       }
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
    PDI = #{
      source_interface => access,
      network_instance => InPortName,
      local_f_teid => #f_teid{teid = LocalTEI}
     },
    PDR = #{
      pdr_id => RuleId,
      precedence => 100,
      pdi => PDI,
      outer_header_removal => true,
      far_id => RuleId
     },
    [PDR | PDRs];

update_pdr({RuleId, sgi,
	    #context{vrf = InPortName, ms_v4 = MSv4, ms_v6 = MSv6} = Ctx,
	    #context{vrf = OldInPortName, ms_v4 = OldMSv4, ms_v6 = OldMSv6}},
	   PDRs)
  when OldInPortName /= InPortName;
       OldMSv4 /= MSv4;
       OldMSv6 /= MSv6 ->
    PDI = #{
      source_interface => core,
      network_instance => InPortName,
      ue_ip_address => ue_ip_address(dst, Ctx)
     },
    PDR = #{
      pdr_id => RuleId,
      precedence => 100,
      pdi => PDI,
      outer_header_removal => false,
      far_id => RuleId
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
    FAR0 = #{
      far_id => RuleId,
      apply_action => [forward],
      update_forwarding_parameters => #{
	destination_interface => access,
	network_instance => OutPortName,
	outer_header_creation => #f_teid{ipv4 = PeerIP, teid = RemoteTEI}
       }
     },
    FAR = if v2 =:= Version andalso
	     v2 =:= OldVersion ->
		  FAR0#{sxsmreq_flags => [sndem]};
	     true ->
		  FAR0
	  end,
    [FAR | FARs];

update_far({RuleId, sgi,
	    #context{vrf = OutPortName},
	    #context{vrf = OldOutPortName}},
	   FARs)
  when OldOutPortName /= OutPortName ->
    FAR = #{
      far_id => RuleId,
      apply_action => [forward],
      update_forwarding_parameters => #{
	destination_interface => core,
	network_instance => OutPortName
       }
     },
    [FAR | FARs];

update_far({_RuleId, _Type, _Out, _OldOut}, FARs) ->
    FARs.
