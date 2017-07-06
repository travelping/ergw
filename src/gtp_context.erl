%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context).

-compile({parse_transform, cut}).
-compile({parse_transform, do}).

-export([lookup/2, handle_message/2, handle_packet_in/4, handle_response/4,
	 start_link/5,
	 send_request/4, send_request/6, send_response/2,
	 forward_request/5, path_restart/2,
	 delete_context/1,
	 register_remote_context/1, update_remote_context/2,
	 enforce_restrictions/2,
	 info/1,
	 validate_options/3,
	 validate_option/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-define('Tunnel Endpoint Identifier Data I',	{tunnel_endpoint_identifier_data_i, 0}).

%%====================================================================
%% API
%%====================================================================

lookup(GtpPort, TEI) ->
    gtp_context_reg:lookup(GtpPort, TEI).

%% TEID handling for GTPv1 is brain dead....
try_handle_message(#request{gtp_port = GtpPort} = Request,
	       #gtp{version = v2, type = MsgType, tei = 0} = Msg)
  when MsgType == change_notification_request;
       MsgType == change_notification_response ->
    Keys = gtp_v2_c:get_msg_keys(Msg),
    context_handle_message(lookup_keys(GtpPort, Keys), Request, Msg);

%% same as above for GTPv1
try_handle_message(#request{gtp_port = GtpPort} = Request,
	       #gtp{version = v1, type = MsgType, tei = 0} = Msg)
  when MsgType == ms_info_change_notification_request;
       MsgType == ms_info_change_notification_response ->
    Keys = gtp_v1_c:get_msg_keys(Msg),
    context_handle_message(lookup_keys(GtpPort, Keys), Request, Msg);

try_handle_message(#request{gtp_port = GtpPort} = Request, #gtp{version = Version, tei = 0} = Msg) ->
    case get_handler(Request, Msg) of
	{ok, Context} when is_pid(Context) ->
	    gen_server:cast(Context, {handle_message, Request, Msg, true});

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
    context_handle_message(lookup(GtpPort, TEI), Request, Msg).

handle_message(Request, Msg) ->
    proc_lib:spawn(fun() -> q_handle_message(Request, Msg) end),
    ok.

q_handle_message(Request, Msg) ->
    Q = load_class(Msg),
    try
	jobs:run(Q, fun() -> try_handle_message(Request, Msg) end)
    catch
	throw:{error, Error} ->
	    lager:error("handler failed with: ~p", [Error]),
	    generic_error(Request, Msg, Error);
	error:Error = rejected ->
	    lager:debug("handler failed with: ~p", [Error]),
	    generic_error(Request, Msg, Error)
    end.

handle_packet_in(GtpPort, IP, Port,
		 #gtp{type = error_indication,
		      ie = #{?'Tunnel Endpoint Identifier Data I' :=
				 #tunnel_endpoint_identifier_data_i{tei = TEI}}} = Msg) ->
    lager:debug("handle_packet_in: ~p", [lager:pr(Msg, ?MODULE)]),
    case lookup(GtpPort, {remote_data, IP, TEI}) of
	Context when is_pid(Context) ->
	    gen_server:cast(Context, {packet_in, GtpPort, IP, Port, Msg});

	_ ->
	    lager:error("handle_packet_in: didn't find ~p, ~p, ~p)", [GtpPort, IP, TEI]),
	    ok
    end.

handle_response(Context, ReqInfo, Request, Response) ->
    gen_server:cast(Context, {handle_response, ReqInfo, Request, Response}).

send_request(GtpPort, RemoteIP, Msg, ReqInfo) ->
    CbInfo = {?MODULE, handle_response, [self(), ReqInfo, Msg]},
    gtp_socket:send_request(GtpPort, RemoteIP, Msg, CbInfo).

send_request(GtpPort, RemoteIP, T3, N3, Msg, ReqInfo) ->
    CbInfo = {?MODULE, handle_response, [self(), ReqInfo, Msg]},
    gtp_socket:send_request(GtpPort, RemoteIP, T3, N3, Msg, CbInfo).

forward_request(GtpPort, RemoteIP, Msg, ReqId, ReqInfo) ->
    CbInfo = {?MODULE, handle_response, [self(), ReqInfo, Msg]},
    gtp_socket:forward_request(GtpPort, RemoteIP, Msg, ReqId, CbInfo).

start_link(GtpPort, Version, Interface, IfOpts, Opts) ->
    gen_server:start_link(?MODULE, [GtpPort, Version, Interface, IfOpts], Opts).

path_restart(Context, Path) ->
    jobs:run(path_restart, fun() -> gen_server:call(Context, {path_restart, Path}) end).

register_remote_context(#context{
			   control_port       = CntlPort,
			   remote_control_ip  = CntlIP,
			   remote_control_tei = CntlTEI,
			   data_port          = DataPort,
			   remote_data_ip     = DataIP,
			   remote_data_tei    = DataTEI,
			   imsi               = IMSI,
			   imei               = IMEI}) ->
    gtp_context_reg:register(CntlPort, {remote_control, CntlIP, CntlTEI}),
    gtp_context_reg:register(DataPort, {remote_data,    DataIP, DataTEI}),
    if IMSI /= undefiend ->
	    gtp_context_reg:register(CntlPort, {imsi, IMSI});
       true ->
	    ok
    end,
    if IMEI /= undefiend ->
	    gtp_context_reg:register(CntlPort, {imei, IMEI});
       true ->
	    ok
    end,
    ok.

update_remote_control_context(#context{control_port = OldCntlPort, remote_control_ip = OldCntlIP, remote_control_tei = OldCntlTEI},
			      #context{control_port = NewCntlPort, remote_control_ip = NewCntlIP, remote_control_tei = NewCntlTEI})
  when OldCntlPort =/= OldCntlIP; OldCntlTEI =/= NewCntlPort; NewCntlIP =/= NewCntlTEI ->
    gtp_context_reg:unregister(OldCntlPort, {remote_control, OldCntlIP, OldCntlTEI}),
    gtp_context_reg:register(NewCntlPort, {remote_control, NewCntlIP, NewCntlTEI}),
    ok.

update_remote_data_context(#context{data_port = OldDataPort, remote_data_ip = OldDataIP, remote_data_tei = OldDataTEI},
			   #context{data_port = NewDataPort, remote_data_ip = NewDataIP, remote_data_tei = NewDataTEI})
  when OldDataPort =/= OldDataIP; OldDataTEI =/= NewDataPort; NewDataIP =/= NewDataTEI ->
    gtp_context_reg:unregister(OldDataPort, {remote_data, OldDataIP, OldDataTEI}),
    gtp_context_reg:register(NewDataPort, {remote_data, NewDataIP, NewDataTEI}),
    ok.

update_remote_context(OldContext, NewContext) ->
    update_remote_control_context(OldContext, NewContext),
    update_remote_data_context(OldContext, NewContext).

delete_context(Context) ->
    gen_server:call(Context, delete_context).

info(Context) ->
    gen_server:call(Context, info).

enforce_restrictions(Msg, #context{restrictions = Restrictions} = Context) ->
    lists:foreach(fun(R) -> enforce_restriction(Context, Msg, R) end, Restrictions).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(ContextDefaults, [{data_paths, undefined},
			  {aaa,        []}]).

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
       Value == 's5s8' ->
    Value;
validate_option(handler, Value) when is_atom(Value) ->
    Value;
validate_option(sockets, Value) when is_list(Value) ->
    Value;
validate_option(data_paths, Value) when is_list(Value) ->
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
      #{data_paths := DPs, aaa := AAAOpts} = Opts]) ->

    lager:debug("init(~p)", [[CntlPort, Interface]]),
    process_flag(trap_exit, true),

    DataPort = gtp_socket_reg:lookup(hd(DPs)),

    {ok, CntlTEI} = gtp_c_lib:alloc_tei(CntlPort),
    {ok, DataTEI} = gtp_c_lib:alloc_tei(DataPort),

    Context = #context{
		 version           = Version,
		 control_interface = Interface,
		 control_port      = CntlPort,
		 local_control_tei = CntlTEI,
		 data_port         = DataPort,
		 local_data_tei    = DataTEI
		},

    State = #{
      context   => Context,
      version   => Version,
      interface => Interface,
      aaa_opts  => AAAOpts},

    Interface:init(Opts, State).

handle_call(info, _From, State) ->
    {reply, State, State};
handle_call(Request, From, #{interface := Interface} = State) ->
    lager:debug("~w: handle_call: ~p", [?MODULE, Request]),
    Interface:handle_call(Request, From, State).

handle_cast({handle_message, Request, #gtp{} = Msg, Resent}, State) ->
    lager:debug("handle gtp request: ~w, ~p",
		[Request#request.port, gtp_c_lib:fmt_gtp(Msg)]),
    handle_request(Request, Msg, Resent, State);

handle_cast({handle_response, ReqInfo, Request, Response},
	    #{interface := Interface} = State0) ->
    lager:debug("handle gtp response: ~p", [gtp_c_lib:fmt_gtp(Response)]),
    try
	case Response of
	    #gtp{} ->
		validate_message(Response, State0);
	    _ when is_atom(Response) ->
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


send_response(#request{gtp_port = GtpPort} = Request, #gtp{seq_no = SeqNo} = Msg) ->
    %% TODO: handle encode errors
    try
	gtp_context_reg:unregister(GtpPort, Request),
	gtp_socket:send_response(Request, Msg, SeqNo /= 0)
    catch
	Class:Error ->
	    Stack = erlang:get_stacktrace(),
	    lager:error("gtp send failed with ~p:~p (~p) for ~p",
			[Class, Error, Stack, gtp_c_lib:fmt_gtp(Msg)])
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

enforce_restriction(Context, #gtp{version = Version}, {Version, false}) ->
    throw(#ctx_err{level = ?FATAL,
		   reply = {version_not_supported, []},
		   context = Context});
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

get_handler(#request{gtp_port = GtpPort} = Request, Msg) ->
    case gtp_context_reg:lookup(GtpPort, Request) of
	Context when is_pid(Context) ->
	    {ok, Context};
	_ ->
	    get_handler_if(GtpPort, Msg)
    end.

lookup_keys(_, []) ->
    throw({error, not_found});
lookup_keys(GtpPort, [H|T]) ->
    case gtp_context_reg:lookup(GtpPort, H) of
	Pid when is_pid(Pid) ->
	    Pid;
	_ ->
	    gtp_context_reg:lookup(GtpPort, T)
    end.

context_new(GtpPort, Version, Interface, InterfaceOpts) ->
    case gtp_context_sup:new(GtpPort, Version, Interface, InterfaceOpts) of
	{ok, Context} ->
	    Context;
	{error, Error} ->
	    throw({error, Error})
    end.

context_handle_message(Context, #request{gtp_port = GtpPort} = Request, Msg)
  when is_pid(Context) ->
    gtp_context_reg:register(GtpPort, Request, Context),
    gen_server:cast(Context, {handle_message, Request, Msg, false});
context_handle_message(_Context, _Request, _Msg) ->
    throw({error, not_found}).

generic_error(#request{gtp_port = GtpPort} = Request,
	      #gtp{version = Version, type = MsgType, seq_no = SeqNo}, Error) ->
    Handler = gtp_path:get_handler(GtpPort, Version),
    Reply = Handler:build_response({MsgType, 0, Error}),
    gtp_socket:send_response(Request, Reply#gtp{seq_no = SeqNo}, SeqNo /= 0).

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
	    throw(#ctx_err{level = ?WARNING,
			   reply = [{mandatory_ie_missing, hd(Missing)}]})
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
