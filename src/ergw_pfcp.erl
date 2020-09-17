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
	 assign_data_teid/3,
	 up_inactivity_timer/1]).
-export([init_ctx/1, reset_ctx/1,
	 get_id/2, get_id/3, update_pfcp_rules/3]).
-export([get_urr_id/4, get_urr_group/2,
	 get_urr_ids/1, get_urr_ids/2,
	 find_urr_by_id/2]).
-export([set_timer/3, apply_timers/2, timer_expired/2]).

-ifdef(TEST).
-export([pfcp_rule_diff/2]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% Helper functions
%%%===================================================================

alloc_info_addr(AI) ->
    ergw_inet:ip2bin(ergw_ip_pool:addr(AI)).

ue_ip_address(Direction, #context{ms_v4 = MSv4, ms_v6 = undefined})
  when MSv4 /= undefined ->
    #ue_ip_address{type = Direction, ipv4 = alloc_info_addr(MSv4)};
ue_ip_address(Direction, #context{ms_v4 = undefined, ms_v6 = MSv6})
  when MSv6 /= undefined ->
    #ue_ip_address{type = Direction, ipv6 = alloc_info_addr(MSv6)};
ue_ip_address(Direction, #context{ms_v4 = MSv4, ms_v6 = MSv6})
  when MSv4 /= undefined, MSv6 /= undefined ->
    #ue_ip_address{type = Direction, ipv4 = alloc_info_addr(MSv4),
		   ipv6 = alloc_info_addr(MSv6)};

ue_ip_address(Direction, #tdf_ctx{ms_v4 = MSv4}) when MSv4 /= undefined ->
    #ue_ip_address{type = Direction, ipv4 = alloc_info_addr(MSv4)};
ue_ip_address(Direction, #tdf_ctx{ms_v6 = MSv6}) when MSv6 /= undefined ->
    #ue_ip_address{type = Direction, ipv6 = alloc_info_addr(MSv6)}.

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

assign_data_teid(PCtx, {VRFs, _} = _NodeCaps,
		 #context{control_port = ControlPort} = Context) ->
    #vrf{name = Name, ipv4 = IP4, ipv6 = IP6} =
	get_port_vrf(ControlPort, VRFs),

    IP = ergw_gsn_lib:choose_context_ip(IP4, IP6, Context),
    {ok, DataTEI} = ergw_tei_mngr:alloc_tei(PCtx),
    Context#context{
      local_data_endp = #gtp_endp{vrf = Name, ip = ergw_inet:bin2ip(IP), teid = DataTEI}
     }.

up_inactivity_timer(#pfcp_ctx{up_inactivity_timer = Timer})
  when is_integer(Timer) ->
    #user_plane_inactivity_timer{timer = Timer};
up_inactivity_timer(_) ->
    #user_plane_inactivity_timer{timer = 0}.

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
    pfcp_rule_diff(OldUpd0, maps:next(maps:iterator(NewUpd0)), #{}).

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
    UpdF = ordsets:add_element(Id, _),
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
    ?LOG(debug, "Update Timers Old: ~p", [Old]),
    ?LOG(debug, "Update Timers New: ~p", [New]),
    maps:map(fun del_timers/2, maps:without(maps:keys(New), Old)),
    R = maps:fold(upd_timers(_, _, Old, _), reset_ctx_timers(PCtx), New),
    ?LOG(debug, "Update Timers Final: ~p", [R#pfcp_ctx.timers]),
    R.

del_timers(_, {TRef, _}) ->
    erlang:cancel_timer(TRef).

upd_timers(Time, {_, Evs} = Timer, Old, #pfcp_ctx{timers = Ts, timer_by_tref = Ids} = PCtx) ->
    TRef =
	case maps:get(Time, Old, Timer) of
	    {TRef0, _} when is_reference(TRef0) ->
		TRef0;
	    _ ->
		erlang:start_timer(Time, self(), pfcp_timer, [{abs, true}])
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
%%% Translate PFCP state into Create/Modify/Delete rules
%%%===================================================================
update_pfcp_rules(#pfcp_ctx{sx_rules = Old},
		  #pfcp_ctx{idmap = IdMap, sx_rules = New}, Opts) ->
    ?LOG(debug, "Update PFCP Rules Old: ~p", [Old]),
    ?LOG(debug, "Update PFCP Rules New: ~p", [New]),
    Del = maps:fold(del_pfcp_rules(_, _, IdMap, _), #{}, maps:without(maps:keys(New), Old)),
    maps:fold(upd_pfcp_rules(_, _, Old, _, Opts), Del, New).

update_m_rec(Record, Map) when is_tuple(Record) ->
    maps:update_with(element(1, Record), [Record | _], [Record], Map).

put_rec(Record, Map) when is_tuple(Record) ->
    maps:put(element(1, Record), Record, Map).

del_pfcp_rules({pdr, _}, #{pdr_id := Id}, _, Acc) ->
    update_m_rec(#remove_pdr{group = [Id]}, Acc);
del_pfcp_rules({far, _}, #{far_id := Id}, _, Acc) ->
    update_m_rec(#remove_far{group = [Id]}, Acc);
del_pfcp_rules({urr, _}, #{urr_id := Id}, _, Acc) ->
    update_m_rec(#remove_urr{group = [Id]}, Acc).

upd_pfcp_rules({Type, _} = K, V, Old, Acc, Opts) ->
    upd_pfcp_rules_1(Type, V, maps:get(K, Old, undefined), Acc, Opts).

upd_pfcp_rules_1(pdr, V, undefined, Acc, _Opts) ->
    update_m_rec(#create_pdr{group = V}, Acc);
upd_pfcp_rules_1(far, V, undefined, Acc, _Opts) ->
    update_m_rec(#create_far{group = V}, Acc);
upd_pfcp_rules_1(urr, M, undefined, Acc, _Opts)
  when is_map(M) ->
    V = maps:remove('Update-Time-Stamp', M),
    update_m_rec(#create_urr{group = V}, Acc);
upd_pfcp_rules_1(urr, V, undefined, Acc, _Opts)
  when is_list(V) ->
    update_m_rec(#create_urr{group = V}, Acc);

upd_pfcp_rules_1(_Type, V, V, Acc, _Opts) ->
    Acc;

upd_pfcp_rules_1(pdr, V, OldV, Acc, Opts) ->
    update_m_rec(#update_pdr{group = update_pfcp_pdr(V, OldV, Opts)}, Acc);
upd_pfcp_rules_1(far, V, OldV, Acc, Opts) ->
    update_m_rec(#update_far{group = update_pfcp_far(V, OldV, Opts)}, Acc);
upd_pfcp_rules_1(urr, V, _OldV, Acc, _Opts)
  when is_list(V) ->
    update_m_rec(#update_urr{group = V}, Acc);

upd_pfcp_rules_1(urr,
		 #{'Update-Time-Stamp' := TS} = _M,
		 #{'Update-Time-Stamp' := TS} = _OldV, Acc, _Opts) ->
    Acc;
upd_pfcp_rules_1(urr, M, _OldV, Acc, _Opts)
  when is_map(M) ->
    V = maps:remove('Update-Time-Stamp', M),
    update_m_rec(#update_urr{group = V}, Acc);
upd_pfcp_rules_1(urr, V, _OldV, Acc, _Opts)
  when is_list(V) ->
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
    ?LOG(debug, "Update PFCP Far Old: ~s", [pfcp_packet:pretty_print(Old)]),
    ?LOG(debug, "Update PFCP Far New: ~s", [pfcp_packet:pretty_print(New)]),
    Update = update_pfcp_simplify(New, Old),
    ?LOG(debug, "Update PFCP Far Update: ~s", [pfcp_packet:pretty_print(Update)]),
    maps:fold(update_pfcp_far(_, _, Old, _, Opts), #{}, put_rec(Id, Update)).

update_pfcp_far(_, #forwarding_parameters{
		    group =
			#{destination_interface :=
			      #destination_interface{interface = Interface}} = New},
	      #{forwarding_parameters := #forwarding_parameters{group = Old}},
	      Far, Opts) ->
    ?LOG(debug, "Update PFCP Forward Old: ~p", [Old]),
    ?LOG(debug, "Update PFCP Forward P0: ~p", [New]),

    SendEM = maps:get(send_end_marker, Opts, false),
    Update0 = update_pfcp_simplify(New, Old),
    ?LOG(debug, "Update PFCP Forward Update: ~p", [Update0]),
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
    ?LOG(debug, "Update PFCP Far: ~p, ~p", [K, V]),
    Far#{K => V}.
