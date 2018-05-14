%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_pfcp).

-export([
	 f_seid/2,
	 f_teid/2,
	 ue_ip_address/2,
	 network_instance/1,
	 outer_header_creation/2,
	 outer_header_removal/1,
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

network_instance(Name) when is_atom(Name) ->
    #network_instance{instance = [atom_to_binary(Name, latin1)]};
network_instance([Label | _] = Instance) when is_binary(Label) ->
    #network_instance{instance = Instance};
network_instance(#gtp_port{network_instance = NetworkInstance}) ->
    network_instance(NetworkInstance).

f_seid(SEID, {_,_,_,_} = IP) ->
    #f_seid{seid = SEID, ipv4 = ergw_inet:ip2bin(IP)};
f_seid(SEID, {_,_,_,_,_,_,_,_} = IP) ->
    #f_seid{seid = SEID, ipv6 = ergw_inet:ip2bin(IP)}.

f_teid(TEID, {_,_,_,_} = IP) ->
    #f_teid{teid = TEID, ipv4 = ergw_inet:ip2bin(IP)};
f_teid(TEID, {_,_,_,_,_,_,_,_} = IP) ->
    #f_teid{teid = TEID, ipv6 = ergw_inet:ip2bin(IP)}.

outer_header_creation(TEID, {_,_,_,_} = IP) ->
    #outer_header_creation{type = 'GTP-U', teid = TEID, ipv4 = ergw_inet:ip2bin(IP)};
outer_header_creation(TEID,  {_,_,_,_,_,_,_,_} = IP) ->
    #outer_header_creation{type = 'GTP-U', teid = TEID, ipv6 = ergw_inet:ip2bin(IP)}.

outer_header_removal({_,_,_,_}) ->
    #outer_header_removal{header = 'GTP-U/UDP/IPv4'};
outer_header_removal({_,_,_,_,_,_,_,_}) ->
    #outer_header_removal{header = 'GTP-U/UDP/IPv6'}.

get_context_nwi(control, #context{control_port = #gtp_port{name = Name}}, NWIs) ->
    maps:get(Name, NWIs);
get_context_nwi(data, #context{data_port = #gtp_port{name = Name}}, NWIs) ->
    maps:get(Name, NWIs);
get_context_nwi(cp, #context{cp_port = #gtp_port{name = Name}}, NWIs) ->
    maps:get(Name, NWIs).

assign_data_teid(#context{data_port = DataPort} = Context, Type) ->

    {ok, NWIs} = ergw_sx_node:get_network_instances(Context),
    #nwi{name = Name, ipv4 = IP4, ipv6 = IP6} =
	get_context_nwi(Type, Context, NWIs),

    {ok, DataTEI} = gtp_context_reg:alloc_tei(DataPort),
    IP = ergw_gsn_lib:choose_context_ip(IP4, IP6, Context),
    Context#context{
      data_port = DataPort#gtp_port{ip = ergw_inet:bin2ip(IP), network_instance = Name},
      local_data_tei = DataTEI
     }.
