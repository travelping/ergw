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
	 start_link/6,
	 send_request/8,
	 send_response/2, send_response/3,
	 send_request/7, resend_request/2,
	 request_finished/1,
	 path_restart/2,
	 terminate_colliding_context/2, terminate_context/1,
	 delete_context/1, trigger_delete_context/1,
	 remote_context_register/3, remote_context_register_new/3,
	 tunnel_reg_update/2,
	 info/1,
	 validate_options/3,
	 validate_option/2,
	 generic_error/3,
	 context_key/2, socket_teid_key/2]).
-export([usage_report_to_accounting/1,
	 collect_charging_events/2]).

-export([usage_report/3, trigger_usage_report/3]).

%% ergw_context callbacks
-export([sx_report/2, port_message/2, port_message/4]).

-ignore_xref([start_link/6,
	      delete_context/1,			% used by Ops through Erlang CLI
	      handle_response/4			% used from callback handler
	      ]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-ifdef(TEST).
-export([tunnel_key/2, test_cmd/2]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("ergw_core_config.hrl").
-include("include/ergw.hrl").

-define(TestCmdTag, '$TestCmd').

-import(ergw_aaa_session, [to_session/1]).

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

%% Used in tests only
delete_context(Context) ->
    gen_statem:call(Context, {delete_context, normal}).

%% Trigger from admin API
trigger_delete_context(Context) ->
    gen_statem:cast(Context, {delete_context, administrative}).

%% TODO: add online charing events
collect_charging_events(OldS0, NewS0) ->
    Fields = ['3GPP-MS-TimeZone',
	      'QoS-Information',
	      '3GPP-RAT-Type',
	      '3GPP-SGSN-Address',
	      '3GPP-SGSN-IPv6-Address',
	      '3GPP-SGSN-MCC-MNC',
	      'User-Location-Info'],
    OldS = maps:merge(maps:with(Fields, OldS0), maps:get('User-Location-Info', OldS0)),
    NewS = maps:merge(maps:with(Fields, NewS0), maps:get('User-Location-Info', NewS0)),

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
	gen_statem:call(Context, terminate_context)
    catch
	exit:_ ->
	    ok
    end,
    gtp_context_reg:await_unreg(Context).

info(Context) ->
    gen_statem:call(Context, info).

-ifdef(TEST).

test_cmd(Pid, Cmd) when is_pid(Pid) ->
    gen_statem:call(Pid, {?TestCmdTag, Cmd}).

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

sx_report(Server, Report) ->
    gen_statem:call(Server, {sx, Report}).

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
		    port_message(Server, Request, Msg, false);

		_ ->
		    gtp_context:generic_error(Request, Msg, no_resources_available),
		    ok
	    end;

	{error, _} = Error ->
	    throw(Error)
    end;
port_message(_Request, _Msg) ->
    throw({error, not_found}).

port_message(Server, Request, #gtp{type = g_pdu} = Msg, _Resent) ->
    gen_statem:cast(Server, {handle_pdu, Request, Msg});
port_message(Server, Request, Msg, Resent) ->
    if not Resent -> register_request(?MODULE, Server, Request);
       true       -> ok
    end,
    gen_statem:cast(Server, {handle_message, Request, Msg, Resent}).

%%====================================================================
%% gen_statem API
%%====================================================================

callback_mode() -> [handle_event_function, state_enter].

init([Socket, Info, Version, Interface,
      #{node_selection := NodeSelect,
	aaa := AAAOpts} = Opts]) ->

    ?LOG(debug, "init(~p)", [[Socket, Info, Interface]]),
    process_flag(trap_exit, true),

    LeftTunnel =
	ergw_gsn_lib:assign_tunnel_teid(
	  local, Info, ergw_gsn_lib:init_tunnel('Access', Info, Socket, Version)),
    Context = #context{
		 charging_identifier = ergw_gtp_c_socket:get_uniq_id(Socket),

		 version           = Version
		},
    Bearer = #{left => #bearer{interface = 'Access'},
	       right => #bearer{interface = 'SGi-LAN'}},
    Data = #{
      context        => Context,
      version        => Version,
      interface      => Interface,
      node_selection => NodeSelect,
      aaa_opts       => AAAOpts,
      left_tunnel    => LeftTunnel,
      bearer         => Bearer},

    Interface:init(Opts, Data).

handle_event({call, From}, info, _, Data) ->
    {keep_state_and_data, [{reply, From, Data}]};

handle_event({call, From}, {?TestCmdTag, pfcp_ctx}, _State, #{pfcp := PCtx}) ->
    {keep_state_and_data, [{reply, From, {ok, PCtx}}]};
handle_event({call, From}, {?TestCmdTag, session}, _State, #{'Session' := Session}) ->
    {keep_state_and_data, [{reply, From, {ok, Session}}]};
handle_event({call, From}, {?TestCmdTag, pcc_rules}, _State, #{pcc := PCC}) ->
    {keep_state_and_data, [{reply, From, {ok, PCC#pcc_ctx.rules}}]};

handle_event(enter, _OldState, shutdown, _Data) ->
    % TODO unregsiter context ....

    %% this makes stop the last message in the inbox and
    %% guarantees that we process any left over messages first
    gen_statem:cast(self(), stop),
    keep_state_and_data;

handle_event(cast, stop, shutdown, _Data) ->
    {stop, normal};

handle_event(enter, OldState, State, #{interface := Interface} = Data) ->
    Interface:handle_event(enter, OldState, State, Data);

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
	    {next_state, shutdown, Data, [{reply, From, {ok, PCtx}}]}
    end;

%% PFCP Session Deleted By the UP function
handle_event({call, From},
	     {sx, #pfcp{type = session_report_request,
			ie = #{pfcpsrreq_flags := #pfcpsrreq_flags{psdbu = 1},
			       report_type := ReportType} = IEs}},
	     _State, #{pfcp := PCtx} = Data0) ->
    TermCause =
	case ReportType of
	    #report_type{upir = 1} ->
		up_inactivity_timeout;
	    _ ->
		deleted_by_upf
	end,
    UsageReport = maps:get(usage_report_srr, IEs, undefined),
    Data = ergw_gtp_gsn_lib:close_context('pfcp', TermCause, UsageReport, Data0),
    {next_state, shutdown, Data, [{reply, From, {ok, PCtx}}]};

%% User Plane Inactivity Timer expired
handle_event({call, From},
	     {sx, #pfcp{type = session_report_request,
			ie = #{report_type := #report_type{upir = 1}}}},
	     State, #{pfcp := PCtx} = Data0) ->
    Data = close_context(both, up_inactivity_timeout, State, Data0),
    {next_state, shutdown, Data, [{reply, From, {ok, PCtx}}]};

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

handle_event(cast, {handle_message, Request, #gtp{} = Msg0, Resent}, State, Data) ->
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

handle_event(info, #aaa_request{procedure = {gx, 'RAR'},
				events = Events} = Request,
	     connected,
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
    {PCtx1, UsageReport, _} =
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
    {PCtx, _, _} =
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
	     connected, Data) ->
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
    {PCtx, _, _} =
	case ergw_pfcp_context:modify_session(PCC, [], #{}, Bearer, PCtx0) of
	    {ok, Result1} -> Result1;
	    {error, Err1} -> throw(Err1#ctx_err{context = Context, tunnel = LeftTunnel})
	end,
    {keep_state, Data#{pfcp := PCtx, pcc := PCC}};

%% Enable AAA to provide reason for session stop
handle_event(internal, {session, {stop, Reason}, _Session}, State, Data) ->
     delete_context(undefined, Reason, State, Data);

handle_event(internal, {session, stop, _Session}, State, Data) ->
     delete_context(undefined, error, State, Data);

handle_event(internal, {session, Ev, _}, _State, _Data) ->
    ?LOG(error, "unhandled session event: ~p", [Ev]),
    keep_state_and_data;

handle_event(info, {timeout, TRef, pfcp_timer} = Info, _State, #{pfcp := PCtx0} = Data0) ->
    ?LOG(debug, "handle_info: ~p", [Info]),
    Now = erlang:monotonic_time(),
    {Evs, PCtx} = ergw_pfcp:timer_expired(TRef, PCtx0),
    Data = Data0#{pfcp => PCtx},
    #{validity_time := ChargingKeys} = ergw_gsn_lib:pfcp_to_context_event(Evs),
    ergw_gtp_gsn_lib:triggered_charging_event(validity_time, Now, ChargingKeys, Data),
    {keep_state, Data};

handle_event({call, From}, {delete_context, Reason}, State, Data)
  when State == connected; State == connecting ->
    delete_context(From, Reason, State, Data);
handle_event({call, From}, delete_context, State, Data)
  when State == connected; State == connecting ->
    delete_context(From, administrative, State, Data);
handle_event({call, From}, delete_context, shutdown, _Data) ->
    {keep_state_and_data, [{reply, From, {ok, ok}}]};
handle_event({call, _From}, delete_context, _State, _Data) ->
    {keep_state_and_data, [postpone]};

handle_event({call, From}, terminate_context, State, Data0) ->
    Data = close_context(left, normal, State, Data0),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, Path}, State,
	     #{left_tunnel := #tunnel{path = Path}} = Data0) ->
    Data = close_context(left, peer_restart, State, Data0),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, Path}, State,
	     #{right_tunnel := #tunnel{path = Path}} = Data0) ->
    Data = close_context(right, peer_restart, State, Data0),
    {next_state, shutdown, Data, [{reply, From, ok}]};

handle_event({call, From}, {path_restart, _Path}, _State, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};

handle_event(cast, {usage_report, URRActions, UsageReport}, _State, Data) ->
    ergw_gtp_gsn_lib:usage_report(URRActions, UsageReport, Data),
    keep_state_and_data;

handle_event(cast, {delete_context, Reason}, State, Data) ->
    delete_context(undefined, Reason, State, Data);

handle_event(info, {'DOWN', _MonitorRef, Type, Pid, _Info}, State,
	     #{pfcp := #pfcp_ctx{node = Pid}} = Data0)
  when Type == process; Type == pfcp ->
    Data = close_context(both, upf_failure, State, Data0),
    {next_state, shutdown, Data};

handle_event({timeout, context_idle}, stop_session, State, Data) ->
    delete_context(undefined, cp_inactivity_timeout, State, Data);

handle_event(Type, Content, State, #{interface := Interface} = Data) ->
    ?LOG(debug, "~w: handle_event: (~p, ~p, ~p)",
		[?MODULE, Type, Content, State]),
    Interface:handle_event(Type, Content, State, Data).

terminate(Reason, State, #{interface := Interface} = Data) ->
    Interface:terminate(Reason, State, Data);
terminate(_Reason, _State, _Data) ->
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Message Handling functions
%%%===================================================================

log_ctx_error(#ctx_err{level = Level, where = {File, Line}, reply = Reply}, St) ->
    ?LOG(debug, #{type => ctx_err, level => Level, file => File,
		  line => Line, reply => Reply, stack => St}).

handle_ctx_error(#ctx_err{level = Level, context = Context} = CtxErr, St, _State, Data) ->
    log_ctx_error(CtxErr, St),
    case Level of
	?FATAL when is_record(Context, context) ->
	    {stop, normal, Data#{context => Context}};
	?FATAL ->
	    {stop, normal, Data};
	_ when is_record(Context, context) ->
	    {keep_state, Data#{context => Context}};
	_ ->
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
    case gtp_context_sup:new(Socket, Info, Version, Interface, InterfaceOpts) of
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

close_context(Side, Reason, State, #{interface := Interface} = Data) ->
    Interface:close_context(Side, Reason, State, Data).

delete_context(From, Reason, State, #{interface := Interface} = Data) ->
    Interface:delete_context(From, Reason, State, Data).

%%====================================================================
%% asynchrounus usage reporting
%%====================================================================

usage_report(Server, URRActions, Report) ->
    gen_statem:cast(Server, {usage_report, URRActions, Report}).

usage_report_fun(Owner, URRActions, PCtx) ->
    case ergw_pfcp_context:query_usage_report(offline, PCtx) of
	{ok, {_, Report, _}} ->
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
