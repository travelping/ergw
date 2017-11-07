%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-define(GTP0_PORT,	3386).
-define(GTP1c_PORT,	2123).
-define(GTP1u_PORT,	2152).
-define(GTP2c_PORT,	2123).

%% ErrLevel
-define(WARNING, 1).
-define(FATAL, 2).

-record(ctx_err, {
	  level,
	  where = {?FILE, ?LINE},
	  reply,
	  context
	 }).

-record(gtp_port, {
	  name            :: term(),
	  type            :: 'gtp-c' | 'gtp-u',
	  pid             :: pid(),
	  restart_counter :: integer(),
	  ip              :: inet:ip_address()
	 }).

-record(context, {
	  apn                    :: [binary()],
	  imsi                   :: 'undefined' | binary(),
	  imei                   :: 'undefined' | binary(),
	  msisdn                 :: 'undefined' | binary(),
	  context_id             :: term(),

	  version                :: 'v1' | 'v2',
	  control_interface      :: atom(),
	  control_port           :: #gtp_port{},
	  path                   :: 'undefined' | pid(),
	  local_control_tei      :: non_neg_integer(),
	  remote_control_ip      :: inet:ip_address(),
	  remote_control_tei = 0 :: non_neg_integer(),
	  remote_restart_counter :: 0 .. 255,
	  data_port              :: #gtp_port{},
	  dp_pid                 :: pid(),
	  vrf                    :: atom(),
	  local_data_tei         :: non_neg_integer(),
	  remote_data_ip         :: inet:ip_address(),
	  remote_data_tei = 0    :: non_neg_integer(),
	  ms_v4                  :: inet:ip4_address(),
	  ms_v6                  :: inet:ip6_address(),
	  state                  :: term(),
	  restrictions = []      :: [{'v1', boolean()} |
				     {'v2', boolean()}]
	 }).

-record(request, {
	  key		:: term(),
	  gtp_port	:: #gtp_port{},
	  ip		:: inet:ip_address(),
	  port		:: 0 .. 65535,
	  version	:: 'v1' | 'v2',
	  type		:: atom(),
	  arrival_ts    :: integer()
	 }).

-record(proxy_request, {
	  direction	:: atom(),
	  request	:: #request{},
	  seq_no	:: gtp_socket:sequence_id(),
	  context	:: #context{},
	  proxy_ctx	:: #context{},
	  new_peer	:: boolean()
}).

-record(f_teid, {
	  ipv4			:: inet:ip4_address(),
	  ipv6			:: inet:ip6_address(),
	  teid			:: 0..16#ffffffff
	 }).
