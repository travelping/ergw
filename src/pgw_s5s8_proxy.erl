%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8_proxy).

-behaviour(gtp_api).

-compile({parse_transform, cut}).
-compile({parse_transform, do}).

-export([validate_options/1, init/2, request_spec/3,
	 handle_request/4, handle_response/4,
	 handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").
-include("gtp_proxy_ds.hrl").

-define(GTP_v1_Interface, ggsn_gn_proxy).
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

%====================================================================
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
-define('Bearer Contexts',				{v2_bearer_context, 0}).
-define('Protocol Configuration Options',		{v2_protocol_configuration_options, 0}).
-define('ME Identity',					{v2_mobile_equipment_identity, 0}).
-define('AMBR',						{v2_aggregate_maximum_bit_rate, 0}).

-define('EPS Bearer ID',                                {v2_eps_bearer_id, 0}).

-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).

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
    [{?'RAT Type',					mandatory},
     {?'Sender F-TEID for Control Plane',		mandatory},
     {?'Access Point Name',				mandatory},
     {?'Bearer Contexts',				mandatory}];
request_spec(v2, create_session_response, _) ->
    [{?'Cause',						mandatory},
     {?'Bearer Contexts',				mandatory}];
request_spec(v2, modify_bearer_request, _) ->
    [];
request_spec(v2, modify_bearer_response, _) ->
    [{?'Cause',						mandatory}];
request_spec(v2, modify_bearer_command, _) ->
    [];
request_spec(v2, delete_session_request, _) ->
    [];
request_spec(v2, delete_session_response, _) ->
    [{?'Cause',						mandatory}];
request_spec(v2, update_bearer_request, _) ->
    [{?'Bearer Contexts',				mandatory},
     {?'AMBR',						mandatory}];
request_spec(v2, update_bearer_response, _) ->
    [{?'Cause',						mandatory},
     {?'Bearer Contexts',				mandatory}];
request_spec(v2, delete_bearer_request, _) ->
    [];
request_spec(v2, delete_bearer_response, _) ->
    [{?'Cause',						mandatory}];
request_spec(v2, suspend_notification, _) ->
    [];
request_spec(v2, suspend_acknowledge, _) ->
    [{?'Cause',						mandatory}];
request_spec(v2, resume_notification, _) ->
    [{?'IMSI',						mandatory}];
request_spec(v2, resume_acknowledge, _) ->
    [{?'Cause',						mandatory}];
request_spec(v2, _, _) ->
    [].

-define(Defaults, [{pgw, undefined}]).

validate_options(Opts) ->
    lager:debug("PGW S5/S8 Options: ~p", [Opts]),
    ergw_proxy_lib:validate_options(fun validate_option/2, Opts, ?Defaults).

validate_option(pgw, {_,_,_,_} = Value) ->
    Value;
validate_option(pgw, {_,_,_,_,_,_,_,_} = Value) ->
    Value;
validate_option(Opt, Value) ->
    ergw_proxy_lib:validate_option(Opt, Value).

-record(context_state, {ebi}).

init(#{proxy_sockets := ProxyPorts, proxy_data_paths := ProxyDPs,
       pgw := PGW, proxy_data_source := ProxyDS,
       contexts := Contexts}, State) ->

    {ok, State#{proxy_ports => ProxyPorts, proxy_dps => ProxyDPs,
		contexts => Contexts, default_gw => PGW, proxy_ds => ProxyDS}}.

handle_call(delete_context, _From, State) ->
    lager:warning("delete_context no handled(yet)"),
    {reply, ok, State};

handle_call(terminate_context, _From,
	    #{context := Context,
	      proxy_context := ProxyContext} = State) ->
    initiate_session_teardown(sgw2pgw, State),
    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, normal, ok, State};

handle_call({path_restart, Path}, _From,
	    #{context := #context{path = Path} = Context,
	      proxy_context := ProxyContext
	     } = State) ->
    initiate_session_teardown(sgw2pgw, State),
    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, normal, ok, State};

handle_call({path_restart, Path}, _From,
	    #{context := Context,
	      proxy_context := #context{path = Path} = ProxyContext
	     } = State) ->
    initiate_session_teardown(pgw2sgw, State),
    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, normal, ok, State};

handle_call({path_restart, _Path}, _From, State) ->
    {reply, ok, State}.

handle_cast({packet_in, _GtpPort, _IP, _Port, _Msg}, State) ->
    lager:warning("packet_in not handled (yet): ~p", [_Msg]),
    {noreply, State}.

handle_info({_, session_report_request,
	     #{report_type := [error_indication_report],
	       error_indication_report := [#{remote_f_teid := FTEID}]}},
	    #{context := Context, proxy_context := ProxyContext} = State) ->
    Direction = fteid_forward_context(FTEID, State),
    initiate_session_teardown(Direction, State),
    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, normal, State};

handle_info({timeout, _, {delete_session_request, Direction, _ReqKey, _Request}},
	    #{context := Context, proxy_context := ProxyContext} = State) ->
    lager:warning("Proxy Delete Session Timeout ~p", [Direction]),

    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, normal, State};

handle_info({timeout, _, {delete_bearer_request, Direction, _ReqKey, _Request}},
	    #{context := Context, proxy_context := ProxyContext} = State) ->
    lager:warning("Proxy Delete Bearer Timeout ~p", [Direction]),

    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, normal, State};

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

handle_request(ReqKey, #gtp{version = v1} = Msg, Resent, State) ->
    ?GTP_v1_Interface:handle_request(ReqKey, Msg, Resent, State);

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
handle_request(ReqKey, #gtp{type = create_session_request} = Request, true,
	       #{proxy_context := ProxyContext} = State) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    {noreply, State};
handle_request(ReqKey, #gtp{type = change_notification_request} = Request, true,
	       #{context := Context, proxy_context := ProxyContext} = State)
  when ?IS_REQUEST_CONTEXT_OPTIONAL_TEI(ReqKey, Request, Context) ->
    ergw_proxy_lib:forward_request(ProxyContext, ReqKey, Request),
    {noreply, State};

handle_request(_ReqKey, _Request, true, State) ->
    lager:error("resend of request not handled ~p, ~p",
		[lager:pr(_ReqKey, ?MODULE), gtp_c_lib:fmt_gtp(_Request)]),
    {noreply, State};

handle_request(ReqKey,
	       #gtp{type = create_session_request} = Request,
	       _Resent,
	       #{context := Context0} = State) ->

    Context1 = update_context_from_gtp_req(Request, Context0#context{state = #context_state{}}),
    ContextPreProxy = gtp_path:bind(Request, Context1),

    gtp_context:terminate_colliding_context(ContextPreProxy),
    gtp_context:remote_context_register_new(ContextPreProxy),

    ProxyInfo = handle_proxy_info(Request, ContextPreProxy, State),
    #proxy_ggsn{restrictions = Restrictions} = ProxyGGSN = gtp_proxy_ds:lb(ProxyInfo),

    Context = ContextPreProxy#context{restrictions = Restrictions},
    gtp_context:enforce_restrictions(Request, Context),

    {ProxyGtpPort, ProxyGtpDP} = get_proxy_sockets(ProxyGGSN, State),

    ProxyContext0 = init_proxy_context(ProxyGtpPort, ProxyGtpDP, Context, ProxyInfo, ProxyGGSN),
    ProxyContext = gtp_path:bind(ProxyContext0),

    StateNew = State#{context => Context, proxy_context => ProxyContext},
    forward_request(sgw2pgw, ReqKey, Request, StateNew, State),

    {noreply, StateNew};

handle_request(ReqKey,
	       #gtp{type = modify_bearer_request} = Request,
	       _Resent,
	       #{context := OldContext,
		 proxy_context := OldProxyContext} = State)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, OldContext) ->

    Context0 = update_context_from_gtp_req(Request, OldContext),
    Context1 = gtp_path:bind(Request, Context0),

    gtp_context:enforce_restrictions(Request, Context1),
    gtp_context:remote_context_update(OldContext, Context1),

    Context = update_path_bind(Context1, OldContext),
    ProxyContext = update_path_bind(OldProxyContext#context{version = v2}, OldProxyContext),

    StateNew = State#{context => Context, proxy_context => ProxyContext},
    forward_request(sgw2pgw, ReqKey, Request, StateNew, State),

    {noreply, StateNew};

handle_request(ReqKey,
	       #gtp{type = modify_bearer_command} = Request,
	       _Resent,
	       #{context := Context} = State0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->

    State1 = bind_forward_path(sgw2pgw, Request, State0),
    forward_request(sgw2pgw, ReqKey, Request, State1, State0),

    State = trigger_request(sgw2pgw, ReqKey, Request, State1),

    gtp_context:request_finished(ReqKey),
    {noreply, State};

%%
%% SGW to PGW requests without tunnel endpoint modification
%%
handle_request(ReqKey,
	       #gtp{type = change_notification_request} = Request,
	       _Resent,
	       #{context := Context} = State)
  when ?IS_REQUEST_CONTEXT_OPTIONAL_TEI(ReqKey, Request, Context) ->

    StateNew = bind_forward_path(sgw2pgw, Request, State),
    forward_request(sgw2pgw, ReqKey, Request, StateNew, State),

    {noreply, StateNew};

%%
%% SGW to PGW notifications without tunnel endpoint modification
%%
handle_request(ReqKey,
	       #gtp{type = Type} = Request,
	       _Resent,
	       #{context := Context} = State)
  when (Type == suspend_notification orelse
	Type == resume_notification) andalso
       ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->

    StateNew = bind_forward_path(sgw2pgw, Request, State),
    forward_request(sgw2pgw, ReqKey, Request, StateNew, State),

    {noreply, StateNew};

%%
%% PGW to SGW requests without tunnel endpoint modification
%%
handle_request(ReqKey,
	       #gtp{type = update_bearer_request} = Request,
	       _Resent,
	       #{proxy_context := ProxyContext} = State0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->

    State = bind_forward_path(pgw2sgw, Request, State0),
    forward_request(pgw2sgw, ReqKey, Request, State, State),
    {noreply, State};

%%
%% SGW to PGW delete session requests
%%
handle_request(ReqKey,
	       #gtp{type = delete_session_request} = Request, _Resent,
	       #{context := Context} = State0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, Context) ->

    forward_request(sgw2pgw, ReqKey, Request, State0, State0),

    Msg = {delete_session_request, sgw2pgw, ReqKey, Request},
    State = restart_timeout(?RESPONSE_TIMEOUT, Msg, State0),

    {noreply, State};

%%
%% PGW to SGW delete bearer requests
%%
handle_request(ReqKey,
	       #gtp{type = delete_bearer_request} = Request, _Resent,
	       #{proxy_context := ProxyContext} = State0)
  when ?IS_REQUEST_CONTEXT(ReqKey, Request, ProxyContext) ->

    forward_request(pgw2sgw, ReqKey, Request, State0, State0),

    Msg = {delete_bearer_request, pgw2sgw, ReqKey, Request},
    State = restart_timeout(?RESPONSE_TIMEOUT, Msg, State0),

    {noreply, State};

handle_request(ReqKey, _Request, _Resent, State) ->
    gtp_context:request_finished(ReqKey),
    {noreply, State}.

handle_response(ReqInfo, #gtp{version = v1} = Msg, Request, State) ->
    ?GTP_v1_Interface:handle_response(ReqInfo, Msg, Request, State);

handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		#gtp{type = create_session_response,
		     ie = #{?'Cause' := #v2_cause{v2_cause = Cause}}} = Response, _Request,
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

handle_response(#proxy_request{direction = sgw2pgw,
			       context = PrevContext,
			       proxy_ctx = PrevProxyCtx} = ProxyRequest,
		#gtp{type = modify_bearer_response} = Response, _Request,
		#{context := Context,
		  proxy_context := OldProxyContext} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    ProxyContext = update_context_from_gtp_req(Response, OldProxyContext),
    gtp_context:remote_context_update(OldProxyContext, ProxyContext),

    forward_response(ProxyRequest, Response, Context),
    ergw_proxy_lib:modify_forward_session(PrevContext, Context, PrevProxyCtx, ProxyContext),

    {noreply, State#{proxy_context => ProxyContext}};

%%
%% PGW to SGW response without tunnel endpoint modification
%%
handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		#gtp{type = change_notification_response} = Response, _Request,
		#{context := Context} = State) ->
    lager:warning("OK Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    forward_response(ProxyRequest, Response, Context),
    {noreply, State};

%%
%% PGW to SGW acknowledge without tunnel endpoint modification
%%
handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		#gtp{type = Type} = Response, _Request,
		#{context := Context} = State)
  when Type == suspend_acknowledge;
       Type == resume_acknowledge ->
    lager:warning("OK Proxy Acknowledge ~p", [lager:pr(Response, ?MODULE)]),

    forward_response(ProxyRequest, Response, Context),
    {noreply, State};

%%
%% SGW to PGW response without tunnel endpoint modification
%%
handle_response(#proxy_request{direction = pgw2sgw} = ProxyRequest,
		#gtp{type = update_bearer_response} = Response, _Request,
		#{proxy_context := ProxyContext} = State) ->
    lager:warning("OK Response ~p", [lager:pr(Response, ?MODULE)]),

    forward_response(ProxyRequest, Response, ProxyContext),
    {noreply, State};

handle_response(#proxy_request{direction = sgw2pgw} = ProxyRequest,
		Response0, #gtp{type = delete_session_request},
		#{context := Context,
		  proxy_context := ProxyContext} = State) ->
    lager:warning("Proxy Response ~p", [lager:pr(Response0, ?MODULE)]),

    Response =
	if is_record(Response0, gtp) ->
		Response0;
	   true ->
		#gtp{version = v2,
		     type = delete_session_response,
		     ie = #{?'Cause' => #v2_cause{v2_cause = request_accepted}}}
	end,
    forward_response(ProxyRequest, Response, Context),
    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, State};

%%
%% SGW to PGW delete bearer response
%%
handle_response(#proxy_request{direction = pgw2sgw} = ProxyRequest,
		Response0, #gtp{type = delete_bearer_request},
		#{context := Context,
		  proxy_context := ProxyContext} = State) ->
    lager:warning("Proxy Response ~p", [lager:pr(Response0, ?MODULE)]),

    Response =
	if is_record(Response0, gtp) ->
		Response0;
	   true ->
		#context{state = #context_state{ebi = EBI}} = ProxyContext,
		#gtp{version = v2,
		     type = delete_bearer_response,
		     ie = #{?'Cause' => #v2_cause{v2_cause = request_accepted},
			    ?'EPS Bearer ID' =>
				#v2_eps_bearer_id{eps_bearer_id = EBI}}}
	end,
    forward_response(ProxyRequest, Response, ProxyContext),
    ergw_proxy_lib:delete_forward_session(Context, ProxyContext),
    {stop, State};

handle_response(#proxy_request{request = ReqKey} = _ReqInfo,
		Response, _Request, State) ->
    lager:warning("Unknown Proxy Response ~p", [lager:pr(Response, ?MODULE)]),

    gtp_context:request_finished(ReqKey),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%%===================================================================
%%% Helper functions
%%%===================================================================

handle_proxy_info(#gtp{ie = #{?'Recovery' := Recovery}},
		  Context,
		  #{default_gw := DefaultPGW, proxy_ds := ProxyDS}) ->
    ProxyInfo0 = proxy_info(DefaultPGW, Context),
    case ProxyDS:map(ProxyInfo0) of
	{ok, #proxy_info{} = ProxyInfo} ->
	    lager:debug("OK Proxy Map: ~p", [lager:pr(ProxyInfo, ?MODULE)]),
	    ProxyInfo;

	Other ->
	    lager:warning("Failed Proxy Map: ~p", [Other]),

	    ResponseIEs0 = [#v2_cause{v2_cause = user_authentication_failed}],
	    ResponseIEs = gtp_v2_c:build_recovery(Context, Recovery /= undefined, ResponseIEs0),
	    throw(#ctx_err{level = ?FATAL,
			   reply = {create_session_response,
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

init_proxy_context(CntlPort, DataPort,
		   #context{imei = IMEI, context_id = ContextId, version = Version,
			    control_interface = Interface, state = State},
		   #proxy_info{imsi = IMSI, msisdn = MSISDN},
		   #proxy_ggsn{address = PGW, dst_apn = APN}) ->

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
       remote_control_ip = PGW,
       state             = State
      }.

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

update_context_from_gtp_req(#gtp{ie = IEs} = Req, Context0) ->
    Context1 = gtp_v2_c:update_context_id(Req, Context0),
    maps:fold(fun get_context_from_req/3, Context1, IEs).

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

set_req_from_context(#context{apn = APN},
		     _K, #v2_access_point_name{instance = 0} = IE)
  when is_list(APN) ->
    IE#v2_access_point_name{apn = APN};
set_req_from_context(#context{imsi = IMSI},
		  _K, #v2_international_mobile_subscriber_identity{instance = 0} = IE)
  when is_binary(IMSI) ->
    IE#v2_international_mobile_subscriber_identity{imsi = IMSI};
set_req_from_context(#context{msisdn = MSISDN},
		     _K, #v2_msisdn{instance = 0} = IE)
  when is_binary(MSISDN) ->
    IE#v2_msisdn{msisdn = MSISDN};
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

proxy_info(DefaultGGSN,
	   #context{apn = APN, imsi = IMSI,
		    msisdn = MSISDN, restrictions = Restrictions}) ->
    GGSNs = [#proxy_ggsn{address = DefaultGGSN, 
                         dst_apn = APN,
		                 restrictions = Restrictions}],
    LookupAPN = (catch gtp_c_lib:normalize_labels(APN)),
    #proxy_info{ggsns = GGSNs, imsi = IMSI, msisdn = MSISDN, src_apn = LookupAPN}.

build_context_request(#context{remote_control_tei = TEI} = Context,
		      NewPeer, SeqNo, #gtp{ie = RequestIEs} = Request) ->
    ProxyIEs0 = maps:without([?'Recovery'], RequestIEs),
    ProxyIEs1 = update_gtp_req_from_context(Context, ProxyIEs0),
    ProxyIEs = gtp_v2_c:build_recovery(Context, NewPeer, ProxyIEs1),
    Request#gtp{tei = TEI, seq_no = SeqNo, ie = ProxyIEs}.

send_request(#context{control_port = GtpPort,
		      remote_control_tei = RemoteCntlTEI,
		      remote_control_ip = RemoteCntlIP},
	     T3, N3, Type, RequestIEs) ->
    Msg = #gtp{version = v2, type = Type, tei = RemoteCntlTEI, ie = RequestIEs},
    gtp_context:send_request(GtpPort, RemoteCntlIP, ?GTP2c_PORT, T3, N3, Msg, undefined).

initiate_session_teardown(sgw2pgw,
			  #{proxy_context :=
				#context{state = #context_state{ebi = EBI}} = Ctx}) ->
    RequestIEs0 = [#v2_cause{v2_cause = network_failure},
		   #v2_eps_bearer_id{eps_bearer_id = EBI}],
    RequestIEs = gtp_v2_c:build_recovery(Ctx, false, RequestIEs0),
    send_request(Ctx, ?T3, ?N3, delete_session_request, RequestIEs);
initiate_session_teardown(pgw2sgw,
			  #{context :=
				#context{state = #context_state{ebi = EBI}} = Ctx}) ->
    RequestIEs0 = [#v2_cause{v2_cause = reactivation_requested},
		   #v2_eps_bearer_id{eps_bearer_id = EBI}],
    RequestIEs = gtp_v2_c:build_recovery(Ctx, false, RequestIEs0),
    send_request(Ctx, ?T3, ?N3, delete_bearer_request, RequestIEs).

bind_forward_path(sgw2pgw, Request, #{context := Context,
				      proxy_context := ProxyContext} = State) ->
    State#{
      context => gtp_path:bind(Request, Context),
      proxy_context => gtp_path:bind(ProxyContext)
     };
bind_forward_path(pgw2sgw, Request, #{context := Context,
				      proxy_context := ProxyContext} = State) ->
    State#{
      context => gtp_path:bind(Context),
      proxy_context => gtp_path:bind(Request, ProxyContext)
     }.

fteid_forward_context(#f_teid{ipv4 = IPv4, teid = TEID},
			     #{proxy_context := #context{remote_data_ip = IPv4,
							 remote_data_tei = TEID}}) ->
    pgw2sgw;
fteid_forward_context(#f_teid{ipv4 = IPv4, teid = TEID},
			     #{context := #context{remote_data_ip = IPv4,
						   remote_data_tei = TEID}}) ->
    sgw2pgw.

forward_context(sgw2pgw, #{proxy_context := Context}) ->
    Context;
forward_context(pgw2sgw, #{context := Context}) ->
    Context.

forward_request(Direction, ReqKey,
		#gtp{seq_no = ReqSeqNo,
		     ie = #{?'Recovery' := Recovery}} = Request,
		#{last_trigger_id :=
		      {ReqSeqNo, LastFwdSeqNo, GtpPort, SrcIP, SrcPort}} = State,
	       StateOld) ->

    Context = forward_context(Direction, State),
    FwdReq = build_context_request(Context, false, LastFwdSeqNo, Request),
    ergw_proxy_lib:forward_request(Direction, GtpPort, SrcIP, SrcPort, FwdReq, ReqKey,
				   ReqSeqNo, Recovery /= undefined, StateOld);
forward_request(Direction, ReqKey,
		#gtp{seq_no = ReqSeqNo,
		     ie = #{?'Recovery' := Recovery}} = Request,
		State, StateOld) ->
    Context = forward_context(Direction, State),
    FwdReq = build_context_request(Context, false, undefined, Request),
    ergw_proxy_lib:forward_request(Direction, Context, FwdReq, ReqKey,
				   ReqSeqNo, Recovery /= undefined, StateOld).

trigger_request(Direction, #request{gtp_port = GtpPort, ip = SrcIP, port = SrcPort} = ReqKey,
		#gtp{seq_no = SeqNo} = Request, State) ->
    Context = forward_context(Direction, State),
    case ergw_proxy_lib:get_seq_no(Context, ReqKey, Request) of
	{ok, FwdSeqNo} ->
	    State#{last_trigger_id => {FwdSeqNo, SeqNo, GtpPort, SrcIP, SrcPort}};
	_ ->
	    State
    end.

forward_response(#proxy_request{request = ReqKey, seq_no = SeqNo, new_peer = NewPeer},
		 Response, Context) ->
    GtpResp = build_context_request(Context, NewPeer, SeqNo, Response),
    gtp_context:send_response(ReqKey, GtpResp).

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
