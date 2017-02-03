%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8_proxy).

-behaviour(gtp_api).

-compile({parse_transform, cut}).
-compile({parse_transform, do}).

-export([validate_options/1, init/2, request_spec/2,
	 handle_request/4, handle_response/4,
	 handle_cast/2, handle_info/2]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").
-include("gtp_proxy_ds.hrl").

-define(GTP_v1_Interface, ggsn_gn_proxy).
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
-define('Bearer Contexts created',			{v2_bearer_context, 0}).
-define('Bearer Contexts to be modified',		{v2_bearer_context, 0}).
-define('Protocol Configuration Options',		{v2_protocol_configuration_options, 0}).
-define('ME Identity',					{v2_mobile_equipment_identity, 0}).

-define('EPS Bearer ID',                                {v2_eps_bearer_id, 0}).

-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).

request_spec(v1, Type) ->
    ?GTP_v1_Interface:request_spec(v1, Type);
request_spec(v2, create_session_request) ->
    [{?'RAT Type',					mandatory},
     {?'Sender F-TEID for Control Plane',		mandatory},
     {?'Access Point Name',				mandatory},
     {?'Bearer Contexts to be created',			mandatory}];
request_spec(v2, create_session_response) ->
    [{?'Cause',						mandatory},
     {?'Bearer Contexts created',			mandatory}];
request_spec(v2, modify_bearer_request) ->
    [];
request_spec(v2, modify_bearer_response) ->
    [{?'Cause',						mandatory}];
request_spec(v2, delete_session_request) ->
    [];
request_spec(v2, delete_session_response) ->
    [{?'Cause',						mandatory}];
request_spec(v2, _) ->
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
    Opts1 = lists:ukeymerge(1, lists:keysort(1, Opts0), lists:keysort(1, Defaults)),
    Opts = maps:from_list(ergw_config:validate_options(
			    fun validate_context_option/2, Opts1)),
    {Name, Opts};
validate_context({Name, Opts0})
  when is_binary(Name), is_map(Opts0) ->
    Defaults = #{proxy_sockets    => [],
		 proxy_data_paths => []},
    Opts1 = maps:merge(Defaults, Opts0),
    Opts = maps:from_list(ergw_config:validate_options(
			    fun validate_context_option/2, maps:to_list(Opts1))),
    {Name, Opts};
validate_context(Value) ->
    throw({error, {options, {contexts, Value}}}).

validate_options(Opts0) ->
    lager:debug("PGW S5/S8 Options: ~p", [Opts0]),
    Defaults = [{proxy_data_source, gtp_proxy_ds},
		{proxy_sockets,     []},
		{proxy_data_paths,  []},
		{pgw,               undefined},
		{contexts,          []}],
    Opts1 = lists:ukeymerge(1, lists:keysort(1, Opts0), lists:keysort(1, Defaults)),
    ergw_config:validate_options(fun validate_option/2, Opts1).

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
validate_option(pgw, {_,_,_,_} = Value) ->
    Value;
validate_option(pgw, {_,_,_,_,_,_,_,_} = Value) ->
    Value;
validate_option(contexts, Values) when is_list(Values) ->
    lists:map(fun validate_context/1, Values);
validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

-record(request_info, {request_key, seq_no, new_peer}).
-record(context_state, {ebi}).

-define(CAUSE_OK(Cause), (Cause =:= request_accepted orelse
			  Cause =:= request_accepted_partially orelse
			  Cause =:= new_pdp_type_due_to_network_preference orelse
			  Cause =:= new_pdp_type_due_to_single_address_bearer_only)).

init(Opts, State) ->
    ProxyPorts = proplists:get_value(proxy_sockets, Opts),
    ProxyDPs = proplists:get_value(proxy_data_paths, Opts),
    PGW = proplists:get_value(pgw, Opts),
    ProxyDS = proplists:get_value(proxy_data_source, Opts, gtp_proxy_ds),
    Contexts = maps:from_list(proplists:get_value(contexts, Opts)),
    {ok, State#{proxy_ports => ProxyPorts, proxy_dps => ProxyDPs,
		contexts => Contexts, default_gw => PGW, proxy_ds => ProxyDS}}.

handle_cast({path_restart, Path},
	    #{context := #context{path = Path} = Context,
	      proxy_context := ProxyContext
	     } = State) ->
    initiate_delete_session_request(ProxyContext),
    dp_delete_pdp_context(Context, ProxyContext),
    {stop, normal, State};

handle_cast({path_restart, Path},
	    #{context := Context,
	      proxy_context := #context{path = Path} = ProxyContext
	     } = State) ->
    initiate_delete_session_request(Context),
    dp_delete_pdp_context(Context, ProxyContext),
    {stop, normal, State};

handle_cast({path_restart, _Path}, State) ->
    {noreply, State};

handle_cast({packet_in, _GtpPort, _IP, _Port, #gtp{type = error_indication}},
	    #{context := Context, proxy_context := ProxyContext} = State) ->
    dp_delete_pdp_context(Context, ProxyContext),
    {stop, normal, State};

handle_cast({packet_in, _GtpPort, _IP, _Port, _Msg}, State) ->
    lager:warning("packet_in not handled (yet): ~p", [_Msg]),
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

%% API Message Matrix:
%%
%% SGSN/MME/ TWAN/ePDG to PGW (S4/S11, S5/S8, S2a, S2b)
%%
%%   Create Session Request/Response
%%   Delete Session Request/Response
%%
%% SGSN/MME/ePDG to PGW (S4/S11, S5/S8, S2b)
%%
%%   Modify Bearer Request/Response
%%
%% SGSN/MME to PGW (S4/S11, S5/S8)
%%
%%   Change Notification Request/Response
%%   Resume Notification/Acknowledge

handle_request(_From, _Msg, true, State) ->
%% resent request
    {noreply, State};

handle_request(ReqKey, #gtp{version = v1} = Msg, Resent, State) ->
    ?GTP_v1_Interface:handle_request(ReqKey, Msg, Resent, State);

handle_request(ReqKey,
	       #gtp{type = create_session_request, seq_no = SeqNo,
		    ie = #{?'Recovery' := Recovery} = IEs} = Request,
	       _Resent,
	       #{context := Context0, default_gw := DefaultPGW, proxy_ds := ProxyDS} = State0) ->

    Context1 = update_context_from_gtp_req(Request, Context0#context{state = #context_state{}}),
    Context = gtp_path:bind(Recovery, Context1),
    gtp_context:register_remote_context(Context),
    State1 = State0#{context => Context},

    %% #gtp_port{ip = LocalCntlIP} = GtpPort,
    %% Session0 = #{'GGSN-Address' => gtp_c_lib:ip2bin(LocalCntlIP)},
    %% Session1 = init_session(IEs, Session0),
    %% lager:debug("Invoking CONTROL: ~p", [Session1]),
    %% ergw_control:authenticate(Session1),

    ProxyInfo0 = init_proxy_info(DefaultPGW, IEs),
    case ProxyDS:map(ProxyInfo0) of
	{ok, #proxy_info{ggsn = PGW} = ProxyInfo} ->
	    lager:debug("OK Proxy Map: ~p", [lager:pr(ProxyInfo, ?MODULE)]),
	    {ProxyGtpPort, ProxyGtpDP} = get_proxy_sockets(ProxyInfo, State1),

	    ProxyContext0 = init_proxy_context(PGW, ProxyGtpPort, ProxyGtpDP, Context),
	    ProxyContext1 = copy_subscriber_info(Context, ProxyInfo, ProxyContext0),
	    ProxyContext = gtp_path:bind(undefined, ProxyContext1),
	    State = State1#{proxy_info    => ProxyInfo,
			    proxy_context => ProxyContext},

	    ProxyReq0 = build_context_request(ProxyContext, ProxyInfo, Request),
	    ProxyReq = build_recovery(ProxyContext, false, ProxyReq0),
	    forward_request(ProxyContext, ProxyReq, ReqKey, SeqNo, Recovery /= undefined),

	    {noreply, State};

	Other ->
	    lager:warning("Failed Proxy Map: ~p", [Other]),

	    ResponseIEs0 = [#v2_cause{v2_cause = user_authentication_failed}],
	    ResponseIEs = gtp_v2_c:build_recovery(Context, Recovery /= undefined, ResponseIEs0),
	    Reply = {create_session_response, Context#context.remote_control_tei, ResponseIEs},
	    {stop, Reply, State1}
    end;

handle_request(ReqKey,
	       #gtp{version = Version,
		    type = modify_bearer_request, seq_no = SeqNo,
		    ie = #{?'Recovery' := Recovery}} = Request,
	       _Resent,
	       #{context := OldContext, proxy_info := ProxyInfo,
		 proxy_context := OldProxyContext} = State0) ->

    Context0 = OldContext#context{version = Version},
    Context1 = update_context_from_gtp_req(Request, Context0),
    Context = gtp_path:bind(Recovery, Context1),
    gtp_context:update_remote_context(OldContext, Context),
    State = apply_context_change(Context, OldContext, State0),

    ProxyContext0 = OldProxyContext#context{version = Version},
    ProxyContext = gtp_path:bind(undefined, ProxyContext0),

    ProxyReq0 = build_context_request(ProxyContext, ProxyInfo, Request),
    ProxyReq = build_recovery(ProxyContext, false, ProxyReq0),
    forward_request(ProxyContext, ProxyReq, ReqKey, SeqNo, Recovery /= undefined),

    {noreply, State#{context := Context, proxy_context := ProxyContext}};

handle_request(ReqKey,
	       #gtp{type = delete_session_request, seq_no = SeqNo} = Request, _Resent,
	       #{proxy_context := ProxyContext} = State) ->
    ProxyReq = build_context_request(ProxyContext, undefined, Request),
    forward_request(ProxyContext, ProxyReq, ReqKey, SeqNo, false),

    {noreply, State};

handle_request(_From, _Msg, _Resent, State) ->
    {noreply, State}.

handle_response(ReqInfo, #gtp{version = v1} = Msg, Request, State) ->
    ?GTP_v1_Interface:handle_response(ReqInfo, Msg, Request, State);

handle_response(#request_info{request_key = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
		#gtp{type = create_session_response,
		     ie = #{?'Recovery' := Recovery,
			    ?'Cause'    := #v2_cause{v2_cause = Cause}}} = Response, _Request,
		#{context := Context,
		  proxy_context := ProxyContext0} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext1 = update_context_from_gtp_req(Response, ProxyContext0),
    ProxyContext = gtp_path:bind(Recovery, ProxyContext1),
    gtp_context:register_remote_context(ProxyContext),

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
		#gtp{type = modify_bearer_response} = Response, _Request,
		#{context := Context,
		  proxy_context := OldProxyContext} = State0) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext = update_context_from_gtp_req(Response, OldProxyContext),
    gtp_context:update_remote_context(OldProxyContext, ProxyContext),
    State = apply_proxy_context_change(ProxyContext, OldProxyContext, State0),

    GtpResp0 = build_context_request(Context, undefined, Response),
    GtpResp = build_recovery(Context, NewPeer, GtpResp0),
    gtp_context:send_response(ReqKey, GtpResp#gtp{seq_no = SeqNo}),

    dp_update_pdp_context(Context, ProxyContext),

    {noreply, State};

handle_response(#request_info{request_key = ReqKey, seq_no = SeqNo},
		#gtp{type = delete_session_response} = Response, _Request,
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
%%% Helper functions
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

init_proxy_context(PGW, CntlPort, DataPort,
		   #context{version = Version, control_interface = Interface, state = State}) ->
    {ok, CntlTEI} = gtp_c_lib:alloc_tei(CntlPort),
    {ok, DataTEI} = gtp_c_lib:alloc_tei(DataPort),
    #context{
       version           = Version,
       control_interface = Interface,
       control_port      = CntlPort,
       local_control_tei = CntlTEI,
       data_port         = DataPort,
       local_data_tei    = DataTEI,
       remote_control_ip = PGW,
       state             = State
      }.

copy_subscriber_info(#context{apn = APN, imei = IMEI},
		     #proxy_info{imsi = IMSI, msisdn = MSISDN}, Context) ->
    Context#context{apn = APN, imsi = IMSI, imei = IMEI, msisdn = MSISDN}.

get_context_from_bearer(_, #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-U SGW',
			      key = RemoteDataTEI,
			      ipv4 = RemoteDataIP
			     }, Context) ->
    Context#context{
      remote_data_ip  = gtp_c_lib:bin2ip(RemoteDataIP),
      remote_data_tei = RemoteDataTEI
     };
get_context_from_bearer(_, #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-U PGW',
			      key = RemoteDataTEI,
			      ipv4 = RemoteDataIP
			     }, Context) ->
    Context#context{
      remote_data_ip  = gtp_c_lib:bin2ip(RemoteDataIP),
      remote_data_tei = RemoteDataTEI
     };
get_context_from_bearer(?'EPS Bearer ID', #v2_eps_bearer_id{eps_bearer_id = EBI},
			#context{state = State} = Context) ->
    Context#context{state = State#context_state{ebi = EBI}};
get_context_from_bearer(_K, _, Context) ->
    Context.

get_context_from_req(_, #v2_fully_qualified_tunnel_endpoint_identifier{
			   interface_type = ?'S5/S8-C SGW',
			key = RemoteCntlTEI, ipv4 = RemoteCntlIP
		       }, Context) ->
    Context#context{
      remote_control_ip  = gtp_c_lib:bin2ip(RemoteCntlIP),
      remote_control_tei = RemoteCntlTEI
     };
get_context_from_req(_, #v2_fully_qualified_tunnel_endpoint_identifier{
			   interface_type = ?'S5/S8-C PGW',
			key = RemoteCntlTEI, ipv4 = RemoteCntlIP
		       }, Context) ->
    Context#context{
      remote_control_ip  = gtp_c_lib:bin2ip(RemoteCntlIP),
      remote_control_tei = RemoteCntlTEI
     };
get_context_from_req(_K, #v2_bearer_context{instance = 0, group = Bearer}, Context) ->
    maps:fold(fun get_context_from_bearer/3, Context, Bearer);
get_context_from_req(?'Access Point Name', #v2_access_point_name{apn = APN}, Context) ->
    Context#context{apn = APN};
get_context_from_req(?'IMSI', #v2_international_mobile_subscriber_identity{imsi = IMSI}, Context) ->
    Context#context{imsi = IMSI};
get_context_from_req(?'ME Identity', #v2_mobile_equipment_identity{mei = IMEI}, Context) ->
    Context#context{imei = IMEI};
get_context_from_req(?'MSISDN', #v2_msisdn{msisdn = MSISDN}, Context) ->
    Context#context{msisdn = MSISDN};
get_context_from_req(_K, _, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs}, Context) ->
    maps:fold(fun get_context_from_req/3, Context, IEs).

set_bearer_from_context(#context{data_port = #gtp_port{ip = DataIP}, local_data_tei = DataTEI},
			_, #v2_fully_qualified_tunnel_endpoint_identifier{interface_type = ?'S5/S8-U SGW'} = IE) ->
    IE#v2_fully_qualified_tunnel_endpoint_identifier{
      key = DataTEI,
      ipv4 = gtp_c_lib:ip2bin(DataIP)};
set_bearer_from_context(#context{data_port = #gtp_port{ip = DataIP}, local_data_tei = DataTEI},
			_, #v2_fully_qualified_tunnel_endpoint_identifier{interface_type = ?'S5/S8-U PGW'} = IE) ->
    IE#v2_fully_qualified_tunnel_endpoint_identifier{
      key = DataTEI,
      ipv4 = gtp_c_lib:ip2bin(DataIP)};
set_bearer_from_context(_, _K, IE) ->
    IE.

set_req_from_context(#context{control_port = #gtp_port{ip = CntlIP}, local_control_tei = CntlTEI},
		     _K, #v2_fully_qualified_tunnel_endpoint_identifier{interface_type = ?'S5/S8-C SGW'} = IE) ->
    IE#v2_fully_qualified_tunnel_endpoint_identifier{
      key = CntlTEI,
      ipv4 = gtp_c_lib:ip2bin(CntlIP)};
set_req_from_context(#context{control_port = #gtp_port{ip = CntlIP}, local_control_tei = CntlTEI},
		     _K, #v2_fully_qualified_tunnel_endpoint_identifier{interface_type = ?'S5/S8-C PGW'} = IE) ->
    IE#v2_fully_qualified_tunnel_endpoint_identifier{
      key = CntlTEI,
      ipv4 = gtp_c_lib:ip2bin(CntlIP)};
set_req_from_context(Context, _K, #v2_bearer_context{instance = 0, group = Bearer} = IE) ->
    IE#v2_bearer_context{group = maps:map(set_bearer_from_context(Context, _, _), Bearer)};
set_req_from_context(_, _K, IE) ->
    IE.

update_gtp_req_from_context(Context, GtpReqIEs) ->
    maps:map(set_req_from_context(Context, _, _), GtpReqIEs).

init_proxy_info(?'Access Point Name', #v2_access_point_name{apn = APN}, PI) ->
    PI#proxy_info{apn = APN};
init_proxy_info(?'IMSI', #v2_international_mobile_subscriber_identity{imsi = IMSI}, PI) ->
    PI#proxy_info{imsi = IMSI};
init_proxy_info(?'MSISDN', #v2_msisdn{msisdn = MSISDN}, PI) ->
    PI#proxy_info{msisdn = MSISDN};
init_proxy_info(_K, _V, PI) ->
    PI.

init_proxy_info(DefaultGGSN, IEs) ->
    maps:fold(fun init_proxy_info/3, #proxy_info{ggsn = DefaultGGSN}, IEs).

proxy_request_nat(#proxy_info{apn = APN},
		  _K, #v2_access_point_name{instance = 0} = IE)
  when is_list(APN) ->
    IE#v2_access_point_name{apn = APN};

proxy_request_nat(#proxy_info{imsi = IMSI},
		  _K, #v2_international_mobile_subscriber_identity{instance = 0} = IE)
  when is_binary(IMSI) ->
    IE#v2_international_mobile_subscriber_identity{imsi = IMSI};

proxy_request_nat(#proxy_info{msisdn = MSISDN},
		  _K, #v2_msisdn{instance = 0} = IE)
  when is_binary(MSISDN) ->
    IE#v2_msisdn{msisdn = MSISDN};

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
	     T3, N3, Type, RequestIEs) ->
    Msg = #gtp{version = v2, type = Type, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(GtpPort, RemoteCntlIP, T3, N3, Msg, undefined).

initiate_delete_session_request(#context{state = #context_state{ebi = EBI}} = Context) ->
    RequestIEs0 = [#v2_cause{v2_cause = network_failure},
		   #v2_eps_bearer_id{eps_bearer_id = EBI}],
    RequestIEs = gtp_v2_c:build_recovery(Context, false, RequestIEs0),
    send_request(Context, ?T3, ?N3, delete_session_request, RequestIEs).

forward_request(#context{control_port = GtpPort, remote_control_ip = RemoteCntlIP},
	       Request, ReqKey, SeqNo, NewPeer) ->
    ReqInfo = #request_info{request_key = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
    lager:debug("Invoking Context Send Request: ~p", [Request]),
    gtp_context:forward_request(GtpPort, RemoteCntlIP, Request, ReqInfo).

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

build_recovery(Context, NewPeer, #gtp{ie = IEs} = Request) ->
    Request#gtp{ie = gtp_v2_c:build_recovery(Context, NewPeer, IEs)}.

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
