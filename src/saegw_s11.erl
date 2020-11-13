%% Copyright 2018-2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(saegw_s11).

-behaviour(gtp_api).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([validate_options/1, init/2, request_spec/3,
	 handle_pdu/4,
	 handle_request/5, handle_response/5,
	 handle_event/4, terminate/3]).

-export([delete_context/4, close_context/4]).

%% PFCP context API's
%%-export([defered_usage_report/3]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define(GTP_v1_Interface, ggsn_gn).
-define(T3, 10 * 1000).
-define(N3, 5).

%%====================================================================
%% API
%%====================================================================

-define('Cause',					{v2_cause, 0}).
-define('Recovery',					{v2_recovery, 0}).
-define('IMSI',						{v2_international_mobile_subscriber_identity, 0}).
-define('MSISDN',					{v2_msisdn, 0}).
-define('PDN Address Allocation',			{v2_pdn_address_allocation, 0}).
-define('RAT Type',					{v2_rat_type, 0}).
-define('Sender F-TEID for Control Plane',		{v2_fully_qualified_tunnel_endpoint_identifier, 0}).
-define('Access Point Name',				{v2_access_point_name, 0}).
-define('Bearer Contexts to be created',		{v2_bearer_context, 0}).
-define('Bearer Contexts to be modified',		{v2_bearer_context, 0}).
-define('Protocol Configuration Options',		{v2_protocol_configuration_options, 0}).
-define('ME Identity',					{v2_mobile_equipment_identity, 0}).
-define('APN-AMBR',					{v2_aggregate_maximum_bit_rate, 0}).
-define('Bearer Level QoS',				{v2_bearer_level_quality_of_service, 0}).
-define('EPS Bearer ID',                                {v2_eps_bearer_id, 0}).
-define('Indication',                                   {v2_indication, 0}).

-define('S1-U eNode-B', 0).
-define('S1-U SGW',     1).
-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).
-define('S11-C MME',    10).
-define('S11/S4-C SGW', 11).

-define(CAUSE_OK(Cause), (Cause =:= request_accepted orelse
			  Cause =:= request_accepted_partially orelse
			  Cause =:= new_pdp_type_due_to_network_preference orelse
			  Cause =:= new_pdp_type_due_to_single_address_bearer_only)).

request_spec(v1, Type, Cause) ->
    ?GTP_v1_Interface:request_spec(v1, Type, Cause);
request_spec(v2, _Type, Cause)
  when Cause /= undefined andalso not ?CAUSE_OK(Cause) ->
    [];
request_spec(v2, create_session_request, _) ->
    [{?'RAT Type',						mandatory},
     {?'Sender F-TEID for Control Plane',			mandatory},
     {?'Access Point Name',					mandatory},
     {?'Bearer Contexts to be created',				mandatory}];
request_spec(v2, delete_session_request, _) ->
    [];
request_spec(v2, modify_bearer_request, _) ->
    [];
request_spec(v2, modify_bearer_command, _) ->
    [{?'APN-AMBR' ,						mandatory},
     {?'Bearer Contexts to be modified',			mandatory}];
request_spec(v2, _, _) ->
    [].

validate_options(Options) ->
    ?LOG(debug, "SAEGW S11 Options: ~p", [Options]),
    gtp_context:validate_options(fun validate_option/2, Options, []).

validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

init(_Opts, Data) ->
    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),
    SessionOpts = ergw_aaa_session:get(Session),
    OCPcfg = maps:get('Offline-Charging-Profile', SessionOpts, #{}),
    PCC = #pcc_ctx{offline_charging_profile = OCPcfg},
    {ok, run, Data#{'Session' => Session, pcc => PCC}}.

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event(cast, {packet_in, _Socket, _IP, _Port, _Msg}, _State, _Data) ->
    ?LOG(warning, "packet_in not handled (yet): ~p", [_Msg]),
    keep_state_and_data;

handle_event(info, _Info, _State, _Data) ->
    keep_state_and_data.

handle_pdu(ReqKey, #gtp{ie = PDU} = Msg, _State,
	   #{context := Context, pfcp := PCtx,
	     bearer := #{left := LeftBearer, right := RightBearer}} = Data) ->
    ?LOG(debug, "GTP-U SAE-GW: ~p, ~p", [ReqKey, gtp_c_lib:fmt_gtp(Msg)]),

    ergw_gsn_lib:ip_pdu(PDU, LeftBearer, RightBearer, Context, PCtx),
    {keep_state, Data}.

handle_request(_ReqKey, _Msg, true, _State, _Data) ->
    %% resent request
    keep_state_and_data;

handle_request(ReqKey,
	       #gtp{type = create_session_request,
		    ie = #{?'Access Point Name' := #v2_access_point_name{apn = APN},
			   ?'Bearer Contexts to be created' :=
			       #v2_bearer_context{group = #{?'EPS Bearer ID' := EBI}}
			  } = IEs} = Request,
	       _Resent, _State,
	       #{context := Context0, aaa_opts := AAAopts, node_selection := NodeSelect,
		  left_tunnel := LeftTunnel0, bearer := #{left := LeftBearer0},
		 'Session' := Session, pcc := PCC0} = Data) ->

    Services = [{"x-3gpp-upf", "x-sxb"}],

    {ok, UpSelInfo} =
	ergw_gtp_gsn_lib:connect_upf_candidates(APN, Services, NodeSelect, []),

    PAA = maps:get(?'PDN Address Allocation', IEs, undefined),
    DAF = proplists:get_bool('DAF', gtp_v2_c:get_indication_flags(IEs)),

    Context1 = update_context_from_gtp_req(Request, Context0),

    {LeftTunnel1, LeftBearer1} =
	case update_tunnel_from_gtp_req(Request, LeftTunnel0, LeftBearer0) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context1, tunnel = LeftTunnel0})
	end,

    LeftTunnel = gtp_path:bind(Request, LeftTunnel1),

    gtp_context:terminate_colliding_context(LeftTunnel, Context1),

    SessionOpts0 = pgw_s5s8:init_session(IEs, LeftTunnel, Context1, AAAopts),
    SessionOpts1 = pgw_s5s8:init_session_from_gtp_req(IEs, AAAopts, LeftTunnel, SessionOpts0),
    %% SessionOpts = init_session_qos(ReqQoSProfile, SessionOpts1),

    {Cause, SessionOpts, Context, Bearer, PCC4, PCtx} =
	case ergw_gtp_gsn_lib:create_session(APN, pdn_alloc(PAA), DAF, UpSelInfo, Session,
					     SessionOpts1, Context1, LeftTunnel, LeftBearer1, PCC0) of
	    {ok, Result} -> Result;
	    {error, Err} -> throw(Err)
	end,

    ResponseIEs = create_session_response(Cause, SessionOpts, IEs, EBI, LeftTunnel, Bearer, Context),
    Response = response(create_session_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    FinalData =
	Data#{context => Context, pfcp => PCtx, pcc => PCC4,
	      left_tunnel => LeftTunnel, bearer => Bearer},

    Actions = context_idle_action([], Context),
    {next_state, connected, FinalData, Actions};

handle_request(ReqKey,
	       #gtp{type = modify_bearer_request,
		    ie = #{?'Bearer Contexts to be modified' :=
			       #v2_bearer_context{group = #{?'EPS Bearer ID' := EBI}}
			  } = IEs} = Request,
	       _Resent, _State,
	       #{context := Context, pfcp := PCtx0,
		 left_tunnel := LeftTunnelOld,
		 bearer := #{left := LeftBearerOld} = Bearer0,
		 'Session' := Session, pcc := PCC} = Data) ->

    {LeftTunnel0, LeftBearer} =
	case update_tunnel_from_gtp_req(
	       Request, LeftTunnelOld#tunnel{version = v2}, LeftBearerOld) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context, tunnel = LeftTunnelOld})
	end,
    Bearer = Bearer0#{left => LeftBearer},

    LeftTunnel = ergw_gtp_gsn_lib:update_tunnel_endpoint(Request, LeftTunnelOld, LeftTunnel0),
    URRActions = update_session_from_gtp_req(IEs, Session, LeftTunnel),
    PCtx =
	if LeftBearer /= LeftBearerOld ->
		case ergw_gtp_gsn_lib:apply_bearer_change(
		       Bearer, URRActions, true, PCtx0, PCC) of
		    {ok, Result2} -> Result2;
		    {error, Err2} -> throw(Err2#ctx_err{context = Context, tunnel = LeftTunnel})
		end;
	   true ->
		gtp_context:trigger_usage_report(self(), URRActions, PCtx0),
		PCtx0
	end,

    ResponseIEs = [#v2_cause{v2_cause = request_accepted},
		    #v2_bearer_context{
		       group=[#v2_cause{v2_cause = request_accepted},
			      EBI]}],
    Response = response(modify_bearer_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    DataNew = Data#{pfcp => PCtx, left_tunnel => LeftTunnel, bearer => Bearer},
    Actions = context_idle_action([], Context),
    {keep_state, DataNew, Actions};

handle_request(ReqKey,
	       #gtp{type = modify_bearer_request, ie = IEs} = Request,
	       _Resent, _State,
	       #{context := Context, pfcp := PCtx,
		 left_tunnel := LeftTunnelOld, bearer := #{left := LeftBearerOld},
		 'Session' := Session} = Data)
  when not is_map_key(?'Bearer Contexts to be modified', IEs) ->
    {LeftTunnel0, _LeftBearer} =
	case update_tunnel_from_gtp_req(
	       Request, LeftTunnelOld#tunnel{version = v2}, LeftBearerOld) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context, tunnel = LeftTunnelOld})
	end,

    LeftTunnel = ergw_gtp_gsn_lib:update_tunnel_endpoint(Request, LeftTunnelOld, LeftTunnel0),
    URRActions = update_session_from_gtp_req(IEs, Session, LeftTunnel),
    gtp_context:trigger_usage_report(self(), URRActions, PCtx),

    DataNew =
	Data#{pfcp => PCtx, left_tunnel => LeftTunnel},

    ResponseIEs = [#v2_cause{v2_cause = request_accepted}],
    Response = response(modify_bearer_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = context_idle_action([], Context),
    {keep_state, DataNew, Actions};

handle_request(#request{ip = SrcIP, port = SrcPort} = ReqKey,
	       #gtp{type = modify_bearer_command,
		    seq_no = SeqNo,
		    ie = #{?'APN-AMBR' := AMBR,
			   ?'Bearer Contexts to be modified' :=
			       #v2_bearer_context{
				  group = #{?'EPS Bearer ID' := EBI} = Bearer}} = IEs},
	       _Resent, _State,
	       #{context := Context, pfcp := PCtx,
		 left_tunnel := LeftTunnel, 'Session' := Session}) ->
    gtp_context:request_finished(ReqKey),

    URRActions = update_session_from_gtp_req(IEs, Session, LeftTunnel),
    gtp_context:trigger_usage_report(self(), URRActions, PCtx),

    Type = update_bearer_request,
    RequestIEs0 = [AMBR,
		   #v2_bearer_context{
		      group = copy_ies_to_response(Bearer, [EBI], [?'Bearer Level QoS'])}],
    RequestIEs = gtp_v2_c:build_recovery(Type, LeftTunnel, false, RequestIEs0),
    Msg = msg(LeftTunnel, Type, RequestIEs),
    send_request(LeftTunnel, SrcIP, SrcPort, ?T3, ?N3, Msg#gtp{seq_no = SeqNo}, undefined),

    Actions = context_idle_action([], Context),
    {keep_state_and_data, Actions};

handle_request(ReqKey,
	       #gtp{type = release_access_bearers_request} = Request, _Resent, _State,
	       #{context := Context, pfcp := PCtx0,
		 left_tunnel := LeftTunnel,
		 bearer := #{left := LeftBearer0} = Bearer0,
		 pcc := PCC} = Data) ->
    LeftBearer = LeftBearer0#bearer{remote = undefined},
    Bearer = Bearer0#{left => LeftBearer},

    PCtx =
	case ergw_gtp_gsn_lib:apply_bearer_change(Bearer, [], true, PCtx0, PCC) of
	    {ok, Result2} -> Result2;
	    {error, Err2} -> throw(Err2#ctx_err{context = Context, tunnel = LeftTunnel})
	end,

    ResponseIEs = [#v2_cause{v2_cause = request_accepted}],
    Response = response(release_access_bearers_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    DataNew = Data#{context => Context, pfcp => PCtx, bearer => Bearer},
    Actions = context_idle_action([], Context),
    {keep_state, DataNew, Actions};

handle_request(ReqKey,
	       #gtp{type = delete_session_request, ie = IEs} = Request,
	       _Resent, _State, #{left_tunnel := LeftTunnel} = Data) ->
    FqTEID = maps:get(?'Sender F-TEID for Control Plane', IEs, undefined),

    case match_tunnel(?'S11-C MME', LeftTunnel, FqTEID) of
	ok ->
	    ergw_gtp_gsn_lib:close_context(normal, Data),
	    Response = response(delete_session_response, LeftTunnel, request_accepted),
	    gtp_context:send_response(ReqKey, Request, Response),
	    {next_state, shutdown, Data};

	{error, ReplyIEs} ->
	    Response = response(delete_session_response, LeftTunnel, ReplyIEs),
	    gtp_context:send_response(ReqKey, Request, Response),
	    keep_state_and_data
    end;

handle_request(ReqKey, _Msg, _Resent, _State, _Data) ->
    gtp_context:request_finished(ReqKey),
    keep_state_and_data.

handle_response(_,
		#gtp{type = update_bearer_response,
		     ie = #{?'Cause' := #v2_cause{v2_cause = Cause},
			    ?'Bearer Contexts to be modified' :=
				#v2_bearer_context{
				   group = #{?'Cause' := #v2_cause{v2_cause = BearerCause}}
				  }} = IEs} = Response,
		_Request, connected = State,
		#{pfcp := PCtx, left_tunnel := LeftTunnel0, 'Session' := Session} = Data) ->
    LeftTunnel = gtp_path:bind(Response, LeftTunnel0),

    DataNew = Data#{left_tunnel => LeftTunnel},

    if Cause =:= request_accepted andalso BearerCause =:= request_accepted ->
	    URRActions = update_session_from_gtp_req(IEs, Session, LeftTunnel),
	    gtp_context:trigger_usage_report(self(), URRActions, PCtx),
	    {keep_state, DataNew};
       true ->
	    ?LOG(error, "Update Bearer Request failed with ~p/~p",
			[Cause, BearerCause]),
	    delete_context(undefined, link_broken, State, DataNew)
    end;

handle_response(_, timeout, #gtp{type = update_bearer_request}, connected = State, Data) ->
    ?LOG(error, "Update Bearer Request failed with timeout"),
    delete_context(undefined, link_broken, State, Data);

handle_response({From, TermCause}, timeout, #gtp{type = delete_bearer_request},
		_State, Data) ->
    ergw_gtp_gsn_lib:close_context(TermCause, Data),
    if is_tuple(From) -> gen_statem:reply(From, {error, timeout});
       true -> ok
    end,
    {next_state, shutdown, Data};

handle_response({From, TermCause},
		#gtp{type = delete_bearer_response,
		     ie = #{?'Cause' := #v2_cause{v2_cause = Cause}}} = Response,
		_Request, _State, #{left_tunnel := LeftTunnel0} = Data) ->
    LeftTunnel = gtp_path:bind(Response, LeftTunnel0),

    DataNew = Data#{left_tunnel => LeftTunnel},

    ergw_gtp_gsn_lib:close_context(TermCause, Data),
    if is_tuple(From) -> gen_statem:reply(From, {ok, Cause});
       true -> ok
    end,
    {next_state, shutdown, DataNew};

handle_response(_CommandReqKey, _Response, _Request, State, _Data)
  when State =/= connected ->
    keep_state_and_data.

terminate(_Reason, _State, #{context := Context}) ->
    ergw_gsn_lib:release_context_ips(Context),
    ok.

%%%===================================================================
%%% Helper functions
%%%===================================================================
ip2prefix({IP, Prefix}) ->
    <<Prefix:8, (ergw_inet:ip2bin(IP))/binary>>.

%% response/3
response(Cmd, #tunnel{remote = #fq_teid{teid = TEID}}, Response) ->
    {Cmd, TEID, Response}.

%% response/4
response(Cmd, Tunnel, IEs0, #gtp{ie = ReqIEs})
  when is_record(Tunnel, tunnel) ->
    IEs = gtp_v2_c:build_recovery(Cmd, Tunnel, is_map_key(?'Recovery', ReqIEs), IEs0),
    response(Cmd, Tunnel, IEs).

match_tunnel(_Type, _Expected, undefined) ->
    ok;
match_tunnel(Type, #fq_teid{ip = RemoteCntlIP, teid = RemoteCntlTEI} = Expected,
	     #v2_fully_qualified_tunnel_endpoint_identifier{
		instance       = 0,
		interface_type = Type,
		key            = RemoteCntlTEI,
		ipv4           = RemoteCntlIP4,
		ipv6           = RemoteCntlIP6} = IE) ->
    case ergw_inet:ip2bin(RemoteCntlIP) of
	RemoteCntlIP4 ->
	    ok;
	RemoteCntlIP6 ->
	    ok;
	_ ->
	    ?LOG(error, "match_tunnel: IP address mismatch, ~p, ~p, ~p",
			[Type, Expected, IE]),
	    {error, [#v2_cause{v2_cause = invalid_peer}]}
    end;
match_tunnel(Type, Expected, IE) ->
    ?LOG(error, "match_tunnel: FqTEID not found, ~p, ~p, ~p",
		[Type, Expected, IE]),
    {error, [#v2_cause{v2_cause = invalid_peer}]}.

pdn_alloc(#v2_pdn_address_allocation{type = non_ip}) ->
    {'Non-IP', undefined, undefined};
pdn_alloc(#v2_pdn_address_allocation{type = ipv4v6,
				     address = << IP6PrefixLen:8, IP6Prefix:16/binary, IP4:4/binary>>}) ->
    {'IPv4v6', ergw_inet:bin2ip(IP4), {ergw_inet:bin2ip(IP6Prefix), IP6PrefixLen}};
pdn_alloc(#v2_pdn_address_allocation{type = ipv4,
				     address = << IP4:4/binary>>}) ->
    {'IPv4', ergw_inet:bin2ip(IP4), undefined};
pdn_alloc(#v2_pdn_address_allocation{type = ipv6,
				     address = << IP6PrefixLen:8, IP6Prefix:16/binary>>}) ->
    {'IPv6', undefined, {ergw_inet:bin2ip(IP6Prefix), IP6PrefixLen}}.

encode_paa(IPv4, undefined) when IPv4 /= undefined ->
    encode_paa(ipv4, ergw_inet:ip2bin(ergw_ip_pool:addr(IPv4)), <<>>);
encode_paa(undefined, IPv6) when IPv6 /= undefined ->
    encode_paa(ipv6, <<>>, ip2prefix(ergw_ip_pool:ip(IPv6)));
encode_paa(IPv4, IPv6) when IPv4 /= undefined, IPv6 /= undefined ->
    encode_paa(ipv4v6, ergw_inet:ip2bin(ergw_ip_pool:addr(IPv4)),
	       ip2prefix(ergw_ip_pool:ip(IPv6))).

encode_paa(Type, IPv4, IPv6) ->
    #v2_pdn_address_allocation{type = Type, address = <<IPv6/binary, IPv4/binary>>}.

close_context(_Side, Reason, _State, Data) ->
    ergw_gtp_gsn_lib:close_context(Reason, Data).

copy_ppp_to_session({pap, 'PAP-Authentication-Request', _Id, Username, Password}, Session0) ->
    Session = Session0#{'Username' => Username, 'Password' => Password},
    maps:without(['CHAP-Challenge', 'CHAP_Password'], Session);
copy_ppp_to_session({chap, 'CHAP-Challenge', _Id, Value, _Name}, Session) ->
    Session#{'CHAP_Challenge' => Value};
copy_ppp_to_session({chap, 'CHAP-Response', _Id, Value, Name}, Session0) ->
    Session = Session0#{'CHAP_Password' => Value, 'Username' => Name},
    maps:without(['Password'], Session);
copy_ppp_to_session(_, Session) ->
    Session.

non_empty_ip(_, {0,0,0,0}, Opts) ->
    Opts;
non_empty_ip(_, {{0,0,0,0,0,0,0,0}, _}, Opts) ->
    Opts;
non_empty_ip(Key, IP, Opts) ->
    maps:put(Key, IP, Opts).

copy_to_session(_, #v2_protocol_configuration_options{config = {0, Options}},
		#{'Username' := #{from_protocol_opts := true}}, Session) ->
    lists:foldr(fun copy_ppp_to_session/2, Session, Options);
copy_to_session(_, #v2_access_point_name{apn = APN}, _AAAopts, Session) ->
    {NI, _OI} = ergw_node_selection:split_apn(APN),
    Session#{'Called-Station-Id' =>
		 iolist_to_binary(lists:join($., NI))};
copy_to_session(_, #v2_msisdn{msisdn = MSISDN}, _AAAopts, Session) ->
    Session#{'Calling-Station-Id' => MSISDN, '3GPP-MSISDN' => MSISDN};
copy_to_session(_, #v2_international_mobile_subscriber_identity{imsi = IMSI}, _AAAopts, Session) ->
    case itu_e212:split_imsi(IMSI) of
	{MCC, MNC, _} ->
	    Session#{'3GPP-IMSI' => IMSI,
		     '3GPP-IMSI-MCC-MNC' => <<MCC/binary, MNC/binary>>};
	_ ->
	    Session#{'3GPP-IMSI' => IMSI}
    end;

copy_to_session(_, #v2_pdn_address_allocation{type = ipv4,
					      address = IP4}, _AAAopts, Session) ->
    IP4addr = ergw_inet:bin2ip(IP4),
    S0 = Session#{'3GPP-PDP-Type' => 'IPv4'},
    S1 = non_empty_ip('Framed-IP-Address', IP4addr, S0),
    _S = non_empty_ip('Requested-IP-Address', IP4addr, S1);
copy_to_session(_, #v2_pdn_address_allocation{type = ipv6,
					      address = <<IP6PrefixLen:8,
							  IP6Prefix:16/binary>>},
		_AAAopts, Session) ->
    IP6addr = {ergw_inet:bin2ip(IP6Prefix), IP6PrefixLen},
    S0 = Session#{'3GPP-PDP-Type' => 'IPv6'},
    S1 = non_empty_ip('Framed-IPv6-Prefix', IP6addr, S0),
    _S = non_empty_ip('Requested-IPv6-Prefix', IP6addr, S1);
copy_to_session(_, #v2_pdn_address_allocation{type = ipv4v6,
					      address = <<IP6PrefixLen:8,
							  IP6Prefix:16/binary,
							  IP4:4/binary>>},
		_AAAopts, Session) ->
    IP4addr = ergw_inet:bin2ip(IP4),
    IP6addr = {ergw_inet:bin2ip(IP6Prefix), IP6PrefixLen},
    S0 = Session#{'3GPP-PDP-Type' => 'IPv4v6'},
    S1 = non_empty_ip('Framed-IP-Address', IP4addr, S0),
    S2 = non_empty_ip('Requested-IP-Address', IP4addr, S1),
    S3 = non_empty_ip('Framed-IPv6-Prefix', IP6addr, S2),
    _S = non_empty_ip('Requested-IPv6-Prefix', IP6addr, S3);
copy_to_session(_, #v2_pdn_address_allocation{type = non_ip}, _AAAopts, Session) ->
    Session#{'3GPP-PDP-Type' => 'Non-IP'};

%% 3GPP TS 29.274, Rel 15, Table 7.2.1-1, Note 1:
%%   The conditional PDN Type IE is redundant on the S4/S11 and S5/S8 interfaces
%%   (as the PAA IE contains exactly the same field). The receiver may ignore it.
%%

copy_to_session(?'Bearer Contexts to be created',
		#v2_bearer_context{group = #{?'EPS Bearer ID' :=
						 #v2_eps_bearer_id{eps_bearer_id = EBI}}},
		_AAAopts, Session) ->
    Session#{'3GPP-NSAPI' => EBI};
copy_to_session(_, #v2_selection_mode{mode = Mode}, _AAAopts, Session) ->
    Session#{'3GPP-Selection-Mode' => Mode};
copy_to_session(_, #v2_charging_characteristics{value = Value}, _AAAopts, Session) ->
    Session#{'3GPP-Charging-Characteristics' => Value};

copy_to_session(_, #v2_serving_network{mcc = MCC, mnc = MNC}, _AAAopts, Session) ->
    Session#{'3GPP-SGSN-MCC-MNC' => <<MCC/binary, MNC/binary>>};
copy_to_session(_, #v2_mobile_equipment_identity{mei = IMEI}, _AAAopts, Session) ->
    Session#{'3GPP-IMEISV' => IMEI};
copy_to_session(_, #v2_rat_type{rat_type = Type}, _AAAopts, Session) ->
    Session#{'3GPP-RAT-Type' => Type};

%% 0        CGI
%% 1        SAI
%% 2        RAI
%% 3-127    Spare for future use
%% 128      TAI
%% 129      ECGI
%% 130      TAI and ECGI
%% 131-255  Spare for future use

copy_to_session(_, #v2_user_location_information{tai = TAI, ecgi = ECGI}, _AAAopts, Session)
  when is_binary(TAI), is_binary(ECGI) ->
    Value = <<130, TAI/binary, ECGI/binary>>,
    Session#{'TAI' => TAI, 'ECGI' => ECGI, '3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{ecgi = ECGI}, _AAAopts, Session)
  when is_binary(ECGI) ->
    Value = <<129, ECGI/binary>>,
    Session#{'ECGI' => ECGI, '3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{tai = TAI}, _AAAopts, Session)
  when is_binary(TAI) ->
    Value = <<128, TAI/binary>>,
    Session#{'TAI' => TAI, '3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{rai = RAI}, _AAAopts, Session)
  when is_binary(RAI) ->
    Value = <<2, RAI/binary>>,
    Session#{'RAI' => RAI, '3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{sai = SAI}, _AAAopts, Session0)
  when is_binary(SAI) ->
    Session = maps:without(['CGI'], Session0#{'SAI' => SAI}),
    Value = <<1, SAI/binary>>,
    Session#{'3GPP-User-Location-Info' => Value};
copy_to_session(_, #v2_user_location_information{cgi = CGI}, _AAAopts, Session0)
  when is_binary(CGI) ->
    Session = maps:without(['SAI'], Session0#{'CGI' => CGI}),
    Value = <<0, CGI/binary>>,
    Session#{'3GPP-User-Location-Info' => Value};

copy_to_session(_, #v2_ue_time_zone{timezone = TZ, dst = DST}, _AAAopts, Session) ->
    Session#{'3GPP-MS-TimeZone' => {TZ, DST}};
copy_to_session(_, _, _AAAopts, Session) ->
    Session.

copy_qos_to_session(#{?'Bearer Contexts to be created' :=
			  #v2_bearer_context{
			     group = #{?'Bearer Level QoS' :=
					   #v2_bearer_level_quality_of_service{
					      pci = PCI, pl = PL, pvi = PVI, label = Label,
					      maximum_bit_rate_for_uplink = MBR4ul,
					      maximum_bit_rate_for_downlink = MBR4dl,
					      guaranteed_bit_rate_for_uplink = GBR4ul,
					      guaranteed_bit_rate_for_downlink = GBR4dl}}},
		      ?'APN-AMBR' :=
			  #v2_aggregate_maximum_bit_rate{
			     uplink = AMBR4ul, downlink = AMBR4dl}},
		    Session) ->
    ARP = #{
	    'Priority-Level' => PL,
	    'Pre-emption-Capability' => PCI,
	    'Pre-emption-Vulnerability' => PVI
	   },
    Info = #{
	     'QoS-Class-Identifier' => Label,
	     'Max-Requested-Bandwidth-UL' => MBR4ul * 1000,
	     'Max-Requested-Bandwidth-DL' => MBR4dl * 1000,
	     'Guaranteed-Bitrate-UL' => GBR4ul * 1000,
	     'Guaranteed-Bitrate-DL' => GBR4dl * 1000,

	     %% TBD:
	     %%   [ Bearer-Identifier ]

	     'Allocation-Retention-Priority' => ARP,
	     'APN-Aggregate-Max-Bitrate-UL' => AMBR4ul * 1000,
	     'APN-Aggregate-Max-Bitrate-DL' => AMBR4dl * 1000

	     %%  *[ Conditional-APN-Aggregate-Max-Bitrate ]
	    },
    Session#{'QoS-Information' => Info};
copy_qos_to_session(_, Session) ->
    Session.

copy_tunnel_to_session(#tunnel{remote = #fq_teid{ip = {_,_,_,_} = IP}}, Session) ->
    Session#{'3GPP-SGSN-Address' => IP};
copy_tunnel_to_session(#tunnel{remote = #fq_teid{ip = {_,_,_,_,_,_,_,_} = IP}}, Session) ->
    Session#{'3GPP-SGSN-IPv6-Address' => IP};
copy_tunnel_to_session(_, Session) ->
    Session.

update_session_from_gtp_req(IEs, Session, Tunnel)
  when is_record(Tunnel, tunnel) ->
    OldSOpts = ergw_aaa_session:get(Session),
    NewSOpts0 = copy_qos_to_session(IEs, OldSOpts),
    NewSOpts1 = copy_tunnel_to_session(Tunnel, NewSOpts0),
    NewSOpts =
	maps:fold(copy_to_session(_, _, undefined, _), NewSOpts1, IEs),
    ergw_aaa_session:set(Session, NewSOpts),
    gtp_context:collect_charging_events(OldSOpts, NewSOpts).

get_context_from_req(?'Access Point Name', #v2_access_point_name{apn = APN}, Context) ->
    Context#context{apn = APN};
get_context_from_req(?'IMSI', #v2_international_mobile_subscriber_identity{imsi = IMSI}, Context) ->
    Context#context{imsi = IMSI};
get_context_from_req(?'ME Identity', #v2_mobile_equipment_identity{mei = IMEI}, Context) ->
    Context#context{imei = IMEI};
get_context_from_req(?'MSISDN', #v2_msisdn{msisdn = MSISDN}, Context) ->
    Context#context{msisdn = MSISDN};
get_context_from_req(?'PDN Address Allocation', #v2_pdn_address_allocation{type = Type}, Context) ->
    Context#context{pdn_type = Type};
get_context_from_req(_, _, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs} = Req, Context0) ->
    Context1 = gtp_v2_c:update_context_id(Req, Context0),
    maps:fold(fun get_context_from_req/3, Context1, IEs).

get_tunnel_from_bearer(none, _, Bearer) ->
    {ok, Bearer};
get_tunnel_from_bearer({_, #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S1-U eNode-B',
			      key = TEI, ipv4 = IP4, ipv6 = IP6}, Next}, Tunnel, Bearer) ->
    do([error_m ||
	   IP <- ergw_gsn_lib:choose_ip_by_tunnel(Tunnel, IP4, IP6),
	   begin
	       FqTEID = #fq_teid{ip = ergw_inet:bin2ip(IP), teid = TEI},
	       get_tunnel_from_bearer(maps:next(Next), Tunnel, Bearer#bearer{remote = FqTEID})
	   end]);
get_tunnel_from_bearer({_, _, Next}, Tunnel, Bearer) ->
    get_tunnel_from_bearer(maps:next(Next), Tunnel, Bearer).

get_tunnel_from_req(none, Tunnel, Bearer) ->
    {ok, {Tunnel, Bearer}};
get_tunnel_from_req({?'Sender F-TEID for Control Plane',
		     #v2_fully_qualified_tunnel_endpoint_identifier{
			key = TEI, ipv4 = IP4, ipv6 = IP6}, Next},
		    Tunnel, Bearer) ->
    do([error_m ||
	   IP <- ergw_gsn_lib:choose_ip_by_tunnel(Tunnel, IP4, IP6),
	   begin
	       FqTEID = #fq_teid{ip = ergw_inet:bin2ip(IP), teid = TEI},
	       get_tunnel_from_req(
		 maps:next(Next), Tunnel#tunnel{remote = FqTEID}, Bearer)
	   end]);
get_tunnel_from_req({_, #v2_bearer_context{instance = 0, group = Group}, Next},
		    Tunnel, Bearer0) ->
    do([error_m ||
	   Bearer <- get_tunnel_from_bearer(maps:next(maps:iterator(Group)), Tunnel, Bearer0),
	   get_tunnel_from_req(maps:next(Next), Tunnel, Bearer)
       ]);
get_tunnel_from_req({_, _, Next}, Tunnel, Bearer) ->
   get_tunnel_from_req(maps:next(Next), Tunnel, Bearer).

%% update_tunnel_from_gtp_req/3
update_tunnel_from_gtp_req(#gtp{ie = IEs}, Tunnel, Bearer) ->
    get_tunnel_from_req(maps:next(maps:iterator(IEs)), Tunnel, Bearer).

enter_ie(_Key, Value, IEs)
  when is_list(IEs) ->
    [Value|IEs].
%% enter_ie(Key, Value, IEs)
%%   when is_map(IEs) ->
%%     IEs#{Key := Value}.

copy_ies_to_response(_, ResponseIEs, []) ->
    ResponseIEs;
copy_ies_to_response(RequestIEs, ResponseIEs0, [H|T]) ->
    ResponseIEs =
	case RequestIEs of
	    #{H := Value} ->
		enter_ie(H, Value, ResponseIEs0);
	    _ ->
		ResponseIEs0
	end,
    copy_ies_to_response(RequestIEs, ResponseIEs, T).


msg(#tunnel{remote = #fq_teid{teid = RemoteCntlTEI}}, Type, RequestIEs) ->
    #gtp{version = v2, type = Type, tei = RemoteCntlTEI, ie = RequestIEs}.

send_request(Tunnel, DstIP, DstPort, T3, N3, Msg, ReqInfo) ->
    gtp_context:send_request(Tunnel, DstIP, DstPort, T3, N3, Msg, ReqInfo).

send_request(#tunnel{remote = #fq_teid{ip = RemoteCntlIP}} = Tunnel, T3, N3, Msg, ReqInfo) ->
    send_request(Tunnel, RemoteCntlIP, ?GTP2c_PORT, T3, N3, Msg, ReqInfo).

send_request(Tunnel, T3, N3, Type, RequestIEs, ReqInfo) ->
    send_request(Tunnel, T3, N3, msg(Tunnel, Type, RequestIEs), ReqInfo).

delete_context(From, TermCause, connected, #{left_tunnel := Tunnel} = Data) ->
    Type = delete_bearer_request,
    EBI = 5,
    RequestIEs0 = [#v2_cause{v2_cause = reactivation_requested},
		   #v2_eps_bearer_id{eps_bearer_id = EBI}],
    RequestIEs = gtp_v2_c:build_recovery(Type, Tunnel, false, RequestIEs0),
    send_request(Tunnel, ?T3, ?N3, Type, RequestIEs, {From, TermCause}),
    {next_state, shutdown_initiated, Data};
delete_context(undefined, _, _, _) ->
    keep_state_and_data;
delete_context(From, _, _, _) ->
    {keep_state_and_data, [{reply, From, ok}]}.

ppp_ipcp_conf_resp(Verdict, Opt, IPCP) ->
    maps:update_with(Verdict, fun(O) -> [Opt|O] end, [Opt], IPCP).

ppp_ipcp_conf(#{'MS-Primary-DNS-Server' := DNS}, {ms_dns1, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_dns1, ergw_inet:ip2bin(DNS)}, IPCP);
ppp_ipcp_conf(#{'MS-Secondary-DNS-Server' := DNS}, {ms_dns2, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_dns2, ergw_inet:ip2bin(DNS)}, IPCP);
ppp_ipcp_conf(#{'MS-Primary-NBNS-Server' := DNS}, {ms_wins1, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_wins1, ergw_inet:ip2bin(DNS)}, IPCP);
ppp_ipcp_conf(#{'MS-Secondary-NBNS-Server' := DNS}, {ms_wins2, <<0,0,0,0>>}, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Nak', {ms_wins2, ergw_inet:ip2bin(DNS)}, IPCP);

ppp_ipcp_conf(_SessionOpts, Opt, IPCP) ->
    ppp_ipcp_conf_resp('CP-Configure-Reject', Opt, IPCP).

pdn_ppp_pco(SessionOpts, {pap, 'PAP-Authentication-Request', Id, _Username, _Password}, Opts) ->
    [{pap, 'PAP-Authenticate-Ack', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdn_ppp_pco(SessionOpts, {chap, 'CHAP-Response', Id, _Value, _Name}, Opts) ->
    [{chap, 'CHAP-Success', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdn_ppp_pco(SessionOpts, {ipcp,'CP-Configure-Request', Id, CpReqOpts}, Opts) ->
    CpRespOpts = lists:foldr(ppp_ipcp_conf(SessionOpts, _, _), #{}, CpReqOpts),
    maps:fold(fun(K, V, O) -> [{ipcp, K, Id, V} | O] end, Opts, CpRespOpts);

pdn_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv6-Address', <<>>}, Opts) ->
    [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
     || DNS <- maps:get('DNS-Server-IPv6-Address', SessionOpts, [])]
	++ [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
	    || DNS <- maps:get('3GPP-IPv6-DNS-Servers', SessionOpts, [])]
	++ Opts;
pdn_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv4-Address', <<>>}, Opts) ->
    lists:foldr(fun(Key, O) ->
			case maps:find(Key, SessionOpts) of
			    {ok, DNS} ->
				[{?'PCO-DNS-Server-IPv4-Address', ergw_inet:ip2bin(DNS)} | O];
			    _ ->
				O
			end
		end, Opts, ['MS-Secondary-DNS-Server', 'MS-Primary-DNS-Server']);
pdn_ppp_pco(_SessionOpts, PPPReqOpt, Opts) ->
    ?LOG(debug, "Apply PPP Opt: ~p", [PPPReqOpt]),
    Opts.

pdn_pco(SessionOpts, #{?'Protocol Configuration Options' :=
			   #v2_protocol_configuration_options{config = {0, PPPReqOpts}}}, IE) ->
    case lists:foldr(pdn_ppp_pco(SessionOpts, _, _), [], PPPReqOpts) of
	[]   -> IE;
	Opts -> [#v2_protocol_configuration_options{config = {0, Opts}} | IE]
    end;
pdn_pco(_SessionOpts, _RequestIEs, IE) ->
    IE.

bearer_context(EBI, Bearer, Context, IEs) ->
    maps:fold(bearer_context(EBI, _, _, Context, _), IEs, Bearer).

bearer_context(EBI, left, Bearer, _Context, IEs) ->
    IE = #v2_bearer_context{
	    group=[#v2_cause{v2_cause = request_accepted},
		   EBI,
		   #v2_bearer_level_quality_of_service{
		      pl=15,
		      pvi=0,
		      label=9,maximum_bit_rate_for_uplink=0,
		      maximum_bit_rate_for_downlink=0,
		      guaranteed_bit_rate_for_uplink=0,
		      guaranteed_bit_rate_for_downlink=0},
		   %% F-TEID for S1-U SGW GTP-U ???
		   s1_sgw_gtp_u_tei(Bearer),
		   s5s8_pgw_gtp_u_tei(Bearer)]},
    [IE | IEs];
bearer_context(_, _, _, _, IEs) ->
    IEs.

fq_teid(Instance, Type, TEI, {_,_,_,_} = IP) ->
    #v2_fully_qualified_tunnel_endpoint_identifier{
       instance = Instance, interface_type = Type,
       key = TEI, ipv4 = ergw_inet:ip2bin(IP)};
fq_teid(Instance, Type, TEI, {_,_,_,_,_,_,_,_} = IP) ->
    #v2_fully_qualified_tunnel_endpoint_identifier{
       instance = Instance, interface_type = Type,
       key = TEI, ipv6 = ergw_inet:ip2bin(IP)}.

s11_sender_f_teid(#tunnel{local = #fq_teid{ip = IP, teid = TEI}}) ->
    fq_teid(0, ?'S11/S4-C SGW', TEI, IP).

s1_sgw_gtp_u_tei(#bearer{local = #fq_teid{ip = IP, teid = TEI}}) ->
    fq_teid(0, ?'S1-U SGW', TEI, IP).

s5s8_pgw_gtp_c_tei(#tunnel{local = #fq_teid{ip = IP, teid = TEI}}) ->
    %% PGW S5/S8/ S2a/S2b F-TEID for PMIP based interface
    %% or for GTP based Control Plane interface
    fq_teid(1, ?'S5/S8-C PGW', TEI, IP).

s5s8_pgw_gtp_u_tei(#bearer{local = #fq_teid{ip = IP, teid = TEI}}) ->
    %% S5/S8 F-TEI Instance
    fq_teid(2, ?'S5/S8-U PGW', TEI, IP).

cr_ran_type(1)  -> 'UTRAN';
cr_ran_type(2)  -> 'UTRAN';
cr_ran_type(6)  -> 'EUTRAN';
cr_ran_type(8)  -> 'EUTRAN';
cr_ran_type(9)  -> 'EUTRAN';
cr_ran_type(10) -> 'NR';
cr_ran_type(_)  -> undefined.

%% it is unclear from TS 29.274 if the CRA IE can only be included when the
%% SGSN/MME has indicated support for it in the Indication IE.
%% Some comments in Modify Bearer Request suggest that it might be possbile
%% to unconditionally set it, other places state that is should only be sent
%% when the SGSN/MME indicated support for it.
%% For the moment only include it when the CRSI flag was set.

change_reporting_action(true, ENBCRSI, #{?'RAT Type' :=
					     #v2_rat_type{rat_type = Type}}, Trigger, IE) ->
    change_reporting_action(ENBCRSI, cr_ran_type(Type), Trigger, IE);
change_reporting_action(_, _, _, _, IE) ->
    IE.

change_reporting_action(true, 'EUTRAN', #{'tai-change' := true,
					  'user-location-info-change' := true}, IE) ->
    [#v2_change_reporting_action{
	action = start_reporting_tai__macro_enodeb_id_and_extended_macro_enodeb_id}|IE];
change_reporting_action(true, 'EUTRAN', #{'user-location-info-change' := true}, IE) ->
    [#v2_change_reporting_action{
	action = start_reporting_macro_enodeb_id_and_extended_macro_enodeb_id}|IE];
change_reporting_action(_, 'EUTRAN', #{'tai-change' := true, 'ecgi-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_tai_and_ecgi}|IE];
change_reporting_action(_, 'EUTRAN', #{'tai-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_tai}|IE];
change_reporting_action(_, 'EUTRAN', #{'ecgi-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_ecgi}|IE];
change_reporting_action(_, 'UTRAN', #{'user-location-info-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_cgi_sai_and_rai}|IE];
change_reporting_action(_, 'UTRAN', #{'cgi-sai-change' := true, 'rai-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_cgi_sai_and_rai}|IE];
change_reporting_action(_, 'UTRAN', #{'cgi-sai-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_cgi_sai}|IE];
change_reporting_action(_, 'UTRAN', #{'rai-change' := true}, IE) ->
    [#v2_change_reporting_action{action = start_reporting_rai}|IE];
change_reporting_action(_, _, _Triggers, IE) ->
    IE.

change_reporting_actions(RequestIEs, IE0) ->
    Indications = gtp_v2_c:get_indication_flags(RequestIEs),
    Triggers = ergw_charging:reporting_triggers(),

    CRSI = proplists:get_bool('CRSI', Indications),
    ENBCRSI = proplists:get_bool('ENBCRSI', Indications),
    _IE = change_reporting_action(CRSI, ENBCRSI, RequestIEs, Triggers, IE0).

create_session_response(Result, SessionOpts, RequestIEs, EBI,
			Tunnel, Bearer,
			#context{ms_ip = #ue_ip{v4 = MSv4, v6 = MSv6}} = Context) ->

    IE0 = bearer_context(EBI, Bearer, Context, []),
    IE1 = pdn_pco(SessionOpts, RequestIEs, IE0),
    IE2 = change_reporting_actions(RequestIEs, IE1),

    [Result,
     %% Sender F-TEID for Control Plane
     s11_sender_f_teid(Tunnel),
     s5s8_pgw_gtp_c_tei(Tunnel),
     #v2_apn_restriction{restriction_type_value = 0},
     encode_paa(MSv4, MSv6) | IE2].

%% Wrapper for gen_statem state_callback_result Actions argument
%% Timeout set in the context of a prolonged idle gtpv2 session
context_idle_action(Actions, #context{'Idle-Timeout' = Timeout})
  when is_integer(Timeout) orelse Timeout =:= infinity ->
    [{{timeout, context_idle}, Timeout, stop_session} | Actions];
context_idle_action(Actions, _) ->
    Actions.
