%% Copyright 2015,2018 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gtp_socket).

-compile({parse_transform, cut}).

%% API
-export([validate_options/2, info/1, send/4]).
-export([make_seq_id/1, make_request/6]).
-export([make_gtp_socket/3]).

-ignore_xref([info/1, send/4]).

-if(?OTP_RELEASE =< 23).
-ignore_xref([behaviour_info/1]).
-endif.

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-define(EXO_PERF_OPTS, [{time_span, 300 * 1000}]).		%% 5 min histogram

%%====================================================================
%% Behavior spec
%%====================================================================

-callback info(Socket :: #socket{}) -> Info :: term().
-callback send(Socket :: #socket{}, IP :: inet:ip_address(),
	       Port :: inet:port_number(), Data :: binary()) -> Result :: term().

%%====================================================================
%% API
%%====================================================================

info(Socket) ->
    invoke_handler(Socket, info, []).

send(Socket, IP, Port, Data) ->
    invoke_handler(Socket, send, [IP, Port, Data]).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(SocketDefaults, [{ip, invalid}, {burst_size, 10}]).

validate_options(Name, Values) ->
    ergw_config:validate_options(fun validate_option/2, Values,
				 [{name, Name}|?SocketDefaults], map).

validate_option(name, Value) when is_atom(Value) ->
    Value;
validate_option(type, 'gtp-c' = Value) ->
    Value;
validate_option(type, 'gtp-u' = Value) ->
    Value;
validate_option(ip, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Value;
validate_option(netdev, Value) when is_list(Value) ->
    Value;
validate_option(netdev, Value) when is_binary(Value) ->
    unicode:characters_to_list(Value, latin1);
validate_option(netns, Value) when is_list(Value) ->
    Value;
validate_option(netns, Value) when is_binary(Value) ->
    unicode:characters_to_list(Value, latin1);
validate_option(vrf, Value) ->
    vrf:validate_name(Value);
validate_option(freebind, Value) when is_boolean(Value) ->
    Value;
validate_option(reuseaddr, Value) when is_boolean(Value) ->
    Value;
validate_option(rcvbuf, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(burst_size, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% Internal functions
%%%===================================================================

invoke_handler(#socket{type = 'gtp-c'} = Socket, F, A) ->
    erlang:apply(ergw_gtp_c_socket, F, [Socket | A]);
invoke_handler(#socket{type = 'gtp-u'} = Socket, F, A) ->
    erlang:apply(ergw_gtp_u_socket, F, [Socket | A]).

%%%===================================================================
%%% Socket Helper
%%%===================================================================

family({_,_,_,_}) -> inet;
family({_,_,_,_,_,_,_,_}) -> inet6.

make_gtp_socket(IP, Port, #{netns := NetNs} = Opts)
  when is_list(NetNs) ->
    {ok, Socket} = socket:open(family(IP), dgram, udp, #{netns => NetNs}),
    bind_gtp_socket(Socket, IP, Port, Opts);
make_gtp_socket(IP, Port, Opts) ->
    {ok, Socket} = socket:open(family(IP), dgram, udp),
    bind_gtp_socket(Socket, IP, Port, Opts).

bind_gtp_socket(Socket, {_,_,_,_} = IP, Port, Opts) ->
    ok = socket_ip_freebind(Socket, Opts),
    ok = socket_netdev(Socket, Opts),
    {ok, _} = socket:bind(Socket, #{family => inet, addr => IP, port => Port}),
    ok = socket:setopt(Socket, ip, recverr, true),
    ok = socket:setopt(Socket, ip, mtu_discover, dont),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    {ok, Socket};

bind_gtp_socket(Socket, {_,_,_,_,_,_,_,_} = IP, Port, Opts) ->
    ok = socket:setopt(Socket, ipv6, v6only, true),
    ok = socket_netdev(Socket, Opts),
    {ok, _} = socket:bind(Socket, #{family => inet6, addr => IP, port => Port}),
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

%%%===================================================================
%%% Request Helper
%%%===================================================================

make_seq_id(#gtp{version = Version, seq_no = SeqNo})
  when is_integer(SeqNo) ->
    {Version, SeqNo};
make_seq_id(_) ->
    undefined.

make_request(ArrivalTS, IP, Port, Msg = #gtp{version = Version, type = Type}, Socket, Info) ->
    SeqId = make_seq_id(Msg),
    #request{
       key = {Socket, IP, Port, Type, SeqId},
       socket = Socket,
       info = Info,
       ip = IP,
       port = Port,
       version = Version,
       type = Type,
       arrival_ts = ArrivalTS}.
