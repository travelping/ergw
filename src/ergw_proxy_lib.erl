%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_proxy_lib).

-export([validate_options/3, validate_option/2,
	 forward_request/3, forward_request/6, forward_request/8,
	 get_seq_no/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% API
%%%===================================================================

forward_request(Direction, GtpPort, DstIP, DstPort,
		Request, ReqKey, SeqNo, NewPeer) ->
    {ReqId, ReqInfo} = make_proxy_request(Direction, ReqKey, SeqNo, NewPeer),
    lager:debug("Invoking Context Send Request: ~p", [Request]),
    gtp_context:send_request(GtpPort, DstIP, DstPort, ReqId, Request, ReqInfo).

forward_request(Direction,
		#context{control_port = GtpPort,
			 remote_control_ip = RemoteCntlIP},
		Request, ReqKey, SeqNo, NewPeer) ->
    forward_request(Direction, GtpPort, RemoteCntlIP, ?GTP1c_PORT,
		    Request, ReqKey, SeqNo, NewPeer).

forward_request(#context{control_port = GtpPort}, ReqKey, Request) ->
    ReqId = make_request_id(ReqKey, Request),
    gtp_context:resend_request(GtpPort, ReqId).

get_seq_no(#context{control_port = GtpPort}, ReqKey, Request) ->
    ReqId = make_request_id(ReqKey, Request),
    gtp_socket:get_seq_no(GtpPort, ReqId).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(ProxyDefaults, [{proxy_data_source, gtp_proxy_ds},
			{proxy_sockets,     []},
			{proxy_data_paths,  []},
			{contexts,          []}]).

-define(ContextDefaults, [{proxy_sockets,    []},
			  {proxy_data_paths, []}]).

validate_options(Fun, Opts, Defaults) ->
    gtp_context:validate_options(Fun, Opts, Defaults ++ ?ProxyDefaults).

validate_option(proxy_data_source, Value) ->
    case code:ensure_loaded(Value) of
	{module, _} ->
	    ok;
	_ ->
	    throw({error, {options, {proxy_data_source, Value}}})
    end,
    Value;
validate_option(Opt, Value)
  when Opt == proxy_sockets;
       Opt == proxy_data_paths ->
    validate_context_option(Opt, Value);
validate_option(contexts, Values) when is_list(Values); is_map(Values) ->
    ergw_config:opts_fold(fun validate_context/3, #{}, Values);
validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

validate_context_option(proxy_sockets, Value) when is_list(Value), Value /= [] ->
    Value;
validate_context_option(proxy_data_paths, Value) when is_list(Value), Value /= [] ->
    Value;
validate_context_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_context(Name, Opts0, Acc)
  when is_binary(Name) andalso (is_list(Opts0) orelse is_map(Opts0)) ->
    Opts = ergw_config:validate_options(
	     fun validate_context_option/2, Opts0, ?ContextDefaults, map),
    Acc#{Name => Opts};
validate_context(Name, Opts, _Acc) ->
    throw({error, {options, {contexts, {Name, Opts}}}}).

%%%===================================================================
%%% Helper functions
%%%===================================================================

make_request_id(#request{key = ReqKey}, #gtp{seq_no = SeqNo})
  when is_integer(SeqNo) ->
    {ReqKey, SeqNo};
make_request_id(#request{key = ReqKey}, SeqNo)
  when is_integer(SeqNo) ->
    {ReqKey, SeqNo}.

make_proxy_request(Direction, Request, SeqNo, NewPeer) ->
    ReqId = make_request_id(Request, SeqNo),
    ReqInfo = #proxy_request{
		 direction = Direction,
		 request = Request,
		 seq_no = SeqNo,
		 new_peer = NewPeer
		},
    {ReqId, ReqInfo}.
