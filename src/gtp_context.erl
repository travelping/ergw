%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context).

-compile({parse_transform, do}).

-export([lookup/2, handle_message/4, start_link/5,
	 send_request/4, send_request/6, send_response/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

%%====================================================================
%% API
%%====================================================================

lookup(GtpPort, TEI) ->
    gtp_context_reg:lookup(GtpPort, TEI).

handle_message(IP, Port, GtpPort, #gtp{version = Version, tei = 0} = Msg) ->
    case get_handler(IP, GtpPort, Msg) of
	{ok, Context} when is_pid(Context) ->
	    gen_server:cast(Context, {handle_message, GtpPort, IP, Port, Msg, true});

	{ok, Interface, InterfaceOpts} ->
	    do([error_m ||
		   Context <- gtp_context_sup:new(GtpPort, Version, Interface, InterfaceOpts),
		   do_handle_message(Context, GtpPort, IP, Port, Msg)
	       ]);

	{error, Error} ->
	    generic_error(IP, Port, GtpPort, Msg, Error);
	_ ->
	    %% TODO: correct error message
	    generic_error(IP, Port, GtpPort, Msg, not_found)
    end;

handle_message(IP, Port, GtpPort, #gtp{tei = TEI} = Msg) ->
    case lookup(GtpPort, TEI) of
	Context when is_pid(Context) ->
	    do_handle_message(Context, GtpPort, IP, Port, Msg);

	_ ->
	    generic_error(IP, Port, GtpPort, Msg, not_found)
    end.

send_request(GtpPort, RemoteIP, Msg, ReqId) ->
    gtp_socket:send_request(GtpPort, self(), RemoteIP, Msg, ReqId).

send_request(GtpPort, RemoteIP, T3, N3, Msg, ReqId) ->
    gtp_socket:send_request(GtpPort, self(), RemoteIP, T3, N3, Msg, ReqId).

start_link(GtpPort, Version, Interface, IfOpts, Opts) ->
    gen_server:start_link(?MODULE, [GtpPort, Version, Interface, IfOpts], Opts).

%%====================================================================
%% gen_server API
%%====================================================================

init([GtpPort, Version, Interface, Opts]) ->
    lager:debug("init(~p)", [[GtpPort, Interface]]),

    DP = hd(proplists:get_value(data_paths, Opts, [])),
    GtpDP = gtp_socket_reg:lookup(DP),

    {ok, TEI} = gtp_c_lib:alloc_tei(GtpPort),

    State = #{
      gtp_port  => GtpPort,
      gtp_dp_port => GtpDP,
      version   => Version,
      handler   => gtp_path:get_handler(GtpPort, Version),
      interface => Interface,
      tei       => TEI},

    Interface:init(Opts, State).

handle_call(Request, _From, State) ->
    lager:warning("handle_call: ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({handle_message, GtpPort, IP, Port, #gtp{type = MsgType, ie = IEs} = Msg, Resent},
	    #{interface := Interface} = State) ->
    lager:debug("~w: handle gtp: ~w, ~p",
		[?MODULE, Port, gtp_c_lib:fmt_gtp(Msg)]),

    From = {GtpPort, IP, Port},
    Spec = Interface:request_spec(MsgType),
    {Req, Missing} = gtp_c_lib:build_req_record(MsgType, Spec, IEs),
    lager:debug("Mis: ~p", [Missing]),

    if Missing /= [] ->
	    handle_error(From, Msg, {mandatory_ie_missing, hd(Missing)}, State);
       true ->
	    handle_request(From, Msg, Req, Resent, State)
    end;

handle_cast(Msg, State) ->
    lager:error("~w: handle_cast: ~p", [?MODULE, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info({ReqId, Request, Response = #gtp{type = MsgType, ie = IEs}},
	    #{interface := Interface} = State) ->
    Spec = Interface:request_spec(MsgType),
    {RespRec, Missing} = gtp_c_lib:build_req_record(MsgType, Spec, IEs),
    lager:debug("Mis: ~p", [Missing]),

    if Missing /= [] ->
	    %% TODO: handle error
	    %% handle_error({GtpPort, IP, Port}, Msg, {mandatory_ie_missing, hd(Missing)}, State);
	    ok;
       true ->
	    handle_response(ReqId, Request, Response, RespRec, State)
    end;

handle_info(Info, State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Message Handling functions
%%%===================================================================

handle_error(From, #gtp{type = MsgType, seq_no = SeqNo}, Reply,
	     #{handler := Handler} = State) ->
    Response = Handler:build_response({MsgType, Reply}),
    send_response(From, Response#gtp{seq_no = SeqNo}),
    {noreply, State}.

handle_request(From = {_GtpPort, IP, Port}, #gtp{version = Version, seq_no = SeqNo} = Msg, Req, Resent,
	        #{handler := Handler, interface := Interface} = State0) ->
    lager:debug("GTP~s ~s:~w: ~p",
		[Version, inet:ntoa(IP), Port, gtp_c_lib:fmt_gtp(Msg)]),

    try Interface:handle_request(From, Msg, Req, Resent, State0) of
	{reply, Reply, State1} ->
	    Response = Handler:build_response(Reply),
	    send_response(From, Response#gtp{seq_no = SeqNo}),
	    {noreply, State1};

	{stop, Reply, State1} ->
	    Response = Handler:build_response(Reply),
	    send_response(From, Response#gtp{seq_no = SeqNo}),
	    {stop, normal, State1};

	{error, Reply} ->
	    Response = Handler:build_response(Reply),
	    send_response(From, Response#gtp{seq_no = SeqNo}),
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

handle_response(ReqId, Request, Response, RespRec, #{interface := Interface} = State0) ->
    try Interface:handle_response(ReqId, Response, RespRec, Request, State0) of
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

send_response({GtpPort, IP, Port}, #gtp{seq_no = SeqNo} = Msg) ->
    %% TODO: handle encode errors
    try
	gtp_context_reg:unregister(GtpPort, {seq, IP, SeqNo}),
	lager:debug("gtp_context send ~s to ~w:~w: ~p", [GtpPort#gtp_port.type, IP, Port, Msg]),
	gtp_socket:send_response(GtpPort, IP, Port, Msg)
    catch
	Class:Error ->
	    Stack  = erlang:get_stacktrace(),
	    lager:error("gtp send failed with ~p:~p (~p)", [Class, Error, Stack])
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_handler_if(GtpPort, #gtp{version = v1} = Msg) ->
    gtp_v1_c:get_handler(GtpPort, Msg);
get_handler_if(GtpPort, #gtp{version = v2} = Msg) ->
    gtp_v2_c:get_handler(GtpPort, Msg).

get_handler(IP, GtpPort, #gtp{seq_no = SeqNo} = Msg) ->
    case lookup(GtpPort, {IP, SeqNo}) of
	Context when is_pid(Context) ->
	    {ok, Context};
	_ ->
	    get_handler_if(GtpPort, Msg)
    end.

do_handle_message(Context, GtpPort, IP, Port, #gtp{seq_no = SeqNo} = Msg) ->
    gtp_context_reg:register(GtpPort, {seq, IP, SeqNo}, Context),
    gen_server:cast(Context, {handle_message, GtpPort, IP, Port, Msg, false}).

generic_error(IP, Port, GtpPort,
	      #gtp{version = Version, type = MsgType, seq_no = SeqNo}, Error) ->
    Handler = gtp_path:get_handler(GtpPort, Version),
    Reply = Handler:build_response({MsgType, Error}),
    gtp_socket:send_response(GtpPort, IP, Port, Reply#gtp{seq_no = SeqNo}).
