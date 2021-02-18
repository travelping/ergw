%% Copyright 2015,2018 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gtp_socket).

-compile({parse_transform, cut}).

%% API
-export([validate_options/2, config_meta/0, info/1, send/5]).
-export([make_seq_id/1, make_request/7]).
-export([make_gtp_socket/3]).

-ignore_xref([info/1, send/5]).

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
-callback send(Socket :: #socket{}, Src :: atom(), IP :: inet:ip_address(),
	       Port :: inet:port_number(), Data :: binary()) -> Result :: term().

%%====================================================================
%% API
%%====================================================================

info(Socket) ->
    invoke_handler(Socket, info, []).

send(Socket, Src, IP, Port, Data) ->
    invoke_handler(Socket, send, [Src, IP, Port, Data]).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(SocketDefaults, [{ip, invalid}, {burst_size, 10}, {send_port, true}]).

validate_options(Name, Values) ->
    maps:remove(
      name,
      ergw_config_legacy:validate_options(fun validate_option/2, Values,
					  [{vrf, Name}|?SocketDefaults], map)).

validate_option(name, Value) ->
    Value;
validate_option(type, 'gtp-c' = Value) ->
    Value;
validate_option(type, 'gtp-u' = Value) ->
    Value;
validate_option(ip, Value)
  when is_tuple(Value) andalso
       (tuple_size(Value) == 4 orelse tuple_size(Value) == 8) ->
    Value;
validate_option(cluster_ip, Value)
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
validate_option(send_port, Port)
  when is_integer(Port) andalso
       (Port =:= 0 orelse (Port >= 1024 andalso Port < 65536)) ->
    Port;
validate_option(send_port, true) ->
    0;
validate_option(send_port, false) ->
    false;
validate_option(rcvbuf, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(burst_size, Value)
  when is_integer(Value) andalso Value > 0 ->
    Value;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

config_meta() ->
    load_typespecs(),

    Meta = #{name => atom,
	     type => {enum, atom, ['gtp-c', 'gtp-u']},
	     ip => {ip_address, invalid},
	     cluster_ip => ip_address,
	     netdev => string,
	     netns => string,
	     vrf => vrf,
	     freebind => boolean,
	     reuseaddr => boolean,
	     send_port => {send_port, true},
	     rcvbuf => integer,
	     burst_size => {integer, 10}},
    ergw_config:normalize_meta(Meta).

is_send_port(V) when is_boolean(V) ->
    true;
is_send_port(Port) ->
    is_integer(Port)
	andalso (Port =:= 0 orelse (Port >= 1024 andalso Port < 65536)).

to_send_port(Port) ->
    case (catch ergw_config:to_atom(Port)) of
	V when is_boolean(V) ->
	    V;
	_ ->
	    ergw_config:to_integer(Port)
    end.

from_send_port(Port) when is_atom(Port) ->
    Port;
from_send_port(Port) -> Port.

serialize_schema_send_port() ->
    #{'oneOf' =>
	  [#{type => boolean},
	   #{type => integer}]}.

%%%===================================================================
%%% Type Specs
%%%===================================================================

load_typespecs() ->
    Spec =
	#{
	  send_port =>
	      #cnf_type{
		 schema    = fun serialize_schema_send_port/0,
		 coerce = fun to_send_port/1,
		 serialize = fun from_send_port/1,
		 validate = fun is_send_port/1
		}
	 },
    ergw_config:register_typespec(Spec).

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

-if(?OTP_RELEASE =< 23).
-define(BIND_OK, {ok, _}).
-else.
-define(BIND_OK, ok).
-endif.

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
    ?BIND_OK = socket:bind(Socket, #{family => inet, addr => IP, port => Port}),
    ok = socket:setopt(Socket, ip, recverr, true),
    ok = socket:setopt(Socket, ip, mtu_discover, dont),
    maps:fold(fun(K, V, ok) -> ok = socket_setopts(Socket, K, V) end, ok, Opts),
    {ok, Socket};

bind_gtp_socket(Socket, {_,_,_,_,_,_,_,_} = IP, Port, Opts) ->
    ok = socket:setopt(Socket, ipv6, v6only, true),
    ok = socket_netdev(Socket, Opts),
    ?BIND_OK = socket:bind(Socket, #{family => inet6, addr => IP, port => Port}),
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

make_request(ArrivalTS, Src, IP, Port, Msg = #gtp{version = Version, type = Type},
	     #socket{name = SocketName} = Socket, Info) ->
    SeqId = make_seq_id(Msg),
    #request{
       key = {request, {SocketName, IP, Port, Type, SeqId}},
       socket = Socket,
       info = Info,
       src = Src,
       ip = IP,
       port = Port,
       version = Version,
       type = Type,
       arrival_ts = ArrivalTS}.
