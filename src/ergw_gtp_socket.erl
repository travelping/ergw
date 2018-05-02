%% Copyright 2015,2018 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gtp_socket).

-compile({parse_transform, cut}).

%% API
-export([validate_options/1, start_socket/2, start_link/1,
	 send/4, get_restart_counter/1]).
-export([make_seq_id/1, make_request/5]).
-export([make_gtp_socket/3]).

-include_lib("gen_socket/include/gen_socket.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-define(EXO_PERF_OPTS, [{time_span, 300 * 1000}]).		%% 5 min histogram

%%====================================================================
%% API
%%====================================================================

start_socket(Name, Opts)
  when is_atom(Name) ->
    ergw_gtp_socket_sup:new({Name, Opts}).

start_link('gtp-c', Opts) ->
    ergw_gtp_c_socket:start_link(Opts);
start_link('gtp-u', Opts) ->
    ergw_gtp_u_socket:start_link(Opts).

start_link(Socket = {_Name, #{type := Type}}) ->
    start_link(Type, Socket);
start_link(Socket = {_Name, SocketOpts})
  when is_list(SocketOpts) ->
    Type = proplists:get_value(type, SocketOpts, 'gtp-c'),
    start_link(Type, Socket).

send(GtpPort, IP, Port, Data) ->
    invoke_handler(GtpPort, send, [IP, Port, Data]).

get_restart_counter(GtpPort) ->
    invoke_handler(GtpPort, get_restart_counter, []).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(SocketDefaults, [{ip, invalid}]).

validate_options(Values0) ->
    Values = if is_list(Values0) ->
		     proplists:unfold(Values0);
		true ->
		     Values0
	     end,
    ergw_config:validate_options(fun validate_option/2, Values, ?SocketDefaults, map).

validate_option(name, Value) when is_atom(Value) ->
    Value;
validate_option(type, 'gtp-c') ->
    'gtp-c';
validate_option(type, 'gtp-u') ->
    'gtp-u';
validate_option(ip, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Value;
validate_option(netdev, Value)
  when is_list(Value); is_binary(Value) ->
    Value;
validate_option(netns, Value)
  when is_list(Value); is_binary(Value) ->
    Value;
validate_option(freebind, Value) when is_boolean(Value) ->
    Value;
validate_option(reuseaddr, Value) when is_boolean(Value) ->
    Value;
validate_option(rcvbuf, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% Internal functions
%%%===================================================================

invoke_handler(#gtp_port{type = 'gtp-c'} = GtpPort, F, A) ->
    erlang:apply(ergw_gtp_c_socket, F, [GtpPort | A]);
invoke_handler(#gtp_port{type = 'gtp-u'} = GtpPort, F, A) ->
    erlang:apply(ergw_gtp_u_socket, F, [GtpPort | A]).

%%%===================================================================
%%% Socket Helper
%%%===================================================================

family({_,_,_,_}) -> inet;
family({_,_,_,_,_,_,_,_}) -> inet6.

make_gtp_socket(IP, Port, #{netns := NetNs} = Opts)
  when is_list(NetNs) ->
    {ok, Socket} = gen_socket:socketat(NetNs, family(IP), dgram, udp),
    bind_gtp_socket(Socket, IP, Port, Opts);
make_gtp_socket(IP, Port, Opts) ->
    {ok, Socket} = gen_socket:socket(family(IP), dgram, udp),
    bind_gtp_socket(Socket, IP, Port, Opts).

bind_gtp_socket(Socket, {_,_,_,_} = IP, Port, Opts) ->
    ok = socket_ip_freebind(Socket, Opts),
    ok = socket_netdev(Socket, Opts),
    ok = gen_socket:bind(Socket, {inet4, IP, Port}),
    ok = gen_socket:setsockopt(Socket, sol_ip, recverr, true),
    ok = gen_socket:setsockopt(Socket, sol_ip, mtu_discover, 0),
    ok = gen_socket:input_event(Socket, true),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    {ok, Socket};

bind_gtp_socket(Socket, {_,_,_,_,_,_,_,_} = IP, Port, Opts) ->
    %% ok = gen_socket:setsockopt(Socket, sol_ip, recverr, true),
    ok = socket_ip_freebind(Socket, Opts),
    ok = socket_netdev(Socket, Opts),
    ok = gen_socket:bind(Socket, {inet6, IP, Port}),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    ok = gen_socket:input_event(Socket, true),
    {ok, Socket}.

socket_ip_freebind(Socket, #{freebind := true}) ->
    gen_socket:setsockopt(Socket, sol_ip, freebind, true);
socket_ip_freebind(_, _) ->
    ok.

socket_netdev(Socket, #{netdev := Device}) ->
    BinDev = iolist_to_binary([Device, 0]),
    gen_socket:setsockopt(Socket, sol_socket, bindtodevice, BinDev);
socket_netdev(_, _) ->
    ok.

socket_setopts(Socket, rcvbuf, Size) when is_integer(Size) ->
    case gen_socket:setsockopt(Socket, sol_socket, rcvbufforce, Size) of
	ok -> ok;
	_  -> gen_socket:setsockopt(Socket, sol_socket, rcvbuf, Size)
    end;
socket_setopts(Socket, reuseaddr, true) ->
    ok = gen_socket:setsockopt(Socket, sol_socket, reuseaddr, true);
socket_setopts(_Socket, _, _) ->
    ok.

%%%===================================================================
%%% Request Helper
%%%===================================================================

make_seq_id(#gtp{version = Version, seq_no = SeqNo})
  when is_integer(SeqNo) ->
    {Version, SeqNo};
make_seq_id(_) ->
    undefined.

make_request(ArrivalTS, IP, Port, Msg = #gtp{version = Version, type = Type}, GtpPort) ->
    SeqId = make_seq_id(Msg),
    #request{
       key = {GtpPort, IP, Port, Type, SeqId},
       gtp_port = GtpPort,
       ip = IP,
       port = Port,
       version = Version,
       type = Type,
       arrival_ts = ArrivalTS}.
