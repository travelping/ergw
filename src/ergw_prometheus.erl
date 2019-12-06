%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_prometheus).

-export([declare/0]).
-export([gtp_error/3, gtp/4, gtp/5,
	 gtp_request_duration/4,
	 gtp_path_rtt/4,
	 gtp_path_contexts/4
	]).

-include("include/ergw.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").

%%%===================================================================
%%% API
%%%===================================================================

declare() ->
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
   ok.

%%%===================================================================
%%% Metrics collections
%%%===================================================================

%% gtp_error/3
gtp_error(Direction, #gtp_port{name = Name, type = 'gtp-c'}, Error) ->
    prometheus_counter:inc(gtp_c_socket_errors_total, [Name, Direction, Error]).

%% gtp/4
gtp(Direction, #gtp_port{name = Name, type = 'gtp-c'},
    RemoteIP, #gtp{version = Version, type = MsgType, ie = IEs}) ->
    prometheus_counter:inc(gtp_c_socket_messages_processed_total,
			   [Name, Direction, Version, MsgType]),
    gtp_reply(Name, RemoteIP, Direction, Version, MsgType, IEs);

gtp(Direction, #gtp_port{name = Name, type = 'gtp-u'}, IP,
    #gtp{version = Version, type = MsgType}) ->
    prometheus_counter:inc(gtp_path_messages_processed_total,
			   [Name, inet:ntoa(IP), Direction, Version, MsgType]),
    prometheus_counter:inc(gtp_u_socket_messages_processed_total,
			   [Name, Direction, Version, MsgType]).

gtp_c_msg_counter(PathMetric, SocketMetric,
		  #gtp_port{name = Name, type = 'gtp-c'}, IP,
		  #gtp{version = Version, type = MsgType}) ->
    prometheus_counter:inc(PathMetric, [Name, inet:ntoa(IP), Version, MsgType]),
    prometheus_counter:inc(SocketMetric, [Name, Version, MsgType]).

%% gtp/5
gtp(tx, #gtp_port{type = 'gtp-c'} = GtpPort, RemoteIP, Msg, retransmit) ->
    gtp_c_msg_counter(gtp_path_messages_retransmits_total,
		      gtp_c_socket_messages_retransmits_total,
		      GtpPort, RemoteIP, Msg);
gtp(tx, #gtp_port{type = 'gtp-c'} = GtpPort, RemoteIP, Msg, timeout) ->
    gtp_c_msg_counter(gtp_path_messages_timeouts_total,
		      gtp_c_socket_messages_timeouts_total,
		      GtpPort, RemoteIP, Msg);
gtp(rx, #gtp_port{type = 'gtp-c'} = GtpPort, RemoteIP, Msg, duplicate) ->
    gtp_c_msg_counter(gtp_path_messages_duplicates_total,
		      gtp_c_socket_messages_duplicates_total,
		      GtpPort, RemoteIP, Msg).

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

gtp_request_duration(#gtp_port{name = Name}, Version, MsgType, Duration) ->
    prometheus_histogram:observe(
      gtp_c_socket_request_duration_microseconds, [Name, Version, MsgType], Duration).

gtp_path_rtt(#gtp_port{name = Name}, RemoteIP, #gtp{version = Version, type = MsgType}, RTT) ->
    prometheus_histogram:observe(
      gtp_path_rtt_milliseconds, [Name, inet:ntoa(RemoteIP), Version, MsgType], RTT).

gtp_path_contexts(#gtp_port{name = Name}, RemoteIP, Version, Counter) ->
    prometheus_gauge:set(
      gtp_path_contexts_total, [Name, inet:ntoa(RemoteIP), Version], Counter).
