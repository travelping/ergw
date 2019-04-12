%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context).

-behavior(gen_server).
-behavior(ergw_context).

-compile({parse_transform, cut}).
-compile({parse_transform, do}).

-export([handle_response/4,
	 start_link/5,
	 send_request/7, send_response/2,
	 send_request/6, resend_request/2,
	 request_finished/1,
	 path_restart/2,
	 terminate_colliding_context/1, terminate_context/1, delete_context/1,
	 remote_context_register/1, remote_context_register_new/1, remote_context_update/2,
	 enforce_restrictions/2,
	 info/1,
	 validate_options/3,
	 validate_option/2,
	 generic_error/3,
	 port_key/2, port_teid_key/2]).
-export([usage_report_to_accounting/1,
	 collect_charging_events/3,
	 trigger_charging_events/2,
	 triggered_offline_usage_report/4]).

%% ergw_context callbacks
-export([sx_report/2, port_message/2, port_message/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define('Tunnel Endpoint Identifier Data I',	{tunnel_endpoint_identifier_data_i, 0}).

%%====================================================================
%% API
%%====================================================================

handle_response(Context, ReqInfo, Request, Response) ->
    gen_server:cast(Context, {handle_response, ReqInfo, Request, Response}).

%% send_request/7
send_request(GtpPort, DstIP, DstPort, T3, N3, Msg, ReqInfo) ->
    CbInfo = {?MODULE, handle_response, [self(), ReqInfo, Msg]},
    ergw_gtp_c_socket:send_request(GtpPort, DstIP, DstPort, T3, N3, Msg, CbInfo).

%% send_request/6
send_request(GtpPort, DstIP, DstPort, ReqId, Msg, ReqInfo) ->
    CbInfo = {?MODULE, handle_response, [self(), ReqInfo, Msg]},
    ergw_gtp_c_socket:send_request(GtpPort, DstIP, DstPort, ReqId, Msg, CbInfo).

resend_request(GtpPort, ReqId) ->
    ergw_gtp_c_socket:resend_request(GtpPort, ReqId).

start_link(GtpPort, Version, Interface, IfOpts, Opts) ->
    gen_server:start_link(?MODULE, [GtpPort, Version, Interface, IfOpts], Opts).

path_restart(Context, Path) ->
    jobs:run(path_restart, fun() -> gen_server:call(Context, {path_restart, Path}) end).

remote_context_register(Context)
  when is_record(Context, context) ->
    Keys = context2keys(Context),
    gtp_context_reg:register(Keys, ?MODULE, self()).

remote_context_register_new(Context)
  when is_record(Context, context) ->
    Keys = context2keys(Context),
    case gtp_context_reg:register_new(Keys, ?MODULE, self()) of
	ok ->
	    ok;
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, Context))
    end.

remote_context_update(OldContext, NewContext)
  when is_record(OldContext, context),
       is_record(NewContext, context) ->
    OldKeys = context2keys(OldContext),
    NewKeys = context2keys(NewContext),
    Delete = ordsets:subtract(OldKeys, NewKeys),
    Insert = ordsets:subtract(NewKeys, OldKeys),
    gtp_context_reg:update(Delete, Insert, ?MODULE, self()).

delete_context(Context) ->
    gen_server:call(Context, delete_context).

triggered_offline_usage_report(Pid, ChargeEv, OldS, Response) ->
    gen_server:cast(Pid, {triggered_offline_usage_report, ChargeEv, OldS, Response}).

trigger_charging_events(URRActions, PCtx)
  when is_record(PCtx, pfcp_ctx) ->
    lists:map(fun({offline, Cb}) ->
		      ergw_gsn_lib:trigger_offline_usage_report(PCtx, Cb);
		 (_) ->
		      ok
	      end, URRActions).

%% TODO: add online charing events
collect_charging_events(OldS, NewS, _Context) ->
    EvChecks =
	[
	 {'CGI',                     'cgi-sai-change'},
	 {'SAI',                     'cgi-sai-change'},
	 {'ECGI',                    'ecgi-change'},
	 %%{qos, 'max-cond-change'},
	 {'3GPP-MS-TimeZone',        'ms-time-zone-change'},
	 {'QoS-Information',         'qos-change'},
	 {'RAI',                     'rai-change'},
	 {'3GPP-RAT-Type',           'rat-change'},
	 {'3GPP-SGSN-Address',       'sgsn-sgw-change'},
	 {'3GPP-SGSN-IPv6-Address',  'sgsn-sgw-change'},
	 {'3GPP-SGSN-MCC-MNC',       'sgsn-sgw-plmn-id-change'},
	 {'TAI',                     'tai-change'},
	 %%{ qos, 'tariff-switch-change'},
	 {'3GPP-User-Location-Info', 'user-location-info-change'}
	],

    Events =
	lists:foldl(
	  fun({Field, Ev}, Evs) ->
		  Old = maps:get(Field, OldS, undefined),
		  New = maps:get(Field, NewS, undefined),
		  if Old /= New ->
			  [Ev | Evs];
		     true ->
			  Evs
		  end
	  end, [], EvChecks),
    case ergw_charging:is_charging_event(offline, Events) of
	false ->
	    [];
	ChargeEv ->
	    [{offline, {?MODULE, triggered_offline_usage_report, [self(), ChargeEv, OldS]}}]
    end.

%% 3GPP TS 29.060 (GTPv1-C) and TS 29.274 (GTPv2-C) have language that states
%% that when an incomming Create PDP Context/Create Session requests collides
%% with an existing context based on a IMSI, Bearer, Protocol tuple, that the
%% preexisting context should be deleted locally. This function does that.
terminate_colliding_context(#context{control_port = GtpPort, context_id = Id})
  when Id /= undefined ->
    case gtp_context_reg:lookup(port_key(GtpPort, Id)) of
	{?MODULE, Server} when is_pid(Server) ->
	    gtp_context:terminate_context(Server);
	_ ->
	    ok
    end;
terminate_colliding_context(_) ->
    ok.

terminate_context(Context)
  when is_pid(Context) ->
    try
	gen_server:call(Context, terminate_context)
    catch
	exit:_ ->
	    ok
    end,
    gtp_context_reg:await_unreg(Context).

info(Context) ->
    gen_server:call(Context, info).

enforce_restrictions(Msg, #context{restrictions = Restrictions} = Context) ->
    lists:foreach(fun(R) -> enforce_restriction(Context, Msg, R) end, Restrictions).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

-define(ContextDefaults, [{node_selection, undefined},
			  {aaa,            []}]).

-define(DefaultAAAOpts,
	#{
	  'AAA-Application-Id' => ergw_aaa_provider,
	  'Username' => #{default => <<"ergw">>,
			  from_protocol_opts => true},
	  'Password' => #{default => <<"ergw">>}
	 }).

validate_options(Fun, Opts, Defaults) ->
    ergw_config:validate_options(Fun, Opts, Defaults ++ ?ContextDefaults, map).

validate_option(protocol, Value)
  when Value == 'gn' orelse
       Value == 's5s8' orelse
       Value == 's11' ->
    Value;
validate_option(handler, Value) when is_atom(Value) ->
    Value;
validate_option(sockets, Value) when is_list(Value) ->
    Value;
validate_option(node_selection, [S|_] = Value)
  when is_atom(S) ->
    Value;
validate_option(aaa, Value) when is_list(Value); is_map(Value) ->
    ergw_config:opts_fold(fun validate_aaa_option/3, ?DefaultAAAOpts, Value);
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_aaa_option(Key, AppId, AAA)
  when Key == appid; Key == 'AAA-Application-Id' ->
    AAA#{'AAA-Application-Id' => AppId};
validate_aaa_option(Key, Value, AAA)
  when (is_list(Value) orelse is_map(Value)) andalso
       (Key == 'Username' orelse Key == 'Password') ->
    %% Attr = maps:get(Key, AAA),
    %% maps:put(Key, ergw_config:opts_fold(validate_aaa_attr_option(Key, _, _, _), Attr, Value), AAA);

    %% maps:update_with(Key, fun(Attr) ->
    %% 				  ergw_config:opts_fold(validate_aaa_attr_option(Key, _, _, _), Attr, Value)
    %% 			  end, AAA);
    maps:update_with(Key, ergw_config:opts_fold(validate_aaa_attr_option(Key, _, _, _), _, Value), AAA);

validate_aaa_option(Key, Value, AAA)
  when Key == '3GPP-GGSN-MCC-MNC' ->
    AAA#{'3GPP-GGSN-MCC-MNC' => Value};
validate_aaa_option(Key, Value, _AAA) ->
    throw({error, {options, {aaa, {Key, Value}}}}).

validate_aaa_attr_option('Username', default, Default, Attr) ->
    Attr#{default => Default};
validate_aaa_attr_option('Username', from_protocol_opts, Bool, Attr)
  when Bool == true; Bool == false ->
    Attr#{from_protocol_opts => Bool};
validate_aaa_attr_option('Password', default, Default, Attr) ->
    Attr#{default => Default};
validate_aaa_attr_option(Key, Setting, Value, _Attr) ->
    throw({error, {options, {aaa_attr, {Key, Setting, Value}}}}).

%%====================================================================
%% ergw_context API
%%====================================================================

sx_report(Server, Report) ->
    gen_server:call(Server, {sx, Report}).

%% TEID handling for GTPv1 is brain dead....
port_message(Request, #gtp{version = v2, type = MsgType, tei = 0} = Msg)
  when MsgType == change_notification_request;
       MsgType == change_notification_response ->
    Keys = gtp_v2_c:get_msg_keys(Msg),
    ergw_context:port_message(Keys, Request, Msg);

%% same as above for GTPv2
port_message(Request, #gtp{version = v1, type = MsgType, tei = 0} = Msg)
  when MsgType == ms_info_change_notification_request;
       MsgType == ms_info_change_notification_response ->
    Keys = gtp_v1_c:get_msg_keys(Msg),
    ergw_context:port_message(Keys, Request, Msg);

port_message(#request{gtp_port = GtpPort} = Request,
		 #gtp{version = Version, tei = 0} = Msg) ->
    case get_handler_if(GtpPort, Msg) of
	{ok, Interface, InterfaceOpts} ->
	    case ergw:get_accept_new() of
		true -> ok;
		_ ->
		    throw({error, no_resources_available})
	    end,
	    validate_teid(Msg),
	    Server = context_new(GtpPort, Version, Interface, InterfaceOpts),
	    port_message(Server, Request, Msg, false);

	{error, _} = Error ->
	    throw(Error)
    end;
port_message(_Request, _Msg) ->
    throw({error, not_found}).

port_message(Server, Request, #gtp{type = g_pdu} = Msg, _Resent) ->
    gen_server:cast(Server, {handle_pdu, Request, Msg});
port_message(Server, Request, Msg, Resent) ->
    if not Resent -> register_request(?MODULE, Server, Request);
       true       -> ok
    end,
    gen_server:cast(Server, {handle_message, Request, Msg, Resent}).

%%====================================================================
%% gen_server API
%%====================================================================

init([CntlPort, Version, Interface,
      #{node_selection := NodeSelect,
	aaa := AAAOpts} = Opts]) ->

    lager:debug("init(~p)", [[lager:pr(CntlPort, ?MODULE), Interface]]),
    process_flag(trap_exit, true),

    {ok, CntlTEI} = gtp_context_reg:alloc_tei(CntlPort),

    Context = #context{
		 charging_identifier = ergw_gtp_c_socket:get_uniq_id(CntlPort),

		 version           = Version,
		 control_interface = Interface,
		 control_port      = CntlPort,
		 local_control_tei = CntlTEI
		},

    State = #{
      context        => Context,
      version        => Version,
      interface      => Interface,
      node_selection => NodeSelect,
      aaa_opts       => AAAOpts},

    Interface:init(Opts, State).

handle_call(info, _From, State) ->
    {reply, State, State};

handle_call({sx, Report}, From,
	    #{interface := Interface, pfcp := PCtx} = State0) ->
    lager:debug("~w: handle_call Sx: ~p", [?MODULE, lager:pr(Report, ?MODULE)]),
    case Interface:handle_sx_report(Report, From, State0) of
	{ok, State} ->
	    {reply, {ok, PCtx}, State};
	{reply, Reply, State} ->
	    {reply, {ok, PCtx, Reply}, State};
	{stop, State} ->
	    {stop, normal, {ok, PCtx}, State};
	{error, Reply, State} ->
	    {reply, {ok, PCtx, Reply}, State};
	{noreply, State} ->
	    {noreply, State}
    end;

handle_call(Request, From, #{interface := Interface} = State) ->
    lager:debug("~w: handle_call: ~p", [?MODULE, Request]),
    Interface:handle_call(Request, From, State).

handle_cast({handle_message, Request, #gtp{} = Msg0, Resent}, State) ->
    Msg = gtp_packet:decode_ies(Msg0),
    lager:debug("handle gtp request: ~w, ~p",
		[Request#request.port, gtp_c_lib:fmt_gtp(Msg)]),
    handle_request(Request, Msg, Resent, State);

handle_cast({handle_pdu, Request, Msg}, #{interface := Interface} = State) ->
    lager:debug("handle GTP-U PDU: ~w, ~p",
		[Request#request.port, gtp_c_lib:fmt_gtp(Msg)]),
    Interface:handle_pdu(Request, Msg, State);

handle_cast({handle_response, ReqInfo, Request, Response0},
	    #{interface := Interface} = State0) ->
    try
	Response = gtp_packet:decode_ies(Response0),
	case Response of
	    #gtp{} ->
		lager:debug("handle gtp response: ~p", [gtp_c_lib:fmt_gtp(Response)]),
		validate_message(Response, State0);
	    _ when is_atom(Response) ->
		lager:debug("handle gtp response: ~p", [Response]),
		ok
	end,
	Interface:handle_response(ReqInfo, Response, Request, State0)
    of
	{stop, State1} ->
	    {stop, normal, State1};

	{noreply, State1} ->
	    {noreply, State1}
    catch
	throw:#ctx_err{} = CtxErr ->
	    handle_ctx_error(CtxErr, State0);

	Class:Error ->
	    Stack = erlang:get_stacktrace(),
	    lager:error("GTP response failed with: ~p:~p (~p)", [Class, Error, Stack]),
	    {noreply, State0}
    end;

handle_cast({triggered_offline_usage_report, {Reason, _} = ChargeEv, OldS, #pfcp{ie = IEs}},
	    #{pfcp := PCtx, 'Session' := Session} = State)
  when ChargeEv =/= false ->
    Now = erlang:monotonic_time(),

    UsageReport = maps:get(usage_report_smr, IEs, undefined),
    {_Online, Offline, _} =
	ergw_gsn_lib:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx),
    ergw_gsn_lib:process_offline_charging_events(Reason, Offline, Now, OldS, Session),

    {noreply, State};

handle_cast({triggered_offline_usage_report, _ChargeEv, _OldS, _Response}, State) ->
    {noreply, State};

handle_cast(Msg, #{interface := Interface} = State) ->
    lager:debug("~w: handle_cast: ~p", [?MODULE, lager:pr(Msg, ?MODULE)]),
    Interface:handle_cast(Msg, State).

%%====================================================================

handle_info({update_session, Session, Events} = Us, #{interface := Interface} = State0) ->
    lager:warning("UpdateSession: ~p", [Us]),
    State = Interface:session_events(Session, Events, State0),
    {noreply, State};

%%====================================================================

handle_info({timeout, TRef, pfcp_timer} = Info,
	    #{interface := Interface, pfcp := PCtx0} = State) ->
    lager:debug("handle_info ~p:~p", [Interface, lager:pr(Info, ?MODULE)]),
    {Evs, PCtx} = ergw_pfcp:timer_expired(TRef, PCtx0),
    CtxEvs = ergw_gsn_lib:pfcp_to_context_event(Evs),
    Interface:handle_info({pfcp_timer, CtxEvs}, State#{pfcp => PCtx});

handle_info(Info, #{interface := Interface} = State) ->
    lager:debug("handle_info ~p:~p", [Interface, lager:pr(Info, ?MODULE)]),
    Interface:handle_info(Info, State).

terminate(Reason, #{interface := Interface} = State) ->
    Interface:terminate(Reason, State);
terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Message Handling functions
%%%===================================================================

log_ctx_error(#ctx_err{level = Level, where = {File, Line}, reply = Reply}) ->
    lager:debug("CtxErr: ~w, at ~s:~w, ~p", [Level, File, Line, Reply]).

handle_ctx_error(#ctx_err{level = Level} = CtxErr, State) ->
    log_ctx_error(CtxErr),
    case Level of
	?FATAL ->
	    {stop, normal, State};
	_ ->
	    {noreply, State}
    end.

handle_ctx_error(#ctx_err{reply = Reply} = CtxErr, Handler,
		 Request, #gtp{type = MsgType, seq_no = SeqNo}, State) ->
    Response = if is_list(Reply) orelse is_atom(Reply) ->
		       Handler:build_response({MsgType, Reply});
		  true ->
		       Handler:build_response(Reply)
	       end,
    send_response(Request, Response#gtp{seq_no = SeqNo}),
    handle_ctx_error(CtxErr, State).

handle_request(#request{gtp_port = GtpPort} = Request,
	       #gtp{version = Version, seq_no = SeqNo} = Msg,
	       Resent, #{interface := Interface} = State0) ->
    lager:debug("GTP~s ~s:~w: ~p",
		[Version, inet:ntoa(Request#request.ip), Request#request.port, gtp_c_lib:fmt_gtp(Msg)]),

    Handler = gtp_path:get_handler(GtpPort, Version),
    try
	validate_message(Msg, State0),
	handle_request_metrics( not Resent, Msg ),
	Interface:handle_request(Request, Msg, Resent, State0)
    of
	{reply, Reply, State1} ->
	    Response = Handler:build_response(Reply),
	    send_response(Request, Response#gtp{seq_no = SeqNo}),
	    {noreply, State1};

	{stop, Reply, State1} ->
	    Response = Handler:build_response(Reply),
	    send_response(Request, Response#gtp{seq_no = SeqNo}),
	    {stop, normal, State1};

	{noreply, State1} ->
	    {noreply, State1}
    catch
	throw:#ctx_err{} = CtxErr ->
	    handle_ctx_error(CtxErr, Handler, Request, Msg, State0);

	Class:Error ->
	    Stack = erlang:get_stacktrace(),
	    lager:error("GTP~p failed with: ~p:~p (~p)", [Version, Class, Error, Stack]),
	    {noreply, State0}
    end.


send_response(Request, #gtp{seq_no = SeqNo} = Msg) ->
    %% TODO: handle encode errors
    try
	request_finished(Request),
	send_response_metrics( Msg ),
	ergw_gtp_c_socket:send_response(Request, Msg, SeqNo /= 0)
    catch
	Class:Error ->
	    Stack = erlang:get_stacktrace(),
	    lager:error("gtp send failed with ~p:~p (~p) for ~p",
			[Class, Error, Stack, gtp_c_lib:fmt_gtp(Msg)])
    end.

request_finished(Request) ->
    unregister_request(Request).

generic_error(_Request, #gtp{type = g_pdu}, _Error) ->
    ok;
generic_error(#request{gtp_port = GtpPort} = Request,
	      #gtp{version = Version, type = MsgType, seq_no = SeqNo}, Error) ->
    Handler = gtp_path:get_handler(GtpPort, Version),
    Reply = Handler:build_response({MsgType, 0, Error}),
    ergw_gtp_c_socket:send_response(Request, Reply#gtp{seq_no = SeqNo}, SeqNo /= 0).

%%%===================================================================
%%% Internal functions
%%%===================================================================


handle_request_metrics( true, #gtp{type = create_pdp_context_request} ) -> ergw_metrics:pdp_context_create_request();
handle_request_metrics( true, #gtp{type = create_session_request} ) -> ergw_metrics:session_create_request();
handle_request_metrics( _, _GTP ) -> ok.


register_request(Handler, Server, #request{key = ReqKey, gtp_port = GtpPort}) ->
    gtp_context_reg:register([port_key(GtpPort, ReqKey)], Handler, Server).


send_response_metrics( #gtp{type = create_pdp_context_response, version = v1, ie = [#cause{value=V}|_]} ) ->
	ergw_metrics:pdp_context_create_response( V );
send_response_metrics( #gtp{type = create_pdp_context_response, version = v1, ie = IE} ) ->
	ergw_metrics:pdp_context_create_response( gtp_v1_c:get_cause(IE) );
send_response_metrics( #gtp{type = create_session_response, version = v2, ie = [#v2_cause{v2_cause=V}|_]} ) ->
	ergw_metrics:session_create_response( V );
send_response_metrics( #gtp{type = create_session_response, version = v2, ie = IE} ) ->
	ergw_metrics:session_create_response( gtp_v2_c:get_cause(IE) );
send_response_metrics( _GTP ) -> ok.


unregister_request(#request{key = ReqKey, gtp_port = GtpPort}) ->
    gtp_context_reg:unregister([port_key(GtpPort, ReqKey)], ?MODULE, self()).

enforce_restriction(Context, #gtp{version = Version}, {Version, false}) ->
    throw(?CTX_ERR(?FATAL, {version_not_supported, []}, Context));
enforce_restriction(_Context, _Msg, _Restriction) ->
    ok.

get_handler_if(GtpPort, #gtp{version = v1} = Msg) ->
    gtp_v1_c:get_handler(GtpPort, Msg);
get_handler_if(GtpPort, #gtp{version = v2} = Msg) ->
    gtp_v2_c:get_handler(GtpPort, Msg).

context_new(GtpPort, Version, Interface, InterfaceOpts) ->
    case gtp_context_sup:new(GtpPort, Version, Interface, InterfaceOpts) of
	{ok, Server} when is_pid(Server) ->
	    Server;
	{error, Error} ->
	    throw({error, Error})
    end.

validate_teid(#gtp{version = v1, type = MsgType, tei = TEID}) ->
    gtp_v1_c:validate_teid(MsgType, TEID);
validate_teid(#gtp{version = v2, type = MsgType, tei = TEID}) ->
    gtp_v2_c:validate_teid(MsgType, TEID).

validate_message(#gtp{version = Version, ie = IEs} = Msg, State) ->
    Cause = case Version of
		v1 -> gtp_v1_c:get_cause(IEs);
		v2 -> gtp_v2_c:get_cause(IEs)
	    end,
    case validate_ies(Msg, Cause, State) of
	[] ->
	    ok;
	Missing ->
	    lager:debug("Missing IEs: ~p", [Missing]),
	    throw(?CTX_ERR(?WARNING, [{mandatory_ie_missing, hd(Missing)}]))
    end.

validate_ies(#gtp{version = Version, type = MsgType, ie = IEs}, Cause, #{interface := Interface}) ->
    Spec = Interface:request_spec(Version, MsgType, Cause),
    lists:foldl(fun({Id, mandatory}, M) ->
			case maps:is_key(Id, IEs) of
			    true  -> M;
			    false -> [Id | M]
			end;
		   (_, M) ->
			M
		end, [], Spec).

%%====================================================================
%% context registry
%%====================================================================

context2keys(#context{
		context_id         = ContextId,
		control_port       = CntlPort,
		local_control_tei  = LocalCntlTEI,
		remote_control_teid = RemoteCntlTEID
	       }) ->
    ordsets:from_list(
      [port_teid_key(CntlPort, 'gtp-c', LocalCntlTEI),
       port_teid_key(CntlPort, 'gtp-c', RemoteCntlTEID)]
      ++ [port_key(CntlPort, ContextId) || ContextId /= undefined]).

port_key(#gtp_port{name = Name}, Key) ->
    {Name, Key}.

port_teid_key(#gtp_port{type = Type} = Port, TEI) ->
    port_teid_key(Port, Type, TEI).

port_teid_key(#gtp_port{name = Name}, Type, TEI) ->
    {Name, {teid, Type, TEI}}.

%%====================================================================
%% Experimental Trigger Support
%%====================================================================

usage_report_to_accounting(
  #{volume_measurement :=
	#volume_measurement{uplink = RcvdBytes, downlink = SendBytes},
    tp_packet_measurement :=
	#tp_packet_measurement{uplink = RcvdPkts, downlink = SendPkts}}) ->
    [{'InPackets',  RcvdPkts},
     {'OutPackets', SendPkts},
     {'InOctets',   RcvdBytes},
     {'OutOctets',  SendBytes}];
usage_report_to_accounting(
  #{volume_measurement :=
	#volume_measurement{uplink = RcvdBytes, downlink = SendBytes}}) ->
    [{'InOctets',   RcvdBytes},
     {'OutOctets',  SendBytes}];
usage_report_to_accounting(#usage_report_smr{group = UR}) ->
    usage_report_to_accounting(UR);
usage_report_to_accounting(#usage_report_sdr{group = UR}) ->
    usage_report_to_accounting(UR);
usage_report_to_accounting(#usage_report_srr{group = UR}) ->
    usage_report_to_accounting(UR);
usage_report_to_accounting([H|_]) ->
    usage_report_to_accounting(H);
usage_report_to_accounting(undefined) ->
    [].
