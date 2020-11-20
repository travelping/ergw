%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-ifndef(ERGW_NO_IMPORTS).

-import('ergw_test_lib', [lib_init_per_suite/1,
			  lib_end_per_suite/1,
			  update_app_config/3,
			  load_config/1]).
-import('ergw_test_lib', [meck_init/1,
			  meck_init_hut_handle_request/1,
			  meck_reset/1,
			  meck_unload/1,
			  meck_validate/1]).
-import('ergw_test_lib', [init_seq_no/2,
			  gtp_context/1, gtp_context/2, gtp_context/3,
			  gtp_context_inc_seq/1,
			  gtp_context_inc_restart_counter/1,
			  gtp_context_new_teids/1,
			  make_error_indication_report/1]).
-import('ergw_test_lib', [start_gtpc_server/1, start_gtpc_server/2,
			  stop_gtpc_server/1, stop_gtpc_server/0,
			  wait_for_all_sx_nodes/0, reconnect_all_sx_nodes/0,
			  stop_all_sx_nodes/0,
			  make_gtp_socket/1, make_gtp_socket/2,
			  send_pdu/2, send_pdu/3,
			  send_recv_pdu/2, send_recv_pdu/3, send_recv_pdu/4,
			  recv_pdu/2, recv_pdu/3, recv_pdu/4]).
-import('ergw_test_lib', [set_cfg_value/3, add_cfg_value/3]).
-import('ergw_test_lib', [outstanding_requests/0, wait4tunnels/1, hexstr2bin/1,
			  maps_key_length/2]).
-import('ergw_test_lib', [get_metric/4]).

-endif.

-define(SECONDS_PER_DAY, 86400).
-define(DAYS_FROM_0_TO_1970, 719528).
-define(SECONDS_FROM_0_TO_1970, (?DAYS_FROM_0_TO_1970*?SECONDS_PER_DAY)).

-define(MUST_BE_UPDATED, 'must be updated').

-define(LOCALHOST_IPv4, {127,0,0,1}).
-define(CLIENT_IP_IPv4, {127,127,127,127}).
-define(TEST_GSN_IPv4, ?LOCALHOST_IPv4).
-define(PROXY_GSN_IPv4, {127,0,100,1}).
-define(FINAL_GSN_IPv4, {127,0,200,1}).
-define(FINAL_GSN2_IPv4, {127,0,200,2}).

-define(SGW_U_SX_IPv4, {127,0,100,1}).
-define(PGW_U01_SX_IPv4, {127,0,200,1}).
-define(PGW_U02_SX_IPv4, {127,0,200,2}).
-define(TDF_U_SX_IPv4, {127,0,210,1}).

-define(LOCALHOST_IPv6, {0,0,0,0,0,0,0,1}).
-define(CLIENT_IP_IPv6, {16#fd96, 16#dcd2, 16#efdb, 16#41c3, 0, 0, 0, 16#10}).
-define(TEST_GSN_IPv6, ?LOCALHOST_IPv6).
-define(PROXY_GSN_IPv6, {16#fd96, 16#dcd2, 16#efdb, 16#41c3, 0, 0, 0, 16#20}).
-define(FINAL_GSN_IPv6, {16#fd96, 16#dcd2, 16#efdb, 16#41c3, 0, 0, 0, 16#30}).
-define(FINAL_GSN2_IPv6, {16#fd96, 16#dcd2, 16#efdb, 16#41c3, 0, 0, 0, 16#40}).

-define(SGW_U_SX_IPv6, {16#fd96, 16#dcd2, 16#efdb, 16#41c3, 0, 0, 0, 16#20}).
-define(PGW_U01_SX_IPv6, {16#fd96, 16#dcd2, 16#efdb, 16#41c3, 0, 0, 0, 16#30}).
-define(PGW_U02_SX_IPv6, {16#fd96, 16#dcd2, 16#efdb, 16#41c3, 0, 0, 0, 16#40}).
-define(TDF_U_SX_IPv6, {16#fd96, 16#dcd2, 16#efdb, 16#41c3, 0, 0, 0, 16#50}).

-define('APN-EXAMPLE', [<<"example">>, <<"net">>]).
-define('APN-ExAmPlE', [<<"eXaMpLe">>, <<"net">>]).
-define('APN-EXA.MPLE', [<<"exa.mple">>, <<"net">>]).
-define('APN-LB-1', [<<"lb-1">>]).
-define('IMSI', <<"111111111111111">>).
-define('MSISDN', <<"440000000000">>).

-define('APN-PROXY',   [<<"proxy">>, <<"example">>, <<"net">>]).
-define('PROXY-IMSI', <<"222222222222222">>).
-define('PROXY-MSISDN', <<"491111111111">>).

-define('IMEISV', <<"3520990017614823">>).			%% found on wikipedia

-define(IPv4PoolStart, {10, 180, 0, 1}).
%%-define(IPv4PoolEnd,   {10, 180, 255, 254}).
-define(IPv4PoolEnd,   {10, 187, 255, 254}).
-define(IPv4StaticIP,  {10, 180, 128, 128}).
%%-define(IPv4PoolSize,  65534).
-define(IPv4PoolSize,  524286).

-define(IPv6PoolStart, {16#8001, 0, 1, 0, 0, 0, 0, 0}).
-define(IPv6PoolEnd,   {16#8001, 0, 7, 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF, 16#FFFF}).
-define(IPv6StaticIP,  {16#8001, 0, 1, 16#0180, 1, 2, 3, 4}).

%% for non-standard /128 assigments
%% NOTE: the pool allocator can't handle pools larger than > 2^20
-define(IPv6HostPoolStart, {16#8001, 0, 0, 0, 0, 0, 0, 0}).
-define(IPv6HostPoolEnd,   {16#8001, 0, 0, 0, 0, 0, 0, 16#FFFF}).
-define(IPv6StaticHostIP,  {16#8001, 0, 0, 0, 0, 0, 0, 8}).

-record(gtpc, {
	  counter         :: atom(),
	  restart_counter :: 0..255,
	  seq_no          :: 0..16#ffffffff,

	  socket,

	  ue_ip                  :: inet:ip_address(),

	  local_ip               :: inet:ip_address(),
	  local_control_tei      :: non_neg_integer(),
	  local_data_tei         :: non_neg_integer(),
	  remote_ip              :: inet:ip_address(),
	  remote_control_tei = 0 :: non_neg_integer(),
	  remote_data_tei = 0    :: non_neg_integer(),

	  rat_type = 1           :: non_neg_integer()
	 }).

-define(equal(Expected, Actual),
    (fun (Expected@@@, Expected@@@) -> true;
	 (Expected@@@, Actual@@@) ->
	     ct:pal("MISMATCH(~s:~b, ~s)~nExpected: ~p~nActual:   ~p~n",
		    [?FILE, ?LINE, ??Actual, Expected@@@, Actual@@@]),
	     false
     end)(Expected, Actual) orelse error(badmatch)).

-define(not_equal(A, B),
    (fun (A@@@, A@@@) ->
	     ct:pal("SHOULD NOT BE EQUAL(~s:~b, ~s, ~s)~nGot: ~p~n",
		    [?FILE, ?LINE, ??A, ??B, A]),
	     false;
	 (_, _) -> true
     end)(A, B) orelse error(badmatch)).

-define(match(Guard, Expr),
	((fun () ->
		  case (Expr) of
		      Guard -> ok;
		      V -> ct:pal("MISMATCH(~s:~b, ~s)~nExpected: ~p~nActual:   ~s~n",
				   [?FILE, ?LINE, ??Expr, ??Guard,
				    ergw_test_lib:pretty_print(V)]),
			    error(badmatch)
		  end
	  end)())).

-define(match_map(Expected, Actual), ergw_test_lib:match_map(Expected, Actual, ?FILE, ?LINE)).

-define(match_metric(Type, Name, LabelValues, Expected),
	ergw_test_lib:match_metric(Type, Name, LabelValues, Expected, ?FILE, ?LINE, 10)).
