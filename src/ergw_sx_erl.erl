%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sx_erl).

-behavior(gen_server).
-behavior(ergw_sx_api).

%% API
-export([validate_options/1,
	 start_link/1, send/4, get_id/1,
	 call/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-record(state, {state, tref, timeout, name, node, remote_name, ip, pid, gtp_port}).

%%====================================================================
%% API
%%====================================================================

start_link({Name, SocketOpts}) ->
    gen_server:start_link(?MODULE, [Name, SocketOpts], []).

send(GtpPort, IP, Port, Data) ->
    cast(GtpPort, {send, IP, Port, Data}).

get_id(GtpPort) ->
    call_port(GtpPort, get_id).

call(Context, Request, IEs) ->
    case dp_call(Context, Request, IEs) of
	{ok, Pid} when is_pid(Pid) ->
	    Context#context{dp_pid = Pid};
	_ ->
	    Context
    end.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(SocketDefaults, [{node, "invalid"},
			 {name, "invalid"}]).

validate_options(Values) ->
     ergw_config:validate_options(fun validate_option/2, Values, ?SocketDefaults, map).

validate_option(node, Value) when is_atom(Value) ->
    Value;
validate_option(name, Value) when is_atom(Value) ->
    Value;
validate_option(type, Value) when Value =:= 'gtp-u' ->
    Value;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

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

call_port(#gtp_port{pid = Handler}, Request)
  when is_pid(Handler) ->
    gen_server:call(Handler, Request);
call_port(GtpPort, Request) ->
    lager:warning("GTP DP Port ~p, CAST Request ~p not implemented yet",
		  [lager:pr(GtpPort, ?MODULE), Request]).

dp_call(#context{local_data_tei = TEI, dp_pid = Pid}, Request, IEs) when is_pid(Pid) ->
    lager:debug("DP Direct Call ~p: ~p(~p)", [Pid, Request, IEs]),
    gen_server:call(Pid, {TEI, Request, IEs});
dp_call(#context{local_data_tei = TEI, data_port = GtpPort}, Request, IEs) ->
    lager:debug("DP Server Call ~p: ~p(~p)", [lager:pr(GtpPort, ?MODULE), Request, IEs]),
    call_port(GtpPort, {dp, TEI, Request, IEs}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, #{node := Node, name := RemoteName}]) ->
    State0 = #state{state = disconnected,
		    tref = undefined,
		    timeout = 10,
		    name = Name,
		    node = Node,
		    remote_name = RemoteName},
    State = connect(State0),
    {ok, State}.

handle_call({dp, TEI, Request, IEs}, _From, #state{pid = Pid} = State) ->
    lager:debug("DP Call ~p: ~p(~p)", [Pid, Request, IEs]),
    Reply = gen_server:call(Pid, {TEI, Request, IEs}),
    lager:debug("DP Call Reply: ~p", [Reply]),
    {reply, Reply, State};

handle_call(get_id, _From, #state{pid = Pid} = State) ->
    {reply, {ok, Pid}, State};

handle_call(Request, _From, State) ->
    lager:error("handle_call: unknown ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({send, _IP, _Port, _Data} = Msg, #state{pid = Pid} = State) ->
    lager:debug("DP Cast ~p: ~p", [Pid, Msg]),
    gen_server:cast(Pid, Msg),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info({nodedown, Node}, State0) ->
    lager:warning("node down: ~p", [Node]),

    State1 = handle_nodedown(State0),
    State = start_nodedown_timeout(State1),
    {noreply, State};

handle_info(reconnect, State0) ->
    lager:warning("trying to reconnect"),
    State = connect(State0#state{tref = undefined}),
    {noreply, State};

handle_info({_, session_report_request, _} = Report,
	    #state{gtp_port = GtpPort} = State) ->
    lager:debug("handle_info: ~p, ~p", [Report, lager:pr(State, ?MODULE)]),
    gtp_context:session_report(GtpPort, Report),
    {noreply, State};

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
start_nodedown_timeout(State = #state{tref = undefined, timeout = Timeout}) ->
    NewTimeout = if Timeout < 3000 -> Timeout * 2;
		    true           -> Timeout
		 end,
    TRef = erlang:send_after(Timeout, self(), reconnect),
    State#state{tref = TRef, timeout = NewTimeout};

start_nodedown_timeout(State) ->
    State.

connect(#state{name = Name, node = Node, remote_name = RemoteName} = State) ->
    case net_adm:ping(Node) of
	pong ->
	    lager:warning("Node ~p is up", [Node]),
	    erlang:monitor_node(Node, true),

	    {ok, Pid, IP} = bind(Node, RemoteName),
	    ok = clear(Pid),
	    {ok, RCnt} = gtp_config:get_restart_counter(),
	    GtpPort = #gtp_port{name = Name, type = 'gtp-u', pid = self(),
				ip = IP, restart_counter = RCnt},
	    gtp_socket_reg:register(Name, GtpPort),

	    State#state{state = connected, timeout = 10, ip = IP, pid = Pid, gtp_port = GtpPort};
	pang ->
	    lager:warning("Node ~p is down", [Node]),
	    start_nodedown_timeout(State)
    end.

handle_nodedown(#state{name = Name} = State) ->
    gtp_socket_reg:unregister(Name),
    State#state{state = disconnected}.

%%%===================================================================
%%% Data Path Remote API
%%%===================================================================

clear(Pid) ->
    gen_server:call(Pid, clear).

bind(Node, Port) ->
    gen_server:call({'gtp-u', Node}, {bind, Port}).
