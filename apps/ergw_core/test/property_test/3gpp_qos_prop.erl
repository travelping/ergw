%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module('3gpp_qos_prop').

-compile([export_all, nowarn_export_all]).

-proptest(proper).
-proptest([triq,eqc]).

-ifndef(EQC).
-ifndef(PROPER).
-ifndef(TRIQ).
-define(PROPER,true).
%%-define(EQC,true).
%%-define(TRIQ,true).
-endif.
-endif.
-endif.

-ifdef(EQC).
-include_lib("eqc/include/eqc.hrl").
-define(MOD_eqc,eqc).

-else.
-ifdef(PROPER).
-include_lib("proper/include/proper.hrl").
-define(MOD_eqc,proper).

-else.
-ifdef(TRIQ).
-define(MOD_eqc,triq).
-include_lib("triq/include/triq.hrl").

-endif.
-endif.
-endif.

-include_lib("ergw_core/include/3gpp.hrl").

-define(equal(Expected, Actual),
    (fun (Expected@@@, Expected@@@) -> true;
         (Expected@@@, Actual@@@) ->
             ct:pal("MISMATCH(~s:~b, ~s)~nExpected: ~p~nActual:   ~p~n",
                    [?FILE, ?LINE, ??Actual, Expected@@@, Actual@@@]),
             false
     end)(Expected, Actual) orelse error(badmatch)).

%%%===================================================================
%%% Tests
%%%===================================================================

%%--------------------------------------------------------------------
enc_dec_prop(_Config) ->
    numtests(1000,
	     ?FORALL(Msg, qos_gen(),
		     begin
			 ?equal(Msg, '3gpp_qos':decode('3gpp_qos':encode(Msg)))
		     end)).

%%%===================================================================
%%% Internal functions
%%%===================================================================

scaled_int(L, H, Scale) ->
    ?LET(X, integer(L div Scale, H div Scale), X * Scale).

sdu_size() ->
    oneof([subscribed,
	   scaled_int(10, 1500, 10),
	   1502,
	   1510,
	   1520]).

-define(Mbps, 1000).
-define(Gbps, ?Mbps * ?Mbps).
bit_rate() ->
    oneof([subscribed,
	   %% octed 8 and 9
	   0,
	   scaled_int(           1,           63,           1),
	   scaled_int(          64,          568,           8),
	   scaled_int(         576,         8600,          64),
	   scaled_int(        8700,        16000,         100),
	   %% octed 15, 16, 17 and 18
	   scaled_int(  17 * ?Mbps,  128 * ?Mbps,   1 * ?Mbps),
	   scaled_int( 130 * ?Mbps,  256 * ?Mbps,   2 * ?Mbps),

	   %% octed 19, 20, 21 and 22
	   scaled_int( 260 * ?Mbps,  500 * ?Mbps,   4 * ?Mbps),
	   scaled_int( 510 * ?Mbps, 1500 * ?Mbps,  10 * ?Mbps),
	   scaled_int(1600 * ?Mbps,   10 * ?Gbps, 100 * ?Mbps)
	  ]).

transfer_delay() ->
    oneof([subscribed,
	   scaled_int(10, 150, 10),
	   scaled_int(200, 950, 50),
	   scaled_int(1000, 4000, 100),
	   reserved]).

qos_gen() ->
    #qos{
       delay_class			= integer(0,7),
       reliability_class		= integer(0,7),
       peak_throughput			= integer(0,15),
       precedence_class			= integer(0,7),
       mean_throughput			= integer(0,31),
       traffic_class			= integer(0,7),
       delivery_order			= integer(0,3),
       delivery_of_erroneorous_sdu	= integer(0,7),
       max_sdu_size			= sdu_size(),
       max_bit_rate_uplink		= bit_rate(),
       max_bit_rate_downlink		= bit_rate(),
       residual_ber			= integer(0,15),
       sdu_error_ratio			= integer(0,15),
       transfer_delay			= transfer_delay(),
       traffic_handling_priority	= integer(0,3),
       guaranteed_bit_rate_uplink	= bit_rate(),
       guaranteed_bit_rate_downlink	= bit_rate(),
       signaling_indication		= integer(0,1),
       source_statistics_descriptor	= integer(0,15)
      }.
