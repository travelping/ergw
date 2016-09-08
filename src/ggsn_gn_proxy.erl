%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn_proxy).

-behaviour(gtp_api).

-compile({parse_transform, cut}).

-export([init/2, request_spec/1, handle_request/4, handle_response/5]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-compile([nowarn_unused_record]).

%%====================================================================
%% API
%%====================================================================

-record(create_pdp_context_request, {
	  imsi,
	  routeing_area_identity,
	  selection_mode,
	  tunnel_endpoint_identifier_data_i,
	  tunnel_endpoint_identifier_control_plane,
	  nsapi,
	  linked_nsapi,
	  charging_characteristics,
	  trace_reference,
	  trace_type,
	  end_user_address,
	  apn,
	  pco,
	  sgsn_address_for_signalling,
	  sgsn_address_for_user_traffic,
	  alternative_sgsn_address_for_signalling,
	  alternative_sgsn_address_for_user_traffic,
	  msisdn,
	  quality_of_service_profile,
	  traffic_flow_template,
	  trigger_id,
	  omc_identity,
	  common_flags,
	  apn_restriction,
	  rat_type,
	  user_location_information,
	  ms_time_zone,
	  imei,
	  camel_charging_information_container,
	  additional_trace_info,
	  correlation_id,
	  evolved_allocation_retention_priority_i,
	  extended_common_flags,
	  user_csg_information,
	  ambr,
	  signalling_priority_indication,
	  cn_operator_selection_entity,
	  private_extension,
	  additional_ies
	 }).

-record(create_pdp_context_response, {
	  cause,
	  reordering_required,
	  recovery,
	  tunnel_endpoint_identifier_data_i,
	  tunnel_endpoint_identifier_control_plane,
	  nsapi,
	  charging_id,
	  end_user_address,
	  protocol_configuration_options,
	  ggsn_address_for_control_plane,
	  ggsn_address_for_user_traffic,
	  alternative_sgsn_address_for_control_plane,
	  alternative_sgsn_address_for_user_traffic,
	  quality_of_service_profile,
	  charging_gateway_address,
	  alternative_charging_gateway_address,
	  common_flags,
	  apn_restriction,
	  ms_info_change_reporting_action,
	  bearer_control_mode,
	  evolved_allocation_retention_priority_i,
	  csg_information_reporting_action,
	  apn_ambr_with_nsapi,
	  ggsn_back_off_time,
	  private_extension,
	  additional_ies
	 }).

-record(update_pdp_context_request, {
	  imsi,
	  routeing_area_identity,
	  tunnel_endpoint_identifier_data_i,
	  tunnel_endpoint_identifier_control_plane,
	  nsapi,
	  trace_reference,
	  trace_type,
	  pco,
	  sgsn_address_for_signalling,
	  sgsn_address_for_user_traffic,
	  alternative_sgsn_address_for_signalling,
	  alternative_sgsn_address_for_user_traffic,
	  quality_of_service_profile,
	  traffic_flow_template,
	  trigger_id,
	  omc_identity,
	  common_flags,
	  rat_type,
	  user_location_information,
	  ms_time_zone,
	  additional_trace_info,
	  direct_tunnel_flags,
	  evolved_allocation_retention_priority_i,
	  extended_common_flags,
	  user_csg_information,
	  ambr,
	  signalling_priority_indication,
	  cn_operator_selection_entity,
	  private_extension,
	  additional_ies
	 }).

-record(update_pdp_context_response, {
	  cause,
	  tunnel_endpoint_identifier_data_i,
	  tunnel_endpoint_identifier_control_plane,
	  charging_id,
	  protocol_configuration_options,
	  ggsn_address_for_control_plane,
	  ggsn_address_for_user_traffic,
	  alternative_ggsn_address_for_control_plane,
	  alternative_ggsn_address_for_user_traffic,
	  quality_of_service_profile,
	  charging_gateway_address,
	  alternative_charging_gateway_address,
	  common_flags,
	  apn_restriction,
	  bearer_control_mode,
	  ms_info_change_reporting_action,
	  evolved_allocation_retention_priority_i,
	  csg_information_reporting_action,
	  ambr,
	  private_extension,
	  additional_ies
	 }).


-record(delete_pdp_context_request, {
	  cause,
	  teardown_ind,
	  nsapi,
	  protocol_configuration_options,
	  user_location_information,
	  ms_time_zone,
	  extended_common_flags,
	  uli_timestamp,
	  private_extension,
	  additional_ies
	 }).

-record(delete_pdp_context_response, {
	  cause,
	  protocol_configuration_options,
	  user_location_information,
	  ms_time_zone,
	  uli_timestamp,
	  private_extension,
	  additional_ies
	 }).

request_spec(create_pdp_context_request) ->
    [{{international_mobile_subscriber_identity, 0},	conditional},
     {{routeing_area_identity, 0},			optional},
     {{selection_mode, 0},				conditional},
     {{tunnel_endpoint_identifier_data_i, 0},		mandatory},
     {{tunnel_endpoint_identifier_control_plane, 0},	conditional},
     {{nsapi, 0},					mandatory},
     {{nsapi, 1},					conditional},
     {{charging_characteristics, 0},			conditional},
     {{trace_reference, 0},				optional},
     {{trace_type, 0},					optional},
     {{end_user_address, 0},				conditional},
     {{access_point_name, 0},				conditional},
     {{protocol_configuration_options, 0},		optional},
     {{gsn_address, 0},					mandatory},
     {{gsn_address, 1},					mandatory},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {{ms_international_pstn_isdn_number, 0},		conditional},
     {{quality_of_service_profile, 0},			mandatory},
     {{traffic_flow_template, 0},			conditional},
     {{trigger_id, 0},					optional},
     {{omc_identity, 0},				optional},
     {{common_flags, 0},				optional},
     {{apn_restriction, 0},				optional},
     {{rat_type, 0},					optional},
     {{user_location_information, 0},			optional},
     {{ms_time_zone, 0},				optional},
     {{imei, 0},					conditional},
     {{camel_charging_information_container, 0},	optional},
     {{additional_trace_info, 0},			optional},
     {{correlation_id, 0},				optional},
     {{evolved_allocation_retention_priority_i, 0},	optional},
     {{extended_common_flags, 0},			optional},
     {{user_csg_information, 0},			optional},
     {{ambr, 0},					optional},
     {{signalling_priority_indication, 0},		optional},
     {{cn_operator_selection_entity, 0},		optional},
     {{private_extension, 0},				optional}];

request_spec(create_pdp_context_response) ->
    [{{cause, 0},					mandatory},
     {{reordering_required, 0},				conditional},
     {{recovery, 0},					optional},
     {{tunnel_endpoint_identifier_data_i, 0},		conditional},
     {{tunnel_endpoint_identifier_control_plane, 0},	conditional},
     {{nsapi, 0},					optional},
     {{charging_id, 0},					conditional},
     {{end_user_address, 0},				conditional},
     {{protocol_configuration_options, 0},		optional},
     {{gsn_address, 0},					conditional},
     {{gsn_address, 1},					conditional},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {{quality_of_service_profile, 0},			conditional},
     {{charging_gateway_address, 0},			optional},
     {{charging_gateway_address, 1},			optional},
     {{common_flags, 0},				optional},
     {{apn_restriction, 0},				optional},
     {{ms_info_change_reporting_action, 0},		optional},
     {{bearer_control_mode, 0},				optional},
     {{evolved_allocation_retention_priority_i, 0},	optional},
     {{csg_information_reporting_action, 0},		optional},
     {{apn_ambr_with_nsapi, 0},				optional},
     {{ggsn_back_off_time, 0},				optional},
     {{private_extension, 0},				optional}];

request_spec(update_pdp_context_request) ->
    [{{international_mobile_subscriber_identity, 0},	optional},
     {{routeing_area_identity, 0},			optional},
     {{tunnel_endpoint_identifier_data_i, 0},		mandatory},
     {{tunnel_endpoint_identifier_control_plane, 0},	conditional},
     {{nsapi, 0},					mandatory},
     {{trace_reference, 0},				optional},
     {{trace_type, 0},					optional},
     {{protocol_configuration_options, 0},		optional},
     {{gsn_address, 0},					mandatory},
     {{gsn_address, 1},					mandatory},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {{quality_of_service_profile, 0},			mandatory},
     {{traffic_flow_template, 0},			conditional},
     {{trigger_id, 0},					optional},
     {{omc_identity, 0},				optional},
     {{common_flags, 0},				optional},
     {{rat_type, 0},					optional},
     {{user_location_information, 0},			optional},
     {{ms_time_zone, 0},				optional},
     {{additional_trace_info, 0},			optional},
     {{direct_tunnel_flags, 0},				optional},
     {{evolved_allocation_retention_priority_i, 0},	optional},
     {{extended_common_flags, 0},			optional},
     {{user_csg_information, 0},			optional},
     {{ambr, 0},					optional},
     {{signalling_priority_indication, 0},		optional},
     {{cn_operator_selection_entity, 0},		optional},
     {{private_extension, 0},				optional}];

request_spec(update_pdp_context_response) ->
    [{{cause, 0},					mandatory},
     {{tunnel_endpoint_identifier_data_i, 0},		conditional},
     {{tunnel_endpoint_identifier_control_plane, 0},	conditional},
     {{charging_id, 0},					conditional},
     {{protocol_configuration_options, 0},		optional},
     {{gsn_address, 0},					conditional},
     {{gsn_address, 1},					conditional},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {{quality_of_service_profile, 0},			conditional},
     {{charging_gateway_address, 0},			optional},
     {{charging_gateway_address, 1},			optional},
     {{common_flags, 0},				optional},
     {{apn_restriction, 0},				optional},
     {{bearer_control_mode, 0},				optional},
     {{ms_info_change_reporting_action, 0},		optional},
     {{evolved_allocation_retention_priority_i, 0},	optional},
     {{csg_information_reporting_action, 0},		optional},
     {{ambr, 0},					optional},
     {{private_extension, 0},				optional}];

request_spec(delete_pdp_context_request) ->
    [{{cause, 0},					optional},
     {{teardown_ind, 0},				conditional},
     {{nsapi, 0},					mandatory},
     {{protocol_configuration_options, 0},		optional},
     {{user_location_information, 0},			optional},
     {{ms_time_zone, 0},				optional},
     {{extended_common_flags, 0},			optional},
     {{uli_timestamp, 0},				optional},
     {{private_extension, 0},				optional}];

request_spec(delete_pdp_context_response) ->
    [{{cause, 0},					mandatory},
     {{protocol_configuration_options, 0},		optional},
     {{user_location_information, 0},			optional},
     {{ms_time_zone, 0},				optional},
     {{uli_timestamp, 0},				optional},
     {{private_extension, 0},				optional}];

request_spec(_) ->
    [].

-record(request_info, {from, seq_no}).

init(Opts, State) ->
    ProxyPorts = proplists:get_value(proxy_sockets, Opts),
    ProxyDPs = proplists:get_value(proxy_data_paths, Opts),
    GGSN = proplists:get_value(ggns, Opts),
    {ok, State#{proxy_ports => ProxyPorts, proxy_dps => ProxyDPs, ggsn => GGSN}}.

handle_request(From,
	       #gtp{type = create_pdp_context_request, seq_no = SeqNo, ie = IEs} = Request, _ReqRec,
	       #{tei := LocalTEI, gtp_port := GtpPort, gtp_dp_port := GtpDP,
		 proxy_ports := ProxyPorts, proxy_dps := ProxyDPs, ggsn := GGSN} = State0) ->

    Context0 = #context{
		  version           = v1,
		  control_interface = ?MODULE,
		  control_port      = GtpPort,
		  local_control_tei = LocalTEI,
		  data_port         = GtpDP,
		  local_data_tei    = LocalTEI
		 },
    Context = update_context_from_gtp_req(Request, Context0),
    State1 = State0#{context => Context},

    #gtp_port{ip = LocalCntlIP} = GtpPort,

    Session0 = #{'GGSN-Address' => gtp_c_lib:ip2bin(LocalCntlIP)},
    Session1 = init_session(IEs, Session0),
    lager:debug("Invoking CONTROL: ~p", [Session1]),
    %% ergw_control:authenticate(Session1),

    {ok, NewPeer} = gtp_v1_c:handle_sgsn(IEs, Context),
    lager:debug("New: ~p", [NewPeer]),
    gtp_context:setup(Context),

    ProxyGtpPort = gtp_socket_reg:lookup(hd(ProxyPorts)),
    ProxyGtpDP = gtp_socket_reg:lookup(hd(ProxyDPs)),
    {ok, ProxyLocalTEI} = gtp_c_lib:alloc_tei(ProxyGtpPort),

    lager:debug("ProxyGtpPort: ~p", [lager:pr(ProxyGtpPort, ?MODULE)]),
    ProxyContext = #context{
		      version           = v1,
		      control_interface = ?MODULE,
		      control_port      = ProxyGtpPort,
		      local_control_tei = ProxyLocalTEI,
		      remote_control_ip = GGSN,
		      data_port         = ProxyGtpDP,
		      local_data_tei    = ProxyLocalTEI,
		      remote_data_ip    = GGSN
		     },
    State = State1#{proxy_context => ProxyContext},
    gtp_path:register(ProxyContext),

    ProxyReq = build_context_request(ProxyContext, Request),
    forward_request(ProxyContext, ProxyReq, From, SeqNo),

    {noreply, State};

handle_request(From,
	       #gtp{type = update_pdp_context_request, seq_no = SeqNo, ie = IEs} = Request, _ReqRec,
	       #{context := OldContext, proxy_context := ProxyContext} = State0) ->

    Context = update_context_from_gtp_req(Request, OldContext),
    State = apply_context_change(Context, OldContext, State0),

    {ok, NewPeer} = gtp_v1_c:handle_sgsn(IEs, Context),
    lager:debug("New: ~p", [NewPeer]),

    ProxyReq = build_context_request(ProxyContext, Request),
    forward_request(ProxyContext, ProxyReq, From, SeqNo),

    {noreply, State};

handle_request(From,
	       #gtp{type = delete_pdp_context_request, seq_no = SeqNo, ie = IEs} = Request, _ReqRec,
	       #{context := Context, proxy_context := ProxyContext} = State) ->

    {ok, NewPeer} = gtp_v1_c:handle_sgsn(IEs, Context),
    lager:debug("New: ~p", [NewPeer]),

    ProxyReq = build_context_request(ProxyContext, Request),
    forward_request(ProxyContext, ProxyReq, From, SeqNo),

    {noreply, State};

handle_request({GtpPort, _IP, _Port}, Msg, _ReqRec, State) ->
    lager:warning("Unknown Proxy Message on ~p: ~p", [GtpPort, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_response(#request_info{from = From, seq_no = SeqNo},
		#gtp{type = create_pdp_context_response} = Response, _RespRec, _Request,
		#{context := Context,
		  proxy_context := ProxyContext0} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext = update_context_from_gtp_req(Response, ProxyContext0),
    gtp_context:setup(ProxyContext),

    GtpResp = build_context_request(Context, Response),
    gtp_context:send_response(From, GtpResp#gtp{seq_no = SeqNo}),

    dp_create_pdp_context(Context, ProxyContext),
    lager:info("Create PDP Context ~p", [Context]),

    {noreply, State#{proxy_context => ProxyContext}};

handle_response(#request_info{from = From, seq_no = SeqNo},
		#gtp{type = update_pdp_context_response} = Response, _RespRec, _Request,
		#{context := Context,
		  proxy_context := OldProxyContext} = State0) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext = update_context_from_gtp_req(Response, OldProxyContext),
    State = apply_proxy_context_change(ProxyContext, OldProxyContext, State0),

    GtpResp = build_context_request(Context, Response),
    gtp_context:send_response(From, GtpResp#gtp{seq_no = SeqNo}),

    dp_update_pdp_context(Context, ProxyContext),

    {noreply, State};

handle_response(#request_info{from = From, seq_no = SeqNo},
		#gtp{type = delete_pdp_context_response} = Response, _RespRec, _Request,
		#{context := Context,
		  proxy_context := ProxyContext} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    GtpResp = build_context_request(Context, Response),
    gtp_context:send_response(From, GtpResp#gtp{seq_no = SeqNo}),

    dp_delete_pdp_context(Context, ProxyContext),
    gtp_context:teardown(Context),
    gtp_context:teardown(ProxyContext),
    {stop, State};

handle_response(_ReqInfo, Response, _RespRec, _Req, State) ->
    lager:warning("Unknown Proxy Response ~p", [lager:pr(Response, ?MODULE)]),
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

apply_context_change(NewContext, OldContext, State)
  when NewContext /= OldContext ->
    ok = gtp_context:update(NewContext, OldContext),
    State#{context => NewContext};
apply_context_change(_NewContext, _OldContext, State) ->
    State.

apply_proxy_context_change(NewContext, OldContext, State)
  when NewContext /= OldContext ->
    ok = gtp_context:update(NewContext, OldContext),
    State#{proxy_context => NewContext};
apply_proxy_context_change(_NewContext, _OldContext, State) ->
    State.

init_session(IEs, Session) ->
    lists:foldr(fun copy_to_session/2, Session, IEs).

%% copy_to_session(#international_mobile_subscriber_identity{imsi = IMSI}, Session) ->
%%     Id = [{'Subscription-Id-Type' , 1}, {'Subscription-Id-Data', IMSI}],
%%     Session#{'Subscription-Id' => Id};

copy_to_session(#international_mobile_subscriber_identity{imsi = IMSI}, Session) ->
    Session#{'IMSI' => IMSI};
copy_to_session(#ms_international_pstn_isdn_number{
		   msisdn = {isdn_address, _, _, 1, MSISDN}}, Session) ->
    Session#{'MSISDN' => MSISDN};
copy_to_session(#gsn_address{instance = 0, address = IP}, Session) ->
    Session#{'SGSN-Address' => gtp_c_lib:ip2bin(IP)};
copy_to_session(#rat_type{rat_type = Type}, Session) ->
    Session#{'RAT-Type' => Type};
copy_to_session(#selection_mode{mode = Mode}, Session) ->
    Session#{'Selection-Mode' => Mode};

copy_to_session(_, Session) ->
    Session.

update_tunnel_ids(#gsn_address{instance = 0, address = CntlIP}, Context) ->
    Context#context{remote_control_ip = gtp_c_lib:bin2ip(CntlIP)};
update_tunnel_ids(#gsn_address{instance = 1, address = DataIP}, Context) ->
    Context#context{remote_data_ip = gtp_c_lib:bin2ip(DataIP)};
update_tunnel_ids(#tunnel_endpoint_identifier_data_i{instance = 0, tei = DataTEI}, Context) ->
    Context#context{remote_data_tei = DataTEI};
update_tunnel_ids(#tunnel_endpoint_identifier_control_plane{instance = 0, tei = CntlTEI}, Context) ->
    Context#context{remote_control_tei = CntlTEI};
update_tunnel_ids(_, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs}, Context) ->
    lists:foldl(fun update_tunnel_ids/2, Context, IEs).

set_tunnel_ids(#context{control_port = #gtp_port{ip = CntlIP}}, #gsn_address{instance = 0} = IE) ->
    IE#gsn_address{address = gtp_c_lib:ip2bin(CntlIP)};
set_tunnel_ids(#context{data_port = #gtp_port{ip = DataIP}}, #gsn_address{instance = 1} = IE) ->
    IE#gsn_address{address = gtp_c_lib:ip2bin(DataIP)};
set_tunnel_ids(#context{local_data_tei = DataTEI}, #tunnel_endpoint_identifier_data_i{instance = 0} = IE) ->
    IE#tunnel_endpoint_identifier_data_i{tei = DataTEI};
set_tunnel_ids(#context{local_control_tei = CntlTEI}, #tunnel_endpoint_identifier_control_plane{instance = 0} = IE) ->
    IE#tunnel_endpoint_identifier_control_plane{tei = CntlTEI};
set_tunnel_ids(_, IE) ->
    IE.

update_gtp_req_from_context(Context, GtpReqIEs) ->
    lists:map(set_tunnel_ids(Context, _), GtpReqIEs).

build_context_request(#context{remote_control_tei = TEI} = Context, #gtp{ie = IEs} = Request) ->
    Request#gtp{tei = TEI, ie = update_gtp_req_from_context(Context, IEs)}.

forward_request(#context{control_port = GtpPort, remote_control_ip = RemoteCntlIP},
	       Request, From, SeqNo) ->
    ReqInfo = #request_info{from = From, seq_no = SeqNo},
    lager:debug("Invoking Context Send Request: ~p", [Request]),
    gtp_context:send_request(GtpPort, RemoteCntlIP, Request, ReqInfo).

proxy_dp_args(#context{data_port = #gtp_port{name = Name},
		       local_data_tei = LocalTEI,
		       remote_data_tei = RemoteTEI,
		       remote_data_ip = RemoteIP}) ->
    {forward, [Name, RemoteIP, LocalTEI, RemoteTEI]}.

dp_create_pdp_context(GrxContext, FwdContext) ->
    Args = proxy_dp_args(FwdContext),
    gtp_dp:create_pdp_context(GrxContext, Args).

dp_update_pdp_context(GrxContext, FwdContext) ->
    Args = proxy_dp_args(FwdContext),
    gtp_dp:update_pdp_context(GrxContext, Args).

dp_delete_pdp_context(GrxContext, FwdContext) ->
    Args = proxy_dp_args(FwdContext),
    gtp_dp:delete_pdp_context(GrxContext, Args).
