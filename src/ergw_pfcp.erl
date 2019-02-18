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
	 assign_data_teid/2]).
-export([init_ctx/1, reset_ctx/1, reset_ctx_timers/1,
	 get_id/2, get_id/3, update_pfcp_rules/3]).
-export([get_urr_id/4, get_urr_group/2,
	 get_urr_ids/1, get_urr_ids/2,
	 find_urr_by_id/2]).
-export([set_timer/3, apply_timers/2, timer_expired/2]).
-export([pfcp_rules_add/2]).

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
    #ue_ip_address{type = Direction, ipv6 = ergw_inet:ip2bin(MSv6)};

ue_ip_address(Direction, #tdf_ctx{ms_v4 = {MSv4,_}, ms_v6 = {MSv6,_}}) ->
    #ue_ip_address{type = Direction, ipv4 = ergw_inet:ip2bin(MSv4),
		   ipv6 = ergw_inet:ip2bin(MSv6)};
ue_ip_address(Direction, #tdf_ctx{ms_v4 = {MSv4,_}}) ->
    #ue_ip_address{type = Direction, ipv4 = ergw_inet:ip2bin(MSv4)};
ue_ip_address(Direction, #tdf_ctx{ms_v6 = {MSv6,_}}) ->
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
%%% Manage PFCP rules identifier
%%%===================================================================

init_ctx(PCtx) ->
    PCtx#pfcp_ctx{idcnt = #{}, idmap = #{}, urr_by_id = #{}, urr_by_grp = #{},
		  sx_rules = #{}, timers = #{}, timer_by_tref = #{}}.

reset_ctx(PCtx) ->
    PCtx#pfcp_ctx{urr_by_grp = #{}, sx_rules = #{}, timers = #{}, timer_by_tref = #{}}.

reset_ctx_timers(PCtx) ->
    PCtx#pfcp_ctx{timers = #{}, timer_by_tref = #{}}.

get_id(Keys, PCtx) ->
    lists:mapfoldr(fun({Type, Name}, P) -> get_id(Type, Name, P) end, PCtx, Keys).

get_id(Type, Name, #pfcp_ctx{idcnt = Cnt, idmap = IdMap} = PCtx) ->
    Key = {Type, Name},
    case IdMap of
	#{Key := Id} ->
	    {Id, PCtx};
	_ ->
	    Id = maps:get(Type, Cnt, 1),
	    {Id, PCtx#pfcp_ctx{idcnt = Cnt#{Type => Id + 1},
			       idmap = IdMap#{Key => Id}}}
    end.

get_urr_id(Key, Groups, Info, #pfcp_ctx{urr_by_id = M, urr_by_grp = Grp0} = PCtx0) ->
    {Id, PCtx1} = ergw_pfcp:get_id(urr, Key, PCtx0),
    UpdF = [Id|_],
    Grp = lists:foldl(maps:update_with(_, UpdF, [Id], _), Grp0, Groups),
    PCtx = PCtx1#pfcp_ctx{
	     urr_by_id  = M#{Id => Info},
	     urr_by_grp = Grp
	    },
    {Id, PCtx}.

get_urr_group(Group, #pfcp_ctx{urr_by_grp = Grp}) ->
    maps:get(Group, Grp, []).

get_urr_ids(#pfcp_ctx{urr_by_id = M}) ->
    M.

get_urr_ids(Names, #pfcp_ctx{idmap = IdMap}) ->
    lists:map(fun(N) -> maps:get({urr, N}, IdMap, undefined) end, Names).

find_urr_by_id(Id, #pfcp_ctx{urr_by_id = M}) ->
    maps:find(Id, M).

%%%===================================================================
%%% Timer handling
%%%===================================================================

set_timer(Time, Ev, #pfcp_ctx{timers = T0} = PCtx) ->
    T = maps:update_with(Time, fun({K, Evs}) -> {K, [Ev|Evs]} end, {undefined, [Ev]}, T0),
    PCtx#pfcp_ctx{timers = T}.

apply_timers(#pfcp_ctx{timers = Old}, #pfcp_ctx{timers = New} = PCtx) ->
    lager:debug("Update Timers Old: ~p", [Old]),
    lager:debug("Update Timers New: ~p", [New]),
    maps:map(fun del_timers/2, maps:without(maps:keys(New), Old)),
    maps:fold(fun upd_timers/3, reset_ctx_timers(PCtx), New).

del_timers(_, {TRef, _}) ->
    erlang:cancel_timer(TRef).

upd_timers(Time, {TRef0, Evs}, #pfcp_ctx{timers = Ts, timer_by_tref = Ids} = PCtx) ->
    TRef = if is_reference(TRef0) -> TRef0;
	      true -> erlang:start_timer(Time, self(), pfcp_timer, [{abs, true}])
	   end,
    PCtx#pfcp_ctx{
      timers = Ts#{Time => {TRef, Evs}},
      timer_by_tref = Ids#{TRef => Time}
     }.

timer_expired(TRef, #pfcp_ctx{timers = Ts, timer_by_tref = Ids} = PCtx0) ->
    case Ids of
	#{TRef := Time} ->
	    {_, Evs} = maps:get(Time, Ts, {undefined, []}),
	    PCtx = PCtx0#pfcp_ctx{
		     timers = maps:remove(Time, Ts),
		     timer_by_tref = maps:remove(TRef, Ids)},
	    {Evs, PCtx};
	_ ->
	    {[], PCtx0}
    end.

%%%===================================================================
%%% Manage PFCP rules in context
%%%===================================================================

pfcp_rules_add([], PCtx) ->
    PCtx;
pfcp_rules_add([{Type, Key, Rule}|T], #pfcp_ctx{sx_rules = Rules} = PCtx) ->
    pfcp_rules_add(T, PCtx#pfcp_ctx{
			sx_rules =
			    Rules#{{Type, Key} => pfcp_packet:ies_to_map(Rule)}}).

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
