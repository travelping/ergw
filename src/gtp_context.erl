%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context).

-compile({parse_transform, do}).

-export([lookup/2, new/4, handle_message/4, start_link/4,
	 setup/2, update/3, teardown/2, handle_recovery/3]).

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

new(IP, Port, GtpPort,
    #gtp{version = Version, ie = IEs} = Msg) ->
    do([error_m ||
	   Interface <- get_interface_type(Version, IEs),
	   Context <- gtp_context_sup:new(GtpPort, Version, Interface),
	   gen_server:cast(Context, {handle_message, GtpPort, IP, Port, Msg})
       ]).

handle_message(IP, Port, GtpPort,
	       #gtp{version = Version, tei = TEI} = Msg) ->
    case lookup(GtpPort, TEI) of
	Context when is_pid(Context) ->
	    gen_server:cast(Context, {handle_message, GtpPort, IP, Port, Msg});
	_ ->
	    Handler = gtp_path:get_handler(GtpPort, Version),
	    Reply = Handler:build_response({Msg#gtp.type, not_found}),
	    Data = gtp_packet:encode(Reply#gtp{seq_no = Msg#gtp.seq_no}),
	    lager:debug("gtp_context send ~s error to ~w:~w: ~p, ~p",
			[GtpPort#gtp_port.type, IP, Port, Reply, Data]),
	    gtp_socket:send(GtpPort, IP, Port, Data)
    end.

start_link(GtpPort, Version, Interface, Opts) ->
    gen_server:start_link(?MODULE, [GtpPort, Version, Interface], Opts).

%%====================================================================
%% gen_server API
%%====================================================================

init([GtpPort, Version, Interface]) ->
    lager:debug("init(~p)", [[GtpPort, Interface]]),
    {ok, TEI} = gtp_c_lib:alloc_tei(GtpPort),

    State = #{
      gtp_port  => GtpPort,
      version   => Version,
      handler   => gtp_path:get_handler(GtpPort, Version),
      interface => Interface,
      tei       => TEI},
    {ok, State}.

handle_call(Request, _From, State) ->
    lager:warning("handle_call: ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({handle_message, GtpPort, IP, Port, #gtp{type = MsgType, ie = IEs} = Msg},
	    #{handler := Handler, interface := Interface} = State) ->
    lager:debug("~w: handle gtp: ~w, ~p",
		[?MODULE, Port, gtp_c_lib:fmt_gtp(Msg)]),

    Spec = Interface:request_spec(MsgType),
    {Req, Missing} = gtp_c_lib:build_req_record(MsgType, Spec, IEs),
    lager:debug("Mis: ~p", [Missing]),

    case Handler:gtp_msg_type(MsgType) of
	response when Missing /= [] ->
	    %% ignore reply with missing mandarory arguments
	    {noreply, State};

	response ->
	    handle_response(GtpPort, IP, Msg, Req, State);

	_ when Missing /= [] ->
	    handle_error(IP, Port, Msg, {mandatory_ie_missing, hd(Missing)}, State);

	_ ->

	    handle_request(GtpPort, IP, Port, Msg, Req, State)
    end;

handle_cast(Msg, State) ->
    lager:error("~w: handle_cast: ~p", [?MODULE, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

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

handle_error(IP, Port, #gtp{type = MsgType, seq_no = SeqNo}, Reply,
	     #{handler := Handler} = State) ->
    Response = Handler:build_response({MsgType, Reply}),
    send_message(IP, Port, Response#gtp{seq_no = SeqNo}, State),
    {noreply, State}.

handle_request(GtpPort, IP, Port, #gtp{version = Version, seq_no = SeqNo} = Msg, Req,
	        #{handler := Handler, interface := Interface} = State0) ->
    lager:debug("GTP~s ~s:~w: ~p",
		[Version, inet:ntoa(IP), Port, gtp_c_lib:fmt_gtp(Msg)]),

    try Interface:handle_request(GtpPort, Msg, Req, State0) of
	{reply, Reply, State1} ->
	    Response = Handler:build_response(Reply),
	    send_message(IP, Port, Response#gtp{seq_no = SeqNo}, State1),
	    {noreply, State1};

	{stop, Reply, State1} ->
	    Response = Handler:build_response(Reply),
	    send_message(IP, Port, Response#gtp{seq_no = SeqNo}, State1),
	    {stop, normal, State1};

	{error, Reply} ->
	    Response = Handler:build_response(Reply),
	    send_message(IP, Port, Response#gtp{seq_no = SeqNo}, State0),
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

handle_response(GtpPort, IP, Msg, Req, State) ->
    lager:debug("GTP Path Lookup: ~p", [GtpPort]),
    case gtp_path:get(GtpPort, IP) of
	Path when is_pid(Path) ->
	    lager:debug("GTP Path Lookup got: ~p", [Path]),
	    case gtp_path:handle_response(Path, Msg) of
		{ok, ReqId, Response} ->
		    handle_response(ReqId, Response, Req, State);
		_ ->
		    {noreply, State}
	    end;
	_Other ->
	    lager:debug("GTP Path Lookup got: ~p", [_Other]),
	    {noreply, State}
    end.

handle_response(ReqId, Msg, Req,
		#{interface := Interface} = State0) ->
    try Interface:handle_response(ReqId, Msg, Req, State0) of
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

send_message(IP, Port, Msg, #{gtp_port := GtpPort} = State) ->
    %% TODO: handle encode errors
    try
        Data = gtp_packet:encode(Msg),
	lager:debug("gtp_context send ~s to ~w:~w: ~p, ~p", [GtpPort#gtp_port.type, IP, Port, Msg, Data]),
	gtp_socket:send(GtpPort, IP, Port, Data)
    catch
	Class:Error ->
	    Stack  = erlang:get_stacktrace(),
	    lager:error("gtp send failed with ~p:~p (~p)", [Class, Error, Stack])
    end,
    State.

%%%===================================================================
%%% API Module Helper
%%%===================================================================

setup(#context{
	 control_ip  = RemoteCntlIP,
	 data_tunnel = gtp_v1_u,
	 data_ip     = RemoteDataIP,
	 data_tei    = RemoteDataTEI,
	 ms_v4       = MSv4},
      #{gtp_port  := GtpPort,
	version   := Version,
	tei       := LocalTEI}) ->

    ok = gtp_dp:create_pdp_context(GtpPort, Version, RemoteDataIP, MSv4, LocalTEI, RemoteDataTEI),
    gtp_path:register(GtpPort, Version, RemoteCntlIP),
    ok.

update(#context{
	  control_ip  = RemoteCntlIPNew,
	  data_tunnel = gtp_v1_u,
	  data_ip     = RemoteDataIPNew,
	  data_tei    = RemoteDataTEINew,
	  ms_v4       = MSv4},
        #context{
	    control_ip  = RemoteCntlIPOld,
	    data_tunnel = gtp_v1_u,
	    data_ip     = _RemoteDataIPOld,
	    ms_v4       = MSv4},
	 #{gtp_port  := GtpPort,
	   version   := Version,
	   tei       := LocalTEI}) ->

    gtp_path:unregister(GtpPort, Version, RemoteCntlIPOld),
    ok = gtp_dp:update_pdp_context(GtpPort, Version, RemoteDataIPNew, MSv4, LocalTEI, RemoteDataTEINew),
    gtp_path:register(GtpPort, Version, RemoteCntlIPNew),
    ok.

teardown(#context{
	    control_ip  = RemoteCntlIP,
	    data_tunnel = gtp_v1_u,
	    data_ip     = RemoteDataIP,
	    data_tei    = RemoteDataTEI,
	    ms_v4       = MSv4},
	 #{gtp_port  := GtpPort,
	   version   := Version,
	   tei       := LocalTEI}) ->

    gtp_path:unregister(GtpPort, Version, RemoteCntlIP),
    ok = gtp_dp:delete_pdp_context(GtpPort, Version, RemoteDataIP, MSv4, LocalTEI, RemoteDataTEI).

handle_recovery(RecoveryCounter,
		#context{
		   control_ip  = RemoteCntlIP,
		   data_tunnel = gtp_v1_u,
		   data_ip     = _RemoteDataIP},
		#{gtp_port  := GtpPort,
		  version   := Version}) ->
    gtp_path:handle_recovery(RecoveryCounter, GtpPort, Version, RemoteCntlIP).

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_interface_type(v1, _) ->
    {ok, ggsn_gn};
get_interface_type(v2, IEs) ->
    case find_ie(v2_fully_qualified_tunnel_endpoint_identifier, 0, IEs) of
	#v2_fully_qualified_tunnel_endpoint_identifier{interface_type = IfType} ->
	     map_v2_iftype(IfType);
	_ ->
	    {error, {mandatory_ie_missing, {v2_fully_qualified_tunnel_endpoint_identifier, 0}}}
    end.

find_ie(_, _, []) ->
    undefined;
find_ie(Type, Instance, [IE|_])
  when element(1, IE) == Type,
       element(2, IE) == Instance ->
    IE;
find_ie(Type, Instance, [_|Next]) ->
    find_ie(Type, Instance, Next).

map_v2_iftype(6)  -> {ok, pgw_s5s8};
map_v2_iftype(34) -> {ok, pgw_s2a};
map_v2_iftype(_)  -> {error, unsupported}.
