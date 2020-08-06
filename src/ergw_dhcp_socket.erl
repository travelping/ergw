%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_dhcp_socket).

-behavior(gen_server).

-compile({parse_transform, cut}).

%% API
-export([validate_options/2, start_link/1]).
-export([send_request/3, wait_response/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").
-include_lib("dhcp/include/dhcp.hrl").
-include("include/ergw.hrl").

-type xid() :: 0 .. 16#ffffffff.

-record(state, {
	  name    :: term(),
	  ip      :: inet:ip_address(),
	  socket  :: socket:socket(),

	  xid     :: xid(),
	  pending :: gb_trees:tree(xid(), term())
	 }).

-define(SERVER, ?MODULE).
-define(DHCP_SERVER_PORT, 67).
-define(TIMEOUT, 10 * 1000).

%%====================================================================
%% API
%%====================================================================

start_link(Opts) ->
    gen_server:start_link(?MODULE, Opts, []).

%% send_request(Request, Timeout) ->
%%     gen_server:send_request(?SERVER, {send, Request, Timeout}).

%% wait_response(ReqId) ->
%%     gen_server:wait_response(ReqId).

send_request(Pid, Srv, DHCP) when is_pid(Pid) ->
    Mref = monitor(process, Pid),
    From = {self(), Mref},
    gen_server:cast(Pid, {request, From, Srv, DHCP}),
    Mref;
send_request(Socket, Srv, DHCP) ->
    case ergw_socket_reg:lookup(dhcp, Socket) of
	Pid when is_pid(Pid) ->
	    send_request(Pid, Srv, DHCP);
	_ ->
	    Mref = make_ref(),
	    self() ! {'DOWN', Mref, process, Socket, not_found},
	    Mref
    end.

wait_response(_ReqId, Timeout)
  when Timeout =< 0 ->
    timeout;

wait_response(Mref, Timeout) when is_integer(Timeout) ->
    receive
	{'DOWN', Mref, _, _, Reason} ->
	    {error, Reason};
	{Mref, Reply} ->
	    {ok, Reply};
	Other ->
	    {error, Other}
    after Timeout ->
	    {error, timeout}
    end;

wait_response(ReqId, {abs, Timeout}) ->
    wait_response(ReqId, Timeout - erlang:monotonic_time(millisecond)).


%% sockname() ->
%%     gen_server:call(?SERVER, sockname).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(SOCKET_OPTS, [netdev, netns, freebind, reuseaddr, rcvbuf]).
-define(SocketDefaults, [{ip, invalid}, {port, dhcp}]).

validate_options(Name, Values) ->
     ergw_config:validate_options(fun validate_option/2, Values,
				  [{name, Name}|?SocketDefaults], map).

validate_option(type, dhcp = Value) ->
    Value;
validate_option(name, Value) when is_atom(Value) ->
    Value;
validate_option(ip, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Value;
validate_option(port, Value) when Value =:= dhcp; Value =:= random ->
    Value;
validate_option(netdev, Value) when is_list(Value) ->
    Value;
validate_option(netdev, Value) when is_binary(Value) ->
    unicode:characters_to_list(Value, latin1);
validate_option(netns, Value) when is_list(Value) ->
    Value;
validate_option(netns, Value) when is_binary(Value) ->
    unicode:characters_to_list(Value, latin1);
validate_option(freebind, Value) when is_boolean(Value) ->
    Value;
validate_option(reuseaddr, Value) when is_boolean(Value) ->
    Value;
validate_option(rcvbuf, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(socket, Value)
  when is_atom(Value) ->
    Value;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init(#{name := Name, ip := IP, port := PortOpt} = Opts) ->
    process_flag(trap_exit, true),

    SocketOpts = maps:with(?SOCKET_OPTS, Opts),
    {ok, Socket} = make_dhcp_socket(IP, PortOpt, SocketOpts),

    ergw_socket_reg:register('dhcp', Name, self()),
    State = #state{
	       name = Name,
	       ip = IP,
	       socket = Socket,

	       xid = rand:uniform(16#ffffffff),
	       pending = gb_trees:empty()
	      },
    select(Socket),
    {ok, State}.

%% handle_call(sockname, _From, #state{socket = Socket} = State) ->
%%     {reply, socket:sockname(Socket), State};

handle_call(Request, _From, State) ->
    ?LOG(error, "handle_call: unknown ~p", [Request]),
    {reply, ok, State}.

handle_cast({request, From, Srv, #dhcp{} = DHCP}, #state{xid = XId} = State) ->
    Req = DHCP#dhcp{xid = XId},
    %% message_counter(tx, State, DHCP),
    send_request(Srv, Req, From, State#state{xid = (XId + 1) rem 16#100000000});

handle_cast(Msg, State) ->
    ?LOG(error, "handle_cast: unknown ~p", [Msg]),
    {noreply, State}.

handle_info(Info = {timeout, _TRef, {request, #dhcp{xid = XId}}}, State) ->
    ?LOG(debug, "handle_info: ~p", [Info]),
    {noreply, remove_request(XId, State)};

handle_info({'$socket', Socket, select, Info}, #state{socket = Socket} = State) ->
    handle_input(Socket, Info, State);

handle_info({'$socket', Socket, abort, Info}, #state{socket = Socket} = State) ->
    handle_input(Socket, Info, State);

handle_info(Info, State) ->
    ?LOG(error, "handle_info: unknown ~p, ~p", [Info, State]),
    {noreply, State}.

terminate(_Reason, #state{socket = Socket} = _State) ->
    socket:close(Socket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Socket functions
%%%===================================================================

family({_,_,_,_}) -> inet;
family({_,_,_,_,_,_,_,_}) -> inet6.

port_opt(dhcp) -> ?DHCP_SERVER_PORT;
port_opt(_) -> 0.

make_dhcp_socket(IP, Port, #{netns := NetNs} = Opts)
  when is_list(NetNs) ->
    {ok, Socket} = socket:open(family(IP), dgram, udp, #{netns => NetNs}),
    bind_dhcp_socket(Socket, IP, Port, Opts);
make_dhcp_socket(IP, Port, Opts) ->
    {ok, Socket} = socket:open(family(IP), dgram, udp),
    bind_dhcp_socket(Socket, IP, Port, Opts).

bind_dhcp_socket(Socket, {_,_,_,_} = IP, PortOpt, Opts) ->
    ok = socket_ip_freebind(Socket, Opts),
    ok = socket_netdev(Socket, Opts),
    {ok, _} = socket:bind(Socket, #{family => inet, addr => IP, port => port_opt(PortOpt)}),
    ok = socket:setopt(Socket, socket, broadcast, true),
    ok = socket:setopt(Socket, ip, recverr, true),
    ok = socket:setopt(Socket, ip, mtu_discover, dont),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    {ok, Socket};

bind_dhcp_socket(Socket, {_,_,_,_,_,_,_,_} = IP, PortOpt, Opts) ->
    ok = socket:setopt(Socket, ipv6, v6only, true),
    ok = socket_netdev(Socket, Opts),
    {ok, _} = socket:bind(Socket, #{family => inet6, addr => IP, port => port_opt(PortOpt)}),
    ok = socket:setopt(Socket, socket, broadcast, true),
    ok = socket:setopt(Socket, ipv6, recverr, true),
    ok = socket:setopt(Socket, ipv6, mtu_discover, dont),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    {ok, Socket}.

socket_ip_freebind(Socket, #{freebind := true}) ->
    socket:setopt(Socket, ip, freebind, true);
socket_ip_freebind(_, _) ->
    ok.

socket_netdev(Socket, #{netdev := Device}) ->
    socket:setopt(Socket, socket, bindtodevice, Device);
socket_netdev(_, _) ->
    ok.

socket_setopts(Socket, rcvbuf, Size) when is_integer(Size) ->
    case socket:setopt(Socket, socket, rcvbufforce, Size) of
	ok -> ok;
	_  -> socket:setopt(Socket, socket, rcvbuf, Size)
    end;
socket_setopts(Socket, reuseaddr, true) ->
    ok = socket:setopt(Socket, socket, reuseaddr, true);
socket_setopts(_Socket, _, _) ->
    ok.

select(Socket) ->
    self() ! {'$socket', Socket, select, undefined}.

handle_input(Socket, _Info, State0) ->
    case socket:recvfrom(Socket, 0, [], nowait) of
	{error, _} ->
	    State = handle_err_input(Socket, State0),
	    select(Socket),
	    {noreply, State};

	{ok, {Source, Data}} ->
	    State = handle_message(Source, Data, State0),
	    select(Socket),
	    {noreply, State};

	{select, _SelectInfo} ->
	    {noreply, State0}
    end.

-define(IP_RECVERR,             11).
-define(IPV6_RECVERR,           25).
-define(SO_EE_ORIGIN_LOCAL,      1).
-define(SO_EE_ORIGIN_ICMP,       2).
-define(SO_EE_ORIGIN_ICMP6,      3).
-define(SO_EE_ORIGIN_TXSTATUS,   4).
-define(ICMP_DEST_UNREACH,       3).       %% Destination Unreachable
-define(ICMP_HOST_UNREACH,       1).       %% Host Unreachable
-define(ICMP_PROT_UNREACH,       2).       %% Protocol Unreachable
-define(ICMP_PORT_UNREACH,       3).       %% Port Unreachable
-define(ICMP6_DST_UNREACH,       1).
-define(ICMP6_DST_UNREACH_ADDR,  3).       %% address unreachable
-define(ICMP6_DST_UNREACH_NOPORT,4).       %% bad port

handle_dest_unreach(_IP, [Data|_], #state{name = _Name} = State) when is_binary(Data) ->
    %% ergw_prometheus:dhcp(tx, Name, IP, unreachable),
    try dhcp_lib:decode(Data, map) of
	#dhcp{xid = XId} ->
	    case lookup_request(XId, State) of
		none ->
		    ok;
		{value, From} ->
		    reply(From, {error, unreachable}),
		    remove_request(XId, State)
	    end,
	    State
    catch
	Class:Error:Stack ->
	    ?LOG(debug, "HandleSocketError: ~p:~p @ ~p", [Class, Error, Stack]),
	    State
    end;
handle_dest_unreach(_, _, State) ->
    State.

handle_socket_error(#{level := ip, type := ?IP_RECVERR,
		      data := <<_ErrNo:32/native-integer,
				Origin:8, Type:8, Code:8, _Pad:8,
				_Info:32/native-integer, _Data:32/native-integer,
				_/binary>>},
		    IP, _Port, IOV, State)
  when Origin == ?SO_EE_ORIGIN_ICMP, Type == ?ICMP_DEST_UNREACH,
       (Code == ?ICMP_HOST_UNREACH orelse Code == ?ICMP_PORT_UNREACH) ->
    ?LOG(debug, "ICMP indication for ~s: ~p", [inet:ntoa(IP), Code]),
    handle_dest_unreach(IP, IOV, State);

handle_socket_error(#{level := ip, type := recverr,
		      data := #{origin := icmp, type := dest_unreach, code := Code}},
		    IP, _Port, IOV, State)
  when Code == host_unreach;
       Code == port_unreach ->
    ?LOG(debug, "ICMP indication for ~s: ~p", [inet:ntoa(IP), Code]),
    handle_dest_unreach(IP, IOV, State);

handle_socket_error(#{level := ipv6, type := ?IPV6_RECVERR,
		      data := <<_ErrNo:32/native-integer,
				Origin:8, Type:8, Code:8, _Pad:8,
				_Info:32/native-integer, _Data:32/native-integer,
				_/binary>>},
		    IP, _Port, IOV, State)
  when Origin == ?SO_EE_ORIGIN_ICMP6, Type == ?ICMP6_DST_UNREACH,
       (Code == ?ICMP6_DST_UNREACH_ADDR orelse Code == ?ICMP6_DST_UNREACH_NOPORT) ->
    ?LOG(debug, "ICMPv6 indication for ~s: ~p", [inet:ntoa(IP), Code]),
    handle_dest_unreach(IP, IOV, State);

handle_socket_error(#{level := ipv6, type := recverr,
		      data := #{origin := icmp6, type := dest_unreach, code := Code}},
		    IP, _Port, IOV, State)
  when Code == addr_unreach;
       Code == port_unreach ->
    ?LOG(debug, "ICMPv6 indication for ~s: ~p", [inet:ntoa(IP), Code]),
    handle_dest_unreach(IP, IOV, State);

handle_socket_error(Error, IP, _Port, _IOV, State) ->
    ?LOG(debug, "got unhandled error info for ~s: ~p", [inet:ntoa(IP), Error]),
    State.

handle_err_input(Socket, State) ->
    case socket:recvmsg(Socket, [errqueue], nowait) of
	{ok, #{addr := #{addr := IP, port := Port}, iov := IOV, ctrl := Ctrl}} ->
	    lists:foldl(handle_socket_error(_, IP, Port, IOV, _), State, Ctrl);

	{select, SelectInfo} ->
	    socket:cancel(Socket, SelectInfo),
	    State;

	Other ->
	    ?LOG(error, "got unhandled error input: ~p", [Other]),
	    State
    end.

%%%===================================================================
%%% Sx Message functions
%%%===================================================================

handle_message(#{port := Port, addr := IP} = Source,
	       Data, #state{name = _Name} = State0) ->
    ?LOG(debug, "handle message ~s:~w: ~p", [inet:ntoa(IP), Port, Data]),
    try
	Msg = dhcp_lib:decode(Data, map),
	%% ergw_prometheus:dhcp(rx, Name, IP, Msg),
	handle_response(Source, Msg, State0)
    catch
	Class:Error:Stack ->
	    ?LOG(debug, "UDP invalid msg: ~p:~p @ ~p", [Class, Error, Stack]),
	    %% ergw_prometheus:dhcp(rx, Name, IP, 'malformed-message'),
	    State0
    end.

handle_response(_Source, #dhcp{xid = XId} = Msg,
		#state{name = _Name} = State) ->
    case lookup_request(XId, State) of
	none -> %% late, drop silently
	    %% ergw_prometheus:dhcp(rx, Name, IP, Msg, late),
	    State;

	{value, From} ->
	    %% ergw_prometheus:dhcp(rx, Name, IP, Msg),
	    reply(From, Msg),
	    State
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

reply({Pid, Ref}, Reply) ->
    Pid ! {Ref, Reply}.

send_request(Srv, #dhcp{xid = XId} = Req0, From, State) ->
    Req = dhcp_req_opts(Req0, State),
    SendTo = dhcp_server(Srv),
    Data = dhcp_lib:encode(Req),
    case sendto(State, SendTo, Data) of
	ok ->
	    {noreply, start_request(XId, Req, From, State)};
	{error, _} = Error ->
	    reply(From, Error),
	    {noreply, State}
    end.

start_request(XId, Req, From, #state{pending = Pending} = State) ->
    erlang:start_timer(?TIMEOUT, self(), {request, Req}),
    State#state{pending = gb_trees:insert(XId, From, Pending)}.

lookup_request(Xid, #state{pending = Pending}) ->
    gb_trees:lookup(Xid, Pending).

remove_request(Xid, #state{pending = Pending} = State) ->
    State#state{pending = gb_trees:delete_any(Xid, Pending)}.

sendto(#state{socket = Socket, ip = SrcIP}, DstIP, Data) ->
    Dest = #{family => family(SrcIP),
	     addr => DstIP,
	     port => ?DHCP_SERVER_PORT},
    socket:sendto(Socket, Data, Dest, nowait).

dhcp_req_opts(#dhcp{options = Opts} = Req, _State) ->
%%  when Port /= ?DHCP_SERVER_PORT ->
    AgentOpts = [{?RAI_DHCPV4_RELAY_SOURCE_PORT, ?DHCP_SERVER_PORT} |
		 dhcp_lib:get_opt(?DHO_DHCP_AGENT_OPTIONS, Opts, [])],
    Req#dhcp{options = dhcp_lib:put_opt(?DHO_DHCP_AGENT_OPTIONS, AgentOpts, Opts)};
dhcp_req_opts(Req, _) ->
    Req.

dhcp_server(broadcast) ->
    broadcast;
dhcp_server({0,0,0,0}) ->
    broadcast;
dhcp_server(SendTo) ->
    SendTo.

%%%===================================================================
%%% Metrics collections
%%%===================================================================

%% %% message_counter/3
%% message_counter(Direction, #state{name = Name}, #send_req{address = IP, msg = Msg}) ->
%%     %% ergw_prometheus:dhcp(Direction, Name, IP, Msg).

%% %% message_counter/4
%% message_counter(Direction, #state{name = Name}, #sx_request{ip = IP}, #pfcp{} = Msg) ->
%%     %% ergw_prometheus:dhcp(Direction, Name, IP, Msg);
%% message_counter(Direction, #state{name = Name}, #send_req{address = IP, msg = Msg}, Verdict)
%%   when is_atom(Verdict) ->
%%     %% ergw_prometheus:dhcp(Direction, Name, IP, Verdict).

%% %% measure the time it takes our peer to reply to a request
%% measure_response(#state{name = Name},
%%		 #send_req{address = IP, msg = Msg, send_ts = SendTS}, ArrivalTS) ->
%%     %% ergw_prometheus:dhcp_peer_response(Name, IP, Msg, SendTS - ArrivalTS).

%% %% measure the time it takes us to generate a response to a request
%% measure_request(#state{name = Name},
%%		#sx_request{type = MsgType, arrival_ts = ArrivalTS}) ->
%%     Duration = erlang:monotonic_time() - ArrivalTS,
%%     %% ergw_prometheus:dhcp_request_duration(Name, MsgType, Duration).
