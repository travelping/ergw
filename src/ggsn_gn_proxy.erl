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
-define(RESPONSE_TIMEOUT, (?T3 + (?T3 div 2))).

-define(IS_REQUEST_CONTEXT(Key, Msg, Context),
	(is_record(Key, request) andalso
	 is_record(Msg, gtp) andalso
	 Key#request.gtp_port =:= Context#context.control_port andalso
	 Msg#gtp.tei =:= Context#context.local_control_tei)).

-define(IS_REQUEST_CONTEXT_OPTIONAL_TEI(Key, Msg, Context),
	(is_record(Key, request) andalso
	 is_record(Msg, gtp) andalso
	 Key#request.gtp_port =:= Context#context.control_port andalso
	 (Msg#gtp.tei =:= 0 orelse
	  Msg#gtp.tei =:= Context#context.local_control_tei))).

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

-define(Defaults, [{ggsn, undefined}]).

validate_options(Opts) ->
    lager:debug("GGSN Gn/Gp Options: ~p", [Opts]),
    ergw_proxy_lib:validate_options(fun validate_option/2, Opts, ?Defaults).

validate_option(ggsn, {_,_,_,_} = Value) ->
    Value;
validate_option(ggsn, {_,_,_,_,_,_,_,_} = Value) ->
    Value;
validate_option(Opt, Value) ->
    ergw_proxy_lib:validate_option(Opt, Value).

-record(context_state, {nsapi}).

init(#{proxy_sockets := ProxyPorts, proxy_data_paths := ProxyDPs,
       ggsn := GGSN, proxy_data_source := ProxyDS,
       contexts := Contexts}, State) ->

    {ok, State#{proxy_ports => ProxyPorts, proxy_dps => ProxyDPs,
		contexts => Contexts, default_gw => GGSN, proxy_ds => ProxyDS}}.

handle_call(delete_context, _From, State) ->
    lager:warning("delete_context no handled(yet)"),
    {reply, ok, State};

handle_call(terminate_context, _From,
	    #{context := Context,
	      proxy_context := ProxyContext} = State) ->
    initiate_delete_pdp_context_request(ProxyContext),
    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, normal, ok, State};

handle_call({path_restart, Path}, _From,
	    #{context := #context{path = Path} = Context,
	      proxy_context := ProxyContext
	     } = State) ->
    initiate_delete_pdp_context_request(ProxyContext),
    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, normal, ok, State};

handle_call({path_restart, Path}, _From,
	    #{context := Context,
	      proxy_context := #context{path = Path} = ProxyContext
	     } = State) ->
    initiate_delete_pdp_context_request(Context),
    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, normal, ok, State};

handle_call({path_restart, _Path}, _From, State) ->
    {reply, ok, State}.

handle_cast({packet_in, _GtpPort, _IP, _Port, #gtp{type = error_indication}},
	    #{context := Context, proxy_context := ProxyContext} = State) ->
    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, normal, State};

handle_cast({packet_in, _GtpPort, _IP, _Port, _Msg}, State) ->
    lager:warning("packet_in not handled (yet): ~p", [_Msg]),
    {noreply, State}.


handle_info({timeout, _, {delete_pdp_context_request, Direction, _ReqKey, _Request}},
	    #{context := Context, proxy_context := ProxyContext} = State) ->
    lager:warning("Proxy Delete PDP Context Timeout ~p", [Direction]),

    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.

%%
%% resend request
%%
handle_request(ReqKey, Request, true,
	       #{context := Context, proxy_context := ProxyContext} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    {noreply, State};
handle_request(ReqKey, Request, true,
	       #{context := Context, proxy_context := ProxyContext} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->
    ergw_proxy_lib:forward_request(Context, ReqKey, Request),
    {noreply, State};

%%
%% some request type need special treatment for resends
%%
handle_request(ReqKey, #gtp{type = create_pdp_context_request} = Request, true,
	       #{proxy_context := ProxyContext} = State) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    {noreply, State};
handle_request(ReqKey, #gtp{type = ms_info_change_notification_request} = Request, true,
	       #{context := Context, proxy_context := ProxyContext} = State)
  when ?IS_REQUEST_CONTEXT_OPTIONAL_TEI(ReqKey, Request, Context) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    {noreply, State};

handle_request(_ReqKey, _Request, true, State) ->
    lager:error("resend of request not handled ~p, ~p",
		[lager:pr(_ReqKey, ?MODULE), gtp_c_lib:fmt_gtp(_Request)]),
    {noreply, State};

handle_request(ReqKey,
	       #gtp{type = create_pdp_context_request,
		    ie = IEs} = Request, _Resent,
	       #{context := Context0} = State) ->

    Context1 = update_context_from_gtp_req(Request, Context0#context{state = #context_state{}}),
    ContextPreProxy = gtp_path:bind(Request, Context1),

    gtp_context:terminate_colliding_context(ContextPreProxy),
    gtp_context:remote_context_register_new(ContextPreProxy),

    Session1 = init_session(IEs, ContextPreProxy),
    lager:debug("Invoking CONTROL: ~p", [Session1]),
    %% ergw_control:authenticate(Session1),

	ProxyInfo = handle_proxy_info(Request, ContextPreProxy, State),
    #proxy_ggsn{restrictions = Restrictions} = ProxyGGSN = gtp_proxy_ds:lb(ProxyInfo),

    Context = ContextPreProxy#context{restrictions = Restrictions},
    gtp_context:enforce_restrictions(Request, Context),

    {ProxyGtpPort, ProxyGtpDP} = get_proxy_sockets(ProxyGGSN, State),

    ProxyContext0 = init_proxy_context(ProxyGtpPort, ProxyGtpDP, Context, ProxyInfo, ProxyGGSN),
    ProxyContext = gtp_path:bind(ProxyContext0),

    StateNew = State#{context => Context, proxy_context => ProxyContext},
    forward_request(sgsn2ggsn, ReqKey, Request, StateNew),

    {noreply, StateNew};

handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request} = Request, _Resent,
	       #{context := OldContext,
		 proxy_context := OldProxyContext} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, OldContext) ->

    Context0 = update_context_from_gtp_req(Request, OldContext),
    Context1 = gtp_path:bind(Request, Context0),

    gtp_context:enforce_restrictions(Request, Context1),
    gtp_context:remote_context_update(OldContext, Context1),

    Context = update_path_bind(Context1, OldContext),
    ProxyContext = update_path_bind(OldProxyContext#context{version = v1}, OldProxyContext),

    StateNew = State#{context => Context, proxy_context => ProxyContext},
    forward_request(sgsn2ggsn, ReqKey, Request, StateNew),

    {noreply, StateNew};

%%
%% GGSN to SGW Update PDP Context Request
%%
handle_request(ReqKey,
	       #gtp{type = update_pdp_context_request} = Request, _Resent,
	       #{context := Context0,
		 proxy_context := ProxyContext0} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext0) ->

    Context = gtp_path:bind(Context0),
    ProxyContext = gtp_path:bind(Request, ProxyContext0),

    StateNew = State#{context => Context, proxy_context => ProxyContext},
    forward_request(ggsn2sgsn, ReqKey, Request, StateNew),

    {noreply, StateNew};

handle_request(ReqKey,
	       #gtp{type = ms_info_change_notification_request} = Request,
	       _Resent,
	       #{context := Context0,
		 proxy_context := ProxyContext0} = State)
  when ?IS_REQUEST_CONTEXT_OPTIONAL_TEI(ReqKey, Request, Context0) ->
    Context = gtp_path:bind(Request, Context0),
    ProxyContext = gtp_path:bind(ProxyContext0),

    StateNew = State#{context => Context, proxy_context => ProxyContext},
    forward_request(sgsn2ggsn, ReqKey, Request, StateNew),

    {noreply, StateNew};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request} = Request, _Resent,
	       #{context := Context} = State0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->

    forward_request(sgsn2ggsn, ReqKey, Request, State0),

    Msg = {delete_pdp_context_request, sgsn2ggsn, ReqKey, Request},
    State = restart_timeout(?RESPONSE_TIMEOUT, Msg, State0),

    {noreply, State};

handle_request(ReqKey,
	       #gtp{type = delete_pdp_context_request} = Request, _Resent,
	       #{proxy_context := ProxyContext} = State0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->

    forward_request(ggsn2sgsn, ReqKey, Request, State0),

    Msg = {delete_pdp_context_request, ggsn2sgsn, ReqKey, Request},
    State = restart_timeout(?RESPONSE_TIMEOUT, Msg, State0),

    {noreply, State};

handle_request(#request{gtp_port = GtpPort} = ReqKey, Msg, _Resent, State) ->
    lager:warning("Unknown Proxy Message on ~p: ~p", [GtpPort, lager:pr(Msg, ?MODULE)]),
    gtp_context:request_finished(ReqKey),
    {noreply, State}.

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = create_pdp_context_response,
		     ie = #{?'Cause' := #cause{value = Cause}}} = Response, _Request,
		#{context := Context,
		  proxy_context := ProxyContext0} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext1 = update_context_from_gtp_req(Response, ProxyContext0),
    ProxyContext = gtp_path:bind(Response, ProxyContext1),
    gtp_context:remote_context_register(ProxyContext),

    forward_response(ProxyRequest, Response, Context),

    if ?CAUSE_OK(Cause) ->
	    ContextNew = ergw_proxy_lib:create_forward_session(Context, ProxyContext),
	    lager:info("Create PDP Context ~p", [ContextNew]),

	    {noreply, State#{context := ContextNew, proxy_context => ProxyContext}};

       true ->
	    {stop, State}
    end;

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = update_pdp_context_response} = Response, _Request,
		#{context := Context,
		  proxy_context := OldProxyContext} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext = update_context_from_gtp_req(Response, OldProxyContext),
    gtp_context:remote_context_update(OldProxyContext, ProxyContext),

    forward_response(ProxyRequest, Response, Context),
    ergw_proxy_lib:modify_forward_session(Context, Context, OldProxyContext, ProxyContext),

    {noreply, State#{proxy_context => ProxyContext}};

handle_response(#proxy_request{direction = ggsn2sgsn} = ProxyRequest,
		#gtp{type = update_pdp_context_response} = Response, _Request,
		#{proxy_context := ProxyContext} = State) ->
    lager:warning("OK SGSN Response ~p", [lager:pr(Response, ?MODULE)]),

    forward_response(ProxyRequest, Response, ProxyContext),
    {noreply, State};

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = ms_info_change_notification_response} = Response, _Request,
		#{context := Context} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    forward_response(ProxyRequest, Response, Context),
    {noreply, State};

handle_response(#proxy_request{direction = sgsn2ggsn} = ProxyRequest,
		#gtp{type = delete_pdp_context_response} = Response, _Request,
		#{context := Context,
		  proxy_context := ProxyContext} = State0) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    forward_response(ProxyRequest, Response, Context),
    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    State = cancel_timeout(State0),
    {stop, State};


handle_response(#proxy_request{direction = ggsn2sgsn} = ProxyRequest,
		#gtp{type = delete_pdp_context_response} = Response, _Request,
		#{context := Context,
		  proxy_context := ProxyContext} = State0) ->
    lager:warning("OK SGSN Response ~p", [lager:pr(Response, ?MODULE)]),

    forward_response(ProxyRequest, Response, ProxyContext),
    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    State = cancel_timeout(State0),
    {stop, State};


handle_response(_ReqInfo, Response, _Req, State) ->
    lager:warning("Unknown Proxy Response ~p", [lager:pr(Response, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_proxy_info(#gtp{ie = #{?'Recovery' := Recovery}},
		  Context,
		  #{default_gw := DefaultGGSN, proxy_ds := ProxyDS}) ->
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

update_path_bind(NewContext0, OldContext)
  when NewContext0 /= OldContext ->
    NewContext = gtp_path:bind(NewContext0),
    gtp_path:unbind(OldContext),
    NewContext;
update_path_bind(NewContext, _OldContext) ->
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

init_proxy_context(CntlPort, DataPort,
		   #context{imei = IMEI, context_id = ContextId, version = Version,
			    control_interface = Interface, state = State},
		   #proxy_info{imsi = IMSI, msisdn = MSISDN},
           #proxy_ggsn{address = GGSN, dst_apn = APN}) ->

    {ok, CntlTEI} = gtp_context_reg:alloc_tei(CntlPort),
    {ok, DataTEI} = gtp_context_reg:alloc_tei(DataPort),
    #context{
       apn               = APN,
       imsi              = IMSI,
       imei              = IMEI,
       msisdn            = MSISDN,
       context_id        = ContextId,

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

update_context_from_gtp_req(#gtp{ie = IEs} = Req, Context0) ->
    Context1 = gtp_v1_c:update_context_id(Req, Context0),
    maps:fold(fun get_context_from_req/3, Context1, IEs).

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
    GGSNs = [#proxy_ggsn{address = DefaultGGSN,
                         dst_apn = APN,
		                 restrictions = Restrictions}],
    LookupAPN = (catch gtp_c_lib:normalize_labels(APN)),
    #proxy_info{ggsns = GGSNs, imsi = IMSI, msisdn = MSISDN, src_apn = LookupAPN}.

build_context_request(#context{remote_control_tei = TEI} = Context,
		      NewPeer, #gtp{ie = RequestIEs} = Request) ->
    ProxyIEs0 = maps:without([?'Recovery'], RequestIEs),
    ProxyIEs1 = update_gtp_req_from_context(Context, ProxyIEs0),
    ProxyIEs = gtp_v1_c:build_recovery(Context, NewPeer, ProxyIEs1),
    Request#gtp{tei = TEI, seq_no = undefined, ie = ProxyIEs}.

send_request(#context{control_port = GtpPort,
		      remote_control_tei = RemoteCntlTEI,
		      remote_control_ip = RemoteCntlIP},
	     T3, N3, Type, RequestIEs) ->
    Msg = #gtp{version = v1, type = Type, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(GtpPort, RemoteCntlIP, ?GTP1c_PORT, T3, N3, Msg, undefined).

initiate_delete_pdp_context_request(#context{state = #context_state{nsapi = NSAPI}} = Context) ->
    RequestIEs0 = [#cause{value = request_accepted},
		   #teardown_ind{value = 1},
		   #nsapi{nsapi = NSAPI}],
    RequestIEs = gtp_v1_c:build_recovery(Context, false, RequestIEs0),
    send_request(Context, ?T3, ?N3, delete_pdp_context_request, RequestIEs).

forward_context(sgsn2ggsn, #{proxy_context := Context}) ->
    Context;
forward_context(ggsn2sgsn, #{context := Context}) ->
    Context.

forward_request(Direction, ReqKey,
		#gtp{seq_no = SeqNo,
		     ie = #{?'Recovery' := Recovery}} = Request,
		State) ->
    Context = forward_context(Direction, State),
    FwdReq = build_context_request(Context, false, Request),

    ergw_proxy_lib:forward_request(Direction, Context, FwdReq, ReqKey,
				   SeqNo, Recovery /= undefined).

forward_response(#proxy_request{request = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
		 Response, Context) ->
    GtpResp = build_context_request(Context, NewPeer, Response),
    gtp_context:send_response(ReqKey, GtpResp#gtp{seq_no = SeqNo}).

get_proxy_sockets(#proxy_ggsn{context = Context},
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

cancel_timeout(#{timeout := TRef} = State) ->
    case erlang:cancel_timer(TRef) of
        false ->
            receive {timeout, TRef, _} -> ok
            after 0 -> ok
            end;
        _ ->
            ok
    end,
    maps:remove(timeout, State);
cancel_timeout(State) ->
    State.

restart_timeout(Timeout, Msg, State) ->
    cancel_timeout(State),
    State#{timeout => erlang:start_timer(Timeout, self(), Msg)}.
