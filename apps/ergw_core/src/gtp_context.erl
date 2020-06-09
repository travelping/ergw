%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context).

-behavior(ergw_context).
-behavior(ergw_context_statem).

-compile({parse_transform, cut}).
-compile({parse_transform, do}).

-export([handle_response/4,
	 send_request/8,
	 send_response/2, send_response/3,
	 send_request/7, resend_request/2,
	 request_finished/1,
	 peer_down/3,
	 terminate_colliding_context/2, terminate_context/1,
	 trigger_delete_context/1,
	 remote_context_register/3, remote_context_register_new/3,
	 tunnel_reg_update/2,
	 info/1,
	 get_record_meta/1,
	 restore_session_state/1,
	 validate_options/3,
	 validate_option/2,
	 generic_error/3,
	 log_ctx_error/2,
	 context_key/2, socket_teid_key/2]).
-export([usage_report_to_accounting/1,
	 collect_charging_events/2]).

%% ergw_context callbacks
-export([ctx_sx_report/2, ctx_pfcp_timer/3, port_message/2, ctx_port_message/4]).

-ignore_xref([handle_response/4			% used from callback handler
	      ]).

%% ergw_context_statem callbacks
-export([init/2, handle_event/4, terminate/3, code_change/4]).

-ifdef(TEST).
-export([tunnel_key/2, ctx_test_cmd/2]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("ergw_core_config.hrl").
-include("include/ergw.hrl").

-define(TestCmdTag, '$TestCmd').

-import(ergw_aaa_session, [to_session/1]).

-define(IDLE_TIMEOUT, 500).
-define(IDLE_INIT_TIMEOUT, 5000).
-define(SHUTDOWN_TIMEOUT, 5000).

-define('Tunnel Endpoint Identifier Data I',	{tunnel_endpoint_identifier_data_i, 0}).

%%====================================================================
%% API
%%====================================================================

handle_response(Context, ReqInfo, Request, Response) ->
    ergw_context_statem:cast(Context, {handle_response, ReqInfo, Request, Response}).

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

peer_down(RecordIdOrPid, Path, Notify) ->
    Fun = fun() ->
		  (catch ergw_context_statem:call(RecordIdOrPid, {peer_down, Path, Notify}))
	  end,
    jobs:run(path_restart, Fun).

remote_context_register(LeftTunnel, Bearer, Context)
  when is_record(Context, context) ->
    Keys = context2keys(LeftTunnel, Bearer, Context),
    gtp_context_reg:register(Keys, ?MODULE, self()).

remote_context_register_new(LeftTunnel, Bearer, Context) ->
    Keys = context2keys(LeftTunnel, Bearer, Context),
    ?LOG(debug, "Pid: ~p~nKeys: ~p~n", [self(), Keys]),
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

%% Trigger from admin API
trigger_delete_context(Context) ->
    ergw_context_statem:cast(Context, {delete_context, administrative}).

%% TODO: add online charing events
collect_charging_events(OldS0, NewS0) ->
    Fields = ['3GPP-MS-TimeZone',
	      'QoS-Information',
	      '3GPP-RAT-Type',
	      '3GPP-SGSN-Address',
	      '3GPP-SGSN-IPv6-Address',
	      '3GPP-SGSN-MCC-MNC',
	      'User-Location-Info'],
    OldS = maps:merge(maps:with(Fields, OldS0), maps:get('User-Location-Info', OldS0, #{})),
    NewS = maps:merge(maps:with(Fields, NewS0), maps:get('User-Location-Info', NewS0, #{})),

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
	 {'User-Location-Info', 'user-location-info-change'}
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
    Contexts = gtp_context_reg:global_lookup(context_key(Socket, Id)),
    lists:foreach(
      fun({?MODULE, Server}) when is_pid(Server) ->
	      gtp_context:terminate_context(Server);
	 (_) ->
	      ok
      end, Contexts),
    ok;
terminate_colliding_context(_, _) ->
    ok.

terminate_context(Context)
  when is_pid(Context) ->
    try
	ergw_context_statem:call(Context, terminate_context)
    catch
	exit:_ ->
	    ok
    end,
    gtp_context_reg:await_unreg(Context).

info(Pid) ->
    ergw_context_statem:call(Pid, info).

-ifdef(TEST).

ctx_test_cmd(Id, is_alive) ->
    ergw_context_statem:with_context(Id, is_pid(_));
ctx_test_cmd(Id, whereis) ->
    ergw_context_statem:with_context(Id, {?MODULE, _});
ctx_test_cmd(Id, update_context) ->
    ergw_context_statem:call(Id, update_context);
ctx_test_cmd(Id, delete_context) ->
    ergw_context_statem:call(Id, delete_context);
ctx_test_cmd(Id, terminate_context) ->
    ergw_context_statem:with_context(Id, terminate_context(_));
ctx_test_cmd(Id, Cmd) ->
    ergw_context_statem:call(Id, {?TestCmdTag, Cmd}).

-endif.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(ContextDefaults, [{aaa, []}]).
-define(DefaultAAAOpts,
	#{
	  'AAA-Application-Id' => ergw_aaa_provider,
	  'Username' => #{default => <<"ergw">>,
			  from_protocol_opts => true},
	  'Password' => #{default => <<"ergw">>}
	 }).

validate_options(Fun, Opts, Defaults) ->
    ergw_core_config:mandatory_keys([protocol, handler, sockets, node_selection], Opts),
    ergw_core_config:validate_options(Fun, Opts, Defaults ++ ?ContextDefaults).

validate_option(protocol, Value)
  when Value == 'gn' orelse
       Value == 's5s8' orelse
       Value == 's11' ->
    Value;
validate_option(handler, Value) when is_atom(Value) ->
    Value;
validate_option(sockets, Value) when length(Value) /= 0 ->
    Value;
validate_option(node_selection, Value) when length(Value) /= 0 ->
    Value;
validate_option(aaa, Value0) when ?is_opts(Value0) ->
    Value = ergw_core_config:to_map(Value0),
    maps:fold(fun validate_aaa_option/3, ?DefaultAAAOpts, Value);
validate_option(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

validate_aaa_option(Key, AppId, AAA)
  when Key == appid; Key == 'AAA-Application-Id' ->
    AAA#{'AAA-Application-Id' => AppId};
validate_aaa_option(Key, Value0, AAA)
  when (is_list(Value0) orelse is_map(Value0)) andalso
       (Key == 'Username' orelse Key == 'Password') ->
    Value = ergw_core_config:to_map(Value0),
    maps:update_with(Key, maps:fold(validate_aaa_attr_option(Key, _, _, _), _, Value), AAA);

validate_aaa_option(Key, #{mcc := MCC, mnc := MNC}, AAA)
  when Key == '3GPP-GGSN-MCC-MNC' ->
    AAA#{'3GPP-GGSN-MCC-MNC' => {MCC, MNC}};
validate_aaa_option(Key, Value, _AAA) ->
    erlang:error(badarg, [aaa, {Key, Value}]).

validate_aaa_attr_option('Username', default, Default, Attr) ->
    Attr#{default => Default};
validate_aaa_attr_option('Username', from_protocol_opts, Bool, Attr)
  when Bool == true; Bool == false ->
    Attr#{from_protocol_opts => Bool};
validate_aaa_attr_option('Password', default, Default, Attr) ->
    Attr#{default => Default};
validate_aaa_attr_option(Key, Setting, Value, _Attr) ->
    erlang:error(badarg, [aaa_attr, {Key, Setting, Value}]).

%%====================================================================
%% ergw_context API
%%====================================================================

ctx_sx_report(RecordIdOrPid, Report) ->
    ergw_context_statem:call(RecordIdOrPid, {sx, Report}).

ctx_pfcp_timer(RecordIdOrPid, Time, Evs) ->
    ergw_context_statem:call(RecordIdOrPid, {pfcp_timer, Time, Evs}).

%% TEID handling for GTPv1 is brain dead....
port_message(Request, #gtp{version = v2, type = MsgType, tei = 0} = Msg)
  when MsgType == change_notification_request;
       MsgType == change_notification_response ->
    Id = gtp_v2_c:get_context_id(Msg),
    ergw_context:port_message(Id, Request, Msg);

%% same as above for GTPv2
port_message(Request, #gtp{version = v1, type = MsgType, tei = 0} = Msg)
  when MsgType == ms_info_change_notification_request;
       MsgType == ms_info_change_notification_response ->
    Id = gtp_v1_c:get_context_id(Msg),
    ergw_context:port_message(Id, Request, Msg);

port_message(#request{socket = Socket, info = Info} = Request,
		 #gtp{version = Version, tei = 0} = Msg) ->
    case get_handler_if(Socket, Msg) of
	{ok, Interface, InterfaceOpts} ->
	    case ergw_core:get_accept_new() of
		true ->
		    validate_teid(Msg),
		    Server = context_new(Socket, Info, Version, Interface, InterfaceOpts),
		    handle_port_message(Server, Request, Msg, false);

		_ ->
		    gtp_context:generic_error(Request, Msg, no_resources_available),
		    ok
	    end;

	{error, _} = Error ->
	    throw(Error)
    end;
port_message(_Request, _Msg) ->
    throw({error, not_found}).

handle_port_message(Server, Request, Msg, Resent) when is_pid(Server) ->
    if not Resent -> register_request(?MODULE, Server, Request);
       true       -> ok
    end,
    ergw_context_statem:call(Server, {handle_message, Request, Msg, Resent}).

%% ctx_port_message/4
ctx_port_message(RecordIdOrPid, Request, #gtp{type = g_pdu} = Msg, _Resent) ->
    ergw_context_statem:cast(RecordIdOrPid, {handle_pdu, Request, Msg});
ctx_port_message(RecordIdOrPid, Request, Msg, Resent) ->
    ergw_context_statem:with_context(
      RecordIdOrPid, handle_port_message(_, Request, Msg, Resent)).

%%====================================================================
%% gen_statem API
%%====================================================================

init([Socket, Info, Version, Interface,
      #{node_selection := NodeSelect,
	aaa := AAAOpts} = Opts], Data0) ->

    ?LOG(debug, "init(~p)", [[Socket, Info, Interface]]),

    LeftTunnel =
	ergw_gsn_lib:assign_tunnel_teid(
	  local, Info, ergw_gsn_lib:init_tunnel('Access', Info, Socket, Version)),

    Id = ergw_gtp_c_socket:get_uniq_id(Socket),
    RecordId = iolist_to_binary(["GTP-", integer_to_list(Id)]),

    gtp_context_reg:register_name(RecordId, ?MODULE, self()),

    Context = #context{
		 charging_identifier = Id,

		 version           = Version
		},
    Bearer = #{left => #bearer{interface = 'Access'},
	       right => #bearer{interface = 'SGi-LAN'}},
    Data = Data0#{
      record_id      => RecordId,
      context        => Context,
      version        => Version,
      interface      => Interface,
      node_selection => NodeSelect,
      aaa_opts       => AAAOpts,
      left_tunnel    => LeftTunnel,
      bearer         => Bearer},

    try
	Interface:init(Opts, Data)
    catch
	throw:R ->
	    {ok, R}
    end.

handle_event({call, From}, info, _, Data) ->
    {keep_state_and_data, [{reply, From, Data}]};

handle_event({call, From}, {?TestCmdTag, id}, _State, #{record_id := Id}) ->
    {keep_state_and_data, [{reply, From, {ok, Id}}]};
handle_event({call, From}, {?TestCmdTag, pfcp_ctx}, _State, #{pfcp := PCtx}) ->
    {keep_state_and_data, [{reply, From, {ok, PCtx}}]};
handle_event({call, From}, {?TestCmdTag, session}, _State, #{'Session' := Session}) ->
    {keep_state_and_data, [{reply, From, {ok, Session}}]};
handle_event({call, From}, {?TestCmdTag, pcc_rules}, _State, #{pcc := PCC}) ->
    {keep_state_and_data, [{reply, From, {ok, PCC#pcc_ctx.rules}}]};
handle_event({call, From}, {?TestCmdTag, kill}, State, Data) ->
    {next_state, State#{session := shutdown, fsm := busy}, Data, [{reply, From, ok}]};
handle_event({call, From}, {?TestCmdTag, info}, _State, Data) ->
    {keep_state_and_data, [{reply, From, Data}]};

handle_event(state_timeout, idle, #{fsm := init}, Data) ->
    {stop, normal, Data};
handle_event(state_timeout, idle, #{session := SState, fsm := idle}, Data0) ->
    Data = save_session_state(Data0),
    Meta = get_record_meta(Data),
    ergw_context:put_context_record(SState, Meta, Data),
    {stop, normal, Data};

handle_event(state_timeout, stop, #{session := shutdown_initiated} = State, Data) ->
    {next_state, State#{session := shutdown, fsm := busy}, Data};
handle_event(cast, stop, #{session := shutdown}, _Data) ->
    {stop, normal};

handle_event(enter, _OldState, #{fsm := init}, _Data) ->
    {keep_state_and_data, [{state_timeout, ?IDLE_INIT_TIMEOUT, idle}]};
handle_event(enter, _OldState, #{fsm := idle}, _Data) ->
    {keep_state_and_data, [{state_timeout, ?IDLE_TIMEOUT, idle}]};

handle_event(enter, _OldState, #{session := shutdown_initiated}, _Data) ->
    {keep_state_and_data, [{state_timeout, ?SHUTDOWN_TIMEOUT, stop}]};

handle_event(enter, _OldState, #{session := shutdown}, _Data) ->
    %% TODO unregister context ....

    %% this makes stop the last message in the inbox and
    %% guarantees that we process any left over messages first
    ergw_context_statem:cast(self(), stop),
    keep_state_and_data;

handle_event(enter, OldState, State, #{interface := Interface} = Data) ->
    Interface:handle_event(enter, OldState, State, Data);

%% block all (other) calls, casts and infos while waiting
%%  for the result of an asynchronous action
handle_event({call, _}, _, #{async := Async}, _) when map_size(Async) /= 0 ->
    {keep_state_and_data, [postpone]};
handle_event(cast, _, #{async := Async}, _) when map_size(Async) /= 0 ->
    {keep_state_and_data, [postpone]};
handle_event(info, _, #{async := Async}, _) when map_size(Async) /= 0 ->
    {keep_state_and_data, [postpone]};

handle_event(cast, stop, #{session := shutdown}, _Data) ->
    {stop, normal};

handle_event({call, From}, {sx, _}, #{session := SState}, _Data)
  when SState =/= connected ->
    {keep_state_and_data, [{reply, From, {error, not_found}}]};

%% Error Indication Report
handle_event({call, From},
	     {sx, #pfcp{type = session_report_request,
			ie = #{report_type := #report_type{erir = 1},
			       error_indication_report :=
				   #error_indication_report{
				      group =
					  #{f_teid :=
						#f_teid{ipv4 = IP4, ipv6 = IP6} = FTEID0}}}}},
	     State, #{pfcp := PCtx} = Data0) ->
    FTEID = FTEID0#f_teid{ipv4 = ergw_inet:bin2ip(IP4), ipv6 = ergw_inet:bin2ip(IP6)},
    case fteid_tunnel_side(FTEID, Data0) of
	none ->
	    %% late EIR, we already switched to a new peer
	    {keep_state_and_data, [{reply, From, {ok, PCtx}}]};

	Side ->
	    Data = close_context(Side, remote_failure, State, Data0),
	    Actions = [{reply, From, {ok, PCtx}}],
	    {next_state, State#{session := shutdown, fsm := busy}, Data, Actions}
    end;

%% PFCP Session Deleted By the UP function
handle_event({call, From},
	     {sx, #pfcp{type = session_report_request,
			ie = #{pfcpsrreq_flags := #pfcpsrreq_flags{psdbu = 1},
			       report_type := ReportType} = IEs}},
	     State, #{pfcp := PCtx} = Data0) ->
    TermCause =
	case ReportType of
	    #report_type{upir = 1} ->
		up_inactivity_timeout;
	    _ ->
		deleted_by_upf
	end,
    UsageReport = maps:get(usage_report_srr, IEs, undefined),
    Data = ergw_gtp_gsn_lib:close_context('pfcp', TermCause, UsageReport, Data0),
    {next_state, State#{session := shutdown}, Data, [{reply, From, {ok, PCtx}}]};

%% User Plane Inactivity Timer expired
handle_event({call, From},
	     {sx, #pfcp{type = session_report_request,
			ie = #{report_type := #report_type{upir = 1}}}},
	     State, #{pfcp := PCtx} = Data) ->
    gen_statem:reply(From, {ok, PCtx}),
    delete_context(undefined, up_inactivity_timeout, State, Data);

%% Usage Report
handle_event({call, From},
	     {sx, #pfcp{type = session_report_request,
			ie = #{report_type := #report_type{usar = 1},
			       usage_report_srr := UsageReport}}},
	     State, Data) ->
    ergw_context_statem:next(
      session_report_fun(UsageReport, _, _),
      session_report_ok(From, _, _, _),
      session_report_fail(From, _, _, _),
      State, Data);

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

handle_event(info, #aaa_request{procedure = {_, 'ASR'} = Procedure} = Request, State, Data) ->
    ergw_aaa_session:response(Request, ok, #{}, #{}),
    delete_context(undefined, Procedure, State, Data);

handle_event(info, #aaa_request{procedure = {gx, 'RAR'}} = Request,
	     #{session := connected} = State, Data) ->
    ergw_context_statem:next(
      gx_rar_fun(Request, _, _),
      gx_rar_ok(Request, _, _, _),
      gx_rar_fail(Request, _, _, _),
      State, Data);

handle_event(info, #aaa_request{procedure = {gy, 'RAR'},
				events = Events} = Request,
	     #{session := connected} = State, Data) ->
    ergw_aaa_session:response(Request, ok, #{}, #{}),

    %% Triggered CCR.....
    ChargingKeys =
	case proplists:get_value(report_rating_group, Events) of
	    RatingGroups when is_list(RatingGroups) ->
		[{online, RG} || RG <- RatingGroups];
	    _ ->
		undefined
	end,
    ergw_context_statem:next(
      triggered_charging_event_fun(interim, ChargingKeys, _, _),
      triggered_charging_event_ok(_, _, _),
      triggered_charging_event_fail(_, _, _),
      State, Data);

handle_event(info, #aaa_request{procedure = {_, 'RAR'}} = Request, _State, _Data) ->
    ergw_aaa_session:response(Request, {error, unknown_session}, #{}, #{}),
    keep_state_and_data;

handle_event(info, {update_session, Session, Events}, _State, _Data) ->
    ?LOG(debug, "SessionEvents: ~p~n       Events: ~p", [Session, Events]),
    Actions = [{next_event, internal, {session, Ev, Session}} || Ev <- Events],
    {keep_state_and_data, Actions};

handle_event(internal, {session, {update_credits, _} = CreditEv, _}, State, Data) ->
    ergw_context_statem:next(
      update_credits_fun(CreditEv, _, _),
      update_credits_ok(_, _, _),
      update_credits_fail(_, _, _),
      State, Data);

%% Enable AAA to provide reason for session stop
handle_event(internal, {session, {stop, Reason}, _Session}, State, Data) ->
     delete_context(undefined, Reason, State, Data);

handle_event(internal, {session, stop, _Session}, State, Data) ->
     delete_context(undefined, error, State, Data);

handle_event(internal, {session, Ev, _}, _State, _Data) ->
    ?LOG(error, "unhandled session event: ~p", [Ev]),
    keep_state_and_data;

handle_event({call, From}, {pfcp_timer, Time, Evs} = Info, #{session := connected} = State,
	    #{interface := Interface, pfcp := PCtx0} = Data0) ->
    ?LOG(debug, "handle_event ~p:~p", [Interface, Info]),
    gen_statem:reply(From, ok),
    PCtx = ergw_pfcp:timer_expired(Time, PCtx0),
    Data = Data0#{pfcp => PCtx},
    #{validity_time := ChargingKeys} = ergw_gsn_lib:pfcp_to_context_event(Evs),

    ergw_context_statem:next(
      triggered_charging_event_fun(validity_time, ChargingKeys, _, _),
      triggered_charging_event_ok(_, _, _),
      triggered_charging_event_fail(_, _, _),
      State, Data);

handle_event({call, _From}, {pfcp_timer, _, _} = Info, #{session := SState}, _Data) ->
    ?LOG(warning, "unhandled PFCP timer event ~120p in state ~120p", [Info, SState]),
    keep_state_and_data;

handle_event({call, From}, {delete_context, Reason},  #{session := SState} = State, Data)
  when SState == connected; SState == connecting ->
    delete_context(From, Reason, State, Data);
handle_event({call, From}, delete_context,  #{session := SState} = State, Data)
  when SState == connected; SState == connecting ->
    delete_context(From, administrative, State, Data);
handle_event({call, From}, delete_context, #{session := SState}, _Data)
  when SState =:= shutdown; SState =:= shutdown_initiated ->
    {keep_state_and_data, [{reply, From, {ok, ok}}]};
handle_event({call, _From}, delete_context, _State, _Data) ->
    {keep_state_and_data, [postpone]};

handle_event({call, From}, terminate_context, State, Data0) ->
    Data = close_context(left, normal, State, Data0),
    {next_state, State#{session := shutdown, fsm := busy}, Data, [{reply, From, ok}]};

handle_event({call, From}, {peer_down, Path, Notify}, State,
	     #{left_tunnel := #tunnel{path = Path}} = Data0) ->
    Data = close_context(left, peer_restart, Notify, State, Data0),
    {next_state, State#{session := shutdown, fsm := busy}, Data, [{reply, From, ok}]};

handle_event({call, From}, {peer_down, Path, Notify}, State,
	     #{right_tunnel := #tunnel{path = Path}} = Data0) ->
    Data = close_context(right, peer_restart, Notify, State, Data0),
    {next_state, State#{session := shutdown, fsm := busy}, Data, [{reply, From, ok}]};

handle_event({call, From}, {peer_down, _Path, _Notify}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

handle_event(cast, {delete_context, Reason}, State, Data) ->
    delete_context(undefined, Reason, State, Data);

handle_event(info, {'DOWN', _MonitorRef, Type, Pid, _Info}, State,
	     #{pfcp := #pfcp_ctx{node = Pid}} = Data0)
  when Type == process; Type == pfcp ->
    Data = close_context(both, upf_failure, State, Data0),
    {next_state, State#{session := shutdown, fsm := busy}, Data};

handle_event({timeout, context_idle}, stop_session, State, Data) ->
    delete_context(undefined, cp_inactivity_timeout, State, Data);

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
		 #{session := SState}, Data0) ->
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
%%% Monadic Handlers
%%%===================================================================

gx_events_to_pcc_ctx(Evs, Filter, RuleBase, State, #{pcc := PCC0} = Data) ->
    {PCC, Errors} = ergw_pcc_context:gx_events_to_pcc_ctx(Evs, Filter, RuleBase, PCC0),
    statem_m:return(Errors, State, Data#{pcc => PCC}).

gy_events_to_pcc_ctx(Now, Evs, State, #{pcc := PCC0} = Data) ->
    {PCC, Errors} = ergw_pcc_context:gy_events_to_pcc_ctx(Now, Evs, PCC0),
    statem_m:return(Errors, State, Data#{pcc => PCC}).

usage_report_to_charging_events(UsageReport, ChargeEv) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   PCtx <- statem_m:get_data(maps:get(pfcp, _)),
	   return(
	     ergw_pfcp_context:usage_report_to_charging_events(UsageReport, ChargeEv, PCtx))
       ]).

gy_credit_request(Online, #{pcc := PCC0}, State, #{pcc := PCC2} = Data) ->
    GyReqServices = ergw_pcc_context:gy_credit_request(Online, PCC0, PCC2),
    statem_m:return(GyReqServices, State, Data).

gx_rar_fun(#aaa_request{events = Events}, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	     Now = erlang:monotonic_time(),
	     RuleBase = ergw_charging:rulebase(),

	     %% remove PCC rules
	     gx_events_to_pcc_ctx(Events, remove, RuleBase, _, _),
	     {_, UsageReport, _} <- ergw_gtp_gsn_lib:pfcp_session_modification(),

	     %% collect charging data from remove rules
	     ChargeEv = {online, 'RAR'},   %% made up value, not use anywhere...
	     {Online, Offline, Monitor} <-
		 usage_report_to_charging_events(UsageReport, ChargeEv),

	     Session <- statem_m:get_data(maps:get('Session', _)),
	     _ = ergw_gsn_lib:process_accounting_monitor_events(ChargeEv, Monitor, Now, Session),

	     %% install new PCC rules
	     PCCErrors1 <- gx_events_to_pcc_ctx(Events, install, RuleBase, _, _),

	     % send a Online Charging Event (Gy) with the information for the
	     %% removed rules and request credits for the added rules
	     GyReqServices <- gy_credit_request(Online, Data, _, _),

	     GyReqId <- statem_m:return(
			  ergw_context_statem:send_request(
			    fun() ->
				    ergw_gsn_lib:process_online_charging_events_sync(
				      ChargeEv, GyReqServices, Now, Session)
			    end)),
	     GyResult <- statem_m:wait(GyReqId),
	     GyEvs <- statem_m:lift(GyResult),

	     _ = ergw_gsn_lib:process_offline_charging_events(ChargeEv, Offline, Now, Session),

	     %% install the new rules, collect any errors
	     PCCErrors2 <- gy_events_to_pcc_ctx(Now, GyEvs, _, _),
	     ergw_gtp_gsn_lib:pfcp_session_modification(),

	     %% TODO Charging-Rule-Report for successfully installed/removed rules

	     %% return all PCC errors to be include the RAA
	     return(PCCErrors1 ++ PCCErrors2)
	 ]), State, Data).

gx_rar_ok(Request, Errors, State, Data) ->
    ?LOG(debug, "~s: ~p", [?FUNCTION_NAME, Errors]),

    GxReport = ergw_gsn_lib:pcc_events_to_charging_rule_report(Errors),
    ergw_aaa_session:response(Request, ok, GxReport, #{}),
    {next_state, State, Data}.
gx_rar_fail(_Request, Error, State, Data) ->
    ?LOG(error, "gx_rar failed with ~p", [Error]),

    %% TBD: Gx RAR Error reply
    {next_state, State, Data}.

update_credits_fun(CreditEv, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     Now = erlang:monotonic_time(),

	     _PCCErrors <- gy_events_to_pcc_ctx(Now, [CreditEv], _, _),
	     ergw_gtp_gsn_lib:pfcp_session_modification()
	 ]), State, Data).

update_credits_ok(_Res, State, Data) ->
    ?LOG(debug, "~s: ~p", [?FUNCTION_NAME, _Res]),
    {next_state, State, Data}.
update_credits_fail(Error, State, Data) ->
    ?LOG(error, "update_credits failed with ~p", [Error]),
    {next_state, State, Data}.

session_report_fun(UsageReport, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	     Now = erlang:monotonic_time(),
	     ChargeEv = interim,

	     ergw_gtp_gsn_lib:usage_report_m3(ChargeEv, Now, UsageReport)
	 ]), State, Data).

session_report_ok(From, _, State, #{pfcp := PCtx} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    {next_state, State, Data, [{reply, From, {ok, PCtx}}]}.

session_report_fail(From, Reason, State, #{pfcp := PCtx} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    gen_statem:reply(From, {ok, PCtx}),
    delete_context(undefined, Reason, State, Data).

triggered_charging_event_fun(ChargeEv, ChargingKeys, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	     Now = erlang:monotonic_time(),
	     ergw_gtp_gsn_lib:triggered_charging_event_m(ChargeEv, Now, ChargingKeys)
	 ]), State, Data).

triggered_charging_event_ok(_, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    {next_state, State, Data}.

triggered_charging_event_fail(Reason, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    delete_context(undefined, Reason, State, Data).

%%%===================================================================
%%% Internal functions
%%%===================================================================

terminate_cleanup(#{session := SState}, Data) when SState =/= connected ->
    ergw_context:delete_context_record(Data);
terminate_cleanup(_State, _) ->
    ok.

register_request(Handler, Server, #request{key = ReqKey}) ->
    gtp_context_reg:register([ReqKey], Handler, Server).

unregister_request(#request{key = ReqKey}) ->
    gtp_context_reg:unregister([ReqKey], ?MODULE, self()).

get_handler_if(Socket, #gtp{version = v1} = Msg) ->
    gtp_v1_c:get_handler(Socket, Msg);
get_handler_if(Socket, #gtp{version = v2} = Msg) ->
    gtp_v2_c:get_handler(Socket, Msg).

find_sender_teid(#gtp{version = v1} = Msg) ->
    gtp_v1_c:find_sender_teid(Msg);
find_sender_teid(#gtp{version = v2} = Msg) ->
    gtp_v2_c:find_sender_teid(Msg).

context_new(Socket, Info, Version, Interface, InterfaceOpts) ->
    case ergw_context_sup:new(?MODULE, [Socket, Info, Version, Interface, InterfaceOpts]) of
	{ok, Server} when is_pid(Server) ->
	    Server;
	{error, Error} ->
	    throw({error, Error})
    end.

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

%% not used right now
%%
%% socket_teid_filter(#socket{type = Type} = Socket, TEI) ->
%%     socket_teid_filter(Socket, Type, TEI).

%% socket_teid_filter(#socket{name = Name}, Type, TEI) ->
%%     #{'cond' => 'AND',
%%       units =>
%% 	  [
%% 	   #{tag => type, value => Type},
%% 	   #{tag => socket, value => Name},
%% 	   #{tag => local_control_tei, value => TEI}
%% 	  ]}.

context2keys(#tunnel{socket = Socket} = LeftTunnel, Bearer,
	     #context{apn = APN, context_id = ContextId}) ->
    ordsets:from_list(
      tunnel2keys(LeftTunnel)
      ++ [context_key(Socket, ContextId) || ContextId /= undefined]
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

context_key(#socket{name = Name}, Id) ->
    #context_key{socket = Name, id = Id}.

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

close_context(Side, Reason, Notify, State, #{interface := Interface} = Data) ->
    Interface:close_context(Side, Reason, Notify, State, Data).

close_context(Side, Reason, State, Data) ->
    close_context(Side, Reason, active, State, Data).

delete_context(From, Reason, State, #{interface := Interface} = Data) ->
    Interface:delete_context(From, Reason, State, Data).
