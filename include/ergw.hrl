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
	  where,
	  reply,
	  context
	 }).

-define(CTX_ERR(Level,Reply), #ctx_err{level=Level,reply=Reply,where={?FILE, ?LINE}}).
-define(CTX_ERR(Level,Reply,Context), #ctx_err{level=Level,reply=Reply,
					       context=Context,where={?FILE, ?LINE}}).

-record(node, {
	  node	:: atom(),
	  ip	:: inet:ip_address()
	 }).

-record(fq_teid, {
	  ip       :: inet:ip_address(),
	  teid = 0 :: non_neg_integer()
	 }).

-record(gtp_port, {
	  name             :: term(),
	  vrf              :: term(),
	  type             :: 'gtp-c' | 'gtp-u',
	  pid              :: pid(),
	  restart_counter  :: integer(),
	  ip               :: inet:ip_address()
	 }).

-record(seid, {
	  cp = 0           :: non_neg_integer(),
	  dp = 0           :: non_neg_integer()
	 }).

-record(pfcp_ctx, {
	  name			:: term(),
	  node			:: pid(),
	  seid			:: #seid{},

	  cp_port		:: #gtp_port{},
	  cp_tei		:: non_neg_integer(),

	  idcnt = #{}		:: map(),
	  idmap = #{}		:: map(),
	  urr_by_id = #{}	:: map(),
	  urr_by_grp = #{}	:: map(),
	  sx_rules = #{}	:: map(),
	  timers = #{}		:: map(),
	  timer_by_tref = #{}	:: map(),

	  up_inactivity_timer   :: 'undefined' | non_neg_integer()
	 }).

-record(pcc_ctx, {
	  monitors = #{}	:: map(),
	  rules = #{}		:: map(),
	  credits = #{}		:: map(),

	  %% TBD:
	  offline_charging_profile = #{}	:: map()
	 }).

-record(gtp_endp, {
	  vrf			:: term(),
	  ip			:: inet:ip_address(),
	  teid			:: non_neg_integer()
	 }).

-record(context, {
	  apn                    :: [binary()],
	  imsi                   :: 'undefined' | binary(),
	  imei                   :: 'undefined' | binary(),
	  msisdn                 :: 'undefined' | binary(),

	  context_id             :: term(),
	  charging_identifier    :: non_neg_integer(),

	  'Idle-Timeout'  :: non_neg_integer() | infinity,

	  version                :: 'v1' | 'v2',
	  control_interface      :: atom(),
	  control_port           :: #gtp_port{},
	  path                   :: 'undefined' | pid(),
	  local_control_tei      :: non_neg_integer(),
	  remote_control_teid    :: #fq_teid{},
	  remote_restart_counter :: 0 .. 255,
	  vrf                    :: atom(),
	  pdn_type               :: 'undefined' | 'IPv4' | 'IPv6' | 'IPv4v6' | 'Non-IP',
	  ipv4_pool              :: 'undefined' | binary(),
	  ipv6_pool              :: 'undefined' | binary(),
	  local_data_endp        :: 'undefined' | #gtp_endp{},
	  remote_data_teid       :: #fq_teid{},
	  ms_v4                  :: inet:ip4_address(),
	  ms_v6                  :: inet:ip6_address(),
	  dns_v6                 :: [inet:ip6_address()],
	  state                  :: term(),
	  restrictions = []      :: [{'v1', boolean()} |
				     {'v2', boolean()}],
	  timers = #{}           :: map()
	 }).

-record(tdf_ctx, {
	  in_vrf                 :: atom(),
	  out_vrf                :: atom(),
	  ms_v4                  :: inet:ip4_address(),
	  ms_v6                  :: inet:ip6_address()
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
	  seq_no	:: non_neg_integer(),
	  context	:: #context{},
	  proxy_ctx	:: #context{},
	  new_peer	:: boolean()
}).

-record(vrf, {
	  name                   :: atom(),
	  features = ['SGi-Lan'] :: ['Access' | 'Core' | 'SGi-LAN' |
				     'CP-Function' | 'LI Function'],
	  teid_range,
	  ipv4,
	  ipv6
	 }).

-record(counter, {
	  rx :: {Bytes :: integer(), Packets :: integer()},
	  tx :: {Bytes :: integer(), Packets :: integer()}
	 }).

%% nBsf registration record
-record(bsf, {
	  dnn                       :: [binary()],
	  snssai = {1, 16#ffffff}   :: {0..255, 0..16#ffffff},
	  ip_domain                 :: atom(),
	  ip                        :: {inet:ip4_address(),1..32}|
				       {inet:ip6_address(),1..128}
	}).
