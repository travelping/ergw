%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context).

-compile({parse_transform, cut}).
-compile({parse_transform, do}).

-export([handle_message/2, try_handle_message/2, context_handle_message/3,
	 session_report/2, handle_response/4,
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
	 validate_option/2]).
-export([usage_report_to_accounting/1]).
-export([session_events/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-ifdef(TEST).
-export([query_usage_report/1]).
-endif.

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-import(ergw_aaa_session, [to_session/1]).

-define('Tunnel Endpoint Identifier Data I',	{tunnel_endpoint_identifier_data_i, 0}).

-record(trigger, {key, type, level, value, opts, tref}).

%%====================================================================
%% API
%%====================================================================

%% TEID handling for GTPv1 is brain dead....
try_handle_message(#request{gtp_port = GtpPort} = Request,
	       #gtp{version = v2, type = MsgType, tei = 0} = Msg)
  when MsgType == change_notification_request;
       MsgType == change_notification_response ->
    Keys = gtp_v2_c:get_msg_keys(Msg),
    context_handle_message(gtp_context_reg:match_keys(GtpPort, Keys), Request, Msg);

%% same as above for GTPv2
try_handle_message(#request{gtp_port = GtpPort} = Request,
	       #gtp{version = v1, type = MsgType, tei = 0} = Msg)
  when MsgType == ms_info_change_notification_request;
       MsgType == ms_info_change_notification_response ->
    Keys = gtp_v1_c:get_msg_keys(Msg),
    context_handle_message(gtp_context_reg:match_keys(GtpPort, Keys), Request, Msg);

try_handle_message(#request{gtp_port = GtpPort} = Request,
		   #gtp{version = Version, tei = 0} = Msg) ->
    case get_handler_if(GtpPort, Msg) of
	{ok, Interface, InterfaceOpts} ->
	    case ergw:get_accept_new() of
		true -> ok;
		_ ->
		    throw({error, no_resources_available})
	    end,
	    validate_teid(Msg),
	    Context = context_new(GtpPort, Version, Interface, InterfaceOpts),
	    context_handle_message(Context, Request, Msg);

	{error, _} = Error ->
	    throw(Error)
    end;

try_handle_message(#request{gtp_port = GtpPort} = Request, #gtp{tei = TEI} = Msg) ->
    context_handle_message(gtp_context_reg:lookup_teid(GtpPort, TEI), Request, Msg).

handle_message(Request, Msg) ->
    proc_lib:spawn(fun() -> q_handle_message(Request, Msg) end),
    ok.

q_handle_message(Request, Msg0) ->
    Queue = load_class(Msg0),
    try
	jobs:run(
	  Queue,
	  fun() ->
		  Msg = gtp_packet:decode_ies(Msg0),
		  case lookup_request(Request) of
		      Context when is_pid(Context) ->
			  gen_server:cast(Context, {handle_message, Request, Msg, true});
		      _ ->
			  try_handle_message(Request, Msg)
		  end
	  end)
    catch
	throw:{error, Error} ->
	    lager:error("handler failed with: ~p", [Error]),
	    generic_error(Request, Msg0, Error);
	error:Error = rejected ->
	    lager:debug("handler failed with: ~p", [Error]),
	    generic_error(Request, Msg0, Error)
    end.

session_report(ReqKey, #pfcp{version = v1, seid = SEID} = Report) ->
    lager:debug("Session Report: ~p", [Report]),
    case gtp_context_reg:lookup_seid(SEID) of
	Context when is_pid(Context) ->
	    Context ! {ReqKey, Report},
	    ok;

	_ ->
	    lager:error("Session Report: didn't find ~p", [SEID]),
	    {error, not_found}
    end.

handle_response(Context, ReqInfo, Request, Response) ->
    gen_server:cast(Context, {handle_response, ReqInfo, Request, Response}).

send_request(GtpPort, DstIP, DstPort, T3, N3, Msg, ReqInfo) ->
    CbInfo = {?MODULE, handle_response, [self(), ReqInfo, Msg]},
    ergw_gtp_c_socket:send_request(GtpPort, DstIP, DstPort, T3, N3, Msg, CbInfo).

send_request(GtpPort, DstIP, DstPort, ReqId, Msg, ReqInfo) ->
    CbInfo = {?MODULE, handle_response, [self(), ReqInfo, Msg]},
    ergw_gtp_c_socket:send_request(GtpPort, DstIP, DstPort, ReqId, Msg, CbInfo).

resend_request(GtpPort, ReqId) ->
    ergw_gtp_c_socket:resend_request(GtpPort, ReqId).

start_link(GtpPort, Version, Interface, IfOpts, Opts) ->
    gen_server:start_link(?MODULE, [GtpPort, Version, Interface, IfOpts], Opts).

path_restart(Context, Path) ->
    jobs:run(path_restart, fun() -> gen_server:call(Context, {path_restart, Path}) end).

remote_context_register(Context) ->
    gtp_context_reg:register(Context).

remote_context_register_new(Context) ->
    case gtp_context_reg:register_new(Context) of
	ok ->
	    ok;
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, Context))
    end.

remote_context_update(OldContext, NewContext) ->
    gtp_context_reg:update(OldContext, NewContext).

delete_context(Context) ->
    gen_server:call(Context, delete_context).

%% 3GPP TS 29.060 (GTPv1-C) and TS 29.274 (GTPv2-C) have language that states
%% that when an incomming Create PDP Context/Create Session requests collides
%% with an existing context based on a IMSI, Bearer, Protocol tuple, that the
%% preexisting context should be deleted locally. This function does that.
terminate_colliding_context(#context{control_port = GtpPort, context_id = Id})
  when Id /= undefined ->
    case gtp_context_reg:lookup_key(GtpPort, Id) of
	Context when is_pid(Context) ->
	    gtp_context:terminate_context(Context);
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

session_events(Events, Context) ->
    lists:foldr(fun session_event/2, Context, Events).

%%%===================================================================
%%% Options Validation
%%%===================================================================

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
%% gen_server API
%%====================================================================

init([CntlPort, Version, Interface,
      #{node_selection := NodeSelect, aaa := AAAOpts} = Opts]) ->

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
	    Stack  = erlang:get_stacktrace(),
	    lager:error("GTP response failed with: ~p:~p (~p)", [Class, Error, Stack]),
	    {noreply, State0}
    end;

handle_cast(Msg, #{interface := Interface} = State) ->
    lager:debug("~w: handle_cast: ~p", [?MODULE, lager:pr(Msg, ?MODULE)]),
    Interface:handle_cast(Msg, State).

%%====================================================================

handle_info({timeout, TRef, {trigger, K}},
	    #{context := #context{triggers = Triggers0} = Context} = State0) ->
    State =
	case maps:get(K, Triggers0, undefined) of
	    #trigger{tref = TRef} = T ->
		lager:info("OK Trigger: ~p, ~p, ~p", [TRef, K, Triggers0]),
		State1 = trigger_action(T, State0),
		Triggers = trigger_opts(T, Triggers0),
		State1#{context => Context#context{triggers = Triggers}};
	    _ ->
		lager:error("Spurious Trigger: ~p, ~p, ~p", [TRef, K, Triggers0]),
		State0
	end,
    {noreply, State};

handle_info({update_session, _Session, Events},
	    #{context := Context0} = State) ->
    Context = session_events(Events, Context0),
    {noreply, State#{context => Context}};

%%====================================================================

handle_info(Info, #{interface := Interface} = State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
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
	    Stack  = erlang:get_stacktrace(),
	    lager:error("GTP~p failed with: ~p:~p (~p)", [Version, Class, Error, Stack]),
	    {noreply, State0}
    end.


send_response(Request, #gtp{seq_no = SeqNo} = Msg) ->
    %% TODO: handle encode errors
    try
	request_finished(Request),
	ergw_gtp_c_socket:send_response(Request, Msg, SeqNo /= 0)
    catch
	Class:Error ->
	    Stack = erlang:get_stacktrace(),
	    lager:error("gtp send failed with ~p:~p (~p) for ~p",
			[Class, Error, Stack, gtp_c_lib:fmt_gtp(Msg)])
    end.

request_finished(Request) ->
    unregister_request(Request).

%%%===================================================================
%%% Internal functions
%%%===================================================================

register_request(Context, #request{key = ReqKey, gtp_port = GtpPort}) ->
    gtp_context_reg:register(GtpPort, ReqKey, Context).

unregister_request(#request{key = ReqKey, gtp_port = GtpPort}) ->
    gtp_context_reg:unregister(GtpPort, ReqKey).

lookup_request(#request{key = ReqKey, gtp_port = GtpPort}) ->
    gtp_context_reg:lookup_key(GtpPort, ReqKey).

enforce_restriction(Context, #gtp{version = Version}, {Version, false}) ->
    throw(?CTX_ERR(?FATAL, {version_not_supported, []}, Context));
enforce_restriction(_Context, _Msg, _Restriction) ->
    ok.

get_handler_if(GtpPort, #gtp{version = v1} = Msg) ->
    gtp_v1_c:get_handler(GtpPort, Msg);
get_handler_if(GtpPort, #gtp{version = v2} = Msg) ->
    gtp_v2_c:get_handler(GtpPort, Msg).

load_class(#gtp{version = v1} = Msg) ->
    gtp_v1_c:load_class(Msg);
load_class(#gtp{version = v2} = Msg) ->
    gtp_v2_c:load_class(Msg).

context_new(GtpPort, Version, Interface, InterfaceOpts) ->
    case gtp_context_sup:new(GtpPort, Version, Interface, InterfaceOpts) of
	{ok, Context} ->
	    Context;
	{error, Error} ->
	    throw({error, Error})
    end.

context_handle_message(Context, Request, #gtp{type = g_pdu} = Msg)
  when is_pid(Context) ->
    gen_server:cast(Context, {handle_pdu, Request, Msg});
context_handle_message(Context, Request, Msg)
  when is_pid(Context) ->
    register_request(Context, Request),
    gen_server:cast(Context, {handle_message, Request, Msg, false});
context_handle_message([Context | _], Request, Msg) ->
    context_handle_message(Context, Request, Msg);
context_handle_message(_Context, _Request, _Msg) ->
    throw({error, not_found}).

generic_error(#request{gtp_port = GtpPort} = Request,
	      #gtp{version = Version, type = MsgType, seq_no = SeqNo}, Error) ->
    Handler = gtp_path:get_handler(GtpPort, Version),
    Reply = Handler:build_response({MsgType, 0, Error}),
    ergw_gtp_c_socket:send_response(Request, Reply#gtp{seq_no = SeqNo}, SeqNo /= 0).

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

add_trigger(_, {time, _, 0, _}, Triggers) ->
    Triggers;
add_trigger(K, {time, Level, Value, Opts}, Triggers) ->
    TRef = erlang:start_timer(Value, self(), {trigger, K}),
    Triggers#{K => #trigger{key = K, type = time, level = Level,
			    value = Value, opts = Opts, tref = TRef}}.

del_trigger(K, {time, _, _, _}, Triggers) ->
    case Triggers of
	#{K := #trigger{tref = TRef}} ->
	    erlang:cancel_timer(TRef, [{async, true}]),
	    maps:without(K, Triggers);
	_ ->
	    Triggers
    end.

set_trigger(K, V, Triggers) ->
    add_trigger(K, V, del_trigger(K, V, Triggers)).

session_event({add, {K, {time, _, _, _} = T}}, #context{triggers = Triggers} = Context) ->
    Context#context{triggers = add_trigger(K, T, Triggers)};
session_event({del, {K, {time, _, _, _} = T}}, #context{triggers = Triggers} = Context) ->
    Context#context{triggers = del_trigger(K, T, Triggers)};
session_event({set, {K, {time, _, _, _} = T}}, #context{triggers = Triggers} = Context) ->
    Context#context{triggers = set_trigger(K, T, Triggers)};
session_event(_, Context) ->
    Context.

query_usage_report(Context) ->
    case ergw_gsn_lib:query_usage_report(Context) of
	#pfcp{type = session_modification_response,
	      ie = #{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} = IEs} ->
	    to_session(
	      usage_report_to_accounting(
		maps:get(usage_report_smr, IEs, undefined)));
	_Other ->
	    lager:warning("Gn/Gp: got unexpected Query response: ~p",
			  [lager:pr(_Other, ?MODULE)]),
	    #{}
    end.

trigger_action(#trigger{key = Key, type = time, level = 'IP-CAN', opts = EvOpts} = _Trigger,
	       #{context := Context, 'Session' := Session} = State) ->
    lager:info("TIME Trigger Action: ~p", [lager:pr(_Trigger, ?MODULE)]),
    SessionOpts = query_usage_report(Context),
    lager:info("URR: ~p", [SessionOpts]),
    ergw_aaa_session:event(Session, Key, EvOpts, SessionOpts),
    State;
trigger_action(_Trigger, State) ->
    lager:info("Trigger Action: ~p", [lager:pr(_Trigger, ?MODULE)]),
    State.

trigger_opts(#trigger{key = K, value = Value, opts = Opts} = T, Triggers) ->
    case proplists:get_bool('recurring', Opts) of
	true ->
	    TRef = erlang:start_timer(Value, self(), {trigger, K}),
	    Triggers#{K => T#trigger{tref = TRef}};
	_ ->
	    maps:without(K, Triggers)
    end.
