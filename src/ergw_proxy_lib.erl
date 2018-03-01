%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_proxy_lib).

-export([validate_options/3, validate_option/2,
	 forward_request/3, forward_request/7, forward_request/9,
	 get_seq_no/3,
	 select_proxy_gsn/4]).
-export([create_forward_session/2,
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
    gtp_socket:get_seq_no(GtpPort, ReqId).

select_proxy_gsn(#proxy_info{src_apn = SrcAPN},
		 #proxy_ggsn{address = undefined, dst_apn = DstAPN} = ProxyGSN,
		 Services,
		 #{node_selection := NodeSelect}) ->
    APN = if is_list(DstAPN) -> DstAPN;
	     true            -> SrcAPN
	  end,
    Norm = lists:flatten(lists:join($., [binary_to_list(X) || X <- qualify_apn(APN)])),
    case ergw_node_selection:candidates(Norm, Services, NodeSelect) of
	[{Node, _, _, IP4, _}|_] when length(IP4) /= 0 ->
	    ProxyGSN#proxy_ggsn{node = Node, address = hd(IP4)};
	[{Node, _, _, _, IP6}|_] when length(IP6) /= 0 ->
	    ProxyGSN#proxy_ggsn{node = Node, address = hd(IP6)};
	Other ->
	    lager:error("No proxy address for APN '~w', got ~p", [APN, Other]),
	    ProxyGSN
    end;
select_proxy_gsn(_ProxyInfo, ProxyGSN, _Services, _State) ->
    ProxyGSN.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(ProxyDefaults, [{proxy_data_source, gtp_proxy_ds},
			{proxy_sockets,     []},
			{proxy_data_paths,  []},
			{contexts,          []}]).

-define(ContextDefaults, [{proxy_sockets,    []},
			  {proxy_data_paths, []}]).

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
  when Opt == proxy_sockets;
       Opt == proxy_data_paths ->
    validate_context_option(Opt, Value);
validate_option(contexts, Values) when is_list(Values); is_map(Values) ->
    ergw_config:opts_fold(fun validate_context/3, #{}, Values);
validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

validate_context_option(proxy_sockets, Value) when is_list(Value), Value /= [] ->
    Value;
validate_context_option(proxy_data_paths, Value) when is_list(Value), Value /= [] ->
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

qualify_apn(Labels) ->
    case lists:reverse(Labels) of
	[<<"gprs">>, <<"mcc", _/binary>> = MCC, <<"mnc", _binary>> = MNC | APN] ->
	    lists:reverse(
	      [<<"org">>, <<"3gppnetwork">>, MCC, MNC, <<"epc">>, <<"apn">> | APN]);
	[<<"org">>, <<"3gppnetwork">> | _ ] ->
	    Labels;
	_ ->
	    {MCC, MNC} = ergw:get_plmn_id(),
	    Labels ++ [<<"apn">>, <<"epc">>, <<"mnc", MNC/binary>>, <<"mcc", MCC/binary>>,
		       <<"3gppnetwork">>,<<"org">>]
    end.

%%%===================================================================
%%% Sx DP API
%%%===================================================================

network_instance(Name) when is_atom(Name) ->
    #network_instance{instance = [atom_to_binary(Name, latin1)]}.

f_teid(TEID, {_,_,_,_} = IP) ->
    #f_teid{teid = TEID, ipv4 = gtp_c_lib:ip2bin(IP)};
f_teid(TEID, {_,_,_,_,_,_,_,_} = IP) ->
    #f_teid{teid = TEID, ipv6 = gtp_c_lib:ip2bin(IP)}.

create_pdr({RuleId, Intf,
	    #context{
	       data_port = #gtp_port{name = InPortName, ip = IP},
	       local_data_tei = LocalTEI}},
	   PDRs) ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = Intf},
		  network_instance(InPortName),
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
			 [#destination_interface{interface = Intf},
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
    [FAR | FARs].

update_pdr({RuleId, Intf,
	    #context{data_port = #gtp_port{name = OldInPortName},
		     local_data_tei = OldLocalTEI},
	    #context{data_port = #gtp_port{name = NewInPortName, ip = IP},
		     local_data_tei = NewLocalTEI}},
	   PDRs)
  when OldInPortName /= NewInPortName;
       OldLocalTEI /= NewLocalTEI ->
    PDI = #pdi{
	     group =
		 [#source_interface{interface = Intf},
		  network_instance(NewInPortName),
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
	    #context{version = OldVersion,
		     data_port = #gtp_port{name = OldOutPortName},
		     remote_data_ip = OldPeerIP,
		     remote_data_tei = OldRemoteTEI},
	    #context{version = NewVersion,
		     data_port = #gtp_port{name = NewOutPortName},
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
			  network_instance(NewOutPortName),
			  #outer_header_creation{
			     type = 'GTP-U/UDP/IPv4',
			     teid = NewRemoteTEI,
			     address = gtp_c_lib:ip2bin(NewPeerIP)
			    }
			  | [#sxsmreq_flags{sndem = 1} ||
				v2 =:= NewVersion andalso v2 =:= OldVersion]
			 ]
		    }
		 ]
	    },
    [FAR | FARs];

update_far({_RuleId, _Intf, _OldOut, _NewOut}, FARs) ->
    FARs.

create_forward_session(#context{local_data_tei = SEID} = Left, Right) ->
    IEs =
	[#f_seid{seid = SEID}] ++
	lists:foldl(fun create_pdr/2, [], [{1, 'Access', Left}, {2, 'Core', Right}]) ++
	lists:foldl(fun create_far/2, [], [{2, 'Access', Left}, {1, 'Core', Right}]) ++
	[#create_urr{group =
			 [#urr_id{id = 1}, #measurement_method{volum = 1}]}],
    Req = #pfcp{version = v1, type = session_establishment_request, seid = 0, ie = IEs},
    case ergw_sx:call(Left, Req) of
	{ok, Pid} when is_pid(Pid) ->
	    Left#context{dp_pid = Pid};
	_ ->
	    Left
    end.

modify_forward_session(#context{local_data_tei = OldSEID} = OldLeft,
		       #context{local_data_tei = NewSEID} = NewLeft,
		       OldRight, NewRight) ->
    IEs =
	[#f_seid{seid = NewSEID} || NewSEID /= OldSEID] ++
	lists:foldl(fun update_pdr/2, [],
		    [{1, 'Access', OldLeft, NewLeft},
		     {2, 'Core', OldRight, NewRight}]) ++
	lists:foldl(fun update_far/2, [],
		    [{2, 'Access', OldLeft, NewLeft},
		     {1, 'Core', OldRight, NewRight}]),
    Req = #pfcp{version = v1, type = session_modification_request, seid = OldSEID, ie = IEs},
    ergw_sx:call(NewLeft, Req).

delete_forward_session(#context{local_data_tei = SEID} = Left, _Right) ->
    Req = #pfcp{version = v1, type = session_deletion_request, seid = SEID, ie = []},
    ergw_sx:call(Left, Req).

query_usage_report(#context{local_data_tei = SEID} = Ctx) ->
    IEs = [#query_urr{group = [#urr_id{id = 1}]}],
    Req = #pfcp{version = v1, type = session_modification_request,
		seid = SEID, ie = IEs},
    ergw_sx:call(Ctx, Req).
