%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_inet).

-export([ip2bin/1, bin2ip/1,
	 ipv6_interface_id/2,
	 ipv6_prefix/1, ipv6_prefix/2]).
-export([ip_csum/1, make_udp/5]).

-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).
-define(IPPROTO_UDP, 17).

%%====================================================================
%% IP Address helpers
%%====================================================================

ip2bin(V) when is_atom(V) ->
    V;
ip2bin(IP) when is_binary(IP) ->
    IP;
ip2bin({A, B, C, D}) ->
    <<A, B, C, D>>;
ip2bin({A, B, C, D, E, F, G, H}) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>.

bin2ip(V) when is_atom(V) ->
    V;
bin2ip(<<A, B, C, D>>) ->
    {A, B, C, D};
bin2ip(<<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>) ->
    {A, B, C, D, E, F, G, H}.

ipv6_interface_id({Prefix, PrefixLen}, IntId) when PrefixLen =< 126 ->
    IP = ipv6_interface_id(ergw_inet:ip2bin(Prefix), PrefixLen,
			   ergw_inet:ip2bin(IntId)),
    {ergw_inet:bin2ip(IP), PrefixLen};
ipv6_interface_id(Other, _) ->
    Other.

ipv6_interface_id(Prefix, PrefixLen, InterfaceId)
  when is_binary(Prefix), is_binary(InterfaceId) ->
    <<PrefixPart:PrefixLen/bits, _/bits>> = Prefix,
    <<_:PrefixLen/bits, IntIdPart/bits>> = InterfaceId,
    <<PrefixPart/bits, IntIdPart/bits>>.

%% ipv6_interface_id({{_,_,_,_,A,B,C,D}, _}) ->
%%     {0,0,0,0,A,B,C,D}.

ipv6_prefix({_, Len} = Prefix) when Len =:= 0, Len =:= 128 ->
    Prefix;
ipv6_prefix({Prefix, Len}) ->
    <<IP:Len/bits, _/bitstring>> = ergw_inet:ip2bin(Prefix),
    {ergw_inet:bin2ip(<<IP/bitstring, 0:(128 - Len)>>), Len}.

ipv6_prefix({Prefix, _}, Len) ->
    ipv6_prefix({Prefix, Len}).

%%%===================================================================
%%% Raw IP helper
%%%===================================================================

ip_csum(<<>>, CSum) ->
    CSum;
ip_csum(<<Head:8/integer>>, CSum) ->
    CSum + Head * 256;
ip_csum(<<Head:16/integer, Tail/binary>>, CSum) ->
    ip_csum(Tail, CSum + Head).

ip_csum(Bin) ->
    CSum0 = ip_csum(Bin, 0),
    CSum1 = ((CSum0 band 16#ffff) + (CSum0 bsr 16)),
    ((CSum1 band 16#ffff) + (CSum1 bsr 16)) bxor 16#ffff.


make_udp(NwSrc, NwDst, TpSrc, TpDst, PayLoad)
  when size(NwSrc) =:= 4, size(NwDst) =:= 4 ->
    Id = 0,
    Proto = ?IPPROTO_UDP,

    UDPLength = 8 + size(PayLoad),
    UDPCSum = ip_csum(<<NwSrc:4/bytes-unit:8, NwDst:4/bytes-unit:8,
			0:8, Proto:8, UDPLength:16,
			TpSrc:16, TpDst:16, UDPLength:16, 0:16,
			PayLoad/binary>>),
    UDP = <<TpSrc:16, TpDst:16, UDPLength:16, UDPCSum:16, PayLoad/binary>>,

    TotLen = 20 + size(UDP),
    HdrCSum = ip_csum(<<4:4, 5:4, 0:8, TotLen:16,
			Id:16, 0:16, 64:8, Proto:8,
			0:16/integer, NwSrc:4/bytes-unit:8, NwDst:4/bytes-unit:8>>),
    IP = <<4:4, 5:4, 0:8, TotLen:16,
	   Id:16, 0:16, 64:8, Proto:8,
	   HdrCSum:16/integer, NwSrc:4/bytes-unit:8, NwDst:4/bytes-unit:8>>,
    list_to_binary([IP, UDP]);

make_udp(NwSrc, NwDst, TpSrc, TpDst, PayLoad)
  when size(NwSrc) =:= 16, size(NwDst) =:= 16 ->
    FlowLabel = rand:uniform(16#ffffff),
    Proto = ?IPPROTO_UDP,

    UDPLength = 8 + size(PayLoad),
    UDPCSum = ip_csum(<<NwSrc:16/bytes-unit:8, NwDst:16/bytes-unit:8,
			UDPLength:32,
			0:24, Proto:8,
			TpSrc:16, TpDst:16, UDPLength:16, 0:16,
			PayLoad/binary>>),
    <<6:4, 0:8, FlowLabel:20,
      UDPLength:16, Proto:8, 64:8,
      NwSrc:16/bytes-unit:8, NwDst:16/bytes-unit:8,
      TpSrc:16, TpDst:16, UDPLength:16, UDPCSum:16, PayLoad/binary>>.
