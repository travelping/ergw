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
	     guaranteed_bit_rate_downlink	= decode_br(GuaranteedBitRateDownLink)
	    },
    decode(IE, octet14, Optional, QoS);
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
    encode(octet14, IE, QoS).

%%%===================================================================
%%% Internal functions
%%%===================================================================

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
	1 -> V * 8;
	_ -> V * 64
    end.

encode_br(subscribed) -> 2#00000000;
encode_br(0) -> 2#11111111;
encode_br(V) when V =< 63   -> V;
encode_br(V) when V =< 568  -> ((V -  64) div  8) + 2#01000000;
encode_br(V) when V =< 8640 -> ((V - 576) div 64) + 2#10000000;
encode_br(_) -> 2#11111110.

decode_ext_br(0, P) -> P;
decode_ext_br(V, _) when V >= 2#00000001 andalso V =< 2#01001010 ->   8600 + V * 100;
decode_ext_br(V, _) when V >= 2#01001011 andalso V =< 2#10111010 ->  16000 + (V - 2#01001010) * 1000;
decode_ext_br(V, _) when V >= 2#10111011 andalso V =< 2#11111010 -> 128000 + (V - 2#10111010) * 2000;
decode_ext_br(_, _) -> 256000.

encode_ext_br(V) when V =<   8640 -> 2#00000000;
encode_ext_br(V) when V =<  16000 -> ((V -  8600) div 100);
encode_ext_br(V) when V =< 128000 -> ((V - 16000) div 1000) + 2#01001010;
encode_ext_br(V) when V =< 256000 -> ((V -128000) div 2000) + 2#10111010;
encode_ext_br(_) -> 2#11111010.

decode_delay(0) -> subscribed;
decode_delay(V) when V >= 2#000001 andalso V =< 2#001111 -> V * 10;
decode_delay(V) when V >= 2#010000 andalso V =< 2#011111 ->  200 + (V - 2#01000000) * 50;
decode_delay(V) when V >= 2#100000 andalso V =< 2#111110 -> 1000 + (V - 2#10000000) * 100;
decode_delay(_) -> reserved.

encode_delay(subscribed) -> 0;
encode_delay(V) when V =< 150  -> V div 10;
encode_delay(V) when V =< 950  -> ((V -  200) div  50) + 2#010000;
encode_delay(V) when V =< 4000 -> ((V - 1000) div 100) + 2#100000;
encode_delay(_) -> 2#111111.

decode(_IE, _Octet, <<>>, QoS) ->
    QoS;
decode(IE, octet14, <<_:3, SignalingIndication:1, SourceStatisticsDescriptor:4, Optional/binary>>, QoS0) ->
    QoS = QoS0#qos{
	    signaling_indication		= SignalingIndication,
	    source_statistics_descriptor	= SourceStatisticsDescriptor
	   },
    decode(IE, octet15, Optional, QoS);

decode(IE, octet15, <<MaxBitRateDownLinkExt:8, GuaranteedBitRateDownLinkExt:8, Optional/binary>>,
       #qos{max_bit_rate_downlink        = MaxBitRateDownLink,
	    guaranteed_bit_rate_downlink = GuaranteedBitRateDownLink} = QoS0) ->
    QoS = QoS0#qos{
	    max_bit_rate_downlink        = decode_ext_br(MaxBitRateDownLinkExt, MaxBitRateDownLink),
	    guaranteed_bit_rate_downlink = decode_ext_br(GuaranteedBitRateDownLinkExt, GuaranteedBitRateDownLink)
	   },
    decode(IE, octet17, Optional, QoS);

decode(IE, octet17, <<MaxBitRateUpLinkExt:8, GuaranteedBitRateUpLinkExt:8, Optional/binary>>,
       #qos{max_bit_rate_uplink        = MaxBitRateUpLink,
	    guaranteed_bit_rate_uplink = GuaranteedBitRateUpLink} = QoS0) ->
    QoS = QoS0#qos{
	    max_bit_rate_uplink        = decode_ext_br(MaxBitRateUpLinkExt, MaxBitRateUpLink),
	    guaranteed_bit_rate_uplink = decode_ext_br(GuaranteedBitRateUpLinkExt, GuaranteedBitRateUpLink)
	   },
    decode(IE, octet19, Optional, QoS);

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

encode(octet14, IE0, #qos{signaling_indication         = SignalingIndication,
			  source_statistics_descriptor = SourceStatisticsDescriptor} = QoS)
  when is_integer(SignalingIndication),
       is_integer(SourceStatisticsDescriptor) ->
    IE = <<IE0/binary, 0:3, SignalingIndication:1, SourceStatisticsDescriptor:4>>,
    encode(octet15, IE, QoS);

encode(octet15, IE0, #qos{max_bit_rate_downlink        = MaxBitRateDownLink,
			  max_bit_rate_uplink          = MaxBitRateUpLink,
			  guaranteed_bit_rate_downlink = GuaranteedBitRateDownLink,
			  guaranteed_bit_rate_uplink   = GuaranteedBitRateUpLink} = QoS)
  when MaxBitRateDownLink > 8600 orelse
       MaxBitRateUpLink   > 8600 orelse
       GuaranteedBitRateDownLink > 8600 orelse
       GuaranteedBitRateUpLink   > 8600 ->
    IE = <<IE0/binary, (encode_ext_br(MaxBitRateDownLink)):8, (encode_ext_br(GuaranteedBitRateDownLink)):8>>,
    encode(octet17, IE, QoS);

encode(octet17, IE0, #qos{max_bit_rate_uplink          = MaxBitRateUpLink,
			  guaranteed_bit_rate_uplink   = GuaranteedBitRateUpLink} = QoS)
  when MaxBitRateUpLink        > 8600 orelse
       GuaranteedBitRateUpLink > 8600 ->
    IE = <<IE0/binary, (encode_ext_br(MaxBitRateUpLink)):8, (encode_ext_br(GuaranteedBitRateUpLink)):8>>,
    encode(octet19, IE, QoS);

encode(_Octet, IE, _QoS) ->
    IE.
