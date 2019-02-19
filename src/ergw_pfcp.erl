%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_pfcp).

-export([
	 f_seid/2,
	 f_teid/1, f_teid/2,
	 ue_ip_address/2,
	 network_instance/1,
	 outer_header_creation/1,
	 outer_header_removal/1,
	 ctx_teid_key/2,
	 assign_data_teid/2]).

-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% Helper functions
%%%===================================================================

ue_ip_address(Direction, #context{ms_v4 = {MSv4,_}, ms_v6 = {MSv6,_}}) ->
    #ue_ip_address{type = Direction, ipv4 = ergw_inet:ip2bin(MSv4),
		   ipv6 = ergw_inet:ip2bin(MSv6)};
ue_ip_address(Direction, #context{ms_v4 = {MSv4,_}}) ->
    #ue_ip_address{type = Direction, ipv4 = ergw_inet:ip2bin(MSv4)};
ue_ip_address(Direction, #context{ms_v6 = {MSv6,_}}) ->
    #ue_ip_address{type = Direction, ipv6 = ergw_inet:ip2bin(MSv6)}.

network_instance(Name)
  when is_binary(Name) ->
    #network_instance{instance = Name};
network_instance(#gtp_port{vrf = VRF}) ->
    network_instance(VRF);
network_instance(#gtp_endp{vrf = VRF}) ->
    network_instance(VRF);
network_instance(#context{vrf = VRF}) ->
    network_instance(VRF);
network_instance(#vrf{name = Name}) ->
    network_instance(Name).

f_seid(#pfcp_ctx{seid = #seid{cp = SEID}}, #node{ip = {_,_,_,_} = IP}) ->
   #f_seid{seid = SEID, ipv4 = ergw_inet:ip2bin(IP)};
f_seid(#pfcp_ctx{seid = #seid{cp = SEID}}, #node{ip = {_,_,_,_,_,_,_,_} = IP}) ->
    #f_seid{seid = SEID, ipv6 = ergw_inet:ip2bin(IP)}.

f_teid(#gtp_endp{ip = IP, teid = TEID}) ->
    f_teid(TEID, IP).

f_teid(TEID, {_,_,_,_} = IP) ->
    #f_teid{teid = TEID, ipv4 = ergw_inet:ip2bin(IP)};
f_teid(TEID, {_,_,_,_,_,_,_,_} = IP) ->
    #f_teid{teid = TEID, ipv6 = ergw_inet:ip2bin(IP)}.

outer_header_creation(#fq_teid{ip = {_,_,_,_} = IP, teid = TEID}) ->
    #outer_header_creation{type = 'GTP-U', teid = TEID, ipv4 = ergw_inet:ip2bin(IP)};
outer_header_creation(#fq_teid{ip = {_,_,_,_,_,_,_,_} = IP, teid = TEID}) ->
    #outer_header_creation{type = 'GTP-U', teid = TEID, ipv6 = ergw_inet:ip2bin(IP)}.

outer_header_removal(#gtp_endp{ip = IP}) ->
    outer_header_removal(IP);
outer_header_removal({_,_,_,_}) ->
    #outer_header_removal{header = 'GTP-U/UDP/IPv4'};
outer_header_removal({_,_,_,_,_,_,_,_}) ->
    #outer_header_removal{header = 'GTP-U/UDP/IPv6'}.

get_port_vrf(#gtp_port{vrf = VRF}, VRFs)
  when is_map(VRFs) ->
    maps:get(VRF, VRFs).

ctx_teid_key(#pfcp_ctx{name = Name}, TEI) ->
    {Name, {teid, 'gtp-u', TEI}}.

assign_data_teid(PCtx, #context{control_port = ControlPort} = Context) ->
    {ok, VRFs} = ergw_sx_node:get_vrfs(PCtx, Context),
    #vrf{name = Name, ipv4 = IP4, ipv6 = IP6} =
	get_port_vrf(ControlPort, VRFs),

    IP = ergw_gsn_lib:choose_context_ip(IP4, IP6, Context),
    {ok, DataTEI} = gtp_context_reg:alloc_tei(PCtx),
    Context#context{
      local_data_endp = #gtp_endp{vrf = Name, ip = ergw_inet:bin2ip(IP), teid = DataTEI}
     }.
