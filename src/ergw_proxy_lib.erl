%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_proxy_lib).

-export([validate_options/3, validate_option/2,
	 forward_request/3, forward_request/7, forward_request/9,
	 get_seq_no/3,
	 select_proxy_gsn/4, select_proxy_sockets/2]).
-export([create_forward_session/3,
	 modify_forward_session/4,
	 delete_forward_session/2,
	 query_usage_report/1]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").
-include("gtp_proxy_ds.hrl").

%%%===================================================================
%%% API
%%%===================================================================

forward_request(Direction, GtpPort, DstIP, DstPort,
		Request, ReqKey, SeqNo, NewPeer, OldState) ->
    {ReqId, ReqInfo} = make_proxy_request(Direction, ReqKey, SeqNo, NewPeer, OldState),
    lager:debug("Invoking Context Send Request: ~p", [Request]),
    gtp_context:send_request(GtpPort, DstIP, DstPort, ReqId, Request, ReqInfo).

forward_request(Direction,
		#context{control_port = GtpPort,
			 remote_control_ip = RemoteCntlIP},
		Request, ReqKey, SeqNo, NewPeer, OldState) ->
    forward_request(Direction, GtpPort, RemoteCntlIP, ?GTP1c_PORT,
		    Request, ReqKey, SeqNo, NewPeer, OldState).

forward_request(#context{control_port = GtpPort}, ReqKey, Request) ->
    ReqId = make_request_id(ReqKey, Request),
    gtp_context:resend_request(GtpPort, ReqId).

get_seq_no(#context{control_port = GtpPort}, ReqKey, Request) ->
    ReqId = make_request_id(ReqKey, Request),
    ergw_gtp_c_socket:get_seq_no(GtpPort, ReqId).

select_proxy_gsn(#proxy_info{src_apn = SrcAPN},
		 #proxy_ggsn{address = undefined, dst_apn = DstAPN} = ProxyGSN,
		 Services,
		 #{node_selection := NodeSelect}) ->
    APN = if is_list(DstAPN) -> DstAPN;
	     true            -> SrcAPN
	  end,
    APN_FQDN = ergw_node_selection:apn_to_fqdn(APN),
    case ergw_node_selection:candidates(APN_FQDN, Services, NodeSelect) of
	[{Node, _, _, IP4, _}|_] when length(IP4) /= 0 ->
	    ProxyGSN#proxy_ggsn{node = Node, address = hd(IP4)};
	[{Node, _, _, _, IP6}|_] when length(IP6) /= 0 ->
	    ProxyGSN#proxy_ggsn{node = Node, address = hd(IP6)};
	Other ->
	    lager:error("No proxy address for APN '~w', got ~p", [APN_FQDN, Other]),
	    ProxyGSN
    end;
select_proxy_gsn(_ProxyInfo, ProxyGSN, _Services, _State) ->
    ProxyGSN.

select_proxy_sockets(#proxy_ggsn{node = Node, dst_apn = DstAPN, context = Context},
		     #{contexts := Contexts, proxy_ports := ProxyPorts,
		       node_selection := ProxyNodeSelect}) ->
    {Cntl, NodeSelect} =
	case maps:get(Context, Contexts, undefined) of
	    #{proxy_sockets := Cntl0, node_selection := NodeSelect0} ->
		{Cntl0, NodeSelect0};
	    _ ->
		lager:warning("proxy context ~p not found, using default", [Context]),
		{ProxyPorts, ProxyNodeSelect}
	end,

    APN_FQDN = ergw_node_selection:apn_to_fqdn(DstAPN),
    Services = [{"x-3gpp-upf", "x-sxa"}],
    Candidates0 = ergw_node_selection:candidates(APN_FQDN, Services, NodeSelect),
    PGWCandidate = [{Node, 0, Services, [], []}],
    Candidates =
	case ergw_node_selection:topology_match(Candidates0, PGWCandidate) of
	    {_, C} when is_list(C), length(C) /= 0 ->
		C;
	    {C, _} when is_list(C), length(C) /= 0 ->
		C;
	    _ ->
		%% neither colocation, not topology matched
		Candidates0
	end,
    {ergw_gtp_socket_reg:lookup(hd(Cntl)), Candidates}.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(ProxyDefaults, [{proxy_data_source, gtp_proxy_ds},
			{proxy_sockets,     []},
			{contexts,          []}]).

-define(ContextDefaults, [{proxy_sockets,    []}]).

validate_options(Fun, Opts, Defaults) ->
    gtp_context:validate_options(Fun, Opts, Defaults ++ ?ProxyDefaults).

validate_option(proxy_data_source, Value) ->
    case code:ensure_loaded(Value) of
	{module, _} ->
	    ok;
	_ ->
	    throw({error, {options, {proxy_data_source, Value}}})
    end,
    Value;
validate_option(Opt, Value)
  when Opt == proxy_sockets ->
    validate_context_option(Opt, Value);
validate_option(contexts, Values) when is_list(Values); is_map(Values) ->
    ergw_config:opts_fold(fun validate_context/3, #{}, Values);
validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

validate_context_option(proxy_sockets, Value) when is_list(Value), Value /= [] ->
    Value;
validate_context_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_context(Name, Opts0, Acc)
  when is_binary(Name) andalso (is_list(Opts0) orelse is_map(Opts0)) ->
    Opts = ergw_config:validate_options(
	     fun validate_context_option/2, Opts0, ?ContextDefaults, map),
    Acc#{Name => Opts};
validate_context(Name, Opts, _Acc) ->
    throw({error, {options, {contexts, {Name, Opts}}}}).

%%%===================================================================
%%% Helper functions
%%%===================================================================

make_request_id(#request{key = ReqKey}, #gtp{seq_no = SeqNo})
  when is_integer(SeqNo) ->
    {ReqKey, SeqNo};
make_request_id(#request{key = ReqKey}, SeqNo)
  when is_integer(SeqNo) ->
    {ReqKey, SeqNo}.

make_proxy_request(Direction, Request, SeqNo, NewPeer, State) ->
    ReqId = make_request_id(Request, SeqNo),
    ReqInfo = #proxy_request{
		 direction = Direction,
		 request = Request,
		 seq_no = SeqNo,
		 new_peer = NewPeer,
		 context = maps:get(context, State, undefined),
		 proxy_ctx = maps:get(proxy_context, State, undefined)
		},
    {ReqId, ReqInfo}.

%%%===================================================================
%%% Sx DP API
%%%===================================================================

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

create_pdr({RuleId, Intf,
	    #context{
	       data_port = #gtp_port{ip = IP} = DataPort,
	       local_data_tei = LocalTEI}},
	   PDRs) ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = Intf},
		  network_instance(DataPort),
		  f_teid(LocalTEI, IP)]
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
    [PDR | PDRs].

create_far({RuleId, Intf,
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
			 [#destination_interface{interface = Intf},
			  network_instance(DataPort),
			  gtp_u_peer(RemoteTEI, PeerIP)
			 ]
		    }
		 ]
	    },
    [FAR | FARs];
create_far({_RuleId, _Intf, _Out}, FARs) ->
    FARs.

update_pdr({RuleId, Intf,
	    #context{data_port = #gtp_port{name = OldInPortName},
		     local_data_tei = OldLocalTEI},
	    #context{data_port = #gtp_port{name = NewInPortName, ip = IP} = NewDataPort,
		     local_data_tei = NewLocalTEI}},
	   PDRs)
  when OldInPortName /= NewInPortName;
       OldLocalTEI /= NewLocalTEI ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = Intf},
		  network_instance(NewDataPort),
		  f_teid(NewLocalTEI, IP)]
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

update_pdr({_RuleId, _Intf, _OldIn, _NewIn}, PDRs) ->
    PDRs.

update_far({RuleId, Intf,
	    #context{remote_data_ip = OldPeerIP},
	    #context{remote_data_ip = NewPeerIP} = NewContext},
	   FARs)
  when (OldPeerIP =:= undefined andalso NewPeerIP /= undefined) ->
    create_far({RuleId, Intf, NewContext}, FARs);
update_far({RuleId, Intf,
	    #context{version = OldVersion,
		     data_port = #gtp_port{name = OldOutPortName},
		     remote_data_ip = OldPeerIP,
		     remote_data_tei = OldRemoteTEI},
	    #context{version = NewVersion,
		     data_port = #gtp_port{name = NewOutPortName} = NewDataPort,
		     remote_data_ip = NewPeerIP,
		     remote_data_tei = NewRemoteTEI}},
	   FARs)
  when OldOutPortName /= NewOutPortName;
       OldPeerIP /= NewPeerIP;
       OldRemoteTEI /= NewRemoteTEI ->
    FAR = #update_far{
	     group =
		 [#far_id{id = RuleId},
		  #apply_action{forw = 1},
		  #update_forwarding_parameters{
		     group =
			 [#destination_interface{interface = Intf},
			  network_instance(NewDataPort),
			  gtp_u_peer(NewRemoteTEI, NewPeerIP)
			  | [#sxsmreq_flags{sndem = 1} ||
				v2 =:= NewVersion andalso v2 =:= OldVersion]
			 ]
		    }
		 ]
	    },
    [FAR | FARs];
update_far({_RuleId, _Intf, _OldOut, _NewOut}, FARs) ->
    FARs.

create_forward_session(Candidates, Left0, Right0) ->
    Left1 = ergw_sx_node:select_sx_node(Candidates, Left0),
    Right1 = Right0#context{dp_node = Left1#context.dp_node,
			    data_port = Left1#context.data_port},

    {ok, NWIs} = ergw_sx_node:get_network_instances(Left1),
    Left = assign_data_teid(Left1, get_context_nwi(Left1, NWIs)),
    Right = assign_data_teid(Right1, get_context_nwi(Right1, NWIs)),
    SEID = ergw_sx_socket:seid(),
    {ok, #node{node = _Node, ip = IP}, _} = ergw_sx_socket:id(),

    IEs =
	[f_seid(SEID, IP)] ++
	lists:foldl(fun create_pdr/2, [], [{1, 'Access', Left}, {2, 'Core', Right}]) ++
	lists:foldl(fun create_far/2, [], [{2, 'Access', Left}, {1, 'Core', Right}]) ++
	[#create_urr{group =
			 [#urr_id{id = 1}, #measurement_method{volum = 1}]}],
    Req = #pfcp{version = v1, type = session_establishment_request, seid = 0, ie = IEs},
    case ergw_sx_node:call(Left, Req) of
	#pfcp{version = v1, type = session_establishment_response,
	      %% seid = SEID, TODO: fix DP
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'},
		     f_seid := #f_seid{seid = DataPathSEID}} = _RespIEs} ->
	    {Left#context{cp_seid = SEID, dp_seid = DataPathSEID},
	     Right#context{cp_seid = SEID, dp_seid = DataPathSEID}};
	_Other ->
	    throw(?CTX_ERR(?FATAL, system_failure, Left))
    end.

modify_forward_session(#context{dp_seid = SEID, local_control_tei = OldSEID} = OldLeft,
		       #context{local_control_tei = NewSEID} = NewLeft,
		       OldRight, NewRight) ->
    IEs =
	[#f_seid{seid = NewSEID} || NewSEID /= OldSEID] ++
	lists:foldl(fun update_pdr/2, [],
		    [{1, 'Access', OldLeft, NewLeft},
		     {2, 'Core', OldRight, NewRight}]) ++
	lists:foldl(fun update_far/2, [],
		    [{2, 'Access', OldLeft, NewLeft},
		     {1, 'Core', OldRight, NewRight}]),
    Req = #pfcp{version = v1, type = session_modification_request, seid = SEID, ie = IEs},
    ergw_sx_node:call(NewLeft, Req).

delete_forward_session(#context{dp_seid = SEID} = Left, _Right) ->
    Req = #pfcp{version = v1, type = session_deletion_request, seid = SEID, ie = []},
    ergw_sx_node:call(Left, Req).

query_usage_report(#context{dp_seid = SEID} = Ctx) ->
    IEs = [#query_urr{group = [#urr_id{id = 1}]}],
    Req = #pfcp{version = v1, type = session_modification_request,
		seid = SEID, ie = IEs},
    ergw_sx_node:call(Ctx, Req).

get_context_nwi(#context{control_port = #gtp_port{name = Name}}, NWIs) ->
    maps:get(Name, NWIs).

assign_data_teid(#context{data_port = DataPort} = Context,
		 #user_plane_ip_resource_information{
		    ipv4 = IP4, ipv6 = IP6, network_instance = NWInst}) ->
    {ok, DataTEI} = gtp_context_reg:alloc_tei(DataPort),
    IP = ergw_gsn_lib:choose_context_ip(IP4, IP6, Context),
    Context#context{
      data_port = DataPort#gtp_port{ip = gtp_c_lib:bin2ip(IP), network_instance = NWInst},
      local_data_tei = DataTEI
     }.
