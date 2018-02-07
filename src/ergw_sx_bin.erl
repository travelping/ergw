%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sx_bin).

-behavior(gen_statem).
-behavior(ergw_sx_api).

%% API
-export([validate_options/1,
	 start_link/1, send/4, get_id/1,
	 call/2, response/3]).

%% gen_server callbacks
-export([init/1, callback_mode/0, handle_event/4,
	 terminate/2, code_change/3]).

-include_lib("kernel/include/inet.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-record(data, {timeout, name, cp, dp, gtp_port}).

%%====================================================================
%% API
%%====================================================================

start_link({Name, SocketOpts}) ->
    gen_statem:start_link(?MODULE, [Name, SocketOpts], []).

send(GtpPort, IP, Port, Data) ->
    cast(GtpPort, {send, IP, Port, Data}).

get_id(GtpPort) ->
    call_port(GtpPort, get_id).

call(Context, Request) ->
    dp_call(Context, Request).

response(Pid, Type, Response) ->
    gen_statem:cast(Pid, {Type, Response}).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(SocketDefaults, [{node, "invalid"},
			 {ip, invalid}]).

validate_options(Values) ->
     ergw_config:validate_options(fun validate_option/2, Values, ?SocketDefaults, map).

validate_option(node, Value)
  when is_atom(Value); is_list(Value) ->
    case inet:gethostbyname(Value) of
	{ok, #hostent{h_addr_list = Addrs}} ->
	    hd(Addrs);
	_ ->
	    throw({error, {options, {node, Value}}})
    end;
validate_option(node, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Value;
validate_option(ip, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
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
    gen_statem:cast(Handler, Request);
cast(GtpPort, Request) ->
    lager:warning("GTP DP Port ~p, CAST Request ~p not implemented yet",
		  [lager:pr(GtpPort, ?MODULE), lager:pr(Request, ?MODULE)]).

call_port(#gtp_port{pid = Handler}, Request)
  when is_pid(Handler) ->
    gen_statem:call(Handler, Request);
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

%% callback_mode() -> [handle_event_function, state_enter].
callback_mode() -> handle_event_function.

init([Name, #{node := Node, ip := IP}]) ->
    {ok, CP} =ergw_sx_socket:id(),
    Data = #data{timeout = 10,
		 name = Name,
		 cp = CP,
		 dp = #node{node = Node, ip = IP}},
    {ok, disconnected, Data, [{next_event, internal, setup}]}.

handle_event(_, setup, disconnected, #data{cp = CP, dp = #node{node = Node}}) ->
    IEs = [node_id(CP),
	   #recovery_time_stamp{
	      time = seconds_to_sntp_time(gtp_config:get_start_time())}],
    Req = #pfcp{version = v1, type = association_setup_request, ie = IEs},
    ergw_sx_socket:call(Node, 500, 5, Req, response_cb(association_setup_request)),
    keep_state_and_data;

handle_event(cast, {association_setup_request, timeout}, disconnected, _Data) ->
    {keep_state_and_data, [{state_timeout, 5000, setup}]};

handle_event(cast, {_, #pfcp{version = v1, type = association_setup_response, ie = IEs}},
	     disconnected, Data0) ->
    case IEs of
	#{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} ->
	    Data = handle_nodeup(IEs, Data0),
	    {next_state, connected, Data, [next_heartbeat(Data)]};
	Other ->
	    lager:warning("Other: ~p", [lager:pr(Other, ?MODULE)]),
	    {keep_state_and_data, [{state_timeout, 5000, setup}]}
    end;

%%
%% heartbeat logic
%%
handle_event(state_timeout, heartbeat, connected, Data) ->
    lager:warning("sending heartbeat"),
    send_heartbeat(Data),
    keep_state_and_data;

handle_event(cast, {heartbeat, timeout}, connected, Data0) ->
    Data = handle_nodedown(Data0),
    {next_state, disconnected, Data, [{next_event, internal, setup}]};

handle_event(cast, {_, #pfcp{version = v1, type = heartbeat_response}}, connected, Data) ->
    {next_state, connected, Data, [next_heartbeat(Data)]};

handle_event({call, From}, #pfcp{} = Request, connected, #data{dp = #node{node = Node}}) ->
    lager:debug("DP Call ~p", [lager:pr(Request, ?MODULE)]),
    Reply = ergw_sx_socket:call(Node, Request),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, #pfcp{}, _, _Data) ->
    Reply = {error, not_connected},
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, get_id, _, _Data) ->
    Reply =  {ok, self()},
    {keep_state_and_data, [{reply, From, Reply}]}.

%% handle_event(cast, {send, _IP, _Port, _Data} = Msg, _, #data{pid = Pid}) ->
%%     lager:debug("DP Cast ~p: ~p", [Pid, Msg]),
%%     gen_server:cast(Pid, Msg),
%%     keep_state_and_data.

terminate(_Reason, _Data) ->
    ok.

code_change(_OldVsn, Data, _Extra) ->
    {ok, Data}.

%%%===================================================================
%%% Sx Msg handler functions
%%%===================================================================

%% handle_msg(#pfcp{type = heartbeat_response},
%% 	   #data{state = disconnected} = Data0) ->
%%     Data1 = cancel_timeout(Data0),
%%     Data2 = handle_nodeup(Data1),
%%     Data = shedule_next_heartbeat(Data2),
%%     {noreply, Data};

%% handle_msg(#pfcp{type = heartbeat_response}, Data0) ->
%%     Data1 = cancel_timeout(Data0),
%%     Data = shedule_next_heartbeat(Data1),
%%     {noreply, Data};

%% handle_msg(#pfcp{type = session_report_request} = Report,
%% 	   #data{gtp_port = GtpPort} = Data) ->
%%     lager:debug("handle_info: ~p, ~p",
%% 		[lager:pr(Report, ?MODULE), lager:pr(Data, ?MODULE)]),
%%     gtp_context:session_report(GtpPort, Report),
%%     {noreply, Data};

%% handle_msg(Msg, #data{pending = From} = Data0)
%%   when From /= undefined ->
%%     Data = cancel_timeout(Data0),
%%     gen_server:reply(From, Msg),
%%     {noreply, Data#data{pending = undefined}};

%% handle_msg(Msg, Data) ->
%%     lager:error("handle_msg: unknown ~p, ~p", [Msg, lager:pr(Data, ?MODULE)]),
%%     {noreply, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% sntp_time_to_seconds(Time) ->
%%      case Time band 16#80000000 of
%% 	 0 -> Time + 2085978496; % use base: 7-Feb-2036 @ 06:28:16 UTC
%% 	 _ -> Time - 2208988800  % use base: 1-Jan-1900 @ 01:00:00 UTC
%%      end.

response_cb(Type) ->
    {?MODULE, response, [self(), Type]}.

seconds_to_sntp_time(Sec) ->
    if Sec >= 2085978496 ->
	    Sec - 2085978496;
       true ->
	    Sec + 2208988800
    end.

next_heartbeat(_Data) ->
    {state_timeout, 5000, heartbeat}.

node_id(#node{node = Node})
  when is_atom(Node) ->
    #node_id{id = string:split(atom_to_binary(Node, utf8), ".", all)}.

send_heartbeat(#data{dp = #node{node = Node}}) ->
    IEs = [#recovery_time_stamp{
	      time = seconds_to_sntp_time(gtp_config:get_start_time())}],
    Req = #pfcp{version = v1, type = heartbeat_request, ie = IEs},
    ergw_sx_socket:call(Node, 500, 5, Req, response_cb(heartbeat)).

handle_nodeup(#{user_plane_ip_resource_information :=
		    #user_plane_ip_resource_information{
		       ipv4 = IPv4, ipv6 = IPv6
		      }
	       } = _IEs, #data{name = Name, dp = #node{node = Node} = DP} = Data) ->
    lager:warning("Node ~s is up", [inet:ntoa(Node)]),
    lager:warning("Node IEs: ~p", [lager:pr(_IEs, ?MODULE)]),

    IP =
	if IPv4 /= undefined -> gtp_c_lib:bin2ip(IPv4);
	   IPv6 /= undefined -> gtp_c_lib:bin2ip(IPv6)
	end,

    {ok, RCnt} = gtp_config:get_restart_counter(),
    GtpPort = #gtp_port{name = Name, type = 'gtp-u', pid = self(),
			ip = IP, restart_counter = RCnt},
    gtp_socket_reg:register(Name, GtpPort),

    Data#data{timeout = 100, gtp_port = GtpPort, dp = DP#node{ip = IP}}.

handle_nodedown(#data{name = Name} = Data) ->
    gtp_socket_reg:unregister(Name),
    Data.
