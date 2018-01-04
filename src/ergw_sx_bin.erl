%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sx_bin).

-behavior(gen_server).
-behavior(ergw_sx_api).

%% API
-export([validate_options/1,
	 start_link/1, send/4, get_id/1,
	 call/2, heartbeat_response/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-record(state, {state, tref, timeout, name, node,
		remote_name, remote_ip, ip, pid, gtp_port}).

%%====================================================================
%% API
%%====================================================================

start_link({Name, SocketOpts}) ->
    gen_server:start_link(?MODULE, [Name, SocketOpts], []).

send(GtpPort, IP, Port, Data) ->
    cast(GtpPort, {send, IP, Port, Data}).

get_id(GtpPort) ->
    call_port(GtpPort, get_id).

call(Context, Request) ->
    dp_call(Context, Request).

heartbeat_response(Pid, Response) ->
    gen_server:cast(Pid, {heartbeat, Response}).

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
		  [lager:pr(GtpPort, ?MODULE), lager:pr(Request, ?MODULE)]).

call_port(#gtp_port{pid = Handler}, Request)
  when is_pid(Handler) ->
    gen_server:call(Handler, Request);
call_port(GtpPort, Request) ->
    lager:warning("GTP DP Port ~p, CAST Request ~p not implemented yet",
		  [lager:pr(GtpPort, ?MODULE), lager:pr(Request, ?MODULE)]).

dp_call(#context{data_port = GtpPort}, Request) ->
    lager:debug("DP Server Call ~p: ~p(~p)",
		[lager:pr(GtpPort, ?MODULE), lager:pr(Request, ?MODULE)]),
    call_port(GtpPort, Request).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, #{node := Node, name := RemoteName}]) ->
    State = #state{state = disconnected,
		   tref = undefined,
		   timeout = 10,
		   name = Name,
		   node = Node,
		   remote_name = RemoteName,
		   remote_ip = {172,21,16,1}},
    send_heartbeat(State),
    {ok, State}.

handle_call(#pfcp{} = Request, _From, #state{remote_ip = IP} = State) ->
    lager:debug("DP Call ~p", [lager:pr(Request, ?MODULE)]),
    Reply = ergw_sx_socket:call(IP, Request),
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

handle_cast({heartbeat, timeout}, State0) ->
    lager:warning("peer node down"),

    State1 = handle_nodedown(State0),
    State = shedule_next_heartbeat(State1#state{tref = undefined}),
    {noreply, State};

handle_cast({heartbeat, #pfcp{version = v1, type = heartbeat_response}},
	    #state{state = disconnected} = State0) ->

    State1 = handle_nodeup(State0),
    State = shedule_next_heartbeat(State1),
    {noreply, State};

handle_cast({heartbeat, #pfcp{version = v1, type = heartbeat_response}}, State0) ->
    State = shedule_next_heartbeat(State0),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:error("handle_cast: unknown ~p", [lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(heartbeat, State) ->
    lager:warning("sending heartbeat"),
    send_heartbeat(State),
    {noreply, State#state{tref = undefined}};

handle_info(Info, State) ->
    lager:error("handle_info: unknown ~p, ~p",
		[lager:pr(Info, ?MODULE), lager:pr(State, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Sx Msg handler functions
%%%===================================================================

%% handle_msg(#pfcp{type = heartbeat_response},
%% 	   #state{state = disconnected} = State0) ->
%%     State1 = cancel_timeout(State0),
%%     State2 = handle_nodeup(State1),
%%     State = shedule_next_heartbeat(State2),
%%     {noreply, State};

%% handle_msg(#pfcp{type = heartbeat_response}, State0) ->
%%     State1 = cancel_timeout(State0),
%%     State = shedule_next_heartbeat(State1),
%%     {noreply, State};

%% handle_msg(#pfcp{type = session_report_request} = Report,
%% 	   #state{gtp_port = GtpPort} = State) ->
%%     lager:debug("handle_info: ~p, ~p",
%% 		[lager:pr(Report, ?MODULE), lager:pr(State, ?MODULE)]),
%%     gtp_context:session_report(GtpPort, Report),
%%     {noreply, State};

%% handle_msg(Msg, #state{pending = From} = State0)
%%   when From /= undefined ->
%%     State = cancel_timeout(State0),
%%     gen_server:reply(From, Msg),
%%     {noreply, State#state{pending = undefined}};

%% handle_msg(Msg, State) ->
%%     lager:error("handle_msg: unknown ~p, ~p", [Msg, lager:pr(State, ?MODULE)]),
%%     {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% cancel_timer(Ref) ->
%%     case erlang:cancel_timer(Ref) of
%% 	false ->
%% 	    receive {timeout, Ref, _} -> 0
%% 	    after 0 -> false
%% 	    end;
%% 	RemainingTime ->
%% 	    RemainingTime
%%     end.

%% cancel_timeout(#state{tref = TRef} = State) ->
%%     cancel_timer(TRef),
%%     State#state{tref = undefined}.

%% sntp_time_to_seconds(Time) ->
%%      case Time band 16#80000000 of
%% 	 0 -> Time + 2085978496; % use base: 7-Feb-2036 @ 06:28:16 UTC
%% 	 _ -> Time - 2208988800  % use base: 1-Jan-1900 @ 01:00:00 UTC
%%      end.

seconds_to_sntp_time(Sec) ->
    if Sec >= 2085978496 ->
	    Sec - 2085978496;
       true ->
	    Sec + 2208988800
    end.

shedule_next_heartbeat(State = #state{state = ConnState, timeout = Timeout}) ->
    NewTimeout =
	case ConnState of
	    disconnected
	      when Timeout < 3000 ->
		Timeout * 2;
	    disconnected ->
		Timeout;
	    _ ->
		5000
	end,
    TRef = erlang:send_after(Timeout, self(), heartbeat),
    State#state{tref = TRef, timeout = NewTimeout}.

send_heartbeat(#state{remote_ip = IP}) ->
    IEs = [#recovery_time_stamp{
	      time = seconds_to_sntp_time(gtp_config:get_start_time())}],
    Req = #pfcp{version = v1, type = heartbeat_request, ie = IEs},
    ergw_sx_socket:call(IP, 500, 5, Req, {?MODULE, heartbeat_response, [self()]}).

handle_nodeup(#state{name = Name, node = Node, remote_name = RemoteName} = State) ->
    lager:warning("Node ~p is up", [Node]),

    %% {ok, Pid, IP} = bind(Node, RemoteName),
    %% ok = clear(Pid),
    Pid = self(), IP = {127,0,0,1},

    {ok, RCnt} = gtp_config:get_restart_counter(),
    GtpPort = #gtp_port{name = Name, type = 'gtp-u', pid = self(),
			ip = IP, restart_counter = RCnt},
    gtp_socket_reg:register(Name, GtpPort),

    State#state{state = connected, timeout = 100, ip = IP, pid = Pid, gtp_port = GtpPort}.

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
