%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context).

-compile({parse_transform, cut}).
-compile({parse_transform, do}).

-export([lookup/2, handle_message/2, handle_packet_in/4,
	 start_link/5,
	 send_request/4, send_request/6, send_response/2,
	 forward_request/4, path_restart/2,
	 delete_context/1,
	 register_remote_context/1, update_remote_context/2,
	 info/1, validate_option/2]).

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
try_handle_message(#request_key{gtp_port = GtpPort} = ReqKey,
	       #gtp{version = v2, type = MsgType, tei = 0} = Msg)
  when MsgType == change_notification_request;
       MsgType == change_notification_response ->
    Keys = gtp_v2_c:get_msg_keys(Msg),
    context_handle_message(lookup_keys(GtpPort, Keys), ReqKey, Msg);

%% same as above for GTPv1
try_handle_message(#request_key{gtp_port = GtpPort} = ReqKey,
	       #gtp{version = v1, type = MsgType, tei = 0} = Msg)
  when MsgType == ms_info_change_notification_request;
       MsgType == ms_info_change_notification_response ->
    Keys = gtp_v1_c:get_msg_keys(Msg),
    context_handle_message(lookup_keys(GtpPort, Keys), ReqKey, Msg);

try_handle_message(#request_key{gtp_port = GtpPort} = ReqKey, #gtp{version = Version, tei = 0} = Msg) ->
    case get_handler(ReqKey, Msg) of
	{ok, Context} when is_pid(Context) ->
	    gen_server:cast(Context, {handle_message, ReqKey, Msg, true});

	{ok, Interface, InterfaceOpts} ->
	    validate_teid(Msg),
	    Context = context_new(GtpPort, Version, Interface, InterfaceOpts),
	    context_handle_message(Context, ReqKey, Msg);

	{error, _} = Error ->
	    throw(Error)
    end;

try_handle_message(#request_key{gtp_port = GtpPort} = ReqKey, #gtp{tei = TEI} = Msg) ->
    context_handle_message(lookup(GtpPort, TEI), ReqKey, Msg).

handle_message(ReqKey, Msg) ->
    try
	try_handle_message(ReqKey, Msg)
    catch
	throw:{error, Error} ->
	    lager:error("handler failed with: ~p", [Error]),
	    generic_error(ReqKey, Msg, Error)
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

send_request(GtpPort, RemoteIP, Msg, ReqId) ->
    gtp_socket:send_request(GtpPort, self(), RemoteIP, Msg, ReqId).

send_request(GtpPort, RemoteIP, T3, N3, Msg, ReqId) ->
    gtp_socket:send_request(GtpPort, self(), RemoteIP, T3, N3, Msg, ReqId).

forward_request(GtpPort, RemoteIP, Msg, ReqId) ->
    gtp_socket:forward_request(GtpPort, self(), RemoteIP, Msg, ReqId).

start_link(GtpPort, Version, Interface, IfOpts, Opts) ->
    gen_server:start_link(?MODULE, [GtpPort, Version, Interface, IfOpts], Opts).

path_restart(Context, Path) ->
    gen_server:cast(Context, {path_restart, Path}).

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

validate_option(handler, Value) when is_atom(Value) ->
    Value;
validate_option(sockets, Value) when is_list(Value) ->
    Value;
validate_option(data_paths, Value) when is_list(Value) ->
    Value;
validate_option(aaa, Value) when is_list(Value) ->
    Value;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%====================================================================
%% gen_server API
%%====================================================================

init([CntlPort, Version, Interface, Opts]) ->
    lager:debug("init(~p)", [[CntlPort, Interface]]),
    process_flag(trap_exit, true),

    DP = hd(proplists:get_value(data_paths, Opts, [])),
    DataPort = gtp_socket_reg:lookup(DP),

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

    AAAopts = aaa_config(proplists:get_value(aaa, Opts, [])),
    lager:debug("AAA Config Opts: ~p", [AAAopts]),

    State = #{
      context   => Context,
      version   => Version,
      interface => Interface,
      aaa_opts  => AAAopts},

    Interface:init(Opts, State).

handle_call(info, _From, State) ->
    {reply, State, State};
handle_call(Request, From, #{interface := Interface} = State) ->
    lager:debug("~w: handle_call: ~p", [?MODULE, Request]),
    Interface:handle_call(Request, From, State).

handle_cast({handle_message, ReqKey, #gtp{} = Msg, Resent}, State) ->
    lager:debug("~w: handle gtp: ~w, ~p",
		[?MODULE, ReqKey#request_key.port, gtp_c_lib:fmt_gtp(Msg)]),

    case validate_message(Msg, State) of
	[] ->
	    handle_request(ReqKey, Msg, Resent, State);

	Missing ->
	    lager:debug("Mis: ~p", [Missing]),
	    handle_error(ReqKey, Msg, {mandatory_ie_missing, hd(Missing)}, State)
    end;

handle_cast(Msg, #{interface := Interface} = State) ->
    lager:debug("~w: handle_cast: ~p", [?MODULE, lager:pr(Msg, ?MODULE)]),
    Interface:handle_cast(Msg, State).

handle_info({ReqId, Request, #gtp{} = Response}, State) ->

    case validate_message(Response, State) of
	[] ->
	    handle_response(ReqId, Request, Response, State);

	Missing ->
	    lager:error("Missing IEs in response message: ~p", [Missing]),
	    %% TODO: handle error
	    %% handle_error({GtpPort, IP, Port}, Msg, {mandatory_ie_missing, hd(Missing)}, State);
	    {noreply, State}
    end;

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

handle_error(#request_key{gtp_port = GtpPort} = ReqKey,
	     #gtp{version = Version, type = MsgType, seq_no = SeqNo}, Reply, State) ->
    Handler = gtp_path:get_handler(GtpPort, Version),
    Response = Handler:build_response({MsgType, Reply}),
    send_response(ReqKey, Response#gtp{seq_no = SeqNo}),
    {noreply, State}.

handle_request(#request_key{gtp_port = GtpPort} = ReqKey,
	       #gtp{version = Version, seq_no = SeqNo} = Msg,
	       Resent, #{interface := Interface} = State0) ->
    lager:debug("GTP~s ~s:~w: ~p",
		[Version, inet:ntoa(ReqKey#request_key.ip), ReqKey#request_key.port, gtp_c_lib:fmt_gtp(Msg)]),

    Handler = gtp_path:get_handler(GtpPort, Version),
    try Interface:handle_request(ReqKey, Msg, Resent, State0) of
	{reply, Reply, State1} ->
	    Response = Handler:build_response(Reply),
	    send_response(ReqKey, Response#gtp{seq_no = SeqNo}),
	    {noreply, State1};

	{stop, Reply, State1} ->
	    Response = Handler:build_response(Reply),
	    send_response(ReqKey, Response#gtp{seq_no = SeqNo}),
	    {stop, normal, State1};

	{error, Reply} ->
	    Response = Handler:build_response(Reply),
	    send_response(ReqKey, Response#gtp{seq_no = SeqNo}),
	    {noreply, State0};

	{noreply, State1} ->
	    {noreply, State1};

	Other ->
	    lager:error("handle_request failed with: ~p", [Other]),
	    {noreply, State0}
    catch
	Class:Error ->
	    Stack  = erlang:get_stacktrace(),
	    lager:error("GTP~p failed with: ~p:~p (~p)", [Version, Class, Error, Stack]),
	    {noreply, State0}
    end.

handle_response(ReqId, Request, Response, #{interface := Interface} = State0) ->
    try Interface:handle_response(ReqId, Response, Request, State0) of
	{stop, State1} ->
	    {stop, normal, State1};

	{noreply, State1} ->
	    {noreply, State1};

	Other ->
	    lager:error("handle_request failed with: ~p", [Other]),
	    {noreply, State0}
    catch
	Class:Error ->
	    Stack  = erlang:get_stacktrace(),
	    lager:error("GTP response failed with: ~p:~p (~p)", [Class, Error, Stack]),
	    {noreply, State0}
    end.

send_response(#request_key{gtp_port = GtpPort} = ReqKey, #gtp{seq_no = SeqNo} = Msg) ->
    %% TODO: handle encode errors
    try
	gtp_context_reg:unregister(GtpPort, ReqKey),
	gtp_socket:send_response(ReqKey, Msg, SeqNo /= 0)
    catch
	Class:Error ->
	    Stack = erlang:get_stacktrace(),
	    lager:error("gtp send failed with ~p:~p (~p) for ~p",
			[Class, Error, Stack, gtp_c_lib:fmt_gtp(Msg)])
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_handler_if(GtpPort, #gtp{version = v1} = Msg) ->
    gtp_v1_c:get_handler(GtpPort, Msg);
get_handler_if(GtpPort, #gtp{version = v2} = Msg) ->
    gtp_v2_c:get_handler(GtpPort, Msg).

get_handler(#request_key{gtp_port = GtpPort} = ReqKey, Msg) ->
    case gtp_context_reg:lookup(GtpPort, ReqKey) of
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

context_handle_message(Context, #request_key{gtp_port = GtpPort} = ReqKey, Msg)
  when is_pid(Context) ->
    gtp_context_reg:register(GtpPort, ReqKey, Context),
    gen_server:cast(Context, {handle_message, ReqKey, Msg, false});
context_handle_message(_Context, _ReqKey, _Msg) ->
    throw({error, not_found}).

generic_error(#request_key{gtp_port = GtpPort} = ReqKey,
	      #gtp{version = Version, type = MsgType, seq_no = SeqNo}, Error) ->
    Handler = gtp_path:get_handler(GtpPort, Version),
    Reply = Handler:build_response({MsgType, Error}),
    gtp_socket:send_response(ReqKey, Reply#gtp{seq_no = SeqNo}, SeqNo /= 0).

validate_teid(#gtp{version = v1, type = MsgType, tei = TEID}) ->
    gtp_v1_c:validate_teid(MsgType, TEID);
validate_teid(#gtp{version = v2, type = MsgType, tei = TEID}) ->
    gtp_v2_c:validate_teid(MsgType, TEID).

validate_message(#gtp{version = v1, ie = IEs} = Msg, State) ->
    Cause = gtp_v1_c:get_cause(IEs),
    validate_ies(Msg, Cause, State);
validate_message(#gtp{version = v2, ie = IEs} = Msg, State) ->
    Cause = gtp_v2_c:get_cause(IEs),
    validate_ies(Msg, Cause, State).

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

aaa_config(Opts) ->
    Default = #{
      'AAA-Application-Id' => ergw_aaa_provider,
      'Username' => #{default => <<"ergw">>,
		      from_protocol_opts => true},
      'Password' => #{default => <<"ergw">>}
     },
    lists:foldl(aaa_config(_, _), Default, Opts).

aaa_config({appid, AppId}, AAA) ->
    AAA#{'AAA-Application-Id' => AppId};
aaa_config({Key, Value}, AAA)
  when is_list(Value) andalso
       (Key == 'Username' orelse
	Key == 'Password') ->
    Attr = maps:get(Key, AAA),
    maps:put(Key, lists:foldl(aaa_attr_config(Key, _, _), Attr, Value), AAA);
aaa_config({Key, Value}, AAA)
  when Key == '3GPP-GGSN-MCC-MNC' ->
    AAA#{'3GPP-GGSN-MCC-MNC' => Value};
aaa_config(Other, AAA) ->
    lager:warning("unknown AAA config setting: ~p", [Other]),
    AAA.

aaa_attr_config('Username', {default, Default}, Attr) ->
    Attr#{default => Default};
aaa_attr_config('Username', {from_protocol_opts, Bool}, Attr)
  when Bool == true; Bool == false ->
    Attr#{from_protocol_opts => Bool};
aaa_attr_config('Password', {default, Default}, Attr) ->
    Attr#{default => Default};
aaa_attr_config(Key, Value, Attr) ->
    lager:warning("unknown AAA attribute value: ~w => ~p", [Key, Value]),
    Attr.
