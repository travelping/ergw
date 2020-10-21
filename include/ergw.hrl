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

-record(ue_ip, {
	  v4               :: inet:ip4_address(),
	  v6               :: inet:ip6_address()
	 }).

-record(seid, {
	  cp = 0           :: non_neg_integer(),
	  dp = 0           :: non_neg_integer()
	 }).

-record(socket, {
	  name             :: term(),
	  type             :: 'gtp-c' | 'gtp-u',
	  pid              :: pid()
	 }).

-record(tunnel, {
	  interface		:: 'Access' | 'Core',
	  vrf			:: term(),
	  socket		:: #socket{},
	  path			:: 'undefined' | pid(),
	  version               :: 'v1' | 'v2',
	  local			:: 'undefined' | #fq_teid{},
	  remote		:: 'undefined' | #fq_teid{},
	  remote_restart_counter :: 0 .. 255
	 }).

-record(bearer, {
	  interface             :: 'Access' | 'Core' | 'SGi-LAN' |
				   'CP-Function' | 'LI Function',
	  vrf			:: term(),
	  local			:: 'undefined' | #fq_teid{} | #ue_ip{},
	  remote		:: 'undefined' | #fq_teid{}
	 }).

-record(pfcp_ctx, {
	  name			:: term(),
	  node			:: pid(),
	  seid			:: #seid{},

	  cp_bearer		:: #bearer{},

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

-record(context, {
	  apn                    :: [binary()],
	  imsi                   :: 'undefined' | binary(),
	  imei                   :: 'undefined' | binary(),
	  msisdn                 :: 'undefined' | binary(),

	  context_id             :: term(),
	  charging_identifier    :: non_neg_integer(),

	  'Idle-Timeout'  :: non_neg_integer() | infinity,

	  version                :: 'v1' | 'v2',
	  pdn_type               :: 'undefined' | 'IPv4' | 'IPv6' | 'IPv4v6' | 'Non-IP',
	  left_tnl               :: 'undefined' | #tunnel{},
	  left                   :: 'undefined' | #bearer{},
	  right                  :: 'undefined' | #bearer{},

	  ms_ip                  :: #ue_ip{},
	  dns_v6                 :: [inet:ip6_address()],
	  state                  :: term(),
	  restrictions = []      :: [{'v1', boolean()} |
				     {'v2', boolean()}]
	 }).

-record(tdf_ctx, {
	  left                   :: 'undefined' | #bearer{},
	  right                  :: 'undefined' | #bearer{},

	  ms_ip                  :: #ue_ip{}
	 }).

-record(gtp_socket_info, {
	  vrf              :: term(),
	  ip               :: inet:ip_address()
	 }).

-record(request, {
	  key		:: term(),
	  socket	:: #socket{},
	  info          :: #gtp_socket_info{},
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
