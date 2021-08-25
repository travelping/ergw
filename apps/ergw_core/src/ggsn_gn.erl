%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn).

-behaviour(gtp_api).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([validate_options/1, init/2, request_spec/3,
	 handle_pdu/4,
	 handle_request/5, handle_response/5,
	 handle_event/4, terminate/3]).

-export([delete_context/4, close_context/5]).

%% PFCP context API's
%%-export([defered_usage_report/3]).

%% shared API's
-export([init_session/4,
	 init_session_from_gtp_req/5,
	 update_tunnel_from_gtp_req/3,
	 update_context_from_gtp_req/2
	]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").
-include("include/3gpp.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define(API, 'gn/gp').
-define(T3, 10 * 1000).
-define(N3, 5).

%%====================================================================
%% API
%%====================================================================

-define('Cause',					{cause, 0}).
-define('IMSI',						{international_mobile_subscriber_identity, 0}).
-define('Recovery',					{recovery, 0}).
-define('Tunnel Endpoint Identifier Data I',		{tunnel_endpoint_identifier_data_i, 0}).
-define('Tunnel Endpoint Identifier Control Plane',	{tunnel_endpoint_identifier_control_plane, 0}).
-define('NSAPI',					{nsapi, 0}).
-define('End User Address',				{end_user_address, 0}).
-define('Access Point Name',				{access_point_name, 0}).
-define('Protocol Configuration Options',		{protocol_configuration_options, 0}).
-define('SGSN Address for signalling',			{gsn_address, 0}).
-define('SGSN Address for user traffic',		{gsn_address, 1}).
-define('MSISDN',					{ms_international_pstn_isdn_number, 0}).
-define('Quality of Service Profile',			{quality_of_service_profile, 0}).
-define('IMEI',						{imei, 0}).
-define('APN-AMBR',					{aggregate_maximum_bit_rate, 0}).
-define('Evolved ARP I',				{evolved_allocation_retention_priority_i, 0}).

-define(CAUSE_OK(Cause), (Cause =:= request_accepted orelse
			  Cause =:= new_pdp_type_due_to_network_preference orelse
			  Cause =:= new_pdp_type_due_to_single_address_bearer_only)).

request_spec(v1, _Type, Cause)
  when Cause /= undefined andalso not ?CAUSE_OK(Cause) ->
    [];

request_spec(v1, create_pdp_context_request, _) ->
    [{?'Tunnel Endpoint Identifier Data I',		mandatory},
     {?'NSAPI',						mandatory},
     {?'SGSN Address for signalling',			mandatory},
     {?'SGSN Address for user traffic',			mandatory},
     {?'Quality of Service Profile',			mandatory}];

request_spec(v1, update_pdp_context_request, _) ->
    [{?'Tunnel Endpoint Identifier Data I',		mandatory},
     {?'NSAPI',						mandatory},
     {?'SGSN Address for signalling',			mandatory},
     {?'SGSN Address for user traffic',			mandatory},
     {?'Quality of Service Profile',			mandatory}];

request_spec(v1, _, _) ->
    [].

-define(HandlerDefaults, [{protocol, undefined}]).

validate_options(Options) ->
    ?LOG(debug, "GGSN Gn/Gp Options: ~p", [Options]),
    gtp_context:validate_options(fun validate_option/2, Options, ?HandlerDefaults).

validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

init(_Opts, Data) ->
    {ok, Session} = ergw_aaa_session_sup:new_session(self(), to_session([])),
    SessionOpts = ergw_aaa_session:get(Session),
    OCPcfg = maps:get('Offline-Charging-Profile', SessionOpts, #{}),
    PCC = #pcc_ctx{offline_charging_profile = OCPcfg},
    {ok, run, Data#{'Version' => v1, 'Session' => Session, pcc => PCC}}.

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event(cast, {packet_in, _Socket, _IP, _Port, _Msg}, _State, _Data) ->
    ?LOG(warning, "packet_in not handled (yet): ~p", [_Msg]),
    keep_state_and_data;

handle_event({timeout, context_idle}, check_session_liveness, State,
	     #{context := Context, pfcp := PCtx} = Data) ->
    case ergw_pfcp_context:session_liveness_check(PCtx) of
	ok ->
	    send_context_alive_request(Data),
	    Actions = context_idle_action([], Context),
	    {keep_state, Data, Actions};
	_ ->
	    delete_context(undefined, cp_inactivity_timeout, State, Data)
    end;

handle_event(info, _Info, _State, Data) ->
    ?LOG(warning, "~p, handle_info(~p, ~p)", [?MODULE, _Info, Data]),
    keep_state_and_data.

handle_pdu(ReqKey, #gtp{ie = PDU} = Msg, _State,
	   #{context := Context, pfcp := PCtx,
	     bearer := #{left := LeftBearer, right := RightBearer}} = Data) ->
    ?LOG(debug, "GTP-U GGSN: ~p, ~p", [ReqKey, gtp_c_lib:fmt_gtp(Msg)]),

    ergw_gsn_lib:ip_pdu(PDU, LeftBearer, RightBearer, Context, PCtx),
    {keep_state, Data}.

%% resent request
handle_request(_ReqKey, _Msg, true, _State, _Data) ->
    %% resent request
    keep_state_and_data;

handle_request(ReqKey,
	       #gtp{type = create_pdp_context_request,
		    ie = #{
			   ?'Access Point Name' := #access_point_name{apn = APN}
			  } = IEs} = Request, _Resent, _State,
	       #{context := Context0, aaa_opts := AAAopts, node_selection := NodeSelect,
		 left_tunnel := LeftTunnel0, bearer := #{left := LeftBearer0},
		 'Session' := Session, pcc := PCC0} = Data) ->
    Services = [{'x-3gpp-upf', 'x-sxb'}],

    {ok, UpSelInfo} =
	ergw_gtp_gsn_lib:connect_upf_candidates(APN, Services, NodeSelect, []),

    EUA = maps:get(?'End User Address', IEs, undefined),
    DAF = proplists:get_bool('Dual Address Bearer Flag', gtp_v1_c:get_common_flags(IEs)),

    Context1 = update_context_from_gtp_req(Request, Context0),

    {LeftTunnel1, LeftBearer1} =
	case update_tunnel_from_gtp_req(Request, LeftTunnel0, LeftBearer0) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context1, tunnel = LeftTunnel0})
	end,

    LeftTunnel =
	case gtp_path:bind_tunnel(LeftTunnel1) of
	    {ok, LT} -> LT;
	    {error, #ctx_err{} = Err2} ->
		throw(Err2#ctx_err{context = Context1, tunnel = LeftTunnel1});
	    {error, _} ->
		throw(?CTX_ERR(?FATAL, system_failure))
	end,

    gtp_context:terminate_colliding_context(LeftTunnel, Context1),

    SessionOpts0 = init_session(IEs, LeftTunnel, Context1, AAAopts),
    SessionOpts1 = init_session_from_gtp_req(IEs, AAAopts, LeftTunnel, LeftBearer1, SessionOpts0),
    SessionOpts2 = init_session_qos(IEs, SessionOpts1),


    {Verdict, Cause, SessionOpts, Context, Bearer, PCC4, PCtx} =
	case ergw_gtp_gsn_lib:create_session(APN, pdp_alloc(EUA), DAF, UpSelInfo, Session,
					     SessionOpts2, Context1, LeftTunnel, LeftBearer1, PCC0) of
	   {ok, Result} -> Result;
	   {error, Err} -> throw(Err)
       end,

    FinalData =
	Data#{context => Context, pfcp => PCtx, pcc => PCC4,
	      left_tunnel => LeftTunnel, bearer => Bearer},

    ResponseIEs = create_pdp_context_response(Cause, SessionOpts, Request, LeftTunnel, Bearer, Context),
    Response = response(create_pdp_context_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    case Verdict of
	ok ->
	    Actions = context_idle_action([], Context),
	    {next_state, connected, FinalData, Actions};
	_ ->
	    {next_state, shutdown, FinalData}
    end;

handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request,
		    ie = #{?'Quality of Service Profile' := ReqQoSProfile} = IEs} = Request,
	       _Resent, _State,
	       #{context := Context, pfcp := PCtx0,
		 left_tunnel := LeftTunnelOld,
		 bearer := #{left := LeftBearerOld} = Bearer0,
		 'Session' := Session, pcc := PCC} = Data) ->
    {LeftTunnel0, LeftBearer} =
	case update_tunnel_from_gtp_req(
	       Request, LeftTunnelOld#tunnel{version = v1}, LeftBearerOld) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context, tunnel = LeftTunnelOld})
	end,
    Bearer = Bearer0#{left => LeftBearer},

    LeftTunnel = ergw_gtp_gsn_lib:update_tunnel_endpoint(LeftTunnelOld, LeftTunnel0),
    URRActions = update_session_from_gtp_req(IEs, Session, LeftTunnel, LeftBearer),
    PCtx =
	if LeftBearer /= LeftBearerOld ->
		case ergw_gtp_gsn_lib:apply_bearer_change(
		       Bearer, URRActions, false, PCtx0, PCC) of
		    {ok, {RPCtx, SessionInfo}} ->
			ergw_aaa_session:set(Session, SessionInfo),
			RPCtx;
		    {error, Err2} -> throw(Err2#ctx_err{context = Context, tunnel = LeftTunnel})
		end;
	   true ->
		gtp_context:trigger_usage_report(self(), URRActions, PCtx0),
		PCtx0
	end,

    ResponseIEs0 = [#cause{value = request_accepted},
		    context_charging_id(Context),
		    ReqQoSProfile],
    ResponseIEs1 = tunnel_elements(LeftTunnel, ResponseIEs0),
    ResponseIEs = bearer_elements(Bearer, ResponseIEs1),
    Response = response(update_pdp_context_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    DataNew = Data#{pfcp => PCtx, left_tunnel => LeftTunnel, bearer => Bearer},
    Actions = context_idle_action([], Context),
    {keep_state, DataNew, Actions};

handle_request(ReqKey,
	       #gtp{type = ms_info_change_notification_request, ie = IEs} = Request,
	       _Resent, _State,
	       #{context := Context, pfcp := PCtx, left_tunnel := LeftTunnel,
		 bearer := #{left := LeftBearer}, 'Session' := Session}) ->
    URRActions = update_session_from_gtp_req(IEs, Session, LeftTunnel, LeftBearer),
    gtp_context:trigger_usage_report(self(), URRActions, PCtx),

    ResponseIEs0 = [#cause{value = request_accepted}],
    ResponseIEs = copy_ies_to_response(IEs, ResponseIEs0, [?'IMSI', ?'IMEI']),
    Response = response(ms_info_change_notification_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = context_idle_action([], Context),
    {keep_state_and_data, Actions};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request, ie = _IEs} = Request,
	       _Resent, _State, #{left_tunnel := LeftTunnel} = Data0) ->
    Data = ergw_gtp_gsn_lib:close_context(?API, normal, Data0),
    Response = response(delete_pdp_context_response, LeftTunnel, request_accepted),
    gtp_context:send_response(ReqKey, Request, Response),
    {next_state, shutdown, Data};

handle_request(ReqKey, _Msg, _Resent, _State, _Data) ->
    gtp_context:request_finished(ReqKey),
    keep_state_and_data.

handle_response(alive_check,
		#gtp{type = update_pdp_context_response,
		     ie = #{?'Cause' := #cause{value = request_accepted}}},
		_Request, _State, #{context := Context}) ->
    Actions = context_idle_action([], Context),
    {keep_state_and_data, Actions};

handle_response(alive_check,
		#gtp{type = update_pdp_context_response,
		     ie = #{?'Cause' := #cause{value = context_not_found}}},
		_Request, _State, Data0) ->
    Data = ergw_gtp_gsn_lib:close_context(?API, cp_inactivity_timeout, Data0),
    {next_state, shutdown, Data};

handle_response(alive_check, _, #gtp{type = update_pdp_context_request}, State, Data) ->
    %% cause /= Request Accepted or timeout
    delete_context(undefined, cp_inactivity_timeout, State, Data);

handle_response({From, TermCause}, timeout, #gtp{type = delete_pdp_context_request},
		_State, Data0) ->
    Data = ergw_gtp_gsn_lib:close_context(?API, TermCause, Data0),
    if is_tuple(From) -> gen_statem:reply(From, {error, timeout});
       true -> ok
    end,
    {next_state, shutdown, Data};

handle_response({From, TermCause},
		#gtp{type = delete_pdp_context_response,
		     ie = #{?'Cause' := #cause{value = Cause}}},
		_Request, _State,
		#{left_tunnel := LeftTunnel} = Data0) ->
    Data1 = Data0#{left_tunnel := LeftTunnel},

    Data = ergw_gtp_gsn_lib:close_context(?API, TermCause, Data1),
    if is_tuple(From) -> gen_statem:reply(From, {ok, Cause});
       true -> ok
    end,
    {next_state, shutdown, Data}.

terminate(_Reason, _State, #{pfcp := PCtx, context := Context}) ->
    ergw_pfcp_context:delete_session(terminate, PCtx),
    ergw_gsn_lib:release_context_ips(Context),
    ok;
terminate(_Reason, _State, #{context := Context}) ->
    ergw_gsn_lib:release_context_ips(Context),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% response/3
response(Cmd, #tunnel{remote = #fq_teid{teid = TEID}}, Response) ->
    {Cmd, TEID, Response}.

%% response/4
response(Cmd, Tunnel, IEs0, #gtp{ie = ReqIEs})
  when is_record(Tunnel, tunnel) ->
    IEs = gtp_v1_c:build_recovery(Cmd, Tunnel, is_map_key(?'Recovery', ReqIEs), IEs0),
    response(Cmd, Tunnel, IEs).

pdp_alloc(#end_user_address{pdp_type_organization = 0,
			    pdp_type_number = 2}) ->
    {'Non-IP', undefined, undefined};

pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#21,
			    pdp_address = Address}) ->
    IP4 = case Address of
	      << >> ->
		  {0,0,0,0};
	      <<_:4/bytes>> ->
		  ergw_inet:bin2ip(Address)
	  end,
    {'IPv4', IP4, undefined};

pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#57,
			    pdp_address = Address}) ->
    IP6 = case Address of
	      << >> ->
		  {{0,0,0,0,0,0,0,0},64};
	      <<_:16/bytes>> ->
		  {ergw_inet:bin2ip(Address),128}
	  end,
    {'IPv6', undefined, IP6};

pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#8D,
			    pdp_address = Address}) ->
    case Address of
	<< IP4:4/bytes, IP6:16/bytes >> ->
	    {'IPv4v6', ergw_inet:bin2ip(IP4), {ergw_inet:bin2ip(IP6), 128}};
	<< IP6:16/bytes >> ->
	    {'IPv4v6', {0,0,0,0}, {ergw_inet:bin2ip(IP6), 128}};
	<< IP4:4/bytes >> ->
	    {'IPv4v6', ergw_inet:bin2ip(IP4), {{0,0,0,0,0,0,0,0},64}};
	<<  >> ->
	    {'IPv4v6', {0,0,0,0}, {{0,0,0,0,0,0,0,0},64}}
   end;

pdp_alloc(_) ->
    {undefined, undefined}.

encode_eua(IPv4, undefined) when IPv4 /= undefined ->
    encode_eua(1, 16#21, ergw_inet:ip2bin(ergw_ip_pool:addr(IPv4)), <<>>);
encode_eua(undefined, IPv6) when IPv6 /= undefined ->
    encode_eua(1, 16#57, <<>>, ergw_inet:ip2bin(ergw_ip_pool:addr(IPv6)));
encode_eua(IPv4, IPv6) when IPv4 /= undefined, IPv6 /= undefined ->
    encode_eua(1, 16#8D, ergw_inet:ip2bin(ergw_ip_pool:addr(IPv4)),
	       ergw_inet:ip2bin(ergw_ip_pool:addr(IPv6))).

encode_eua(Org, Number, IPv4, IPv6) ->
    #end_user_address{pdp_type_organization = Org,
		      pdp_type_number = Number,
		      pdp_address = <<IPv4/binary, IPv6/binary >>}.

close_context(_Side, Reason, _Notify, _State, Data) ->
    ergw_gtp_gsn_lib:close_context(?API, Reason, Data).

map_attr('APN', #{?'Access Point Name' := #access_point_name{apn = APN}}) ->
    iolist_to_binary(lists:join($., APN));
map_attr('IMSI', #{?'IMSI' := #international_mobile_subscriber_identity{imsi = IMSI}}) ->
    IMSI;
map_attr('IMEI', #{?'IMEI' := #imei{imei = IMEI}}) ->
    IMEI;
map_attr('MSISDN', #{?'MSISDN' := #ms_international_pstn_isdn_number{
				     msisdn = {isdn_address, _, _, 1, MSISDN}}}) ->
    MSISDN;
map_attr(Value, _) when is_binary(Value); is_list(Value) ->
    Value;
map_attr(Value, _) when is_atom(Value) ->
    atom_to_binary(Value, utf8);
map_attr(Value, _) ->
    io_lib:format("~w", [Value]).

map_username(_IEs, Username, _) when is_binary(Username) ->
    Username;
map_username(_IEs, [], Acc) ->
    iolist_to_binary(lists:reverse(Acc));
map_username(IEs, [H | Rest], Acc) ->
    Part = map_attr(H, IEs),
    map_username(IEs, Rest, [Part | Acc]).

%% init_session/4
init_session(IEs, #tunnel{local = #fq_teid{ip = LocalIP}},
	     #context{charging_identifier = ChargingId},
	     #{'Username' := #{default := Username},
	       'Password' := #{default := Password}}) ->
    MappedUsername = map_username(IEs, Username, []),
    {MCC, MNC} = ergw_core:get_plmn_id(),
    Opts =
	case LocalIP of
	    {_,_,_,_,_,_,_,_} ->
		#{'3GPP-GGSN-IPv6-Address' => LocalIP};
	    _ ->
		#{'3GPP-GGSN-Address' => LocalIP}
	end,
    Opts#{'Username'		=> MappedUsername,
	  'Password'		=> Password,
	  'Service-Type'	=> 'Framed-User',
	  'Framed-Protocol'	=> 'GPRS-PDP-Context',
	  '3GPP-GGSN-MCC-MNC'	=> {MCC, MNC},
	  '3GPP-Charging-Id'	=> ChargingId,
	  'PDP-Context-Type'	=> primary
     }.

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

copy_to_session(_, #protocol_configuration_options{config = {0, Options}},
		#{'Username' := #{from_protocol_opts := true}}, Session) ->
    lists:foldr(fun copy_ppp_to_session/2, Session, Options);
copy_to_session(_, #access_point_name{apn = APN}, _AAAopts, Session) ->
    {NI, _OI} = ergw_node_selection:split_apn(APN),
    Session#{'APN' => APN,
	     'Called-Station-Id' =>
		 iolist_to_binary(lists:join($., NI))};
copy_to_session(_, #ms_international_pstn_isdn_number{
		   msisdn = {isdn_address, _, _, 1, MSISDN}}, _AAAopts, Session) ->
    Session#{'Calling-Station-Id' => MSISDN, '3GPP-MSISDN' => MSISDN};
copy_to_session(_, #international_mobile_subscriber_identity{imsi = IMSI}, _AAAopts, Session) ->
    case itu_e212:split_imsi(IMSI) of
	{MCC, MNC, _} ->
	    Session#{'3GPP-IMSI' => IMSI,
		     '3GPP-IMSI-MCC-MNC' => {MCC, MNC}};
	_ ->
	    Session#{'3GPP-IMSI' => IMSI}
    end;
copy_to_session(_, #end_user_address{pdp_type_organization = 0,
				     pdp_type_number = 1}, _AAAopts, Session) ->
    Session#{'3GPP-PDP-Type' => 'PPP'};
copy_to_session(_, #end_user_address{pdp_type_organization = 0,
				     pdp_type_number = 2}, _AAAopts, Session) ->
    Session#{'3GPP-PDP-Type' => 'Non-IP'};
copy_to_session(_, #end_user_address{pdp_type_organization = 1,
				     pdp_type_number = 16#21,
				     pdp_address = Address}, _AAAopts, Session0) ->
    Session = Session0#{'3GPP-PDP-Type' => 'IPv4'},
    case Address of
	<<_:4/bytes>> ->
	    IP4 = ergw_inet:bin2ip(Address),
	    Session#{'Framed-IP-Address' => IP4,
		     'Requested-IP-Address' => IP4};
	_ ->
	    Session
    end;
copy_to_session(_, #end_user_address{pdp_type_organization = 1,
				     pdp_type_number = 16#57,
				     pdp_address = Address}, _AAAopts, Session0) ->
    Session = Session0#{'3GPP-PDP-Type' => 'IPv6'},
    case Address of
	<<_:16/bytes>> ->
	    IP6 = {ergw_inet:bin2ip(Address), 128},
	    Session#{'Framed-IPv6-Prefix' => IP6,
		     'Requested-IPv6-Prefix' => IP6};
	_ ->
	    Session
    end;
copy_to_session(_, #end_user_address{pdp_type_organization = 1,
				     pdp_type_number = 16#8D,
				     pdp_address = Address}, _AAAopts, Session0) ->
    Session = Session0#{'3GPP-PDP-Type' => 'IPv4v6'},
    case Address of
	<< IP4:4/bytes >> ->
	    IP4addr = ergw_inet:bin2ip(IP4),
	    Session#{'Framed-IP-Address' => IP4addr,
		     'Requested-IP-Address' => IP4addr};
	<< IP6:16/bytes >> ->
	    IP6addr = {ergw_inet:bin2ip(IP6), 128},
	    Session#{'Framed-IPv6-Prefix' => IP6addr,
		     'Requested-IPv6-Prefix' => IP6addr};
	<< IP4:4/bytes, IP6:16/bytes >> ->
	    IP4addr = ergw_inet:bin2ip(IP4),
	    IP6addr = {ergw_inet:bin2ip(IP6), 128},
	    Session#{'Framed-IP-Address' => IP4addr,
		     'Framed-IPv6-Prefix' => IP6addr,
		     'Requested-IP-Address' => IP4addr,
		     'Requested-IPv6-Prefix' => IP6addr};
	_ ->
	    Session
   end;

copy_to_session(_, #gsn_address{instance = 0, address = IP}, _AAAopts, Session)
  when size(IP) == 4 ->
    Session#{'3GPP-SGSN-Address' => ergw_inet:bin2ip(IP)};
copy_to_session(_, #gsn_address{instance = 0, address = IP}, _AAAopts, Session)
  when size(IP) == 16 ->
    Session#{'3GPP-SGSN-IPv6-Address' => ergw_inet:bin2ip(IP)};
copy_to_session(_, #nsapi{instance = 0, nsapi = NSAPI}, _AAAopts, Session) ->
    Session#{'3GPP-NSAPI' => NSAPI};
copy_to_session(_, #selection_mode{mode = Mode}, _AAAopts, Session) ->
    Session#{'3GPP-Selection-Mode' => Mode};
copy_to_session(_, #charging_characteristics{value = Value}, _AAAopts, Session) ->
    Session#{'3GPP-Charging-Characteristics' => Value};
copy_to_session(_, #routeing_area_identity{identity = #rai{plmn_id = PLMN} = RAI},
		_AAAopts, Session) ->
    maps:update_with('User-Location-Info', _#{'RAI' => RAI}, #{'RAI' => RAI},
		     Session#{'3GPP-SGSN-MCC-MNC' => PLMN});
copy_to_session(_, #imei{imei = IMEI}, _AAAopts, Session) ->
    Session#{'3GPP-IMEISV' => IMEI};
copy_to_session(_, #rat_type{rat_type = Type}, _AAAopts, Session) ->
    Session#{'3GPP-RAT-Type' => Type};
copy_to_session(_, #user_location_information{location = Location}, _AAAopts, Session) ->
    ULI0 = maps:with(['RAI'], maps:get('User-Location-Info', Session, #{})),
    ULI = case Location of
	      #cgi{} -> ULI0#{'CGI' => Location};
	      #sai{} -> ULI0#{'SAI' => Location};
	      #rai{} -> ULI0#{'RAI' => Location};
	      _      -> ULI0
	  end,
    Session#{'User-Location-Info' => ULI};
copy_to_session(_, #ms_time_zone{timezone = TZ, dst = DST}, _AAAopts, Session) ->
    Session#{'3GPP-MS-TimeZone' => {TZ, DST}};
copy_to_session(_, _, _AAAopts, Session) ->
    Session.

ip_to_session({_,_,_,_} = IP, #{ip4 := Key}, Session) ->
    Session#{Key => IP};
ip_to_session({_,_,_,_,_,_,_,_} = IP, #{ip6 := Key}, Session) ->
    Session#{Key => IP}.

copy_tunnel_to_session(#tunnel{version = Version, remote = #fq_teid{ip = IP}}, Session) ->
    ip_to_session(IP, #{ip4 => '3GPP-SGSN-Address',
			ip6 => '3GPP-SGSN-IPv6-Address'},
		  Session#{'GTP-Version' => Version});
copy_tunnel_to_session(_, Session) ->
    Session.

copy_bearer_to_session(#bearer{remote = #fq_teid{ip = IP}}, Session) ->
    ip_to_session(IP, #{ip4 => '3GPP-SGSN-UP-Address',
			ip6 => '3GPP-SGSN-UP-IPv6-Address'}, Session);
copy_bearer_to_session(_, Session) ->
    Session.

init_session_from_gtp_req(IEs, AAAopts, Tunnel, Bearer, Session0) ->
    Session1 = copy_tunnel_to_session(Tunnel, Session0),
    Session = copy_bearer_to_session(Bearer, Session1),
    maps:fold(copy_to_session(_, _, AAAopts, _), Session, IEs).

init_session_qos(#{?'Quality of Service Profile' :=
		       #quality_of_service_profile{
			  priority = RequestedPriority,
			  data = RequestedQoS}} = IEs, Session0) ->
    %% TODO: use config setting to init default class....
    {NegotiatedARP, NegotiatedQoS, QoS} =
	negotiate_qos(RequestedPriority, RequestedQoS),
    Session = Session0#{'3GPP-Allocation-Retention-Priority' => NegotiatedARP,
			'3GPP-GPRS-Negotiated-QoS-Profile'   => NegotiatedQoS},
    session_qos_info(QoS, NegotiatedARP, IEs, Session);
init_session_qos(_IEs, Session) ->
    Session.

update_session_from_gtp_req(IEs, Session, Tunnel, Bearer) ->
    OldSOpts = ergw_aaa_session:get(Session),
    NewSOpts0 = init_session_qos(IEs, OldSOpts),
    NewSOpts1 = copy_tunnel_to_session(Tunnel, NewSOpts0),
    NewSOpts2 = copy_bearer_to_session(Bearer, NewSOpts1),
    NewSOpts =
	maps:fold(copy_to_session(_, _, undefined, _), NewSOpts2, IEs),
    ergw_aaa_session:set(Session, NewSOpts),
    gtp_context:collect_charging_events(OldSOpts, NewSOpts).

negotiate_qos_prio(X) when X > 0 andalso X =< 3 ->
    X;
negotiate_qos_prio(_) ->
    2.

session_qos_info_qci(#qos{
			traffic_class			= 1,		%% Conversational class
			source_statistics_descriptor	= 1}) ->	%% Speech
    1;
session_qos_info_qci(#qos{
			traffic_class			= 1,		%% Conversational class
			transfer_delay			= TransferDelay})
  when TransferDelay >= 150 ->
    2;
session_qos_info_qci(#qos{traffic_class			= 1}) ->	%% Conversational class
%% TransferDelay < 150
    3;
session_qos_info_qci(#qos{traffic_class			= 2}) ->	%% Streaming class
    4;
session_qos_info_qci(#qos{
			traffic_class			= 3,		%% Interactive class
			traffic_handling_priority	= 1,		%% Priority level 1
			signaling_indication		= 1}) ->	%% yes
    5;
session_qos_info_qci(#qos{
			traffic_class			= 3,		%% Interactive class
			signaling_indication		= 0}) ->	%% no
    6;
session_qos_info_qci(#qos{
			traffic_class			= 3,		%% Interactive class
			traffic_handling_priority	= 2}) ->	%% Priority level 2
    7;
session_qos_info_qci(#qos{
			traffic_class			= 3,		%% Interactive class
			traffic_handling_priority	= 3}) ->	%% Priority level 3
    8;
session_qos_info_qci(#qos{traffic_class			= 4}) ->	%% Background class
    9;
session_qos_info_qci(_) -> 9.

session_qos_info_arp(_ARP,
		     #{?'Evolved ARP I' :=
			   #evolved_allocation_retention_priority_i{
			      pci = PCI, pl = PL, pvi = PVI}}) ->
    #{'Priority-Level' => PL,
      'Pre-emption-Capability' => PCI,
      'Pre-emption-Vulnerability' => PVI};
session_qos_info_arp(_ARP = 1, _IEs) ->
    #{'Priority-Level' => 1,
      'Pre-emption-Capability' => 1,         %% TODO operator policy
      'Pre-emption-Vulnerability' => 0};     %% TODO operator policy
session_qos_info_arp(_ARP = 2, _IEs) ->
    #{'Priority-Level' => 2,                 %% TODO operator policy, H + 1 with H >= 1
      'Pre-emption-Capability' => 1,         %% TODO operator policy
      'Pre-emption-Vulnerability' => 0};     %% TODO operator policy
session_qos_info_arp(_ARP = 3, _IEs) ->
    #{'Priority-Level' => 3,                 %% TODO operator policy M + 1 with M >= H + 1
      'Pre-emption-Capability' => 1,         %% TODO operator policy
      'Pre-emption-Vulnerability' => 0}.     %% TODO operator policy

%% the UE may send 'subscribed` as rate. There is nothing in specs that
%% tells how to translate this to requested QoS in Session (Gx/Gy/Rf)
session_qos_bitrate(Key, Value, Info) when is_integer(Value) ->
    Info#{Key => Value * 1000};
session_qos_bitrate(_, _, Info) ->
    Info.

session_qos_info_apn_ambr(_QoS,
			  #{?'APN-AMBR' :=
				#aggregate_maximum_bit_rate{
				   uplink   = AMBR4ul,
				   downlink = AMBR4dl
				  }}, Info0) ->
    Info = session_qos_bitrate('APN-Aggregate-Max-Bitrate-UL', AMBR4ul, Info0),
    session_qos_bitrate('APN-Aggregate-Max-Bitrate-DL', AMBR4dl, Info);
session_qos_info_apn_ambr(#qos{
			     max_bit_rate_uplink   = MBR4ul,
			     max_bit_rate_downlink = MBR4dl},
			  _IEs, Info0) ->
    Info = session_qos_bitrate('APN-Aggregate-Max-Bitrate-UL', MBR4ul, Info0),
    session_qos_bitrate('APN-Aggregate-Max-Bitrate-DL', MBR4dl, Info).

%% see 3GPP TS 29.212 version 15.3.0, Appending B.3.3.3
session_qos_info(#qos{
		    max_bit_rate_uplink          = MBR4ul,
		    max_bit_rate_downlink        = MBR4dl,
		    guaranteed_bit_rate_uplink   = GBR4ul,
		    guaranteed_bit_rate_downlink = GBR4dl
		   } = QoS, ARP, IEs, Session) ->
    Info0 = #{
	      'QoS-Class-Identifier' =>
		  session_qos_info_qci(QoS),
	      'Allocation-Retention-Priority' =>
		  session_qos_info_arp(ARP, IEs)
	     },
    Info1 = session_qos_bitrate('Max-Requested-Bandwidth-UL', MBR4ul, Info0),
    Info2 = session_qos_bitrate('Max-Requested-Bandwidth-DL', MBR4dl, Info1),
    Info3 = session_qos_bitrate('Guaranteed-Bitrate-UL', GBR4ul, Info2),
    Info4 = session_qos_bitrate('Guaranteed-Bitrate-DL', GBR4dl, Info3),
    Info = session_qos_info_apn_ambr(QoS, IEs, Info4),
    Session#{'QoS-Information' => Info};

session_qos_info(_QoS, _ARP, _IEs, Session) ->
    Session.

negotiate_qos(ReqPriority, ReqQoSProfileData) ->
    NegPriority = negotiate_qos_prio(ReqPriority),
    case '3gpp_qos':decode(ReqQoSProfileData) of
	Profile when is_binary(Profile) ->
	    {NegPriority, ReqQoSProfileData, undefined};
	#qos{traffic_class = 0} ->			%% MS to Network: Traffic Class: Subscribed
	    %% 3GPP TS 24.008, Sect. 10.5.6.5,
	    QoS = #qos{
		     delay_class			= 4,		%% best effort
		     reliability_class			= 3,		%% Unacknowledged GTP/LLC,
		     %% Ack RLC, Protected data
		     peak_throughput			= 2,		%% 2000 oct/s (2 kBps)
		     precedence_class			= 3,		%% Low priority
		     mean_throughput			= 31,		%% Best effort
		     traffic_class			= 4,		%% Background class
		     delivery_order			= 2,		%% Without delivery order
		     delivery_of_erroneorous_sdu	= 3,		%% Erroneous SDUs are not delivered
		     max_sdu_size			= 1500,		%% 1500 octets
		     max_bit_rate_uplink		= 16,		%% 16 kbps
		     max_bit_rate_downlink		= 16,		%% 16 kbps
		     residual_ber			= 7,		%% 10^-5
		     sdu_error_ratio			= 4,		%% 10^-4
		     transfer_delay			= 300,		%% 300ms
		     traffic_handling_priority		= 3,		%% Priority level 3
		     guaranteed_bit_rate_uplink		= 0,		%% 0 kbps
		     guaranteed_bit_rate_downlink	= 0,		%% 0 kbps
		     signaling_indication		= 0,		%% Not optimised for signalling traffic
		     source_statistics_descriptor	= 0},		%% unknown
	    {NegPriority, '3gpp_qos':encode(QoS), QoS};
	#qos{} = QoS ->
	    {NegPriority, ReqQoSProfileData, QoS}
    end.

get_context_from_req(?'Access Point Name', #access_point_name{apn = APN}, Context) ->
    Context#context{apn = APN};
get_context_from_req(?'IMSI', #international_mobile_subscriber_identity{imsi = IMSI}, Context) ->
    Context#context{imsi = IMSI};
get_context_from_req(?'IMEI', #imei{imei = IMEI}, Context) ->
    Context#context{imei = IMEI};
get_context_from_req(?'MSISDN', #ms_international_pstn_isdn_number{
				   msisdn = {isdn_address, _, _, 1, MSISDN}}, Context) ->
    Context#context{msisdn = MSISDN};
get_context_from_req(_K, #nsapi{instance = 0, nsapi = NSAPI}, Context) ->
    Context#context{default_bearer_id = NSAPI};
get_context_from_req(_, _, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs} = Req, Context0) ->
    Context1 = gtp_v1_c:update_context_id(Req, Context0),
    maps:fold(fun get_context_from_req/3, Context1, IEs).

update_fq_teid(Field, Value, Rec) when is_record(Rec, fq_teid) ->
    ergw_gsn_lib:'#set-'([{Field, Value}], Rec);
update_fq_teid(Field, Value, _) ->
    ergw_gsn_lib:'#new-fq_teid'([{Field, Value}]).

update_fq_teid(Side, Field, Value, Rec) ->
     ergw_gsn_lib:'#set-'(
       [{Side, update_fq_teid(Field, Value, ergw_gsn_lib:'#get-'(Side, Rec))}], Rec).

get_tunnel_from_req(none, Tunnel, Bearer) ->
    {ok, {Tunnel, Bearer}};
get_tunnel_from_req({_, #gsn_address{instance = 0, address = IP}, Next}, Tunnel0, Bearer) ->
    do([error_m ||
	   PeerIP <- ergw_gsn_lib:choose_ip_by_tunnel(Tunnel0, IP, IP),
	   begin
	       Tunnel = update_fq_teid(remote, ip, ergw_inet:bin2ip(PeerIP), Tunnel0),
	       get_tunnel_from_req(maps:next(Next), Tunnel, Bearer)
	   end]);
get_tunnel_from_req({_, #gsn_address{instance = 1, address = IP}, Next}, Tunnel, Bearer0) ->
    do([error_m ||
	   PeerIP <- ergw_gsn_lib:choose_ip_by_tunnel(Tunnel, IP, IP),
	   begin
	       Bearer = update_fq_teid(remote, ip, ergw_inet:bin2ip(PeerIP), Bearer0),
	       get_tunnel_from_req(maps:next(Next), Tunnel, Bearer)
	   end]);
get_tunnel_from_req({_, #tunnel_endpoint_identifier_data_i{instance = 0, tei = TEI}, Next},
		    Tunnel, Bearer) ->
    get_tunnel_from_req(maps:next(Next), Tunnel, update_fq_teid(remote, teid, TEI, Bearer));
get_tunnel_from_req({_, #tunnel_endpoint_identifier_control_plane{instance = 0, tei = TEI}, Next},
		    Tunnel, Bearer) ->
    get_tunnel_from_req(maps:next(Next), update_fq_teid(remote, teid, TEI, Tunnel), Bearer);
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
    #gtp{version = v1, type = Type, tei = RemoteCntlTEI, ie = RequestIEs}.

send_request(Tunnel, DstIP, DstPort, T3, N3, Msg, ReqInfo) ->
    gtp_context:send_request(Tunnel, any, DstIP, DstPort, T3, N3, Msg, ReqInfo).

send_request(#tunnel{remote = #fq_teid{ip = RemoteCntlIP}} = Tunnel, T3, N3, Msg, ReqInfo) ->
    send_request(Tunnel, RemoteCntlIP, ?GTP1c_PORT, T3, N3, Msg, ReqInfo).

send_request(Tunnel, T3, N3, Type, RequestIEs, ReqInfo) ->
    send_request(Tunnel, T3, N3, msg(Tunnel, Type, RequestIEs), ReqInfo).

%% TS 29.060, clause 7.3.3:
%%
%%    An Update PDP Context Request may also be sent from a GGSN to an SGSN:
%%
%%    [...]
%%
%%    - to check that the PDP context is still active at the SGSN. In such a case, the GGSN shall include the optional
%%      IMSI IE, to add robustness against the case the SGSN has re-assigned the TEID to another PDP context (this
%%      may happen when the PDP context is dangling at the GGSN). Also, the "Quality of service profile" IE and the
%%      "End user Address" IE shall not be included in this case;
%%
send_context_alive_request(#{left_tunnel := Tunnel, context :=
				 #context{default_bearer_id = NSAPI, imsi = IMSI}}) ->
    Type = update_pdp_context_request,
    RequestIEs0 = [#nsapi{nsapi = NSAPI} |
		   [#international_mobile_subscriber_identity{imsi = IMSI} || is_binary(IMSI)]],
    RequestIEs = gtp_v1_c:build_recovery(Type, Tunnel, false, RequestIEs0),
    send_request(Tunnel, ?T3, ?N3, Type, RequestIEs, alive_check).

delete_context(From, TermCause, connected,
	       #{left_tunnel := Tunnel, context :=
		     #context{default_bearer_id = NSAPI}} = Data) ->
    Type = delete_pdp_context_request,
    RequestIEs0 = [#nsapi{nsapi = NSAPI},
		   #teardown_ind{value = 1}],
    RequestIEs = gtp_v1_c:build_recovery(Type, Tunnel, false, RequestIEs0),
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

pdp_ppp_pco(SessionOpts, {pap, 'PAP-Authentication-Request', Id, _Username, _Password}, Opts) ->
    [{pap, 'PAP-Authenticate-Ack', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdp_ppp_pco(SessionOpts, {chap, 'CHAP-Response', Id, _Value, _Name}, Opts) ->
    [{chap, 'CHAP-Success', Id, maps:get('Reply-Message', SessionOpts, <<>>)}|Opts];
pdp_ppp_pco(SessionOpts, {ipcp,'CP-Configure-Request', Id, CpReqOpts}, Opts) ->
    CpRespOpts = lists:foldr(ppp_ipcp_conf(SessionOpts, _, _), #{}, CpReqOpts),
    maps:fold(fun(K, V, O) -> [{ipcp, K, Id, V} | O] end, Opts, CpRespOpts);

pdp_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv6-Address', <<>>}, Opts) ->
    [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
     || DNS <- maps:get('DNS-Server-IPv6-Address', SessionOpts, [])]
	++ [{?'PCO-DNS-Server-IPv6-Address', ergw_inet:ip2bin(DNS)}
	    || DNS <- maps:get('3GPP-IPv6-DNS-Servers', SessionOpts, [])]
	++ Opts;
pdp_ppp_pco(SessionOpts, {?'PCO-DNS-Server-IPv4-Address', <<>>}, Opts) ->
    lists:foldr(fun(Key, O) ->
			case maps:find(Key, SessionOpts) of
			    {ok, DNS} ->
				[{?'PCO-DNS-Server-IPv4-Address', ergw_inet:ip2bin(DNS)} | O];
			    _ ->
				O
			end
		end, Opts, ['MS-Secondary-DNS-Server', 'MS-Primary-DNS-Server']);
pdp_ppp_pco(_SessionOpts, PPPReqOpt, Opts) ->
    ?LOG(debug, "Apply PPP Opt: ~p", [PPPReqOpt]),
    Opts.

pdp_pco(SessionOpts, #{?'Protocol Configuration Options' :=
			   #protocol_configuration_options{config = {0, PPPReqOpts}}}, IE) ->
    case lists:foldr(pdp_ppp_pco(SessionOpts, _, _), [], PPPReqOpts) of
	[]   -> IE;
	Opts -> [#protocol_configuration_options{config = {0, Opts}} | IE]
    end;
pdp_pco(_SessionOpts, _RequestIEs, IE) ->
    IE.

pdp_qos_profile(#{'3GPP-Allocation-Retention-Priority' := NegotiatedPriority,
		  '3GPP-GPRS-Negotiated-QoS-Profile'   := NegotiatedQoS}, IE) ->
    [#quality_of_service_profile{priority = NegotiatedPriority, data = NegotiatedQoS} | IE];
pdp_qos_profile(_SessionOpts, IE) ->
    IE.

tunnel_elements(#tunnel{local = #fq_teid{ip = IP, teid = TEI}}, IEs) ->
    [#tunnel_endpoint_identifier_control_plane{tei = TEI},
     #gsn_address{instance = 0, address = ergw_inet:ip2bin(IP)}   %% for Control Plane
     | IEs].

bearer_elements(Bearer, IEs) ->
    maps:fold(fun bearer_elements/3, IEs, Bearer).

bearer_elements(left, #bearer{local = #fq_teid{ip = IP, teid = TEI}}, IEs) ->
    [#tunnel_endpoint_identifier_data_i{tei = TEI},
     #gsn_address{instance = 1, address = ergw_inet:ip2bin(IP)}    %% for User Traffic
    | IEs];
bearer_elements(_, _, IEs) ->
    IEs.

context_charging_id(#context{charging_identifier = ChargingId}) ->
    #charging_id{id = <<ChargingId:32>>}.

change_reporting_action(true, #{'user-location-info-change' := true}, IE) ->
    [#ms_info_change_reporting_action{action = start_reporting_cgi_sai}|IE];
change_reporting_action(true, #{'cgi-sai-change' := true}, IE) ->
    [#ms_info_change_reporting_action{action = start_reporting_cgi_sai}|IE];
change_reporting_action(true, #{'rai-change' := true}, IE) ->
    [#ms_info_change_reporting_action{action = start_reporting_rai}|IE];
change_reporting_action(_, _Triggers, IE) ->
    IE.

change_reporting_actions(#gtp{ext_hdr = ExtHdr}, IEs) ->
    Triggers = ergw_charging:reporting_triggers(),

    CRSI = proplists:get_bool(ms_info_change_reporting_support_indication, ExtHdr),
    _IE = change_reporting_action(CRSI, Triggers, IEs).

create_pdp_context_response(Cause, SessionOpts, #gtp{ie = RequestIEs} = Request,
			    Tunnel, Bearer,
			    #context{ms_ip = #ue_ip{v4 = MSv4, v6 = MSv6}} = Context) ->
    IE0 = [Cause,
	   #reordering_required{required = no},
	   context_charging_id(Context),
	   encode_eua(MSv4, MSv6)],
    IE1 = pdp_qos_profile(SessionOpts, IE0),
    IE2 = pdp_pco(SessionOpts, RequestIEs, IE1),
    IE3 = tunnel_elements(Tunnel, IE2),
    IE4 = bearer_elements(Bearer, IE3),
    _IE = change_reporting_actions(Request, IE4).

%% Wrapper for gen_statem state_callback_result Actions argument
%% Timeout set in the context of a prolonged idle gtp session
context_idle_action(Actions, #context{inactivity_timeout = Timeout})
  when is_integer(Timeout) orelse Timeout =:= infinity ->
    [{{timeout, context_idle}, Timeout, check_session_liveness} | Actions];
context_idle_action(Actions, _) ->
    Actions.
