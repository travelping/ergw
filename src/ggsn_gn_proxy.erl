%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn_proxy).

-behaviour(gtp_api).

-compile({parse_transform, cut}).

-export([validate_options/1, init/2, request_spec/3,
	 handle_request/4, handle_response/4,
	 handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").
-include("gtp_proxy_ds.hrl").

-compile([nowarn_unused_record]).

-define(T3, 10 * 1000).
-define(N3, 5).

-define(IS_REQUEST_CONTEXT(Key, Msg, Context),
	(is_record(Key, request_key) andalso
	 is_record(Msg, gtp) andalso
	 Key#request_key.gtp_port =:= Context#context.control_port andalso
	 Msg#gtp.tei =:= Context#context.local_control_tei)).

-define(IS_REQUEST_CONTEXT_OPTIONAL_TEI(Key, Msg, Context),
	(is_record(Key, request_key) andalso
	 is_record(Msg, gtp) andalso
	 Key#request_key.gtp_port =:= Context#context.control_port andalso
	 (Msg#gtp.tei =:= 0 orelse
	  Msg#gtp.tei =:= Context#context.local_control_tei))).

-define(IS_RESPONSE_CONTEXT(Key, Context, Msg, ProxyContext),
	(is_record(Key, request_key) andalso
	 is_record(Msg, gtp) andalso
	 Key#request_key.gtp_port =:= Context#context.control_port andalso
	 Msg#gtp.tei =:= ProxyContext#context.local_control_tei)).

-define(IS_RESPONSE_CONTEXT_OPTIONAL_TEI(Key, Context, Msg, ProxyContext),
	(is_record(Key, request_key) andalso
	 is_record(Msg, gtp) andalso
	 Key#request_key.gtp_port =:= Context#context.control_port andalso
	 (Msg#gtp.tei =:= 0 orelse
	  Msg#gtp.tei =:= ProxyContext#context.local_control_tei))).

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

-define(CAUSE_OK(Cause), (Cause =:= request_accepted orelse
			  Cause =:= new_pdp_type_due_to_network_preference orelse
			  Cause =:= new_pdp_type_due_to_single_address_bearer_only)).

request_spec(v1, _Type, Cause)
  when Cause /= undefined andalso not ?CAUSE_OK(Cause) ->
    [];

request_spec(v1, create_pdp_context_request, _) ->
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

request_spec(v1, create_pdp_context_response, _) ->
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

%% SGSN initated reqeuest:
%% request_spec(v1, update_pdp_context_request, _) ->
%%     [{?'Tunnel Endpoint Identifier Data I',		mandatory},
%%      {?'Tunnel Endpoint Identifier Control Plane',	conditional},
%%      {?'NSAPI',						mandatory},
%%      {?'SGSN Address for signalling',			mandatory},
%%      {?'SGSN Address for user traffic',			mandatory},
%%      {{gsn_address, 2},					conditional},
%%      {{gsn_address, 3},					conditional},
%%      {?'Quality of Service Profile',			mandatory},
%%      {{traffic_flow_template, 0},			conditional}];

request_spec(v1, update_pdp_context_request, _) ->
    [{?'NSAPI',						mandatory}];

request_spec(v1, update_pdp_context_response, _) ->
    [{{cause, 0},					mandatory},
     {?'Tunnel Endpoint Identifier Data I',		conditional},
     {?'Tunnel Endpoint Identifier Control Plane',	conditional},
     {{charging_id, 0},					conditional},
     {?'SGSN Address for signalling',			conditional},
     {?'SGSN Address for user traffic',			conditional},
     {{gsn_address, 2},					conditional},
     {{gsn_address, 3},					conditional},
     {?'Quality of Service Profile',			conditional}];

request_spec(v1, delete_pdp_context_request, _) ->
    [{{teardown_ind, 0},				conditional},
     {?'NSAPI',						mandatory}];

request_spec(v1, delete_pdp_context_response, _) ->
    [{?'Cause',						mandatory}];

request_spec(v1, _, _) ->
    [].

validate_options(Opts) ->
    lager:debug("GGSN Gn/Gp Options: ~p", [Opts]),
    Defaults = [{proxy_data_source, gtp_proxy_ds},
		{proxy_sockets,     []},
		{proxy_data_paths,  []},
		{ggsn,              undefined},
		{contexts,          []}],
    ergw_config:validate_options(fun validate_option/2, Opts, Defaults).

validate_option(ggsn, {_,_,_,_} = Value) ->
    Value;
validate_option(ggsn, {_,_,_,_,_,_,_,_} = Value) ->
    Value;
validate_option(Opt, Value) ->
    ergw_proxy_lib:validate_option(Opt, Value).

-record(request_info, {request_key, seq_no, new_peer}).
-record(context_state, {nsapi}).

init(Opts, State) ->
    ProxyPorts = proplists:get_value(proxy_sockets, Opts),
    ProxyDPs = proplists:get_value(proxy_data_paths, Opts),
    GGSN = proplists:get_value(ggsn, Opts),
    ProxyDS = proplists:get_value(proxy_data_source, Opts),
    Contexts = maps:from_list(proplists:get_value(contexts, Opts)),
    {ok, State#{proxy_ports => ProxyPorts, proxy_dps => ProxyDPs,
		contexts => Contexts, default_gw => GGSN, proxy_ds => ProxyDS}}.

handle_call(delete_context, _From, State) ->
    lager:warning("delete_context no handled(yet)"),
    {reply, ok, State}.

handle_cast({path_restart, Path},
	    #{context := #context{path = Path} = Context,
	      proxy_context := ProxyContext
	     } = State) ->
    initiate_delete_pdp_context_request(ProxyContext),
    dp_delete_pdp_context(Context, ProxyContext),
    {stop, normal, State};

handle_cast({path_restart, Path},
	    #{context := Context,
	      proxy_context := #context{path = Path} = ProxyContext
	     } = State) ->
    initiate_delete_pdp_context_request(Context),
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

handle_request(_ReqKey, _Msg, true, State) ->
%% resent request
    {noreply, State};

handle_request(ReqKey,
	       #gtp{type = create_pdp_context_request, seq_no = SeqNo,
		    ie = #{?'Recovery' := Recovery} = IEs} = Request, _Resent,
	       #{context := Context0} = State) ->

    Context1 = update_context_from_gtp_req(Request, Context0#context{state = #context_state{}}),
    ContextPreProxy = gtp_path:bind(Recovery, Context1),
    gtp_context:register_remote_context(ContextPreProxy),

    Session1 = init_session(IEs, ContextPreProxy),
    lager:debug("Invoking CONTROL: ~p", [Session1]),
    %% ergw_control:authenticate(Session1),

    #proxy_info{ggsn = GGSN, restrictions = Restrictions} =
	ProxyInfo = handle_proxy_info(ContextPreProxy, Recovery, State),

    Context = ContextPreProxy#context{restrictions = Restrictions},
    gtp_context:enforce_restrictions(Request, Context),

    {ProxyGtpPort, ProxyGtpDP} = get_proxy_sockets(ProxyInfo, State),

    ProxyContext0 = init_proxy_context(GGSN, ProxyGtpPort, ProxyGtpDP, Context, ProxyInfo),
    ProxyContext = gtp_path:bind(undefined, ProxyContext0),

    ProxyReq0 = build_context_request(ProxyContext, Request),
    ProxyReq = build_recovery(ProxyContext, false, ProxyReq0),
    forward_request(ProxyContext, ProxyReq, ReqKey, SeqNo, Recovery /= undefined),

    {noreply, State#{context => Context,
		     proxy_context => ProxyContext}};

handle_request(ReqKey,
	       #gtp{version = Version,
		    type = update_pdp_context_request, seq_no = SeqNo,
		    ie = #{?'Recovery' := Recovery}} = Request, _Resent,
	       #{context := OldContext,
		 proxy_context := OldProxyContext} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, OldContext) ->

    Context0 = OldContext#context{version = Version},
    Context1 = update_context_from_gtp_req(Request, Context0),
    gtp_context:enforce_restrictions(Request, Context1),

    Context2 = gtp_path:bind(Recovery, Context1),
    gtp_context:update_remote_context(OldContext, Context2),
    Context = apply_context_change(Context2, OldContext),

    ProxyContext0 = OldProxyContext#context{version = Version},
    ProxyContext = gtp_path:bind(undefined, ProxyContext0),

    ProxyReq0 = build_context_request(ProxyContext, Request),
    ProxyReq = build_recovery(ProxyContext, false, ProxyReq0),
    forward_request(ProxyContext, ProxyReq, ReqKey, SeqNo, Recovery /= undefined),

    {noreply, State#{context := Context, proxy_context := ProxyContext}};

%%
%% GGSN to SGW Update PDP Context Request
%%
handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request, seq_no = SeqNo,
		    ie = #{?'Recovery' := Recovery}} = ProxyReq, _Resent,
	       #{context := Context0,
		 proxy_context := ProxyContext0} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, ProxyReq, ProxyContext0) ->

    Context = gtp_path:bind(undefined, Context0),
    ProxyContext = gtp_path:bind(Recovery, ProxyContext0),

    Req0 = build_context_request(Context, ProxyReq),
    Req = build_recovery(Context, false, Req0),
    forward_request(Context, Req, ReqKey, SeqNo, Recovery /= undefined),

    {noreply, State#{context := Context, proxy_context := ProxyContext}};

handle_request(ReqKey,
	       #gtp{type = ms_info_change_notification_request, seq_no = SeqNo,
		    ie = #{?'Recovery' := Recovery}} = Request,
	       _Resent,
	       #{context := Context0,
		 proxy_context := ProxyContext0} = State) ->

    Context = gtp_path:bind(Recovery, Context0),
    ProxyContext = gtp_path:bind(undefined, ProxyContext0),

    ProxyReq0 = build_context_request(ProxyContext, Request),
    ProxyReq = build_recovery(ProxyContext, false, ProxyReq0),
    forward_request(ProxyContext, ProxyReq, ReqKey, SeqNo, Recovery /= undefined),

    {noreply, State#{context := Context, proxy_context := ProxyContext}};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request,
		    seq_no = SeqNo} = Request, _Resent,
	       #{context := Context,
		 proxy_context := ProxyContext} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->
    ProxyReq = build_context_request(ProxyContext, Request),
    forward_request(ProxyContext, ProxyReq, ReqKey, SeqNo, false),

    {noreply, State};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request,
		    seq_no = SeqNo} = ProxyReq, _Resent,
	       #{context := Context,
		 proxy_context := ProxyContext} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, ProxyReq, ProxyContext) ->
    Req = build_context_request(Context, ProxyReq),
    forward_request(Context, Req, ReqKey, SeqNo, false),

    {noreply, State};

handle_request(#request_key{gtp_port = GtpPort}, Msg, _Resent, State) ->
    lager:warning("Unknown Proxy Message on ~p: ~p", [GtpPort, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_response(#request_info{request_key = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
		#gtp{type = create_pdp_context_response,
		     ie = #{?'Recovery' := Recovery,
			    ?'Cause' := #cause{value = Cause}}} = Response, _Request,
		#{context := Context,
		  proxy_context := ProxyContext0} = State)
  when ?IS_RESPONSE_CONTEXT(ReqKey, Context, Response, ProxyContext0) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext1 = update_context_from_gtp_req(Response, ProxyContext0),
    ProxyContext = gtp_path:bind(Recovery, ProxyContext1),
    gtp_context:register_remote_context(ProxyContext),

    GtpResp0 = build_context_request(Context, Response),
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
		  proxy_context := OldProxyContext} = State)
  when ?IS_RESPONSE_CONTEXT(ReqKey, Context, Response, OldProxyContext) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext0 = update_context_from_gtp_req(Response, OldProxyContext),
    gtp_context:update_remote_context(OldProxyContext, ProxyContext0),
    ProxyContext = apply_context_change(ProxyContext0, OldProxyContext),

    GtpResp0 = build_context_request(Context, Response),
    GtpResp = build_recovery(Context, NewPeer, GtpResp0),
    gtp_context:send_response(ReqKey, GtpResp#gtp{seq_no = SeqNo}),

    dp_update_pdp_context(Context, ProxyContext),

    {noreply, State#{proxy_context => ProxyContext}};

handle_response(#request_info{request_key = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
		#gtp{type = update_pdp_context_response} = Response, _Request,
		#{context := Context,
		  proxy_context := ProxyContext} = State)
  when ?IS_RESPONSE_CONTEXT(ReqKey, ProxyContext, Response, Context) ->
    lager:warning("OK SGSN Response ~p", [lager:pr(Response, ?MODULE)]),

    GtpResp0 = build_context_request(ProxyContext, Response),
    GtpResp = build_recovery(ProxyContext, NewPeer, GtpResp0),
    gtp_context:send_response(ReqKey, GtpResp#gtp{seq_no = SeqNo}),

    {noreply, State};

handle_response(#request_info{request_key = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
		#gtp{type = ms_info_change_notification_response} = Response, _Request,
		#{context := Context,
		  proxy_context := ProxyContext} = State)
  when ?IS_RESPONSE_CONTEXT_OPTIONAL_TEI(ReqKey, Context, Response, ProxyContext) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    GtpResp0 = build_context_request(Context, Response),
    GtpResp = build_recovery(Context, NewPeer, GtpResp0),
    gtp_context:send_response(ReqKey, GtpResp#gtp{seq_no = SeqNo}),

    {noreply, State};

handle_response(#request_info{request_key = ReqKey, seq_no = SeqNo},
		#gtp{type = delete_pdp_context_response} = Response, _Request,
		#{context := Context,
		  proxy_context := ProxyContext} = State)
  when ?IS_RESPONSE_CONTEXT(ReqKey, Context, Response, ProxyContext) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    GtpResp = build_context_request(Context, Response),
    gtp_context:send_response(ReqKey, GtpResp#gtp{seq_no = SeqNo}),

    dp_delete_pdp_context(Context, ProxyContext),
    {stop, State};


handle_response(#request_info{request_key = ReqKey, seq_no = SeqNo},
		#gtp{type = delete_pdp_context_response} = Response, _Request,
		#{context := Context,
		  proxy_context := ProxyContext} = State)
  when ?IS_RESPONSE_CONTEXT(ReqKey, ProxyContext, Response, Context) ->
    lager:warning("OK SGSN Response ~p", [lager:pr(Response, ?MODULE)]),

    GtpResp = build_context_request(ProxyContext, Response),
    gtp_context:send_response(ReqKey, GtpResp#gtp{seq_no = SeqNo}),

    dp_delete_pdp_context(Context, ProxyContext),
    {stop, State};


handle_response(_ReqInfo, Response, _Req, State) ->
    lager:warning("Unknown Proxy Response ~p", [lager:pr(Response, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_proxy_info(Context, Recovery, #{default_gw := DefaultGGSN,
				       proxy_ds := ProxyDS}) ->
    ProxyInfo0 = proxy_info(DefaultGGSN, Context),
    case ProxyDS:map(ProxyInfo0) of
	{ok, #proxy_info{} = ProxyInfo} ->
	    lager:debug("OK Proxy Map: ~p", [lager:pr(ProxyInfo, ?MODULE)]),
	    ProxyInfo;

	Other ->
	    lager:warning("Failed Proxy Map: ~p", [Other]),

	    ResponseIEs0 = [#cause{value = user_authentication_failed}],
	    ResponseIEs = gtp_v1_c:build_recovery(Context, Recovery /= undefined, ResponseIEs0),
	    throw(#ctx_err{level = ?FATAL,
			   reply = {create_pdp_context_response,
				    Context#context.remote_control_tei,
				    ResponseIEs},
			   context = Context})
    end.

apply_context_change(NewContext0, OldContext)
  when NewContext0 /= OldContext ->
    NewContext = gtp_path:bind(NewContext0),
    gtp_path:unbind(OldContext),
    NewContext;
apply_context_change(NewContext, _OldContext) ->
    NewContext.

init_session(IEs, #context{control_port = #gtp_port{ip = LocalIP}}) ->
    Session = #{'Service-Type'      => 'Framed-User',
		'Framed-Protocol'   => 'GPRS-PDP-Context',
		'3GPP-GGSN-Address' => LocalIP
	       },
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

init_proxy_context(GGSN, CntlPort, DataPort,
		   #context{imei = IMEI, version = Version,
			    control_interface = Interface, state = State},
		   #proxy_info{apn = APN, imsi = IMSI, msisdn = MSISDN}) ->

    {ok, CntlTEI} = gtp_c_lib:alloc_tei(CntlPort),
    {ok, DataTEI} = gtp_c_lib:alloc_tei(DataPort),
    #context{
       apn               = APN,
       imsi              = IMSI,
       imei              = IMEI,
       msisdn            = MSISDN,

       version           = Version,
       control_interface = Interface,
       control_port      = CntlPort,
       local_control_tei = CntlTEI,
       data_port         = DataPort,
       local_data_tei    = DataTEI,
       remote_control_ip = GGSN,
       state             = State
      }.

get_context_from_req(_K, #gsn_address{instance = 0, address = CntlIP}, Context) ->
    Context#context{remote_control_ip = gtp_c_lib:bin2ip(CntlIP)};
get_context_from_req(_K, #gsn_address{instance = 1, address = DataIP}, Context) ->
    Context#context{remote_data_ip = gtp_c_lib:bin2ip(DataIP)};
get_context_from_req(_K, #tunnel_endpoint_identifier_data_i{instance = 0, tei = DataTEI}, Context) ->
    Context#context{remote_data_tei = DataTEI};
get_context_from_req(_K, #tunnel_endpoint_identifier_control_plane{instance = 0, tei = CntlTEI}, Context) ->
    Context#context{remote_control_tei = CntlTEI};
get_context_from_req(?'Access Point Name', #access_point_name{apn = APN}, Context) ->
    Context#context{apn = APN};
get_context_from_req(?'IMSI', #international_mobile_subscriber_identity{imsi = IMSI}, Context) ->
    Context#context{imsi = IMSI};
get_context_from_req(?'IMEI', #imei{imei = IMEI}, Context) ->
    Context#context{imei = IMEI};
get_context_from_req(?'MSISDN', #ms_international_pstn_isdn_number{
				   msisdn = {isdn_address, _, _, 1, MSISDN}}, Context) ->
    Context#context{msisdn = MSISDN};
get_context_from_req(_K, #nsapi{instance = 0, nsapi = NSAPI}, #context{state = State} = Context) ->
    Context#context{state = State#context_state{nsapi = NSAPI}};
get_context_from_req(_K, _, Context) ->
    Context.

update_context_from_gtp_req(#gtp{ie = IEs}, Context) ->
    maps:fold(fun get_context_from_req/3, Context, IEs).

set_req_from_context(#context{apn = APN},
		  _K, #access_point_name{instance = 0} = IE)
  when is_list(APN) ->
    IE#access_point_name{apn = APN};
set_req_from_context(#context{imsi = IMSI},
		  _K, #international_mobile_subscriber_identity{instance = 0} = IE)
  when is_binary(IMSI) ->
    IE#international_mobile_subscriber_identity{imsi = IMSI};
set_req_from_context(#context{msisdn = MSISDN},
		  _K, #ms_international_pstn_isdn_number{instance = 0} = IE)
  when is_binary(MSISDN) ->
    IE#ms_international_pstn_isdn_number{msisdn = {isdn_address, 1, 1, 1, MSISDN}};
set_req_from_context(#context{control_port = #gtp_port{ip = CntlIP}},
		     _K, #gsn_address{instance = 0} = IE) ->
    IE#gsn_address{address = gtp_c_lib:ip2bin(CntlIP)};
set_req_from_context(#context{data_port = #gtp_port{ip = DataIP}},
		     _K, #gsn_address{instance = 1} = IE) ->
    IE#gsn_address{address = gtp_c_lib:ip2bin(DataIP)};
set_req_from_context(#context{local_data_tei = DataTEI},
		     _K, #tunnel_endpoint_identifier_data_i{instance = 0} = IE) ->
    IE#tunnel_endpoint_identifier_data_i{tei = DataTEI};
set_req_from_context(#context{local_control_tei = CntlTEI},
		     _K, #tunnel_endpoint_identifier_control_plane{instance = 0} = IE) ->
    IE#tunnel_endpoint_identifier_control_plane{tei = CntlTEI};
set_req_from_context(_, _K, IE) ->
    IE.

update_gtp_req_from_context(Context, GtpReqIEs) ->
    maps:map(set_req_from_context(Context, _, _), GtpReqIEs).

proxy_info(DefaultGGSN,
	   #context{apn = APN, imsi = IMSI, msisdn = MSISDN,
		    restrictions = Restrictions}) ->
    #proxy_info{ggsn = DefaultGGSN, apn = APN, imsi = IMSI,
		msisdn = MSISDN, restrictions = Restrictions}.

build_context_request(#context{remote_control_tei = TEI} = Context,
		      #gtp{ie = RequestIEs} = Request) ->
    ProxyIEs0 = maps:without([?'Recovery'], RequestIEs),
    ProxyIEs = update_gtp_req_from_context(Context, ProxyIEs0),
    Request#gtp{tei = TEI, ie = ProxyIEs}.

send_request(#context{control_port = GtpPort,
		      remote_control_tei = RemoteCntlTEI,
		      remote_control_ip = RemoteCntlIP},
	     T3, N3, Type, RequestIEs) ->
    Msg = #gtp{version = v1, type = Type, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(GtpPort, RemoteCntlIP, T3, N3, Msg, undefined).

initiate_delete_pdp_context_request(#context{state = #context_state{nsapi = NSAPI}} = Context) ->
    RequestIEs0 = [#cause{value = request_accepted},
		   #teardown_ind{value = 1},
		   #nsapi{nsapi = NSAPI}],
    RequestIEs = gtp_v1_c:build_recovery(Context, false, RequestIEs0),
    send_request(Context, ?T3, ?N3, delete_pdp_context_request, RequestIEs).

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
