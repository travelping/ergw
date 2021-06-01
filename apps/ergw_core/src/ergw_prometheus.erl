%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_prometheus).

-export([validate_options/1]).

-export([declare/0]).
-export([gtp_error/3, gtp/4, gtp/5,
	 gtp_request_duration/4,
	 gtp_path_rtt/4,
	 gtp_path_contexts/4,
	 gtp_path_metrics_remove/1
	]).
-export([pfcp/4, pfcp/5,
	 pfcp_request_duration/3, pfcp_peer_response/4]).

-export([termination_cause/2]).

-ignore_xref([validate_options/1]).

-include("include/ergw.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").

%%%===================================================================
%%% Options Validation
%%%===================================================================

%%-define(DefaultMetricsOpts, [{gtp_path_rtt_millisecond_intervals, [10, 30, 50, 75, 100, 1000, 2000]}]).

validate_options(Opts) ->
    ergw_core_config:validate_options(fun validate_option/2, Opts, []).

%% disabled for now
%%
%% prometheus metrics must be declared early. Changing them once the config is ready
%% to be applied is FFS...

%% validate_options(Opts) ->
%%     ergw_core_config:validate_options(fun validate_option/2, Opts, ?DefaultMetricsOpts).

validate_option(gtp_path_rtt_millisecond_intervals = Opt, Value) ->
    case [V || V <- Value, is_integer(V), V > 0] of
	[_|_] = Value ->
	    Value;
       _ ->
	    erlang:error(badarg, [Opt, Value])
    end;
validate_option(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

%%%===================================================================
%%% API
%%%===================================================================

declare() ->
    %% %% Metrics Config
    %% {ok, Config} = application:get_env(ergw_core, metrics),

    %% GTP path metrics
    prometheus_counter:declare([{name, gtp_path_messages_processed_total},
				{labels, [name, remote, direction, version, type]},
				{help, "Total number of GTP message processed on path"}]),
    prometheus_counter:declare([{name, gtp_path_messages_duplicates_total},
				{labels, [name, remote, version, type]},
				{help, "Total number of duplicate GTP message received on path"}]),
    prometheus_counter:declare([{name, gtp_path_messages_retransmits_total},
				{labels, [name, remote, version, type]},
				{help, "Total number of retransmited GTP message on path"}]),
    prometheus_counter:declare([{name, gtp_path_messages_timeouts_total},
				{labels, [name, remote, version, type]},
				{help, "Total number of timed out GTP message on path"}]),
    prometheus_counter:declare([{name, gtp_path_messages_replies_total},
				{labels, [name, remote, direction, version, type, result]},
				{help, "Total number of reply GTP message on path"}]),
    %% prometheus_histogram:declare([{name, gtp_path_rtt_milliseconds},
    %% 				  {labels, [name, ip, version, type]},
    %% 				  {buckets, maps:get(gtp_path_rtt_millisecond_intervals, Config)},
    %% 				  {help, "GTP path round trip time"}]),
    prometheus_histogram:declare([{name, gtp_path_rtt_milliseconds},
				  {labels, [name, ip, version, type]},
				  {buckets, [10, 30, 50, 75, 100, 1000, 2000]},
				  {help, "GTP path round trip time"}]),
    prometheus_gauge:declare([{name, gtp_path_contexts_total},
			      {labels, [name, ip, version]},
			      {help, "Total number of GTP contexts on path"}]),

    %% GTP-C socket metrics
    prometheus_counter:declare([{name, gtp_c_socket_messages_processed_total},
				{labels, [name, direction, version, type]},
				{help, "Total number of GTP message processed on socket"}]),
    prometheus_counter:declare([{name, gtp_c_socket_messages_duplicates_total},
				{labels, [name, version, type]},
				{help, "Total number of duplicate GTP message received on socket"}]),
    prometheus_counter:declare([{name, gtp_c_socket_messages_retransmits_total},
				{labels, [name, version, type]},
				{help, "Total number of retransmited GTP message on socket"}]),
    prometheus_counter:declare([{name, gtp_c_socket_messages_timeouts_total},
				{labels, [name, version, type]},
				{help, "Total number of timed out GTP message on socket"}]),
    prometheus_counter:declare([{name, gtp_c_socket_messages_replies_total},
				{labels, [name, direction, version, type, result]},
				{help, "Total number of reply GTP message on socket"}]),
    prometheus_counter:declare([{name, gtp_c_socket_errors_total},
				{labels, [name, direction, error]},
				{help, "Total number of GTP errors on socket"}]),
    prometheus_histogram:declare([{name, gtp_c_socket_request_duration_microseconds},
				  {labels, [name, version, type]},
				  {buckets, [100, 300, 500, 750, 1000]},
				  {help, "GTP Request execution time."}]),

    %% GTP-U socket metrics
    prometheus_counter:declare([{name, gtp_u_socket_messages_processed_total},
				{labels, [name, direction, version, type]},
				{help, "Total number of GTP message processed on socket"}]),

    %% PFCP metrics
    prometheus_counter:declare([{name, pfcp_messages_processed_total},
				{labels, [name, direction, remote, type]},
				{help, "Total number of PFCP message processed"}]),
    prometheus_counter:declare([{name, pfcp_messages_duplicates_total},
				{labels, [name, remote, type]},
				{help, "Total number of duplicate PFCP message received"}]),
    prometheus_counter:declare([{name, pfcp_messages_retransmits_total},
				{labels, [name, remote, type]},
				{help, "Total number of retransmited PFCP message"}]),
    prometheus_counter:declare([{name, pfcp_messages_timeouts_total},
				{labels, [name, remote, type]},
				{help, "Total number of timed out PFCP message"}]),
    prometheus_counter:declare([{name, pfcp_messages_replies_total},
				{labels, [name, direction, remote, type, result]},
				{help, "Total number of reply PFCP message"}]),
    prometheus_counter:declare([{name, pfcp_errors_total},
				{labels, [name, direction, remote, type]},
				{help, "Total number of PFCP errors"}]),
    prometheus_histogram:declare([{name, pfcp_peer_response_milliseconds},
				  {labels, [name, remote, type]},
				  {buckets, [100, 300, 500, 750, 1000]},
				  {help, "PFCP round trip time"}]),
    prometheus_histogram:declare([{name, pfcp_request_duration_microseconds},
				  {labels, [name, type]},
				  {buckets, [100, 300, 500, 750, 1000]},
				  {help, "PFCP Request execution time."}]),

    %% Termination cause metrics
    prometheus_counter:declare([{name, termination_cause_total},
				{labels, [api, reason]},
				{help, "Total number of termination causes"}]),
    ok.

gtp_path_metrics_remove(IP) ->
    Peer = inet:ntoa(IP),
    %% GTP path metrics
    prometheus_counter:match_remove(
      gtp_path_messages_processed_total, ['_', Peer, '_', '_', '_'], []),
    prometheus_counter:match_remove(
      gtp_path_messages_duplicates_total, ['_', Peer, '_', '_'], []),
    prometheus_counter:match_remove(
      gtp_path_messages_retransmits_total, ['_', Peer, '_', '_'], []),
    prometheus_counter:match_remove(
      gtp_path_messages_timeouts_total, ['_', Peer, '_', '_'], []),
    prometheus_counter:match_remove(
      gtp_path_messages_replies_total, ['_', Peer, '_', '_', '_', '_'], []),
    ok.

%%%===================================================================
%%% GTP Metrics collections
%%%===================================================================

%% gtp_error/3
gtp_error(Direction, #socket{name = Name, type = 'gtp-c'}, Error) ->
    prometheus_counter:inc(gtp_c_socket_errors_total, [Name, Direction, Error]).

%% gtp/4
gtp(Direction, #socket{name = Name, type = 'gtp-c'}, IP,
    #gtp{version = Version, type = MsgType, ie = IEs}) ->
    prometheus_counter:inc(gtp_path_messages_processed_total,
			   [Name, inet:ntoa(IP), Direction, Version, MsgType]),
    prometheus_counter:inc(gtp_c_socket_messages_processed_total,
			   [Name, Direction, Version, MsgType]),
    gtp_reply(Name, IP, Direction, Version, MsgType, IEs);

gtp(Direction, #socket{name = Name, type = 'gtp-u'}, IP,
    #gtp{version = Version, type = MsgType}) ->
    prometheus_counter:inc(gtp_path_messages_processed_total,
			   [Name, inet:ntoa(IP), Direction, Version, MsgType]),
    prometheus_counter:inc(gtp_u_socket_messages_processed_total,
			   [Name, Direction, Version, MsgType]).

gtp_c_msg_counter(PathMetric, SocketMetric,
		  #socket{name = Name, type = 'gtp-c'}, IP,
		  #gtp{version = Version, type = MsgType}) ->
    prometheus_counter:inc(PathMetric, [Name, inet:ntoa(IP), Version, MsgType]),
    prometheus_counter:inc(SocketMetric, [Name, Version, MsgType]).

%% gtp/5
gtp(tx, #socket{type = 'gtp-c'} = Socket, RemoteIP, Msg, retransmit) ->
    gtp_c_msg_counter(gtp_path_messages_retransmits_total,
		      gtp_c_socket_messages_retransmits_total,
		      Socket, RemoteIP, Msg);
gtp(tx, #socket{type = 'gtp-c'} = Socket, RemoteIP, Msg, timeout) ->
    gtp_c_msg_counter(gtp_path_messages_timeouts_total,
		      gtp_c_socket_messages_timeouts_total,
		      Socket, RemoteIP, Msg);
gtp(rx, #socket{type = 'gtp-c'} = Socket, RemoteIP, Msg, duplicate) ->
    gtp_c_msg_counter(gtp_path_messages_duplicates_total,
		      gtp_c_socket_messages_duplicates_total,
		      Socket, RemoteIP, Msg).

%% gtp_reply/6
gtp_reply(Name, _RemoteIP, Direction, Version, MsgType,
	  #{cause := #cause{value = Cause}}) ->
    gtp_reply_update(Name, Direction, Version, MsgType, Cause);
gtp_reply(Name, _RemoteIP, Direction, Version, MsgType,
	  #{v2_cause := #v2_cause{v2_cause = Cause}}) ->
    gtp_reply_update(Name, Direction, Version, MsgType, Cause);
gtp_reply(Name, _RemoteIP, Direction, Version, MsgType, IEs)
  when is_list(IEs) ->
    CauseIEs =
	lists:filter(
	  fun(IE) when is_record(IE, cause) -> true;
	     (IE) when is_record(IE, v2_cause) -> true;
	     (_) -> false
	  end, IEs),
    case CauseIEs of
	[#cause{value = Cause} | _] ->
	    gtp_reply_update(Name, Direction, Version, MsgType, Cause);
	[#v2_cause{v2_cause = Cause} | _] ->
	    gtp_reply_update(Name, Direction, Version, MsgType, Cause);
	_ ->
	    ok
    end;
gtp_reply(_Name, _RemoteIP, _Direction, _Version, _MsgType, _IEs) ->
    ok.

gtp_reply_update(Name, Direction, Version, MsgType, Cause) ->
    prometheus_counter:inc(gtp_c_socket_messages_replies_total,
			   [Name, Direction, Version, MsgType, Cause]).

gtp_request_duration(#socket{name = Name}, Version, MsgType, Duration) ->
    prometheus_histogram:observe(
      gtp_c_socket_request_duration_microseconds, [Name, Version, MsgType], Duration).

gtp_path_rtt(#socket{name = Name}, RemoteIP, #gtp{version = Version, type = MsgType}, RTT) ->
    prometheus_histogram:observe(
      gtp_path_rtt_milliseconds, [Name, inet:ntoa(RemoteIP), Version, MsgType], RTT).

gtp_path_contexts(#socket{name = Name}, RemoteIP, Version, Counter) ->
    prometheus_gauge:set(
      gtp_path_contexts_total, [Name, inet:ntoa(RemoteIP), Version], Counter).

%%%===================================================================
%%% PFCP Metrics collections
%%%===================================================================

%% pfcp_msg_counter/4
pfcp_msg_counter(Metric, Name, IP, #pfcp{type = MsgType}) ->
    prometheus_counter:inc(Metric, [Name, inet:ntoa(IP), MsgType]).

%% pfcp_msg_counter/5
pfcp_msg_counter(Metric, Name, Direction, IP, Type) ->
    prometheus_counter:inc(Metric, [Name, Direction, inet:ntoa(IP), Type]).

%% pfcp/4
pfcp(Direction, Name, RemoteIP, #pfcp{type = MsgType, ie = IEs}) ->
    pfcp_msg_counter(pfcp_messages_processed_total, Name, Direction, RemoteIP, MsgType),
    pfcp_reply(Name, RemoteIP, Direction, MsgType, IEs);
pfcp(Direction, Name, RemoteIP, Error)
  when is_atom(Error) ->
    pfcp_msg_counter(pfcp_errors_total, Name, Direction, RemoteIP, Error).

%% pfcp/5
pfcp(tx, Name, RemoteIP, Msg, retransmit) ->
    pfcp_msg_counter(pfcp_messages_retransmits_total, Name, RemoteIP, Msg);
pfcp(tx, Name, RemoteIP, Msg, timeout) ->
    pfcp_msg_counter(pfcp_messages_timeouts_total, Name, RemoteIP, Msg);
pfcp(rx, Name, RemoteIP, Msg, duplicate) ->
    pfcp_msg_counter(pfcp_messages_duplicates_total, Name, RemoteIP, Msg).

%% pfcp_reply/5
pfcp_reply(Name, IP, Direction, MsgType, #{pfcp_cause := #pfcp_cause{cause = Cause}}) ->
    prometheus_counter:inc(pfcp_messages_replies_total, [Name, Direction, inet:ntoa(IP), MsgType, Cause]);
pfcp_reply(_Name, _IP, _Direction, _MsgType, _IEs) ->
    ok.

%% pfcp_request_duration/3
pfcp_request_duration(Name, MsgType, Duration) ->
    prometheus_histogram:observe(
      pfcp_request_duration_microseconds, [Name, MsgType], Duration).

%% pfcp_peer_response/4
pfcp_peer_response(Name, RemoteIP, #pfcp{type = MsgType}, RTT) ->
    prometheus_histogram:observe(
      pfcp_peer_response_milliseconds, [Name, inet:ntoa(RemoteIP), MsgType], RTT).

%%%===================================================================
%%% Termination cause Metrics collections
%%%===================================================================

%% termination_cause/2
termination_cause(Name, Type) ->
    prometheus_counter:inc(termination_cause_total, [Name, Type]).
