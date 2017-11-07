%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-ifndef(ERGW_NO_IMPORTS).

-import('ergw_test_lib', [lib_init_per_suite/1,
			  lib_end_per_suite/1,
			  load_config/1]).
-import('ergw_test_lib', [meck_init/1,
			  meck_reset/1,
			  meck_unload/1,
			  meck_validate/1]).
-import('ergw_test_lib', [init_seq_no/2,
			  gtp_context/0, gtp_context/1,
			  gtp_context_inc_seq/1,
			  gtp_context_inc_restart_counter/1,
			  gtp_context_new_teids/1,
			  make_error_indication_report/1]).
-import('ergw_test_lib', [start_gtpc_server/1, stop_gtpc_server/1,
			  make_gtp_socket/1, make_gtp_socket/2,
			  send_pdu/2,
			  send_recv_pdu/2, send_recv_pdu/3, send_recv_pdu/4,
			  recv_pdu/2, recv_pdu/3, recv_pdu/4]).
-import('ergw_test_lib', [set_cfg_value/3, add_cfg_value/3]).
-import('ergw_test_lib', [outstanding_requests/0, wait4tunnels/1, hexstr2bin/1]).

-endif.

-define(LOCALHOST, {127,0,0,1}).
-define(CLIENT_IP, {127,127,127,127}).
-define(TEST_GSN, ?LOCALHOST).
-define(PROXY_GSN, {127,0,100,1}).
-define(FINAL_GSN, {127,0,200,1}).

-define('APN-EXAMPLE', [<<"example">>, <<"net">>]).
-define('APN-ExAmPlE', [<<"eXaMpLe">>, <<"net">>]).
-define('IMSI', <<"111111111111111">>).
-define('MSISDN', <<"440000000000">>).

-define('APN-PROXY',   [<<"proxy">>, <<"example">>, <<"net">>]).
-define('PROXY-IMSI', <<"222222222222222">>).
-define('PROXY-MSISDN', <<"491111111111">>).

-record(gtpc, {
	  counter         :: atom(),
	  restart_counter :: 0..255,
	  seq_no          :: 0..16#ffffffff,

	  local_control_tei      :: non_neg_integer(),
	  local_data_tei         :: non_neg_integer(),
	  remote_control_tei = 0 :: non_neg_integer(),
	  remote_data_tei = 0    :: non_neg_integer()
	 }).

-define(equal(Expected, Actual),
    (fun (Expected@@@, Expected@@@) -> true;
	 (Expected@@@, Actual@@@) ->
	     ct:pal("MISMATCH(~s:~b, ~s)~nExpected: ~p~nActual:   ~p~n",
		    [?FILE, ?LINE, ??Actual, Expected@@@, Actual@@@]),
	     false
     end)(Expected, Actual) orelse error(badmatch)).

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
