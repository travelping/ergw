%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context).

-behavior(gen_statem).
-behavior(ergw_context).

-compile({parse_transform, cut}).
-compile({parse_transform, do}).

-export([handle_response/4,
	 start_link/2, start_link/4, start_link/6,
	 send_request/8,
	 send_response/2, send_response/3,
	 send_request/7, resend_request/2,
	 request_finished/1,
	 path_restart/2,
	 terminate_colliding_context/2,
	 trigger_delete_context/1,
	 remote_context_register/3, remote_context_register_new/3,
	 tunnel_reg_update/2,
	 info/1,
	 validate_options/3,
	 validate_option/2,
	 generic_error/3,
	 socket_key/2, socket_teid_key/2,
	 socket_teid_filter/2
	]).
-export([usage_report_to_accounting/1,
	 collect_charging_events/2]).

-export([usage_report/3, trigger_usage_report/3]).

%% ergw_context callbacks
-export([ctx_sx_report/2, ctx_pfcp_timer/3, port_message/2, ctx_port_message/4]).

-ignore_xref([start_link/2,
	      start_link/4,
	      start_link/6,
	      handle_response/4			% used from callback handler
	      ]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-ifdef(TEST).
-export([tunnel_key/2, ctx_test_cmd/2]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-define(TestCmdTag, '$TestCmd').

-import(ergw_aaa_session, [to_session/1]).

-define(IDLE_TIMEOUT, 100).
-define(IDLE_INIT_TIMEOUT, 5000).
-define(SHUTDOWN_TIMEOUT, 5000).

-define('Tunnel Endpoint Identifier Data I',	{tunnel_endpoint_identifier_data_i, 0}).

%%====================================================================
%% API
%%====================================================================

handle_response(Context, ReqInfo, Request, Response) ->
    gen_statem:cast(Context, {handle_response, ReqInfo, Request, Response}).

%% send_request/8
send_request(#tunnel{socket = Socket}, Src, DstIP, DstPort, T3, N3, Msg, ReqInfo) ->
    CbInfo = {?MODULE, handle_response, [self(), ReqInfo, Msg]},
    ergw_gtp_c_socket:send_request(Socket, Src, DstIP, DstPort, T3, N3, Msg, CbInfo).

%% send_request/7
send_request(Socket, Src, DstIP, DstPort, ReqId, Msg, ReqInfo)
  when is_record(Socket, socket) ->
    CbInfo = {?MODULE, handle_response, [self(), ReqInfo, Msg]},
    ergw_gtp_c_socket:send_request(Socket, Src, DstIP, DstPort, ReqId, Msg, CbInfo);
send_request(#tunnel{socket = Socket}, Src, DstIP, DstPort, ReqId, Msg, ReqInfo) ->
    send_request(Socket, Src, DstIP, DstPort, ReqId, Msg, ReqInfo).

resend_request(#tunnel{socket = Socket}, ReqId) ->
    ergw_gtp_c_socket:resend_request(Socket, ReqId).

start_link(RecordId, Opts) ->
    gen_statem:start_link(?MODULE, [RecordId], Opts).

start_link(RecordId, State, Data, Opts) ->
    gen_statem:start_link(?MODULE, [RecordId, State, Data], Opts).

start_link(Socket, Info, Version, Interface, IfOpts, Opts) ->
    gen_statem:start_link(?MODULE, [Socket, Info, Version, Interface, IfOpts], Opts).

path_restart(Context, Path) ->
    Fun = fun() -> (catch gen_statem:call(Context, {path_restart, Path})) end,
    jobs:run(path_restart, Fun).

remote_context_register(LeftTunnel, Bearer, Context)
  when is_record(Context, context) ->
    Keys = context2keys(LeftTunnel, Bearer, Context),
    gtp_context_reg:register(Keys, ?MODULE, self()).

remote_context_register_new(LeftTunnel, Bearer, Context) ->
    Keys = context2keys(LeftTunnel, Bearer, Context),
    case gtp_context_reg:register_new(Keys, ?MODULE, self()) of
	ok ->
	    ok;
	_ ->
	    {error, ?CTX_ERR(?FATAL, system_failure)}
    end.

tunnel_reg_update(Tunnel, Tunnel) ->
    ok;
tunnel_reg_update(TunnelOld, TunnelNew) ->
    OldKeys = ordsets:from_list(tunnel2keys(TunnelOld)),
    NewKeys = ordsets:from_list(tunnel2keys(TunnelNew)),
    Delete = ordsets:subtract(OldKeys, NewKeys),
    Insert = ordsets:subtract(NewKeys, OldKeys),
    gtp_context_reg:update(Delete, Insert, ?MODULE, self()).

trigger_delete_context(Context) ->
    gen_statem:cast(Context, delete_context).

%% TODO: add online charing events
collect_charging_events(OldS, NewS) ->
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
	    [{offline, {ChargeEv, OldS}}]
    end.

%% 3GPP TS 29.060 (GTPv1-C) and TS 29.274 (GTPv2-C) have language that states
%% that when an incomming Create PDP Context/Create Session requests collides
%% with an existing context based on a IMSI, Bearer, Protocol tuple, that the
%% preexisting context should be deleted locally. This function does that.
terminate_colliding_context(#tunnel{socket = Socket}, #context{context_id = Id})
  when Id /= undefined ->
    case gtp_context_reg:lookup(socket_key(Socket, Id)) of
	{?MODULE, Server} when is_pid(Server) ->
	    terminate_context(Server);
	_ ->
	    ok
    end;
terminate_colliding_context(_, _) ->
    ok.

terminate_context(Context)
  when is_pid(Context) ->
    try
	gen_statem:call(Context, terminate_context)
    catch
	exit:_ ->
	    ok
    end,
    gtp_context_reg:await_unreg(Context).

info(Context) ->
    gen_statem:call(Context, info).

-ifdef(TEST).

ctx_test_cmd(_RecordIdOrPid, is_alive) ->
    true;
ctx_test_cmd(RecordIdOrPid, whereis) ->
    context_run(RecordIdOrPid, fun(Pid, _) -> {?MODULE, Pid} end, undefined);
ctx_test_cmd(RecordIdOrPid, update_context) ->
    context_run(RecordIdOrPid, call, update_context);
ctx_test_cmd(RecordIdOrPid, delete_context) ->
    context_run(RecordIdOrPid, call, delete_context);
ctx_test_cmd(RecordIdOrPid, terminate_context) ->
    context_run(RecordIdOrPid, fun(Pid, _) -> terminate_context(Pid) end, undefined);
ctx_test_cmd(RecordIdOrPid, Cmd) ->
    context_run(RecordIdOrPid, call, {?TestCmdTag, Cmd}).

-endif.

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

ctx_sx_report(RecordIdOrPid, Report) ->
    context_run(RecordIdOrPid, call, {sx, Report}).

ctx_pfcp_timer(RecordIdOrPid, Time, Evs) ->
    context_run(RecordIdOrPid, call, {pfcp_timer, Time, Evs}).

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

port_message(#request{socket = Socket, info = Info} = Request,
		 #gtp{version = Version, tei = 0} = Msg) ->
    case get_handler_if(Socket, Msg) of
	{ok, Interface, InterfaceOpts} ->
	    case ergw:get_accept_new() of
		true -> ok;
		_ ->
		    throw({error, no_resources_available})
	    end,
	    validate_teid(Msg),
	    Server = context_new(Socket, Info, Version, Interface, InterfaceOpts),
	    handle_port_message(Server, Request, Msg, false);

	{error, _} = Error ->
	    throw(Error)
    end;
port_message(_Request, _Msg) ->
    throw({error, not_found}).

handle_port_message(Server, Request, Msg, Resent) when is_pid(Server) ->
    if not Resent -> register_request(?MODULE, Server, Request);
       true       -> ok
    end,
    context_run(Server, call, {handle_message, Request, Msg, Resent}).

%% ctx_port_message/4
ctx_port_message(RecordIdOrPid, Request, #gtp{type = g_pdu} = Msg, _Resent) ->
    context_run(RecordIdOrPid, cast, {handle_pdu, Request, Msg});
ctx_port_message(RecordIdOrPid, Request, Msg, Resent) ->
    EvFun = fun(Server, _) -> handle_port_message(Server, Request, Msg, Resent) end,
    context_run(RecordIdOrPid, EvFun, undefined).

%%====================================================================
%% gen_statem API
%%====================================================================

callback_mode() -> [handle_event_function, state_enter].

init([RecordId]) ->
    process_flag(trap_exit, true),

    case gtp_context_reg:register_name(RecordId, self()) of
	yes ->
	    case ergw_context:get_context_record(RecordId) of
		{ok, State, Data0} ->
		    Data = restore_session_state(Data0),
		    {ok, #c_state{session = State, fsm = init}, Data};
		Other ->
		    {stop, Other}
	    end;
	no ->
	    Pid = gtp_context_reg:whereis_name(RecordId),
	    {stop, {error, {already_started, Pid}}}
    end;

init([Socket, Info, Version, Interface,
      #{node_selection := NodeSelect,
	aaa := AAAOpts} = Opts]) ->

    ?LOG(debug, "init(~p)", [[Socket, Info, Interface]]),
    process_flag(trap_exit, true),

    LeftTunnel =
	ergw_gsn_lib:assign_tunnel_teid(
	  local, Info, ergw_gsn_lib:init_tunnel('Access', Info, Socket, Version)),

    Id = ergw_gtp_c_socket:get_uniq_id(Socket),
    RecordId = iolist_to_binary(["GTP-", integer_to_list(Id)]),

    gtp_context_reg:register_name(RecordId, self()),

    Context = #context{
		 charging_identifier = Id,

		 version           = Version
		},
    Bearer = #{left => #bearer{interface = 'Access'},
	       right => #bearer{interface = 'SGi-LAN'}},
    Data = #{
      record_id      => RecordId,
      context        => Context,
      version        => Version,
      interface      => Interface,
      node_selection => NodeSelect,
      aaa_opts       => AAAOpts,
      left_tunnel    => LeftTunnel,
      bearer         => Bearer},

    case init_it(Interface, Opts, Data) of
	{ok, {ok, #c_state{session = SState} = State, FinalData}} ->
	    Meta = get_record_meta(Data),
	    ergw_context:create_context_record(SState, Meta, FinalData),
	    {ok, State, FinalData};
	InitR ->
	    gtp_context_reg:unregister_name(RecordId),
	    case InitR of
		{ok, {stop, _} = R} ->
		    R;
		{ok, ignore} ->
		    ignore;
		{ok, Else} ->
		    exit({bad_return_value, Else});
		{'EXIT', Class, Reason, Stacktrace} ->
		    erlang:raise(Class, Reason, Stacktrace)
	    end
    end.

init_it(Mod, Opts, Data) ->
    try
	{ok, Mod:init(Opts, Data)}
    catch
	throw:R -> {ok, R};
	Class:R:S -> {'EXIT', Class, R, S}
    end.

handle_event({call, From}, info, _, Data) ->
    {keep_state_and_data, [{reply, From, Data}]};

handle_event({call, From}, {?TestCmdTag, pfcp_ctx}, _State, #{pfcp := PCtx}) ->
    {keep_state_and_data, [{reply, From, {ok, PCtx}}]};
handle_event({call, From}, {?TestCmdTag, session}, _State, #{'Session' := Session}) ->
    {keep_state_and_data, [{reply, From, {ok, Session}}]};
handle_event({call, From}, {?TestCmdTag, pcc_rules}, _State, #{pcc := PCC}) ->
    {keep_state_and_data, [{reply, From, {ok, PCC#pcc_ctx.rules}}]};
handle_event({call, From}, {?TestCmdTag, kill}, State, Data) ->
    {next_state, State#c_state{session = shutdown, fsm = busy}, Data, [{reply, From, ok}]};
handle_event({call, From}, {?TestCmdTag, info}, _State, Data) ->
    {keep_state_and_data, [{reply, From, Data}]};

handle_event(state_timeout, idle, #c_state{fsm = init}, Data) ->
    {stop, normal, Data};
handle_event(state_timeout, idle, #c_state{session = SState, fsm = idle}, Data0) ->
    Data = save_session_state(Data0),
    Meta = get_record_meta(Data),
    ergw_context:put_context_record(SState, Meta, Data),
    {stop, normal, Data};

handle_event(state_timeout, stop, #c_state{session = shutdown_initiated} = State, Data) ->
    {next_state, State#c_state{session = shutdown, fsm = busy}, Data};
handle_event(cast, stop, #c_state{session = shutdown}, _Data) ->
    {stop, normal};

handle_event(enter, _OldState, #c_state{fsm = init}, _Data) ->
    {keep_state_and_data, [{state_timeout, ?IDLE_INIT_TIMEOUT, idle}]};
handle_event(enter, _OldState, #c_state{fsm = idle}, _Data) ->
    {keep_state_and_data, [{state_timeout, ?IDLE_TIMEOUT, idle}]};

handle_event(enter, _OldState, #c_state{session = shutdown_initiated}, _Data) ->
    {keep_state_and_data, [{state_timeout, ?SHUTDOWN_TIMEOUT, stop}]};

handle_event(enter, _OldState, #c_state{session = shutdown}, _Data) ->
    %% TODO unregister context ....

    %% this makes stop the last message in the inbox and
    %% guarantees that we process any left over messages first
    gen_statem:cast(self(), stop),
    keep_state_and_data;

handle_event(enter, OldState, State, #{interface := Interface} = Data) ->
    Interface:handle_event(enter, OldState, State, Data);

handle_event({call, From},
	     {sx, #pfcp{type = session_report_request,
			ie = #{report_type := #report_type{erir = 1},
			       error_indication_report :=
				   #error_indication_report{
				      group =
					  #{f_teid :=
						#f_teid{ipv4 = IP4, ipv6 = IP6} = FTEID0}}}}},
	     State, #{pfcp := PCtx} = Data) ->
    FTEID = FTEID0#f_teid{ipv4 = ergw_inet:bin2ip(IP4), ipv6 = ergw_inet:bin2ip(IP6)},
    case fteid_tunnel_side(FTEID, Data) of
	none ->
	    %% late EIR, we already switched to a new peer
	    {keep_state_and_data, [{reply, From, {ok, PCtx}}]};

	Side ->
	    close_context(Side, remote_failure, State, Data),
	    Actions = [{reply, From, {ok, PCtx}}],
	    {next_state, State#c_state{session = shutdown, fsm = busy}, Data, Actions}
    end;

%% User Plane Inactivity Timer expired
handle_event({call, From},
	     {sx, #pfcp{type = session_report_request,
			ie = #{report_type := #report_type{upir = 1}}}},
	     State, #{pfcp := PCtx} = Data) ->
    close_context(both, inactivity_timeout, State, Data),
    Actions = [{reply, From, {ok, PCtx}}],
    {next_state, State#c_state{session = shutdown, fsm = busy}, Data, Actions};

%% Usage Report
handle_event({call, From},
	     {sx, #pfcp{type = session_report_request,
			ie = #{report_type := #report_type{usar = 1},
			       usage_report_srr := UsageReport}}},
	      _State, #{pfcp := PCtx, 'Session' := Session, pcc := PCC}) ->
    Now = erlang:monotonic_time(),
    ChargeEv = interim,

    ergw_gtp_gsn_session:usage_report_request(ChargeEv, Now, UsageReport, PCtx, PCC, Session),
    {keep_state_and_data, [{reply, From, {ok, PCtx}}]};

handle_event({call, From}, {handle_message, Request, #gtp{} = Msg0, Resent}, State, Data) ->
    gen_statem:reply(From, ok),
    Msg = gtp_packet:decode_ies(Msg0),
    ?LOG(debug, "handle gtp request: ~w, ~p",
		[Request#request.port, gtp_c_lib:fmt_gtp(Msg)]),
    handle_request(Request, Msg, Resent, State, Data);

handle_event(cast, {handle_pdu, Request, Msg}, State, #{interface := Interface} = Data) ->
    ?LOG(debug, "handle GTP-U PDU: ~w, ~p",
		[Request#request.port, gtp_c_lib:fmt_gtp(Msg)]),
    Interface:handle_pdu(Request, Msg, State, Data);

handle_event(cast, {handle_response, ReqInfo, Request, Response0}, State,
	    #{interface := Interface} = Data) ->
    try
	Response = gtp_packet:decode_ies(Response0),
	case Response of
	    #gtp{} ->
		?LOG(debug, "handle gtp response: ~p", [gtp_c_lib:fmt_gtp(Response)]),
		validate_message(Response, Data);
	    _ when is_atom(Response) ->
		?LOG(debug, "handle gtp response: ~p", [Response]),
		ok
	end,
	Interface:handle_response(ReqInfo, Response, Request, State, Data)
    catch
	throw:#ctx_err{} = CtxErr:St ->
	    handle_ctx_error(CtxErr, St, State, Data);

	Class:Reason:Stacktrace ->
	    ?LOG(error, "GTP response failed with: ~p:~p (~p)", [Class, Reason, Stacktrace]),
	    erlang:raise(Class, Reason, Stacktrace)
    end;

handle_event(info, #aaa_request{procedure = {_, 'ASR'}} = Request, State, Data) ->
    ergw_aaa_session:response(Request, ok, #{}, #{}),
    delete_context(undefined, administrative, State, Data);

handle_event(info, #aaa_request{procedure = {gx, 'RAR'},
				events = Events} = Request,
	     #c_state{session = connected} = _State,
	     #{context := Context, pfcp := PCtx0,
	       left_tunnel := LeftTunnel, bearer := Bearer,
	       'Session' := Session, pcc := PCC0} = Data) ->
%%% 1. update PCC
%%%    a) calculate PCC rules to be removed
%%%    b) calculate PCC rules to be installed
%%% 2. figure out which Rating-Groups are new or which ones have to be removed
%%%    based on updated PCC rules
%%% 3. remove PCC rules and unsused Rating-Group URRs from UPF
%%% 4. on Gy:
%%%     - report removed URRs/RGs
%%%     - request credits for new URRs/RGs
%%% 5. apply granted quotas to PCC rules, remove PCC rules without quotas
%%% 6. install new PCC rules which have granted quota
%%% 7. report remove and not installed (lack of quota) PCC rules on Gx
    Now = erlang:monotonic_time(),
    ReqOps = #{now => Now},

    RuleBase = ergw_charging:rulebase(),

%%% step 1a:
    {PCC1, _} =
	ergw_pcc_context:gx_events_to_pcc_ctx(Events, remove, RuleBase, PCC0),
%%% step 1b:
    {PCC2, PCCErrors2} =
	ergw_pcc_context:gx_events_to_pcc_ctx(Events, install, RuleBase, PCC1),

%%% step 2
%%% step 3:
    {PCtx1, UsageReport} =
	case ergw_pfcp_context:modify_session(PCC1, [], #{}, Bearer, PCtx0) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context, tunnel = LeftTunnel})
	end,

%%% step 4:
    ChargeEv = {online, 'RAR'},   %% made up value, not use anywhere...
    {Online, Offline, Monitor} =
	ergw_pfcp_context:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx1),

    ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),
    GyReqServices = ergw_pcc_context:gy_credit_request(Online, PCC0, PCC2),
    {ok, _, GyEvs} =
	ergw_gsn_lib:process_online_charging_events(ChargeEv, GyReqServices, Session, ReqOps),
    ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),

%%% step 5:
    {PCC4, PCCErrors4} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, GyEvs, PCC2),

%%% step 6:
    {PCtx, _} =
	case ergw_pfcp_context:modify_session(PCC4, [], #{}, Bearer, PCtx1) of
	    {ok, Result2} -> Result2;
	    {error, Err2} -> throw(Err2#ctx_err{context = Context, tunnel = LeftTunnel})
	end,

%%% step 7:
    %% TODO Charging-Rule-Report for successfully installed/removed rules

    GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(PCCErrors2 ++ PCCErrors4),
    ergw_aaa_session:response(Request, ok, GxReport, #{}),
    {keep_state, Data#{pfcp := PCtx, pcc := PCC4}};

handle_event(info, #aaa_request{procedure = {gy, 'RAR'},
				events = Events} = Request,
	     #c_state{session = connected} = _State, Data) ->
    ergw_aaa_session:response(Request, ok, #{}, #{}),
    Now = erlang:monotonic_time(),

    %% Triggered CCR.....
    ChargingKeys =
	case proplists:get_value(report_rating_group, Events) of
	    RatingGroups when is_list(RatingGroups) ->
		[{online, RG} || RG <- RatingGroups];
	    _ ->
		undefined
	end,
    ergw_gtp_gsn_lib:triggered_charging_event(interim, Now, ChargingKeys, Data),
    keep_state_and_data;

handle_event(info, #aaa_request{procedure = {_, 'RAR'}} = Request, _State, _Data) ->
    ergw_aaa_session:response(Request, {error, unknown_session}, #{}, #{}),
    keep_state_and_data;

handle_event(info, {update_session, Session, Events}, _State, _Data) ->
    ?LOG(debug, "SessionEvents: ~p~n       Events: ~p", [Session, Events]),
    Actions = [{next_event, internal, {session, Ev, Session}} || Ev <- Events],
    {keep_state_and_data, Actions};

handle_event(internal, {session, {update_credits, _} = CreditEv, _}, _State,
	     #{context := Context, pfcp := PCtx0,
	       left_tunnel := LeftTunnel, bearer := Bearer,
	       pcc := PCC0} = Data) ->
    Now = erlang:monotonic_time(),

    {PCC, _PCCErrors} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, [CreditEv], PCC0),
    {PCtx, _} =
	case ergw_pfcp_context:modify_session(PCC, [], #{}, Bearer, PCtx0) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context, tunnel = LeftTunnel})
	end,
    {keep_state, Data#{pfcp := PCtx, pcc := PCC}};

handle_event(internal, {session, stop, _Session}, State, Data) ->
     delete_context(undefined, normal, State, Data);

handle_event(internal, {session, Ev, _}, _State, _Data) ->
    ?LOG(error, "unhandled session event: ~p", [Ev]),
    keep_state_and_data;

handle_event({call, From}, {pfcp_timer, Time, Evs} = Info, _State,
	    #{interface := Interface, pfcp := PCtx0} = Data0) ->
    ?LOG(debug, "handle_event ~p:~p", [Interface, Info]),
    gen_statem:reply(From, ok),
    Now = erlang:monotonic_time(),
    PCtx = ergw_pfcp:timer_expired(Time, PCtx0),
    Data = Data0#{pfcp => PCtx},
    #{validity_time := ChargingKeys} = ergw_gsn_lib:pfcp_to_context_event(Evs),
    ergw_gtp_gsn_lib:triggered_charging_event(validity_time, Now, ChargingKeys, Data),
    {keep_state, Data};

handle_event({call, From}, delete_context, #c_state{session = SState} = State, Data)
  when SState == connected; SState == connecting ->
    delete_context(From, administrative, State, Data);
handle_event({call, From}, delete_context, #c_state{session = SState}, _Data)
  when SState =:= shutdown; SState =:= shutdown_initiated ->
    {keep_state_and_data, [{reply, From, {ok, ok}}]};
handle_event({call, _From}, delete_context, _State, _Data) ->
    {keep_state_and_data, [postpone]};

handle_event({call, From}, terminate_context, State, Data) ->
    close_context(left, normal, State, Data),
    {next_state, State#c_state{session = shutdown, fsm = busy}, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, Path}, State,
	     #{left_tunnel := #tunnel{path = Path}} = Data) ->
    close_context(left, peer_restart, State, Data),
    {next_state, State#c_state{session = shutdown, fsm = busy}, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, Path}, State,
	     #{right_tunnel := #tunnel{path = Path}} = Data) ->
    close_context(right, peer_restart, State, Data),
    {next_state, State#c_state{session = shutdown, fsm = busy}, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, _Path}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

handle_event(cast, {usage_report, URRActions, UsageReport}, _State, Data) ->
    ergw_gtp_gsn_lib:usage_report(URRActions, UsageReport, Data),
    keep_state_and_data;

handle_event(cast, delete_context, State, Data) ->
    delete_context(undefined, administrative, State, Data);

handle_event(info, {'DOWN', _MonitorRef, Type, Pid, _Info}, State,
	     #{pfcp := #pfcp_ctx{node = Pid}} = Data)
  when Type == process; Type == pfcp ->
    close_context(both, upf_failure, State, Data),
    {next_state, State#c_state{session = shutdown, fsm = busy}, Data};

handle_event({timeout, context_idle}, stop_session, State, Data) ->
    delete_context(undefined, normal, State, Data);

handle_event(Type, Content, State, #{interface := Interface} = Data) ->
    ?LOG(debug, "~w: handle_event: (~p, ~p, ~p)",
		[?MODULE, Type, Content, State]),
    Interface:handle_event(Type, Content, State, Data).

terminate(Reason, State, #{interface := Interface} = Data) ->
    try
	Interface:terminate(Reason, State, Data)
    after
	terminate_cleanup(State, Data)
    end;
terminate(_Reason, State, Data) ->
    terminate_cleanup(State, Data),
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Message Handling functions
%%%===================================================================

log_ctx_error(#ctx_err{level = Level, where = {File, Line}, reply = Reply}, St) ->
    ?LOG(debug, #{type => ctx_err, level => Level, file => File,
		  line => Line, reply => Reply, stack => St}).

handle_ctx_error(#ctx_err{level = Level, context = Context} = CtxErr, St,
		 #c_state{session = SState}, Data0) ->
    log_ctx_error(CtxErr, St),
    Data = if is_record(Context, context) ->
		   Data0#{context => Context};
	      true ->
		   Data0
	   end,
    if Level =:= ?FATAL orelse SState =:= init ->
	    {stop, normal, Data};
       true ->
	    {keep_state, Data}
    end.

handle_ctx_error(#ctx_err{reply = Reply, tunnel = Tunnel} = CtxErr, St, Handler,
		 Request, #gtp{type = MsgType, seq_no = SeqNo} = Msg, State, Data) ->
    Response0 = if is_list(Reply) orelse is_atom(Reply) ->
			Handler:build_response({MsgType, Reply});
		   true ->
			Handler:build_response(Reply)
		end,
    Response = case Tunnel of
		   #tunnel{remote = #fq_teid{teid = TEID}} ->
		       Response0#gtp{tei = TEID};
		   _ ->
		       case find_sender_teid(Msg) of
			   TEID when is_integer(TEID) ->
			       Response0#gtp{tei = TEID};
			   _ ->
			       Response0#gtp{tei = 0}
		       end
	       end,
    send_response(Request, Response#gtp{seq_no = SeqNo}),
    handle_ctx_error(CtxErr, St, State, Data).

handle_request(#request{socket = Socket} = Request,
	       #gtp{version = Version} = Msg,
	       Resent, State, #{interface := Interface} = Data0) ->
    ?LOG(debug, "GTP~s ~s:~w: ~p",
		[Version, inet:ntoa(Request#request.ip), Request#request.port, gtp_c_lib:fmt_gtp(Msg)]),

    try
	validate_message(Msg, Data0),
	Interface:handle_request(Request, Msg, Resent, State, Data0)
    catch
	throw:#ctx_err{} = CtxErr:St ->
	    Handler = gtp_path:get_handler(Socket, Version),
	    handle_ctx_error(CtxErr, St, Handler, Request, Msg, State, Data0);

	Class:Reason:Stacktrace ->
	    ?LOG(error, "GTP~p failed with: ~p:~p (~p)", [Version, Class, Reason, Stacktrace]),
	    erlang:raise(Class, Reason, Stacktrace)
    end.

%% send_response/3
send_response(#request{socket = Socket, version = Version} = ReqKey,
	      #gtp{seq_no = SeqNo}, Reply) ->
    Handler = gtp_path:get_handler(Socket, Version),
    Response = Handler:build_response(Reply),
    send_response(ReqKey, Response#gtp{seq_no = SeqNo}).

%% send_response/2
send_response(Request, #gtp{seq_no = SeqNo} = Msg) ->
    %% TODO: handle encode errors
    try
	request_finished(Request),
	ergw_gtp_c_socket:send_response(Request, Msg, SeqNo /= 0)
    catch
	Class:Error:Stack ->
	    ?LOG(error, "gtp send failed with ~p:~p (~p) for ~p",
			[Class, Error, Stack, gtp_c_lib:fmt_gtp(Msg)])
    end.

request_finished(Request) ->
    unregister_request(Request).

generic_error(_Request, #gtp{type = g_pdu}, _Error) ->
    ok;
generic_error(#request{socket = Socket} = Request,
	      #gtp{version = Version, type = MsgType, seq_no = SeqNo} = Msg, Error) ->
    Handler = gtp_path:get_handler(Socket, Version),
    TEID = case find_sender_teid(Msg) of
	       Value when is_integer(Value) ->
		   Value;
	       _ ->
		   0
	   end,
    Reply = Handler:build_response({MsgType, TEID, Error}),
    ergw_gtp_c_socket:send_response(Request, Reply#gtp{seq_no = SeqNo}, SeqNo /= 0).

%%%===================================================================
%%% Internal functions
%%%===================================================================

terminate_cleanup(#c_state{session = State}, Data) when State =/= connected ->
    ergw_context:delete_context_record(Data);
terminate_cleanup(_State, _) ->
    ok.

register_request(Handler, Server, #request{key = ReqKey, socket = Socket}) ->
    gtp_context_reg:register([socket_key(Socket, ReqKey)], Handler, Server).

unregister_request(#request{key = ReqKey, socket = Socket}) ->
    gtp_context_reg:unregister([socket_key(Socket, ReqKey)], ?MODULE, self()).

get_handler_if(Socket, #gtp{version = v1} = Msg) ->
    gtp_v1_c:get_handler(Socket, Msg);
get_handler_if(Socket, #gtp{version = v2} = Msg) ->
    gtp_v2_c:get_handler(Socket, Msg).

find_sender_teid(#gtp{version = v1} = Msg) ->
    gtp_v1_c:find_sender_teid(Msg);
find_sender_teid(#gtp{version = v2} = Msg) ->
    gtp_v2_c:find_sender_teid(Msg).

context_new(Socket, Info, Version, Interface, InterfaceOpts) ->
    case gtp_context_sup:new(Socket, Info, Version, Interface, InterfaceOpts) of
	{ok, Server} when is_pid(Server) ->
	    Server;
	{error, Error} ->
	    throw({error, Error})
    end.

context_run(Pid, EventType, EventContent) when is_pid(Pid) ->
    context_run_do(Pid, EventType, EventContent);
context_run(RecordId, EventType, EventContent) when is_binary(RecordId) ->
    case gtp_context_reg:whereis_name(RecordId) of
	Pid when is_pid(Pid) ->
	    context_run_do(Pid, EventType, EventContent);
	_ ->
	    case gtp_context_sup:run(RecordId) of
		{ok, Pid2} ->
		    context_run_do(Pid2, EventType, EventContent);
		{already_started, Pid3} ->
		    context_run_do(Pid3, EventType, EventContent);
		Other ->
		    Other
	    end
    end.

context_run_do(Server, cast, EventContent) ->
    gen_statem:cast(Server, EventContent);
context_run_do(Server, call, EventContent) ->
    ReqId = gen_statem:send_request(Server, EventContent),
    gen_statem:wait_response(ReqId, infinity);
context_run_do(Server, info, EventContent) ->
    Server ! EventContent;
context_run_do(Server, Fun, EventContent) when is_function(Fun) ->
    Fun(Server, EventContent).

validate_teid(#gtp{version = v1, type = MsgType, tei = TEID}) ->
    gtp_v1_c:validate_teid(MsgType, TEID);
validate_teid(#gtp{version = v2, type = MsgType, tei = TEID}) ->
    gtp_v2_c:validate_teid(MsgType, TEID).

validate_message(#gtp{version = Version, ie = IEs} = Msg, Data) ->
    Cause = case Version of
		v1 -> gtp_v1_c:get_cause(IEs);
		v2 -> gtp_v2_c:get_cause(IEs)
	    end,
    case validate_ies(Msg, Cause, Data) of
	[] ->
	    ok;
	Missing ->
	    ?LOG(debug, "Missing IEs: ~p", [Missing]),
	    ?LOG(error, "Missing IEs: ~p", [Missing]),
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

get_record_meta(#{left_tunnel := LeftTunnel, bearer := Bearer, context := Context} = Data) ->
    Meta0 = context2tags(Context),
    Meta1 = pfcp2tags(maps:get(pfcp, Data, undefined), Meta0),
    Meta2 = tunnel2tags(LeftTunnel, Meta1),
    Meta = bearer2tags(Bearer, Meta2),
    #{tags => Meta}.

context2tags(#context{apn = APN, context_id = ContextId})
  when APN /= undefined ->
    #{type => 'gtp-c', context_id => ContextId, dnn => APN};
context2tags(#context{context_id = ContextId}) ->
    #{type => 'gtp-c', context_id => ContextId}.

tunnel2tags(#tunnel{socket = #socket{name = Name}} = Tunnel, Meta0) ->
    Meta1 = Meta0#{socket => Name},
    Meta2 = teid2tag(local_control_tei, local_control_ip, Tunnel#tunnel.local, Meta1),
    _Meta = teid2tag(remote_control_tei, remote_control_ip, Tunnel#tunnel.remote, Meta2);
tunnel2tags(_, Meta) ->
    Meta.

teid2tag(TagTEI, TagIP, #fq_teid{ip = IP, teid = TEID}, Meta) ->
    Meta#{TagTEI => TEID, TagIP => IP};
teid2tag(_, _, _, Meta) ->
    Meta.

bearer2tags(#{right := #bearer{vrf = VRF, local = Local}}, Meta0) ->
    Meta1 = Meta0#{ip_domain => VRF},
    _Meta = ue_ip2tags(Local, Meta1);
bearer2tags(_, Meta) ->
    Meta.

ue_ip2tags(#ue_ip{v4 = V4, v6 = V6}, Meta0) ->
    Meta1 = ip2tags(ipv4, V4, Meta0),
    _Meta = ip2tags(ipv6, V6, Meta1);
ue_ip2tags(_, Meta) ->
    Meta.

ip2tags(Tag, IP, Meta) ->
    Meta#{Tag => IP}.

pfcp2tags(#pfcp_ctx{seid = #seid{cp = SEID}}, Meta) ->
    Meta#{seid => SEID};
pfcp2tags(_, Meta) ->
    Meta.

socket_teid_filter(#socket{type = Type} = Socket, TEI) ->
    socket_teid_filter(Socket, Type, TEI).

socket_teid_filter(#socket{name = Name}, Type, TEI) ->
    #{'cond' => 'AND',
      units =>
	  [
	   #{tag => type, value => Type},
	   #{tag => socket, value => Name},
	   #{tag => local_control_tei, value => TEI}
	  ]}.

context2keys(#tunnel{socket = Socket} = LeftTunnel, Bearer,
	     #context{apn = APN, context_id = ContextId}) ->
    ordsets:from_list(
      tunnel2keys(LeftTunnel)
      ++ [socket_key(Socket, ContextId) || ContextId /= undefined]
      ++ maps:fold(bsf_keys(APN, _, _, _), [], Bearer)).

tunnel2keys(Tunnel) ->
    [tunnel_key(local, Tunnel), tunnel_key(remote, Tunnel)].

bsf_keys(APN, _, #bearer{vrf = VRF, local = #ue_ip{v4 = IPv4, v6 = IPv6}}, Keys) ->
    [#bsf{dnn = APN, ip_domain = VRF, ip = ergw_ip_pool:ip(IPv4)} || IPv4 /= undefined] ++
	[#bsf{dnn = APN, ip_domain = VRF,
	      ip = ergw_inet:ipv6_prefix(ergw_ip_pool:ip(IPv6))} || IPv6 /= undefined] ++
    Keys;
bsf_keys(_, _, _, Keys) ->
    Keys.

socket_key(#socket{name = Name}, Key) ->
    #socket_key{name = Name, key = Key};
socket_key({Name, _}, Key) ->
    #socket_key{name = Name, key = Key}.

tunnel_key(local, #tunnel{socket = Socket, local = #fq_teid{teid = TEID}}) ->
    socket_teid_key(Socket, TEID);
tunnel_key(remote, #tunnel{socket = Socket, remote = FqTEID})
  when is_record(FqTEID, fq_teid) ->
    socket_teid_key(Socket, FqTEID).

socket_teid_key(#socket{type = Type} = Socket, TEI) ->
    socket_teid_key(Socket, Type, TEI).

socket_teid_key(#socket{name = Name}, Type, TEI) ->
    #socket_teid_key{name = Name, type = Type, teid = TEI}.

save_session_state(#{'Session' := Session} = Data)
  when is_pid(Session) ->
    Data#{'Session' => ergw_aaa_session:save(Session)};
save_session_state(Data) ->
    Data.

restore_session_state(#{'Session' := Session} = Data)
  when not is_pid(Session) ->
    {ok, SessionPid} = ergw_aaa_session_sup:new_session(self(), Session),
    Data#{'Session' => SessionPid};
restore_session_state(Data) ->
    Data.

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

%%====================================================================
%% Helper
%%====================================================================

fteid_tunnel_side(FqTEID, #{bearer := Bearer}) ->
    fteid_tunnel_side_f(FqTEID, maps:next(maps:iterator(Bearer))).

fteid_tunnel_side_f(_, none) ->
    none;
fteid_tunnel_side_f(#f_teid{ipv4 = IPv4, ipv6 = IPv6, teid = TEID},
		  {Key, #bearer{remote = #fq_teid{ip = IP, teid = TEID}}, _})
  when IP =:= IPv4; IP =:= IPv6 ->
    Key;
fteid_tunnel_side_f(FqTEID, {_, _, Iter}) ->
    fteid_tunnel_side_f(FqTEID, maps:next(Iter)).

close_context(Side, TermCause, State, #{interface := Interface} = Data) ->
    Interface:close_context(Side, TermCause, State, Data).

delete_context(From, TermCause, State, #{interface := Interface} = Data) ->
    Interface:delete_context(From, TermCause, State, Data).

%%====================================================================
%% asynchrounus usage reporting
%%====================================================================

usage_report(Server, URRActions, Report) ->
    gen_statem:cast(Server, {usage_report, URRActions, Report}).

usage_report_fun(Owner, URRActions, PCtx) ->
    case ergw_pfcp_context:query_usage_report(offline, PCtx) of
	{ok, {_, Report}} ->
	    usage_report(Owner, URRActions, Report);
	{error, CtxErr} ->
	    ?LOG(error, "Defered Usage Report failed with ~p", [CtxErr])
    end.

trigger_usage_report(_Self, [], _PCtx) ->
    ok;
trigger_usage_report(Self, URRActions, PCtx) ->
    Self = self(),
    proc_lib:spawn(fun() -> usage_report_fun(Self, URRActions, PCtx) end),
    ok.
