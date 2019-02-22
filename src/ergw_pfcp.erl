%% Copyright 2018,2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_pfcp).

-compile({parse_transform, cut}).

-export([
	 f_seid/2,
	 f_teid/1, f_teid/2,
	 ue_ip_address/2,
	 network_instance/1,
	 outer_header_creation/1,
	 outer_header_removal/1,
	 ctx_teid_key/2,
	 assign_data_teid/2,
	 update_pfcp_rules/3]).
-ifdef(TEST).
-export([pfcp_rule_diff/2]).
-endif.

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

%%%===================================================================
%%% Test Helper
%%%===================================================================

-ifdef(TEST).

pfcp_rule_diff(Old, New) when is_list(Old) ->
    pfcp_rule_diff(pfcp_packet:ies_to_map(Old), New);
pfcp_rule_diff(Old, New) when is_list(New) ->
    pfcp_rule_diff(Old, pfcp_packet:ies_to_map(New));
pfcp_rule_diff(Old, New) when is_map(Old), is_map(New) ->
    Add = maps:without(maps:keys(Old), New),
    Del = maps:without(maps:keys(New), Old),
    OldUpd0 = maps:without(maps:keys(Del), Old),
    NewUpd0 = maps:without(maps:keys(Add), New),
    Upd = pfcp_rule_diff(OldUpd0, maps:next(maps:iterator(NewUpd0)), #{}),
    ct:pal("PFCP Rule Diff~nAdd: ~120p~nDel: ~120p~nUpd: ~120p", [Add, Del, Upd]).

pfcp_rule_diff(_Old, none, Diff) ->
    Diff;
pfcp_rule_diff(Old, {K, V, Next}, Diff) ->
    pfcp_rule_diff(K, maps:get(K, Old), V, pfcp_rule_diff(Old, maps:next(Next), Diff)).

pfcp_rule_diff(_, V, V, Diff) ->
    Diff;
pfcp_rule_diff(K, Old, New, Diff)
  when is_list(Old), is_list(New) ->
    case {lists:sort(Old), lists:sort(New)} of
	{V, V} ->
	    Diff;
	{O, N} ->
	    Diff#{K => {upd, O, N}}
    end;
pfcp_rule_diff(K, Old, New, Diff) ->
    Diff#{K => {upd, Old, New}}.

-endif.

%%%===================================================================
%%% Translate PFCP state into Create/Modify/Delete rules
%%%===================================================================

update_pfcp_rules(#pfcp_ctx{sx_rules = Old}, #pfcp_ctx{sx_rules = New}, Opts) ->
    lager:debug("Update PFCP Rules Old: ~p", [lager:pr(Old, ?MODULE)]),
    lager:debug("Update PFCP Rules New: ~p", [lager:pr(New, ?MODULE)]),
    Del = maps:fold(fun del_pfcp_rules/3, #{}, maps:without(maps:keys(New), Old)),
    maps:fold(upd_pfcp_rules(_, _, Old, _, Opts), Del, New).

update_m_rec(Record, Map) when is_tuple(Record) ->
    maps:update_with(element(1, Record), [Record | _], [Record], Map).

put_rec(Record, Map) when is_tuple(Record) ->
    maps:put(element(1, Record), Record, Map).

del_pfcp_rules({pdr, _}, #{pdr_id := Id}, Acc) ->
    update_m_rec(#remove_pdr{group = [Id]}, Acc);
del_pfcp_rules({far, _}, #{far_id := Id}, Acc) ->
    update_m_rec(#remove_far{group = [Id]}, Acc);
del_pfcp_rules({urr, _}, #{urr_id := Id}, Acc) ->
    update_m_rec(#remove_urr{group = [Id]}, Acc).

upd_pfcp_rules({Type, _} = K, V, Old, Acc, Opts) ->
    upd_pfcp_rules_1(Type, V, maps:get(K, Old, undefined), Acc, Opts).

upd_pfcp_rules_1(pdr, V, undefined, Acc, _Opts) ->
    update_m_rec(#create_pdr{group = V}, Acc);
upd_pfcp_rules_1(far, V, undefined, Acc, _Opts) ->
    update_m_rec(#create_far{group = V}, Acc);
upd_pfcp_rules_1(urr, V, undefined, Acc, _Opts) ->
    update_m_rec(#create_urr{group = V}, Acc);

upd_pfcp_rules_1(_Type, V, V, Acc, _Opts) ->
    Acc;

upd_pfcp_rules_1(pdr, V, OldV, Acc, Opts) ->
    update_m_rec(#update_pdr{group = update_pfcp_pdr(V, OldV, Opts)}, Acc);
upd_pfcp_rules_1(far, V, OldV, Acc, Opts) ->
    update_m_rec(#update_far{group = update_pfcp_far(V, OldV, Opts)}, Acc);
upd_pfcp_rules_1(urr, V, _OldV, Acc, _Opts) ->
    update_m_rec(#update_urr{group = V}, Acc).

update_pfcp_simplify(New, Old)
  when is_map(Old), New =/= Old ->
    Added = maps:without(maps:keys(Old), New),
    maps:fold(fun(K, V, A) ->
		      case maps:get(K, New) of
			  V -> A;
			  NewV -> maps:put(K, NewV, A)
		      end
	      end, Added, Old);
update_pfcp_simplify(New, _Old) ->
    New.

%% TODO: predefined rules (activate/deactivate)
update_pfcp_pdr(#{pdr_id := Id} = New, Old, _Opts) ->
    Update = update_pfcp_simplify(New, Old),
    put_rec(Id, Update).

update_pfcp_far(#{far_id := Id} = New, Old, Opts) ->
    lager:debug("Update PFCP Far Old: ~p", [pfcp_packet:lager_pr(Old)]),
    lager:debug("Update PFCP Far New: ~p", [pfcp_packet:lager_pr(New)]),
    Update = update_pfcp_simplify(New, Old),
    lager:debug("Update PFCP Far Update: ~p", [pfcp_packet:lager_pr(Update)]),
    maps:fold(update_pfcp_far(_, _, Old, _, Opts), #{}, put_rec(Id, Update)).

update_pfcp_far(_, #forwarding_parameters{
		    group =
			#{destination_interface :=
			      #destination_interface{interface = Interface}} = New},
	      #{forwarding_parameters := #forwarding_parameters{group = Old}},
	      Far, Opts) ->
    lager:debug("Update PFCP Forward Old: ~p", [lager:pr(Old, ?MODULE)]),
    lager:debug("Update PFCP Forward P0: ~p", [lager:pr(New, ?MODULE)]),

    SendEM = maps:get(send_end_marker, Opts, false),
    Update0 = update_pfcp_simplify(New, Old),
    lager:debug("Update PFCP Forward Update: ~p", [lager:pr(Update0, ?MODULE)]),
    Update =
	case Update0 of
	    #{outer_header_creation := _}
	      when SendEM andalso (Interface == 'Access' orelse Interface == 'Core')->
		put_rec(#sxsmreq_flags{sndem = 1}, Update0);
	    _ ->
		Update0
	end,
    put_rec(#update_forwarding_parameters{group = Update}, Far);
update_pfcp_far(_, #forwarding_parameters{group = P}, _Old, Far, _Opts) ->
    put_rec(#update_forwarding_parameters{group = P}, Far);
update_pfcp_far(_, #duplicating_parameters{group = P}, _Old, Far, _Opts) ->
    put_rec(#update_duplicating_parameters{group = P}, Far);
update_pfcp_far(K, V, _Old, Far, _Opts) ->
    lager:debug("Update PFCP Far: ~p, ~p", [K, lager:pr(V, ?MODULE)]),
    Far#{K => V}.
