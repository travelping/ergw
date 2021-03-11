-module('3gpp_qos').

-export([decode/1, encode/1]).

-include("include/3gpp.hrl").

%%====================================================================
%% API
%%====================================================================

decode(<<_:2, DelayClass:3, ReliabilityClass:3,
	 PeakThroughput:4, _:1, PrecedenceClass:3,
	 _:3, MeanThroughput:5,
	 TrafficClass:3, DeliveryOrder:2, DeliveryOfErroneorousSDU:3,
	 MaxSDUsize:8,
	 MaxBitRateUpLink:8,
	 MaxBitRateDownLink:8,
	 ResidualBER:4, SDUerrorRatio:4,
	 TransferDelay:6, TrafficHandlingPriority:2,
	 GuaranteedBitRateUpLink:8,
	 GuaranteedBitRateDownLink:8,
	 Optional/binary>> = IE) ->
    QoS = #qos{
	     delay_class			= DelayClass,
	     reliability_class			= ReliabilityClass,
	     peak_throughput			= PeakThroughput,
	     precedence_class			= PrecedenceClass,
	     mean_throughput			= MeanThroughput,
	     traffic_class			= TrafficClass,
	     delivery_order			= DeliveryOrder,
	     delivery_of_erroneorous_sdu	= DeliveryOfErroneorousSDU,
	     max_sdu_size			= decode_sdu_size(MaxSDUsize),
	     max_bit_rate_uplink		= decode_br(MaxBitRateUpLink),
	     max_bit_rate_downlink		= decode_br(MaxBitRateDownLink),
	     residual_ber			= ResidualBER,
	     sdu_error_ratio			= SDUerrorRatio,
	     transfer_delay			= decode_delay(TransferDelay),
	     traffic_handling_priority		= TrafficHandlingPriority,
	     guaranteed_bit_rate_uplink		= decode_br(GuaranteedBitRateUpLink),
	     guaranteed_bit_rate_downlink	= decode_br(GuaranteedBitRateDownLink),
	     signaling_indication		= 0,
	     source_statistics_descriptor	= 0
	    },
    decode(IE, 14, Optional, QoS);
decode(IE) ->
    IE.

encode(IE) when is_binary(IE) ->
    IE;
encode(#qos{
	  delay_class			= DelayClass,
	  reliability_class		= ReliabilityClass,
	  peak_throughput		= PeakThroughput,
	  precedence_class		= PrecedenceClass,
	  mean_throughput		= MeanThroughput,
	  traffic_class			= TrafficClass,
	  delivery_order		= DeliveryOrder,
	  delivery_of_erroneorous_sdu	= DeliveryOfErroneorousSDU,
	  max_sdu_size			= MaxSDUsize,
	  max_bit_rate_uplink		= MaxBitRateUpLink,
	  max_bit_rate_downlink		= MaxBitRateDownLink,
	  residual_ber			= ResidualBER,
	  sdu_error_ratio		= SDUerrorRatio,
	  transfer_delay		= TransferDelay,
	  traffic_handling_priority	= TrafficHandlingPriority,
	  guaranteed_bit_rate_uplink	= GuaranteedBitRateUpLink,
	  guaranteed_bit_rate_downlink	= GuaranteedBitRateDownLink
	 } = QoS) ->
    IE = <<0:2, DelayClass:3, ReliabilityClass:3,
	   PeakThroughput:4, 0:1, PrecedenceClass:3,
	   0:3, MeanThroughput:5,
	   TrafficClass:3, DeliveryOrder:2, DeliveryOfErroneorousSDU:3,
	   (encode_sdu_size(MaxSDUsize)):8,
	   (encode_br(MaxBitRateUpLink)):8,
	   (encode_br(MaxBitRateDownLink)):8,
	   ResidualBER:4, SDUerrorRatio:4,
	   (encode_delay(TransferDelay)):6, TrafficHandlingPriority:2,
	   (encode_br(GuaranteedBitRateUpLink)):8,
	   (encode_br(GuaranteedBitRateDownLink)):8>>,
    encode_optional(IE, QoS).

%%%===================================================================
%%% Internal functions
%%%===================================================================

pad_length(Width, Length) ->
    (Width - Length rem Width) rem Width.

%%
%% pad binary to specific length
%%   -> http://www.erlang.org/pipermail/erlang-questions/2008-December/040709.html
%%
pad_to(Width, Binary) ->
    case pad_length(Width, size(Binary)) of
        0 -> Binary;
        N -> <<Binary/binary, 0:(N*8)>>
    end.

%% 3GPP TS 24.008, Sect. 10.5.6.5, Table 10.5.156
decode_sdu_size(0) -> subscribed;
decode_sdu_size(X) when X =< 2#10010110 -> X * 10;
decode_sdu_size(2#10010111) -> 1502;
decode_sdu_size(2#10011000) -> 1510;
decode_sdu_size(2#10011001) -> 1520;
decode_sdu_size(_) -> reserved.

encode_sdu_size(subscribed) -> 0;
encode_sdu_size(X) when is_integer(X), X =< 1500 -> (X + 9) div 10;
encode_sdu_size(1502) -> 2#10010111;
encode_sdu_size(1510) -> 2#10011000;
encode_sdu_size(1520) -> 2#10011001;
encode_sdu_size(_) -> 2#11111111.

decode_br(2#00000000) -> subscribed;
decode_br(2#11111111) -> 0;
decode_br(V) ->
    case V bsr 6 of
	0 -> V;
	1 ->  64 + (V - 2#01000000) * 8;
	_ -> 576 + (V - 2#10000000) * 64
    end.

encode_br(subscribed) -> 2#00000000;
encode_br(0) -> 2#11111111;
encode_br(V) when V =< 63   -> V;
encode_br(V) when V =< 568  -> ((V -  64) div  8) + 2#01000000;
encode_br(V) when V =< 8640 -> ((V - 576) div 64) + 2#10000000;
encode_br(_) -> 2#11111110.

decode_ext_br(0, P) -> P;
decode_ext_br(V, _) when V =< 2#01001010 ->   8600 + V * 100;
decode_ext_br(V, _) when V =< 2#10111010 ->  16000 + (V - 2#01001010) * 1000;
decode_ext_br(V, _) when V =< 2#11111010 -> 128000 + (V - 2#10111010) * 2000;
decode_ext_br(_, _) -> 256000.

encode_ext_br(subscribed) -> 0;
encode_ext_br(V) when V =<   8640 -> 2#00000000;
encode_ext_br(V) when V =<  16000 -> ((V -  8600) div 100);
encode_ext_br(V) when V =< 128000 -> ((V - 16000) div 1000) + 2#01001010;
encode_ext_br(V) when V =< 256000 -> ((V -128000) div 2000) + 2#10111010;
encode_ext_br(_) -> 2#11111010.

decode_ext2_br(0, P) -> P;
decode_ext2_br(V, _) when V =< 2#00111101 ->  256000 + V * 4000;
decode_ext2_br(V, _) when V =< 2#10100001 ->  500000 + (V - 2#00111101) *  10000;
decode_ext2_br(V, _) when V =< 2#11110110 -> 1500000 + (V - 2#10100001) * 100000;
decode_ext2_br(_, _) -> 10000000.

encode_ext2_br(subscribed) -> 0;
encode_ext2_br(V) when V =<   256000 -> 2#00000000;
encode_ext2_br(V) when V =<   500000 -> ((V -  256000) div   4000);
encode_ext2_br(V) when V =<  1500000 -> ((V -  500000) div  10000) + 2#00111101;
encode_ext2_br(V) when V =< 10000000 -> ((V - 1500000) div 100000) + 2#10100001;
encode_ext2_br(_) -> 2#11110110.

decode_delay(0) -> subscribed;
decode_delay(V) when V =< 2#001111 -> V * 10;
decode_delay(V) when V =< 2#011111 ->  200 + (V - 2#010000) * 50;
decode_delay(V) when V =< 2#111110 -> 1000 + (V - 2#100000) * 100;
decode_delay(_) -> reserved.

encode_delay(subscribed) -> 0;
encode_delay(V) when V =< 150  -> V div 10;
encode_delay(V) when V =< 950  -> ((V -  200) div  50) + 2#010000;
encode_delay(V) when V =< 4000 -> ((V - 1000) div 100) + 2#100000;
encode_delay(_) -> 2#111111.

decode(_IE, _Octet, <<>>, QoS) ->
    QoS;
decode(IE, 14, <<_:3, SignalingIndication:1, SourceStatisticsDescriptor:4, Optional/binary>>, QoS0) ->
    QoS = QoS0#qos{
	    signaling_indication		= SignalingIndication,
	    source_statistics_descriptor	= SourceStatisticsDescriptor
	   },
    decode(IE, 15, Optional, QoS);

decode(IE, 15, <<MaxBitRateDownLinkExt:8, GuaranteedBitRateDownLinkExt:8, Optional/binary>>,
       #qos{max_bit_rate_downlink        = MaxBitRateDownLink,
	    guaranteed_bit_rate_downlink = GuaranteedBitRateDownLink} = QoS0) ->
    QoS = QoS0#qos{
	    max_bit_rate_downlink        = decode_ext_br(MaxBitRateDownLinkExt, MaxBitRateDownLink),
	    guaranteed_bit_rate_downlink = decode_ext_br(GuaranteedBitRateDownLinkExt, GuaranteedBitRateDownLink)
	   },
    decode(IE, 17, Optional, QoS);

decode(IE, 17, <<MaxBitRateUpLinkExt:8, GuaranteedBitRateUpLinkExt:8, Optional/binary>>,
       #qos{max_bit_rate_uplink        = MaxBitRateUpLink,
	    guaranteed_bit_rate_uplink = GuaranteedBitRateUpLink} = QoS0) ->
    QoS = QoS0#qos{
	    max_bit_rate_uplink        = decode_ext_br(MaxBitRateUpLinkExt, MaxBitRateUpLink),
	    guaranteed_bit_rate_uplink = decode_ext_br(GuaranteedBitRateUpLinkExt, GuaranteedBitRateUpLink)
	   },
    decode(IE, 19, Optional, QoS);

decode(IE, 19, <<MaxBitRateDownLinkExt:8, GuaranteedBitRateDownLinkExt:8, Optional/binary>>,
       #qos{max_bit_rate_downlink        = MaxBitRateDownLink,
	    guaranteed_bit_rate_downlink = GuaranteedBitRateDownLink} = QoS0) ->
    QoS = QoS0#qos{
	    max_bit_rate_downlink        = decode_ext2_br(MaxBitRateDownLinkExt, MaxBitRateDownLink),
	    guaranteed_bit_rate_downlink = decode_ext2_br(GuaranteedBitRateDownLinkExt, GuaranteedBitRateDownLink)
	   },
    decode(IE, 21, Optional, QoS);

decode(IE, 21, <<MaxBitRateUpLinkExt:8, GuaranteedBitRateUpLinkExt:8, Optional/binary>>,
       #qos{max_bit_rate_uplink        = MaxBitRateUpLink,
	    guaranteed_bit_rate_uplink = GuaranteedBitRateUpLink} = QoS0) ->
    QoS = QoS0#qos{
	    max_bit_rate_uplink        = decode_ext2_br(MaxBitRateUpLinkExt, MaxBitRateUpLink),
	    guaranteed_bit_rate_uplink = decode_ext2_br(GuaranteedBitRateUpLinkExt, GuaranteedBitRateUpLink)
	   },
    decode(IE, 23, Optional, QoS);

decode(_IE, _Octet, _Rest, QoS) ->
    %% decoding of optional fields failed, but
    %% TS 29.060, Sect. 11.1.6 Invalid IE Length says:
    %%
    %%     if the Length field value is less than the number of fixed octets
    %%     defined for that IE, preceding the extended field(s), the receiver
    %%     shall try to continue the procedure, if possible.
    %%
    %% so, lets continue what we have so far
    QoS.

-define(OPTIONAL_OCTETS, [14, 15, 17, 19, 21]).
encode_optional(IE, QoS) ->
    lists:foldl(fun(Octet, Acc) -> encode(Octet, Acc, QoS) end, IE, ?OPTIONAL_OCTETS).

encode(14, IE, #qos{signaling_indication         = SignalingIndication,
		    source_statistics_descriptor = SourceStatisticsDescriptor})
  when is_integer(SignalingIndication),
       is_integer(SourceStatisticsDescriptor) ->
    <<(pad_to(11, IE))/binary, 0:3, SignalingIndication:1, SourceStatisticsDescriptor:4>>;

encode(15, IE, #qos{max_bit_rate_downlink        = MaxBitRateDownLink,
		    guaranteed_bit_rate_downlink = GuaranteedBitRateDownLink})
  when (is_integer(MaxBitRateDownLink)        andalso MaxBitRateDownLink        > 8600) orelse
       (is_integer(GuaranteedBitRateDownLink) andalso GuaranteedBitRateDownLink > 8600) ->
    <<(pad_to(12, IE))/binary, (encode_ext_br(MaxBitRateDownLink)):8,
                               (encode_ext_br(GuaranteedBitRateDownLink)):8>>;

encode(17, IE, #qos{max_bit_rate_uplink          = MaxBitRateUpLink,
		    guaranteed_bit_rate_uplink   = GuaranteedBitRateUpLink})
  when (is_integer(MaxBitRateUpLink)          andalso MaxBitRateUpLink          > 8600) orelse
       (is_integer(GuaranteedBitRateUpLink)   andalso GuaranteedBitRateUpLink   > 8600) ->
    <<(pad_to(14, IE))/binary, (encode_ext_br(MaxBitRateUpLink)):8,
                                (encode_ext_br(GuaranteedBitRateUpLink)):8>>;

encode(19, IE, #qos{max_bit_rate_downlink        = MaxBitRateDownLink,
		    guaranteed_bit_rate_downlink = GuaranteedBitRateDownLink})
  when (is_integer(MaxBitRateDownLink)        andalso MaxBitRateDownLink        > 256000) orelse
       (is_integer(GuaranteedBitRateDownLink) andalso GuaranteedBitRateDownLink > 256000) ->
    <<(pad_to(16, IE))/binary, (encode_ext2_br(MaxBitRateDownLink)):8,
                               (encode_ext2_br(GuaranteedBitRateDownLink)):8>>;

encode(21, IE, #qos{max_bit_rate_uplink          = MaxBitRateUpLink,
		    guaranteed_bit_rate_uplink   = GuaranteedBitRateUpLink})
  when (is_integer(MaxBitRateUpLink)          andalso MaxBitRateUpLink          > 256000) orelse
       (is_integer(GuaranteedBitRateUpLink)   andalso GuaranteedBitRateUpLink   > 256000) ->
    <<(pad_to(18, IE))/binary, (encode_ext2_br(MaxBitRateUpLink)):8,
                               (encode_ext2_br(GuaranteedBitRateUpLink)):8>>;

encode(_Octet, IE, _QoS) ->
    IE.
