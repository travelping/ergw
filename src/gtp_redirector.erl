%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_redirector).

-export([init/2, 
         validate_option/1, 
         keep_alive/2, 
         timeout_requests/1, 
         handle_message/6, 
         echo_response/6]).

-record(rule, {
          conditions = []          :: list({Key :: atom(), Value :: term()}),
          nodes      = []          :: list(binary())
         }).

-record(node, {
          name                    :: binary(),
          keep_alive_version = v1 :: v1 | v2, 
          address                 :: inet:ip_address()
         }).

-record(redirector, {
          socket     = undefined    :: undefined | gen_socket:socket(),

          % lists of all nodes, including bad
          nodes      = []    :: list(#node{}),

          % here we have nodes which are not answered for Keep-Alive echo request
          % no requests should be transfered to such nodes
          bad_nodes  = []    :: list(),
          lb_type    = random :: random | round_robin, % for now only random is supported
          ka_timeout = 60000 :: non_neg_integer(), % Keep-Alive timeout
          ka_timer   = undefined    :: reference(),

          rules      = []    :: list(#rule{}),

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
    KATimeout = proplists:get_value(keep_alive_timeout, Opts, 60000),
    RTTimeout = proplists:get_value(retransmit_timeout, Opts, 10000),
    Rules = [maps:from_list(Rule) || {rule, Rule} <- proplists:get_value(rules, Opts, [])],
    Nodes0 = lists:map(fun({node, Node}) -> 
                           Name = proplists:get_value(name, Node, undefined),
                           Address = proplists:get_value(address, Node, undefined),
                           Version = proplists:get_value(keep_alive_version, Node, v1),
                           {Name, {Version, Address}}
                       end, proplists:get_value(nodes, Opts, [])),
    Nodes = maps:from_list(Nodes0),
    TRef = erlang:start_timer(KATimeout, self(), redirector_keep_alive),
    % let's assume that on start all backends are available 
    % then set echo_response to the time now for all of them
    Responses = maps:fold(fun(_, Node, Acc) -> Acc#{Node => erlang:monotonic_time()} end, #{}, Nodes),
    #redirector{socket = Socket, 
                nodes = Nodes,
                rules = Rules,
                lb_type = proplists:get_value(lb_type, Opts, random),
                ka_timeout = KATimeout,
                ka_timer = TRef,
                requests = ergw_cache:new(?T3 * 4, redirector_requests), 
                rt_timeout = RTTimeout,
                responses = Responses};
init(_IP, _Opts) -> undefined.


validate_option({rules, Rules}) when is_list(Rules) ->
    lists:map(fun validate_rule/1, Rules),
    ok;
validate_option({nodes, Nodes}) when is_list(Nodes) ->
    lists:map(fun validate_node/1, Nodes),
    ok;
validate_option({lb_type, Type}) 
  when Type == round_robin; Type == random ->
    ok;
validate_option({keep_alive_timeout, Timeout})
  when is_integer(Timeout), Timeout > 0 ->
    ok;
validate_option({retransmit_timeout, Timeout})
  when is_integer(Timeout), Timeout > 0 ->
    ok;
validate_option(Value) ->
    throw({error, {redirector_options, Value}}).

validate_rule({rule, Rule}) ->
    lists:map(fun validate_rule_option/1, Rule),
    ok;
validate_rule(Value) ->
    throw({error, {redirector_rule, Value}}).

validate_rule_option({conditions, Conditions}) when is_list(Conditions) ->
    lists:map(fun validate_condition/1, Conditions),
    ok;
validate_rule_option({nodes, Nodes}) when is_list(Nodes) ->
    lists:map(fun validate_rule_node/1, Nodes),
    ok;
validate_rule_option(Value) ->
    throw({error, {redirector_rule_option, Value}}).

validate_rule_node(Node) when is_binary(Node) -> ok;
validate_rule_node(Value) ->
    throw({error, {redirector_rule, Value}}).

validate_condition({sgsn_ip, {_, _, _, _}}) ->
    ok;
validate_condition({version, Versions}) ->
    validate_versions(Versions);
validate_condition({imsi, IMSI}) when is_list(IMSI); is_binary(IMSI) ->
    ok;
validate_condition(Value) ->
    throw({error, {redirector_rule_condition, Value}}).

validate_node({node, Node}) ->
    lists:map(fun validate_node_option/1, Node),
    ok;
validate_node(Value) ->
    throw({error, {redirector_rule, Value}}).

validate_node_option({name, Name}) when is_binary(Name) ->
    ok;
validate_node_option({keep_alive_version, v1}) ->
    ok;
validate_node_option({keep_alive_version, v2}) ->
    ok;
validate_node_option({address, {_, _, _, _} = _IPv4}) ->
    ok;
validate_node_option(Value) ->
    throw({error, {redirector_node_option, Value}}).

validate_versions(Versions) when is_list(Versions) ->
    lists:map(fun validate_versions/1, Versions),
    ok;
validate_versions(v1) -> ok;
validate_versions(v2) -> ok;
validate_versions(Value) ->
    throw({error, {redirector_rule_version, Value}}).

keep_alive(#redirector{ka_timeout = KATimeout,
                       nodes = Nodes,
                       responses = Responses} = Redirector, GtpPort) ->
    NotAnswered = maps:map(fun(_K, TS) when is_integer(TS) ->  
                                   Now = erlang:monotonic_time(),
                                   Duration = erlang:convert_time_unit(Now - TS, native, millisecond),
                                   Duration > (KATimeout * 2);
                              (_K, _V) -> true
                           end, Responses),
    BadNodes = maps:filter(fun(_, Node) -> maps:get(Node, NotAnswered, false) end, Nodes),
    maps:map(fun(_, {Version, IP}) ->
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
                           rt_timeout = RTTimeout,
                           requests = Requests
                          } = Redirector,
               GtpPort, IP, Port, 
               #gtp{type = Type, seq_no = SeqId} = Msg, Packet0)
  when Socket /= undefined, Type /= echo_response, Type /= echo_request ->
    ReqKey = {GtpPort, IP, Port, Type, SeqId},
    Result = case ergw_cache:get(ReqKey, Requests) of
                 {value, CachedNode} -> 
                     lager:debug("~p: ~p was cached for using backend: ~p", 
                                 [GtpPort#gtp_port.name, ReqKey, CachedNode]),
                     {true, {CachedNode, Redirector}};
                 _Other -> {false, route(Redirector, Msg)}
             end,
    case Result of
        {_, {error, no_nodes}} -> 
            lager:warning("~p: no nodes to redirect request ~p", 
                          [GtpPort#gtp_port.name, ReqKey]),
            Redirector;
        {Cached, {{_, DstIP} = Node, NewRedirector}} ->
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
            NewRedirector#redirector{requests = NewRequests}
    end;
handle_message(Redirector, _GtpPort, _IP, _Port, _Msg, _Packet) -> Redirector.

echo_response(#redirector{socket = Socket,
                          %nodes = [_|_] = Nodes,
                          nodes = Nodes,
                          responses = Responses} = Redirector,
              #gtp_port{name = Name},
              IP, Port, #gtp{version = Version, type = echo_request}, 
              ArrivalTS)
  when Socket /= undefined ->
    Match = lists:any(fun({_, {V0, IP0}}) -> IP0 == IP andalso V0 == Version;
                         (_) -> false
                      end, maps:to_list(Nodes)),
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

route(#redirector{nodes = Nodes, 
                  bad_nodes = BadNodes} = Redirector, Msg) ->
    case maps:filter(fun(Node, _) -> not maps:is_key(Node, BadNodes) end, Nodes) of
        [] -> {error, no_nodes};
        _ -> route_1(Redirector, Msg)
    end.

route_1(#redirector{bad_nodes = BadNodes, rules = Rules} = Redirector, Msg) ->
    Rule = match(Rules, BadNodes, Msg),
    Nodes = maps:get(nodes, Rule, []),
    case lists:filter(fun(Node) -> not maps:is_key(Node, BadNodes) end, Nodes) of
        [] -> {error, no_nodes};
        Nodes0 -> 
            % random
            Index = rand:uniform(length(Nodes0)),
            Name = lists:nth(Index, Nodes0),
            {maps:get(Name, Redirector#redirector.nodes), Redirector}
    end.

match(Rules, BadNodes, Msg) ->
    IEs = (gtp_packet:decode_ies(Msg))#gtp.ie,
    Matched = lists:filter(
                fun(#{conditions := Conditions, nodes := Nodes}) ->
                        length(lists:filter(fun(Node) -> not maps:is_key(Node, BadNodes) end, Nodes)) > 0
                        andalso
                        lists:all(fun({sgsn_ip, IP}) -> match_sender_ip(Msg#gtp.version, IP, IEs);
                                     ({version, Versions}) when is_list(Versions) -> 
                                          lists:member(Msg#gtp.version, Versions);
                                     ({version, Version}) -> Version == Msg#gtp.version;
                                     ({imsi, IMSI}) -> match_imsi(Msg#gtp.version, IMSI, IEs);
                                     (_) -> false
                                  end, Conditions);
                   (_) -> false
                end, Rules),
    case Matched of
        [Rule | _] -> Rule;
        _ -> #{nodes => []}
    end.

match_sender_ip(v1, IP, IEs) ->
    #gsn_address{address = IP0} 
        = maps:get({gsn_address, 0}, IEs,
                   #gsn_address{}),
    if is_tuple(IP) -> gtp_c_lib:ip2bin(IP) == IP0;
       true -> IP == IP0
    end;

match_sender_ip(v2, IP, IEs) ->
    #v2_fully_qualified_tunnel_endpoint_identifier{ipv4 = IP0} 
        = maps:get({v2_fully_qualified_tunnel_endpoint_identifier, 0}, IEs, 
                   #v2_fully_qualified_tunnel_endpoint_identifier{}),
    if is_tuple(IP) -> gtp_c_lib:ip2bin(IP) == IP0;
       true -> IP == IP0
    end;

match_sender_ip(_, _, _) -> false.

match_imsi(v1, IMSI, IEs) ->
    #international_mobile_subscriber_identity{imsi = IMSI0} 
        = maps:get({international_mobile_subscriber_identity, 0}, IEs, 
                   #international_mobile_subscriber_identity{}),
    if is_list(IMSI) -> list_to_binary(IMSI) == IMSI0;
       true -> IMSI == IMSI0
    end;

match_imsi(v2, IMSI, IEs) ->
    #v2_international_mobile_subscriber_identity{imsi = IMSI0} 
        = maps:get({v2_international_mobile_subscriber_identity, 0}, IEs, 
                   #v2_international_mobile_subscriber_identity{}),
    if is_list(IMSI) -> list_to_binary(IMSI) == IMSI0;
       true -> IMSI == IMSI0
    end;

match_imsi(_, _, _) -> false.
