%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn_proxy).

-behaviour(gtp_api).

-compile({parse_transform, cut}).

-export([validate_options/1, init/2, request_spec/1, handle_request/4, handle_response/4, handle_cast/2]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").
-include("gtp_proxy_ds.hrl").

-compile([nowarn_unused_record]).

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

request_spec(create_pdp_context_request) ->
    [{?'IMSI',						conditional},
     {{selection_mode, 0},				conditional},
     {?'Tunnel Endpoint Identifier Data I',		mandatory},
     {?'Tunnel Endpoint Identifier Control Plane',	conditional},
     {?'NSAPI',						mandatory},
     {{nsapi, 1},					conditional},
     {{charging_characteristics, 0},			conditional},
     {?'End User Address',				conditional},
     {?'Access Point Name',				conditional},
     {?'SGSN Address for signalling',			mandatory},
     {?'SGSN Address for user traffic',			mandatory},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {?'MSISDN',					conditional},
     {?'Quality of Service Profile',			mandatory},
     {{traffic_flow_template, 0},			conditional},
     {?'IMEI',						conditional}];

request_spec(create_pdp_context_response) ->
    [{?'Cause',						mandatory},
     {{reordering_required, 0},				conditional},
     {?'Tunnel Endpoint Identifier Data I',		conditional},
     {?'Tunnel Endpoint Identifier Control Plane',	conditional},
     {{charging_id, 0},					conditional},
     {?'End User Address',				conditional},
     {?'SGSN Address for signalling',			conditional},
     {?'SGSN Address for user traffic',			conditional},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {?'Quality of Service Profile',			conditional}];

request_spec(update_pdp_context_request) ->
    [{?'Tunnel Endpoint Identifier Data I',		mandatory},
     {?'Tunnel Endpoint Identifier Control Plane',	conditional},
     {?'NSAPI',						mandatory},
     {?'SGSN Address for signalling',			mandatory},
     {?'SGSN Address for user traffic',			mandatory},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {?'Quality of Service Profile',			mandatory},
     {{traffic_flow_template, 0},			conditional}];

request_spec(update_pdp_context_response) ->
    [{{cause, 0},					mandatory},
     {?'Tunnel Endpoint Identifier Data I',		conditional},
     {?'Tunnel Endpoint Identifier Control Plane',	conditional},
     {{charging_id, 0},					conditional},
     {?'SGSN Address for signalling',			conditional},
     {?'SGSN Address for user traffic',			conditional},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {?'Quality of Service Profile',			conditional}];

request_spec(delete_pdp_context_request) ->
    [{{teardown_ind, 0},				conditional},
     {?'NSAPI',						mandatory}];

request_spec(delete_pdp_context_response) ->
    [{?'Cause',						mandatory}];

request_spec(_) ->
    [].

validate_context_option(proxy_sockets, Value) when is_list(Value), Value /= [] ->
    Value;
validate_context_option(proxy_data_paths, Value) when is_list(Value), Value /= [] ->
    Value;
validate_context_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_context({Name, Opts0})
  when is_binary(Name), is_list(Opts0) ->
    Defaults = [{proxy_sockets,    []},
		{proxy_data_paths, []}],
    Opts1 = lists:keymerge(1, lists:keysort(1, Opts0), lists:keysort(1, Defaults)),
    Opts = maps:from_list(ergw_config:validate_options(
			    fun validate_context_option/2, Opts1)),
    {Name, Opts};
validate_context(Value) ->
    throw({error, {options, {contexts, Value}}}).

validate_options(Opts0) ->
    lager:debug("GGSN Gn/Gp Options: ~p", [Opts0]),
    Defaults = [{proxy_sockets,    []},
		{proxy_data_paths, []}],
    Opts1 = lists:keymerge(1, lists:keysort(1, Opts0), lists:keysort(1, Defaults)),
    ergw_config:validate_options(fun validate_option/2, Opts1).

validate_option(Opt, Value)
  when Opt == proxy_sockets;
       Opt == proxy_data_paths ->
    validate_context_option(Opt, Value);
validate_option(ggsn, Value) ->
    Value;
validate_option(contexts, Values) when is_list(Values) ->
    maps:from_list(lists:map(fun validate_context/1, Values));
validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

-record(request_info, {request_key, seq_no, new_peer}).
-record(context_state, {nsapi}).

-define(CAUSE_OK(Cause), (Cause =:= request_accepted orelse
			  Cause =:= new_pdp_type_due_to_network_preference orelse
			  Cause =:= new_pdp_type_due_to_single_address_bearer_only)).

init(Opts, State) ->
    ProxyPorts = proplists:get_value(proxy_sockets, Opts),
    ProxyDPs = proplists:get_value(proxy_data_paths, Opts),
    GGSN = proplists:get_value(ggsn, Opts),
    ProxyDS = proplists:get_value(proxy_data_source, Opts, gtp_proxy_ds),
    Contexts = proplists:get_value(contexts, Opts, #{}),
    {ok, State#{proxy_ports => ProxyPorts, proxy_dps => ProxyDPs,
		contexts => Contexts, ggsn => GGSN, proxy_ds => ProxyDS}}.

handle_cast({path_restart, Path},
	    #{context := #context{path = Path} = Context,
	      proxy_context := ProxyContext
	     } = State) ->

    RequestIEs0 = [#cause{value = request_accepted},
		   #teardown_ind{value = 1},
		   #nsapi{nsapi = Context#context.state#context_state.nsapi}],
    RequestIEs = gtp_v1_c:build_recovery(ProxyContext, false, RequestIEs0),
    send_request(ProxyContext, ?T3, ?N3, RequestIEs),

    dp_delete_pdp_context(Context, ProxyContext),

    {stop, normal, State};

handle_cast({path_restart, Path},
	    #{context := Context,
	      proxy_context := #context{path = Path} = ProxyContext
	     } = State) ->

    RequestIEs0 = [#cause{value = request_accepted},
		   #teardown_ind{value = 1},
		   #nsapi{nsapi = Context#context.state#context_state.nsapi}],
    RequestIEs = gtp_v1_c:build_recovery(Context, false, RequestIEs0),
    send_request(Context, ?T3, ?N3, RequestIEs),

    dp_delete_pdp_context(Context, ProxyContext),

    {stop, normal, State};

handle_cast({path_restart, _Path}, State) ->
    {noreply, State}.

handle_request(_ReqKey, _Msg, true, State) ->
%% resent request
    {noreply, State};

handle_request(ReqKey,
	       #gtp{type = create_pdp_context_request, seq_no = SeqNo,
		    ie = #{?'Recovery' := Recovery} = IEs} = Request, _Resent,
	       #{tei := LocalTEI, gtp_port := GtpPort, gtp_dp_port := GtpDP,
		 ggsn := DefaultGGSN, proxy_ds := ProxyDS} = State0) ->

    APNie = maps:get(?'Access Point Name', IEs, undefined),

    APN = optional_apn_value(APNie, undefined),

    Context0 = init_context(APN, GtpPort, LocalTEI, GtpDP, LocalTEI),
    Context1 = update_context_from_gtp_req(Request, Context0),
    Context = gtp_path:bind(Recovery, Context1),
    State1 = State0#{context => Context},

    #gtp_port{ip = LocalCntlIP} = GtpPort,
    Session0 = #{'GGSN-Address' => gtp_c_lib:ip2bin(LocalCntlIP)},
    Session1 = init_session(IEs, Session0),
    lager:debug("Invoking CONTROL: ~p", [Session1]),
    %% ergw_control:authenticate(Session1),

    ProxyInfo0 = init_proxy_info(DefaultGGSN, IEs),
    case ProxyDS:map(ProxyInfo0) of
	{ok, #proxy_info{ggsn = GGSN} = ProxyInfo} ->
	    lager:debug("OK Proxy Map: ~p", [lager:pr(ProxyInfo, ?MODULE)]),
	    {ProxyGtpPort, ProxyGtpDP} = get_proxy_sockets(ProxyInfo, State1),
	    {ok, ProxyLocalTEI} = gtp_c_lib:alloc_tei(ProxyGtpPort),

	    lager:debug("ProxyGtpPort: ~p", [lager:pr(ProxyGtpPort, ?MODULE)]),
	    ProxyContext0 = init_context(APN, ProxyGtpPort, ProxyLocalTEI, ProxyGtpDP, ProxyLocalTEI),
	    ProxyContext1 = ProxyContext0#context{
			      remote_control_ip = GGSN,
			      remote_data_ip    = GGSN,
			      state             = Context#context.state
			     },
	    ProxyContext = gtp_path:bind(undefined, ProxyContext1),
	    State = State1#{proxy_info    => ProxyInfo,
			    proxy_context => ProxyContext},

	    ProxyReq0 = build_context_request(ProxyContext, ProxyInfo, Request),
	    ProxyReq = build_recovery(ProxyContext, false, ProxyReq0),
	    forward_request(ProxyContext, ProxyReq, ReqKey, SeqNo, Recovery /= undefined),

	    {noreply, State};

	Other ->
	    lager:warning("Failed Proxy Map: ~p", [Other]),

	    ResponseIEs0 = [#cause{value = user_authentication_failed}],
	    ResponseIEs = gtp_v1_c:build_recovery(Context, Recovery /= undefined, ResponseIEs0),
	    Reply = {create_pdp_context_response, Context#context.remote_control_tei, ResponseIEs},
	    {stop, Reply, State1}
    end;

handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request, seq_no = SeqNo,
		    ie = #{?'Recovery' := Recovery}} = Request, _Resent,
	       #{context := OldContext, proxy_info := ProxyInfo,
		 proxy_context := ProxyContext0} = State0) ->

    Context0 = update_context_from_gtp_req(Request, OldContext),
    Context = gtp_path:bind(Recovery, Context0),
    State = apply_context_change(Context, OldContext, State0),

    ProxyContext = gtp_path:bind(undefined, ProxyContext0),

    ProxyReq0 = build_context_request(ProxyContext, ProxyInfo, Request),
    ProxyReq = build_recovery(ProxyContext, false, ProxyReq0),
    forward_request(ProxyContext, ProxyReq, ReqKey, SeqNo, Recovery /= undefined),

    {noreply, State#{context := Context, proxy_context := ProxyContext}};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request, seq_no = SeqNo} = Request, _Resent,
	       #{proxy_context := ProxyContext} = State) ->
    ProxyReq = build_context_request(ProxyContext, undefined, Request),
    forward_request(ProxyContext, ProxyReq, ReqKey, SeqNo, false),

    {noreply, State};

handle_request({GtpPort, _IP, _Port}, Msg, _Resent, State) ->
    lager:warning("Unknown Proxy Message on ~p: ~p", [GtpPort, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_response(#request_info{request_key = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
		#gtp{type = create_pdp_context_response,
		     ie = #{?'Recovery' := Recovery,
			    ?'Cause' := #cause{value = Cause}}} = Response, _Request,
		#{context := Context,
		  proxy_context := ProxyContext0} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext1 = update_context_from_gtp_req(Response, ProxyContext0),
    ProxyContext = gtp_path:bind(Recovery, ProxyContext1),

    GtpResp0 = build_context_request(Context, undefined, Response),
    GtpResp = build_recovery(Context, NewPeer, GtpResp0),
    gtp_context:send_response(ReqKey, GtpResp#gtp{seq_no = SeqNo}),

    if ?CAUSE_OK(Cause) ->
	    dp_create_pdp_context(Context, ProxyContext),
	    lager:info("Create PDP Context ~p", [Context]),

	    {noreply, State#{proxy_context => ProxyContext}};

       true ->
	    {stop, State}
    end;

handle_response(#request_info{request_key = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
		#gtp{type = update_pdp_context_response} = Response, _Request,
		#{context := Context,
		  proxy_context := OldProxyContext} = State0) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext = update_context_from_gtp_req(Response, OldProxyContext),
    State = apply_proxy_context_change(ProxyContext, OldProxyContext, State0),

    GtpResp0 = build_context_request(Context, undefined, Response),
    GtpResp = build_recovery(Context, NewPeer, GtpResp0),
    gtp_context:send_response(ReqKey, GtpResp#gtp{seq_no = SeqNo}),

    dp_update_pdp_context(Context, ProxyContext),

    {noreply, State};

handle_response(#request_info{request_key = ReqKey, seq_no = SeqNo},
		#gtp{type = delete_pdp_context_response} = Response, _Request,
		#{context := Context,
		  proxy_context := ProxyContext} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    GtpResp = build_context_request(Context, undefined, Response),
    gtp_context:send_response(ReqKey, GtpResp#gtp{seq_no = SeqNo}),

    dp_delete_pdp_context(Context, ProxyContext),
    {stop, State};

handle_response(_ReqInfo, Response, _Req, State) ->
    lager:warning("Unknown Proxy Response ~p", [lager:pr(Response, ?MODULE)]),
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

apply_context_change(NewContext0, OldContext, State)
  when NewContext0 /= OldContext ->
    NewContext = gtp_path:bind(NewContext0),
    gtp_path:unbind(OldContext),
    State#{context => NewContext};
apply_context_change(_NewContext, _OldContext, State) ->
    State.

apply_proxy_context_change(NewContext0, OldContext, State)
  when NewContext0 /= OldContext ->
    NewContext = gtp_path:bind(NewContext0),
    gtp_path:unbind(OldContext),
    State#{proxy_context => NewContext};
apply_proxy_context_change(_NewContext, _OldContext, State) ->
    State.

init_session(IEs, Session) ->
    maps:fold(fun copy_to_session/3, Session, IEs).

%% copy_to_session(#international_mobile_subscriber_identity{imsi = IMSI}, Session) ->
%%     Id = [{'Subscription-Id-Type' , 1}, {'Subscription-Id-Data', IMSI}],
%%     Session#{'Subscription-Id' => Id};

copy_to_session(_K, #international_mobile_subscriber_identity{imsi = IMSI}, Session) ->
    Session#{'IMSI' => IMSI};
copy_to_session(_K, #ms_international_pstn_isdn_number{
		       msisdn = {isdn_address, _, _, 1, MSISDN}}, Session) ->
    Session#{'MSISDN' => MSISDN};
copy_to_session(_K, #gsn_address{instance = 0, address = IP}, Session) ->
    Session#{'SGSN-Address' => gtp_c_lib:ip2bin(IP)};
copy_to_session(_K, #rat_type{rat_type = Type}, Session) ->
    Session#{'RAT-Type' => Type};
copy_to_session(_K, #selection_mode{mode = Mode}, Session) ->
    Session#{'Selection-Mode' => Mode};

copy_to_session(_K, _V, Session) ->
    Session.

init_context(APN, CntlPort, CntlTEI, DataPort, DataTEI) ->
    #context{
       apn               = APN,
       version           = v1,
       control_interface = ?MODULE,
       control_port      = CntlPort,
       local_control_tei = CntlTEI,
       data_port         = DataPort,
       local_data_tei    = DataTEI,
       state             = #context_state{}
      }.

get_context_from_req(_K, #gsn_address{instance = 0, address = CntlIP}, Context) ->
    Context#context{remote_control_ip = gtp_c_lib:bin2ip(CntlIP)};
get_context_from_req(_K, #gsn_address{instance = 1, address = DataIP}, Context) ->
    Context#context{remote_data_ip = gtp_c_lib:bin2ip(DataIP)};
get_context_from_req(_K, #tunnel_endpoint_identifier_data_i{instance = 0, tei = DataTEI}, Context) ->
    Context#context{remote_data_tei = DataTEI};
get_context_from_req(_K, #tunnel_endpoint_identifier_control_plane{instance = 0, tei = CntlTEI}, Context) ->
    Context#context{remote_control_tei = CntlTEI};
get_context_from_req(_K, #nsapi{instance = 0, nsapi = NSAPI}, #context{state = State} = Context) ->
    Context#context{state = State#context_state{nsapi = NSAPI}};
get_context_from_req(_K, _, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs}, Context) ->
    maps:fold(fun get_context_from_req/3, Context, IEs).

set_context_from_req(#context{control_port = #gtp_port{ip = CntlIP}},
		     _K, #gsn_address{instance = 0} = IE) ->
    IE#gsn_address{address = gtp_c_lib:ip2bin(CntlIP)};
set_context_from_req(#context{data_port = #gtp_port{ip = DataIP}},
		     _K, #gsn_address{instance = 1} = IE) ->
    IE#gsn_address{address = gtp_c_lib:ip2bin(DataIP)};
set_context_from_req(#context{local_data_tei = DataTEI},
		     _K, #tunnel_endpoint_identifier_data_i{instance = 0} = IE) ->
    IE#tunnel_endpoint_identifier_data_i{tei = DataTEI};
set_context_from_req(#context{local_control_tei = CntlTEI},
		     _K, #tunnel_endpoint_identifier_control_plane{instance = 0} = IE) ->
    IE#tunnel_endpoint_identifier_control_plane{tei = CntlTEI};
set_context_from_req(_, _K, IE) ->
    IE.

update_gtp_req_from_context(Context, GtpReqIEs) ->
    maps:map(set_context_from_req(Context, _, _), GtpReqIEs).

init_proxy_info(?'Access Point Name', #access_point_name{apn = APN}, PI) ->
    PI#proxy_info{apn = APN};
init_proxy_info(?'IMSI', #international_mobile_subscriber_identity{imsi = IMSI}, PI) ->
    PI#proxy_info{imsi = IMSI};
init_proxy_info(?'MSISDN', #ms_international_pstn_isdn_number{msisdn = MSISDN}, PI) ->
    PI#proxy_info{msisdn = MSISDN};
init_proxy_info(_K, _V, PI) ->
    PI.

init_proxy_info(DefaultGGSN, IEs) ->
    maps:fold(fun init_proxy_info/3, #proxy_info{context = default, ggsn = DefaultGGSN}, IEs).

proxy_request_nat(#proxy_info{apn = APN},
		  _K, #access_point_name{instance = 0} = IE)
  when is_list(APN) ->
    IE#access_point_name{apn = APN};

proxy_request_nat(#proxy_info{imsi = IMSI},
		  _K, #international_mobile_subscriber_identity{instance = 0} = IE)
  when is_binary(IMSI) ->
    IE#international_mobile_subscriber_identity{imsi = IMSI};

proxy_request_nat(#proxy_info{msisdn = MSISDN},
		  _K, #ms_international_pstn_isdn_number{instance = 0} = IE)
  when is_binary(MSISDN) ->
    IE#ms_international_pstn_isdn_number{msisdn = {isdn_address, 1, 1, 1, MSISDN}};

proxy_request_nat(_ProxyInfo, _K, IE) ->
    IE.

apply_proxy_request_nat(ProxyInfo, GtpReqIEs) ->
    maps:map(proxy_request_nat(ProxyInfo, _, _), GtpReqIEs).

build_context_request(#context{remote_control_tei = TEI} = Context,
		      ProxyInfo, #gtp{ie = RequestIEs} = Request) ->
    ProxyIEs0 = maps:without([?'Recovery'], RequestIEs),
    ProxyIEs1 = apply_proxy_request_nat(ProxyInfo, ProxyIEs0),
    ProxyIEs = update_gtp_req_from_context(Context, ProxyIEs1),
    Request#gtp{tei = TEI, ie = ProxyIEs}.

send_request(#context{control_port = GtpPort,
		      remote_control_tei = RemoteCntlTEI,
		      remote_control_ip = RemoteCntlIP},
	     T3, N3, RequestIEs) ->
    Msg = #gtp{version = v1, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(GtpPort, RemoteCntlIP, T3, N3, Msg, undefined).

forward_request(#context{control_port = GtpPort, remote_control_ip = RemoteCntlIP},
	       Request, ReqKey, SeqNo, NewPeer) ->
    ReqInfo = #request_info{request_key = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
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

optional_apn_value(#access_point_name{apn = APN}, _) ->
    APN;
optional_apn_value(_, Default) ->
    Default.

build_recovery(Context, NewPeer, #gtp{ie = IEs} = Request) ->
    Request#gtp{ie = gtp_v1_c:build_recovery(Context, NewPeer, IEs)}.

get_proxy_sockets(#proxy_info{context = Context},
	       #{contexts := Contexts, proxy_ports := ProxyPorts, proxy_dps := ProxyDPs}) ->
    {Cntl, Data} =
	case maps:get(Context, Contexts, undefined) of
	    #{proxy_sockets := Cntl0, proxy_data_paths := Data0} ->
		{Cntl0, Data0};
	    _ ->
		lager:warning("proxy context ~p not found, using default", [Context]),
		{ProxyPorts, ProxyDPs}
	end,
    {gtp_socket_reg:lookup(hd(Cntl)), gtp_socket_reg:lookup(hd(Data))}.
