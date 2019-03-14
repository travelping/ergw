%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_proxy_lib).

-compile({parse_transform, cut}).

-export([validate_options/3, validate_option/2,
	 forward_request/3, forward_request/7, forward_request/9,
	 get_seq_no/3,
	 select_proxy_gsn/4, select_proxy_sockets/2]).
-export([create_forward_session/3,
	 modify_forward_session/4,
	 delete_forward_session/3,
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
			 remote_control_teid = #fq_teid{ip = RemoteCntlIP}},
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
		 Services, State) ->
    APN = if is_list(DstAPN) -> DstAPN;
	     true            -> SrcAPN
	  end,
    FQDN = ergw_node_selection:apn_to_fqdn(APN),
    select_proxy_gsn_fqdn(FQDN, ProxyGSN, Services, State);
select_proxy_gsn(_, #proxy_ggsn{address = {fqdn, _} = FQDN} = ProxyGSN, Services, State) ->
    select_proxy_gsn_fqdn(FQDN, ProxyGSN, Services, State);
select_proxy_gsn(_ProxyInfo, _ProxyGSN, _Services, State) ->
    throw(?CTX_ERR(?FATAL, system_failure, maps:get(context, State))).

select_proxy_gsn_fqdn(FQDN, ProxyGSN, Services, #{node_selection := NodeSelect} = State) ->
    case ergw_node_selection:candidates(FQDN, Services, NodeSelect) of
	[{Node, _, _, IP4, _}|_] when length(IP4) /= 0 ->
	    ProxyGSN#proxy_ggsn{node = Node, address = hd(IP4)};
	[{Node, _, _, _, IP6}|_] when length(IP6) /= 0 ->
	    ProxyGSN#proxy_ggsn{node = Node, address = hd(IP6)};
	_Other ->
	    lager:error("proxy GSN for ~p not found, rejecting request, got ~p", [FQDN, _Other]),
	    throw(?CTX_ERR(?FATAL, system_failure, maps:get(context, State)))
    end.

select_proxy_sockets(#proxy_ggsn{node = Node, dst_apn = DstAPN, context = Context},
		     #{contexts := Contexts, proxy_ports := ProxyPorts,
		       node_selection := ProxyNodeSelect}) ->
    Ctx = maps:get(Context, Contexts, #{}),
    if Ctx =:= #{} ->
	    lager:warning("proxy context ~p not found, using default", [Context]);
       true -> ok
    end,
    Cntl = maps:get(proxy_sockets, Ctx, ProxyPorts),
    NodeSelect = maps:get(node_selection, Ctx, ProxyNodeSelect),

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

-define(ContextDefaults, []).

-define(is_opts(X), (is_list(X) orelse is_map(X))).

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
validate_context_option(node_selection, [S|_] = Value)
  when is_atom(S) ->
    Value;
validate_context_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_context(Name, Opts0, Acc)
  when is_binary(Name) andalso ?is_opts(Opts0) ->
    Opts = ergw_config:validate_options(
	     fun validate_context_option/2, Opts0, ?ContextDefaults, map),
    Acc#{Name => Opts};
validate_context(Name, Opts, _Acc) ->
    throw({error, {options, {contexts, {Name, Opts}}}}).

%%%===================================================================
%%% Helper functions
%%%===================================================================

ctx_update_dp_seid(#{f_seid := #f_seid{seid = DP}},
		   #pfcp_ctx{seid = SEID} = PCtx) ->
    PCtx#pfcp_ctx{seid = SEID#seid{dp = DP}};
ctx_update_dp_seid(_, PCtx) ->
    PCtx.

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

update_m_rec(Record, Map) when is_tuple(Record) ->
    maps:update_with(element(1, Record), [Record | _], [Record], Map).

%%%===================================================================
%%% Sx DP API
%%%===================================================================

proxy_pdr({SrcIntf, #context{local_data_endp = LocalDataEndp},
	  DstIntf, _Right},
	  #pfcp_ctx{sx_rules = Rules} = PCtx0) ->

    {[PdrId, FarId, UrrId], PCtx} =
	ergw_pfcp:get_id([{pdr, SrcIntf}, {far, DstIntf}, {urr, proxy}], PCtx0),
    PDI = #pdi{
	     group =
		 [#source_interface{interface = SrcIntf},
		  ergw_pfcp:network_instance(LocalDataEndp),
		  ergw_pfcp:f_teid(LocalDataEndp)]
	    },
    PDR = [#pdr_id{id = PdrId},
	   #precedence{precedence = 100},
	   PDI,
	   ergw_pfcp:outer_header_removal(LocalDataEndp),
	   #far_id{id = FarId},
	   #urr_id{id = UrrId}],
    PCtx#pfcp_ctx{
      sx_rules =
	  Rules#{{pdr, PdrId} => pfcp_packet:ies_to_map(PDR)}
     }.

proxy_far({_SrcIntf, _Left, DstIntf,
	   #context{
	      local_data_endp = LocalDataEndp,
	      remote_data_teid = PeerTEID}
	  },
	  #pfcp_ctx{sx_rules = Rules} = PCtx0)
  when PeerTEID /= undefined ->
    {FarId, PCtx} = ergw_pfcp:get_id(far, DstIntf, PCtx0),
    FAR = [#far_id{id = FarId},
	   #apply_action{forw = 1},
	   #forwarding_parameters{
	      group =
		  [#destination_interface{interface = DstIntf},
		   ergw_pfcp:network_instance(LocalDataEndp),
		   ergw_pfcp:outer_header_creation(PeerTEID)
		  ]
	     }
	  ],
    PCtx#pfcp_ctx{
      sx_rules =
	  Rules#{{far, FarId} => pfcp_packet:ies_to_map(FAR)}
     };
proxy_far({_SrcIntf, _Left, DstIntf, _Right},
	  #pfcp_ctx{sx_rules = Rules} = PCtx0) ->
    {FarId, PCtx} = ergw_pfcp:get_id(far, DstIntf, PCtx0),
    FAR = [#far_id{id = FarId},
	   #apply_action{drop = 1}
	  ],
    PCtx#pfcp_ctx{
      sx_rules =
	  Rules#{{far, FarId} => pfcp_packet:ies_to_map(FAR)}
     }.

proxy_urr(#pfcp_ctx{sx_rules = Rules} = PCtx0) ->
    {UrrId, PCtx} = ergw_pfcp:get_id(urr, proxy, PCtx0),
    URR = [#urr_id{id = UrrId},
	   #measurement_method{volum = 1},
	   #reporting_triggers{periodic_reporting = 1}
	  ],
    PCtx#pfcp_ctx{
      sx_rules =
	  Rules#{{urr, UrrId} => pfcp_packet:ies_to_map(URR)}
     }.

create_forward_session(Candidates, Left0, Right0) ->
    PCtx0 = ergw_sx_node:select_sx_node(Candidates, Left0),
    Left = ergw_pfcp:assign_data_teid(PCtx0, Left0),
    Right = ergw_pfcp:assign_data_teid(PCtx0, Right0),
    {ok, CntlNode, _} = ergw_sx_socket:id(),

    MakeRules = [{'Access', Left, 'Core', Right}, {'Core', Right, 'Access', Left}],
    PCtx1 = lists:foldl(fun proxy_pdr/2, PCtx0, MakeRules),
    PCtx2 = lists:foldl(fun proxy_far/2, PCtx1, MakeRules),
    PCtx = proxy_urr(PCtx2),
    Rules = ergw_pfcp:update_pfcp_rules(PCtx0, PCtx, #{}),
    IEs = update_m_rec(ergw_pfcp:f_seid(PCtx, CntlNode), Rules),

    Req = #pfcp{version = v1, type = session_establishment_request, ie = IEs},
    case ergw_sx_node:call(PCtx, Req, Left) of
	#pfcp{version = v1, type = session_establishment_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'},
		     f_seid := #f_seid{}} = RespIEs} ->
	    {Left#context{pfcp_ctx = ctx_update_dp_seid(RespIEs, PCtx)},
	     Right#context{pfcp_ctx = ctx_update_dp_seid(RespIEs, PCtx)}};
	_Other ->
	    throw(?CTX_ERR(?FATAL, system_failure, Left))
    end.

modify_forward_session(#context{version = OldVersion,
				pfcp_ctx = OldPCtx} = OldLeft,
		       #context{version = NewVersion} = NewLeft,
		       _OldRight, NewRight) ->
    MakeRules = [{'Access', NewLeft, 'Core', NewRight}, {'Core', NewRight, 'Access', NewLeft}],
    PCtx0 = ergw_pfcp:reset_ctx(OldPCtx),
    PCtx1 = lists:foldl(fun proxy_pdr/2, PCtx0, MakeRules),
    PCtx2 = lists:foldl(fun proxy_far/2, PCtx1, MakeRules),
    PCtx = proxy_urr(PCtx2),
    Opts = #{send_end_marker => (v2 =:= NewVersion andalso v2 =:= OldVersion)},
    IEs = ergw_pfcp:update_pfcp_rules(OldPCtx, PCtx, Opts),

    Req = #pfcp{version = v1, type = session_modification_request, ie = IEs},
    case ergw_sx_node:call(OldPCtx, Req, NewLeft) of
	#pfcp{version = v1, type = session_modification_response,
	      ie = #{
		     pfcp_cause :=
			 #pfcp_cause{cause = 'Request accepted'}} = RespIEs} = _Response ->
	    %%TODO: modify_proxy_report_urrs(Response, URRActions),
	    NewLeft#context{pfcp_ctx = ctx_update_dp_seid(RespIEs, PCtx)};
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, OldLeft))
    end.


delete_forward_session(normal, #context{pfcp_ctx = PCtx} = Left, _Right) ->
    Req = #pfcp{version = v1, type = session_deletion_request, ie = []},
    case ergw_sx_node:call(PCtx, Req, Left) of
	#pfcp{type = session_deletion_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} = IEs} ->
	    maps:get(usage_report_sdr, IEs, undefined);
	_Other ->
	    lager:warning("PFCP (proxy): Session Deletion failed with ~p",
			  [lager:pr(_Other, ?MODULE)]),
	    undefined
    end;
delete_forward_session(_Reason, _Left, _Right) ->
    undefined.

query_usage_report(#context{pfcp_ctx = PCtx} = Ctx) ->
    IEs = [#query_urr{group = [#urr_id{id = 1}]}],
    Req = #pfcp{version = v1, type = session_modification_request, ie = IEs},
    ergw_sx_node:call(PCtx, Req, Ctx).
