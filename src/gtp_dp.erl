%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_dp).

-behavior(gen_server).

%% API
-export([start_link/1, send/4, get_id/1,
	 create_pdp_context/2,
	 update_pdp_context/2,
	 delete_pdp_context/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-record(state, {gtp_port, node, ip, pid}).

%%====================================================================
%% API
%%====================================================================

start_link({Name, SocketOpts}) ->
    gen_server:start_link(?MODULE, [Name, SocketOpts], []).

send(GtpPort, IP, Port, Data) ->
    cast(GtpPort, {send, IP, Port, Data}).

get_id(GtpPort) ->
    call(GtpPort, get_id).

create_pdp_context(#context{data_port = GtpPort, remote_data_ip = PeerIP,
			    local_data_tei = LocalTEI, remote_data_tei = RemoteTEI}, Args) ->
    dp_call(GtpPort, {create_pdp_context, PeerIP, LocalTEI, RemoteTEI, Args}).

update_pdp_context(#context{data_port = GtpPort, remote_data_ip = PeerIP,
			    local_data_tei = LocalTEI, remote_data_tei = RemoteTEI}, Args) ->
    dp_call(GtpPort, {update_pdp_context, PeerIP, LocalTEI, RemoteTEI, Args}).

delete_pdp_context(#context{data_port = GtpPort, remote_data_ip = PeerIP,
			    local_data_tei = LocalTEI, remote_data_tei = RemoteTEI}, Args) ->
    dp_call(GtpPort, {delete_pdp_context, PeerIP, LocalTEI, RemoteTEI, Args}).

%%%===================================================================
%%% call/cast wrapper for gtp_port
%%%===================================================================

%% TODO: GTP data path handler is currently not working!!
cast(#gtp_port{pid = Handler}, Request)
  when is_pid(Handler) ->
    gen_server:cast(Handler, Request);
cast(GtpPort, Request) ->
    lager:warning("GTP DP Port ~p, CAST Request ~p not implemented yet",
		  [lager:pr(GtpPort, ?MODULE), Request]).

call(#gtp_port{pid = Handler}, Request)
  when is_pid(Handler) ->
    gen_server:call(Handler, Request);
call(GtpPort, Request) ->
    lager:warning("GTP DP Port ~p, CAST Request ~p not implemented yet",
		  [lager:pr(GtpPort, ?MODULE), Request]).

dp_call(GtpPort, Request) ->
    lager:info("DP Call ~p: ~p", [lager:pr(GtpPort, ?MODULE), Request]),
    call(GtpPort, {dp, Request}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, SocketOpts]) ->
    %% TODO: better config validation and handling
    Node  = proplists:get_value(node, SocketOpts),
    RemoteName = proplists:get_value(name, SocketOpts),

    {ok, Pid, IP} = bind(Node, RemoteName),

    %% FIXME: this is wrong and must go into the global startup
    RCnt = gtp_config:inc_restart_counter(),

    GtpPort = #gtp_port{name = Name, type = 'gtp-u', pid = self(),
			ip = IP, restart_counter = RCnt},

    gtp_socket_reg:register(Name, GtpPort),

    {ok, #state{gtp_port = GtpPort, node = Node, ip = IP, pid = Pid}}.

handle_call({dp, Request}, _From, #state{pid = Pid} = State) ->
    lager:info("DP Call ~p: ~p", [Pid, Request]),
    Reply = gen_server:call(Pid, Request),
    lager:info("DP Call Reply: ~p", [Reply]),
    {reply, Reply, State};

handle_call(get_id, _From, #state{pid = Pid} = State) ->
    {reply, {ok, Pid}, State};

handle_call(Request, _From, State) ->
    lager:error("handle_call: unknown ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(Info, State) ->
    lager:error("handle_info: unknown ~p, ~p", [lager:pr(Info, ?MODULE), lager:pr(State, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%%%===================================================================
%%% Data Path Remote API
%%%===================================================================

bind(Node, Port) ->
    gen_server:call({'gtp-u', Node}, {bind, Port}).
