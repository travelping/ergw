%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_redirector).

-export([init/2, 
         validate_option/1, 
         get_nodes/1, 
         set_nodes/2,
         keep_alive/2, 
         timeout_requests/1, 
         handle_message/6, 
         echo_response/6]).

-record(redirector, {
          socket     = undefined    :: undefined | gen_socket:socket(),

          % lists of all nodes, including bad
          nodes      = []    :: list(),

          % here we have nodes which are not answered for Keep-Alive echo request
          % no requests should be transfered to such nodes
          bad_nodes  = []    :: list(),
          lb_type    = round_robin :: random | round_robin,
          ka_timeout = 60000 :: non_neg_integer(), % Keep-Alive timeout
          ka_timer   = undefined    :: reference(),

          % cached nodes for requests, because retransmission should happen for the same node
          requests,        % :: ergw_cache(),
          rt_timeout = 10000 :: non_neg_integer(), % retransmission timeout

          % timestamps for responses which used by Keep-Alive mechanism
          responses  = maps:new() :: map()
         }).

-type redirector() :: #redirector{}.

-export_type([redirector/0]).

-include_lib("gtplib/include/gtp_packet.hrl").

-include("include/ergw.hrl").

-define(T3, 10 * 1000).

init(IP, #{redirector := [_|_] = Opts}) -> 
    {ok, Socket} = gen_socket:socket(gtp_socket:family(IP), raw, udp),
    ok = gen_socket:setsockopt(Socket, sol_ip, hdrincl, true),
    ok = gen_socket:bind(Socket, {gtp_socket:family_v(IP), IP, 0}),
    KATimeout = proplists:get_value(redirector_ka_timeout, Opts, 60000),
    RTTimeout = proplists:get_value(redirector_rt_timeout, Opts, 10000),
    Nodes = proplists:get_value(redirector_nodes, Opts, []),
    TRef = erlang:start_timer(KATimeout, self(), redirector_keep_alive),
    % let's assume that on start all backends are available 
    % then set echo_response to the time now for all of them
    Responses = lists:foldl(fun(Node, Acc) -> Acc#{Node => erlang:monotonic_time()} end, #{}, Nodes),
    #redirector{socket = Socket, 
                nodes = Nodes,
                lb_type = proplists:get_value(redirector_lb_type, Opts, round_robin),
                ka_timeout = KATimeout,
                ka_timer = TRef,
                requests = ergw_cache:new(?T3 * 4, redirector_requests), 
                rt_timeout = RTTimeout,
                responses = Responses};
init(_IP, _Opts) -> undefined.

validate_option({redirector_nodes, Nodes}) when is_list(Nodes) ->
    lists:map(fun({Version, IP} = Value) when 
                     is_tuple(IP), 
                     (Version == v1 orelse Version == v2) -> Value;
                 (Value) -> throw({error, {redirector_nodes, Value}})
              end, Nodes),
    ok;
validate_option({redirector_lb_type, Type}) 
  when Type == round_robin; Type == random ->
    ok;
validate_option({redirector_ka_timeout, Timeout})
  when is_integer(Timeout), Timeout > 0 ->
    ok;
validate_option({redirector_rt_timeout, Timeout})
  when is_integer(Timeout), Timeout > 0 ->
    ok;
validate_option(Value) ->
    throw({error, {redirector_options, Value}}).

get_nodes(#redirector{nodes = Nodes}) -> Nodes;
get_nodes(_) -> [].

set_nodes(#redirector{bad_nodes = BadNodes0} = Redirector, Nodes) ->
    BadNodes = BadNodes0 -- Nodes,
    Redirector#redirector{nodes = Nodes, bad_nodes = BadNodes};
set_nodes(Redirector, _) -> Redirector.

keep_alive(#redirector{ka_timeout = KATimeout,
                       nodes = Nodes,
                       responses = Responses} = Redirector, GtpPort) ->
    NotAnswered = maps:map(fun(_K, TS) when is_integer(TS) ->  
                                   Now = erlang:monotonic_time(),
                                   Duration = erlang:convert_time_unit(Now - TS, native, millisecond),
                                   Duration > (KATimeout * 2);
                              (_K, _V) -> true
                           end, Responses),
    BadNodes = lists:filter(fun(Node) -> maps:get(Node, NotAnswered, false) end, Nodes),
    lists:foreach(fun({Version, IP}) ->
                      Msg = case Version of
                                v1 -> gtp_v1_c:build_echo_request(GtpPort);
                                v2 -> gtp_v2_c:build_echo_request(GtpPort)
                            end,
                      gtp_socket:send_request(GtpPort, IP, ?GTP1c_PORT, ?T3 * 2, 0, Msg, [])
                  end, Nodes),
    TRef = erlang:start_timer(KATimeout, self(), redirector_keep_alive),
    Redirector#redirector{ka_timer = TRef, 
                          bad_nodes = BadNodes};
keep_alive(Redirector, _) -> Redirector.

timeout_requests(#redirector{requests = Requests} = Redirector) ->
    Redirector#redirector{requests = ergw_cache:expire(Requests)};
timeout_requests(Redirector) -> Redirector.

handle_message(#redirector{socket = Socket,
                           nodes = [_|_] = Nodes,
                           bad_nodes = BadNodes,
                           rt_timeout = RTTimeout,
                           requests = Requests,
                           lb_type = LBType} = Redirector,
               GtpPort, IP, Port, 
               #gtp{type = Type, seq_no = SeqId} = Msg, Packet0)
  when Socket /= undefined, Type /= echo_response, Type /= echo_request ->
    ReqKey = {GtpPort, IP, Port, Type, SeqId},
    Result = case ergw_cache:get(ReqKey, Requests) of
                 {value, CachedNode} -> 
                     lager:debug("~p: ~p was cached for using backend: ~p", 
                                 [GtpPort#gtp_port.name, ReqKey, CachedNode]),
                     {true, {CachedNode, Nodes}};
                 _Other -> {false, apply_redirector_lb_type(Nodes, BadNodes, LBType)}
             end,
    case Result of
        {_, {error, no_nodes}} -> 
            lager:warning("~p: no nodes to redirect request ~p", 
                          [GtpPort#gtp_port.name, ReqKey]),
            Redirector;
        {Cached, {{_, DstIP} = Node, NewNodes}} ->
            % if a backend was taken from cache we should not update it in cache this time
            NewRequests = if Cached == true -> Requests;
                             true -> ergw_cache:enter(ReqKey, Node, RTTimeout, Requests)
                          end,
            Family = gtp_socket:family_v(DstIP),
            DstPort = ?GTP1c_PORT,
            Packet = case Family of
                         inet4 -> create_ipv4_udp_packet(IP, Port, DstIP, DstPort, Packet0);
                         inet6 -> throw("inet6 is not supported now")
                     end,
            gen_socket:sendto(Socket, {Family, DstIP, DstPort}, Packet),
            lager:debug("~p: redirect to ~p", [GtpPort#gtp_port.name, DstIP]),
            gtp_socket:message_counter(rr, GtpPort, IP, Msg),
            Redirector#redirector{nodes = NewNodes, requests = NewRequests}
    end;
handle_message(Redirector, _GtpPort, _IP, _Port, _Msg, _Packet) -> Redirector.

echo_response(#redirector{socket = Socket,
                          nodes = [_|_] = Nodes,
                          responses = Responses} = Redirector,
              #gtp_port{name = Name},
              IP, Port, #gtp{version = Version, type = echo_request}, 
              ArrivalTS)
  when Socket /= undefined ->
    Match = lists:any(fun({V0, IP0}) -> IP0 == IP andalso V0 == Version;
                         (_) -> false
                      end, Nodes),
    if Match == true ->
        lager:info("~p: ~p got echo_response from ~p:~p", [ArrivalTS, Name, IP, Port]),
        NewResponses = Responses#{{Version, IP} => ArrivalTS},
        Redirector#redirector{responses = NewResponses};
       true -> Redirector
    end;
echo_response(Redirector, _, _, _, _, _) -> Redirector.

optlen(HL) -> (HL - 5) * 4.
create_ipv4_udp_packet({SA1, SA2, SA3, SA4}, SPort, {DA1, DA2, DA3, DA4}, DPort, Payload) ->
    % UDP
    ULen = 8 + byte_size(Payload),
    USum = 0,
    UDP = <<SPort:16, DPort:16, ULen:16, USum:16, Payload/binary>>,
    % IPv4
    HL = 5, DSCP = 0, ECN = 0, Len = 160 + optlen(HL) + byte_size(UDP),
    Id = 0, DF = 0, MF = 0, Off = 0,
    TTL = 64, Protocol = 17, Sum = 0,
    Opt = <<>>,
    % Packet
    <<4:4, HL:4, DSCP:6, ECN:2, Len:16, 
      Id:16, 0:1, DF:1, MF:1, Off:13, 
      TTL:8, Protocol:8, Sum:16,
      SA1:8, SA2:8, SA3:8, SA4:8, 
      DA1:8, DA2:8, DA3:8, DA4:8, 
      Opt:(optlen(HL))/binary, UDP/binary>>.

apply_redirector_lb_type(Nodes, BadNodes, LBType) ->
    case Nodes -- BadNodes of
        [] -> {error, no_nodes};
        _ -> apply_redirector_lb_type_1(Nodes, BadNodes, LBType)
    end.

apply_redirector_lb_type_1([Node | Nodes], BadNodes, LBType = round_robin) ->
    case lists:member(Node, BadNodes) of
        true -> apply_redirector_lb_type_1(Nodes ++ [Node], BadNodes, LBType);
        false -> {Node, Nodes ++ [Node]} 
    end;
apply_redirector_lb_type_1(Nodes, BadNodes, random) ->
    Index = rand:uniform(length(Nodes) - length(BadNodes)),
    {lists:nth(Index, Nodes -- BadNodes), Nodes}.
