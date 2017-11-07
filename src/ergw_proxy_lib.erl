%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_proxy_lib).

-export([validate_options/3, validate_option/2,
	 forward_request/3, forward_request/7, forward_request/9,
	 get_seq_no/3]).
-export([create_forward_session/2,
	 modify_forward_session/4,
	 delete_forward_session/2]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% API
%%%===================================================================

forward_request(Direction, GtpPort, DstIP, DstPort,
		Request, ReqKey, SeqNo, NewPeer, OldState) ->
    {ReqId, ReqInfo} = make_proxy_request(Direction, ReqKey, SeqNo, NewPeer, OldState),
    lager:debug("Invoking Context Send Request: ~p", [Request]),
    gtp_context:send_request(GtpPort, DstIP, DstPort, ReqId, Request, ReqInfo).

forward_request(Direction,
		#context{control_port = GtpPort,
			 remote_control_ip = RemoteCntlIP},
		Request, ReqKey, SeqNo, NewPeer, OldState) ->
    forward_request(Direction, GtpPort, RemoteCntlIP, ?GTP1c_PORT,
		    Request, ReqKey, SeqNo, NewPeer, OldState).

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

make_proxy_request(Direction, Request, SeqNo, NewPeer, State) ->
    ReqId = make_request_id(Request, SeqNo),
    ReqInfo = #proxy_request{
		 direction = Direction,
		 request = Request,
		 seq_no = SeqNo,
		 new_peer = NewPeer,
		 context = maps:get(context, State, undefined),
		 proxy_ctx = maps:get(proxy_context, State, undefined)
		},
    {ReqId, ReqInfo}.

%%%===================================================================
%%% Sx DP API
%%%===================================================================

create_pdr({RuleId,
	    #context{
	       data_port = #gtp_port{name = InPortName},
	       local_data_tei = LocalTEI}},
	   PDRs) ->
    PDI = #{
      source_interface => InPortName,
      local_f_teid => #f_teid{teid = LocalTEI}
     },
    PDR = #{
      pdr_id => RuleId,
      precedence => 100,
      pdi => PDI,
      outer_header_removal => true,
      far_id => RuleId
     },
    [PDR | PDRs].

create_far({RuleId,
	    #context{
	       data_port = #gtp_port{name = OutPortName},
	       remote_data_ip = PeerIP,
	       remote_data_tei = RemoteTEI}},
	   FARs) ->
    FAR = #{
      far_id => RuleId,
      apply_action => [forward],
      forwarding_parameters => #{
	destination_interface => OutPortName,
	outer_header_creation => #f_teid{ipv4 = PeerIP, teid = RemoteTEI}
       }
     },
    [FAR | FARs].

update_pdr({RuleId,
	    #context{data_port = #gtp_port{name = OldInPortName},
		     local_data_tei = OldLocalTEI},
	    #context{data_port = #gtp_port{name = NewInPortName},
		     local_data_tei = NewLocalTEI}},
	   PDRs)
  when OldInPortName /= NewInPortName;
       OldLocalTEI /= NewLocalTEI ->
    PDI = #{
      source_interface => NewInPortName,
      local_f_teid => #f_teid{teid = NewLocalTEI}
     },
    PDR = #{
      pdr_id => RuleId,
      precedence => 100,
      pdi => PDI,
      outer_header_removal => true,
      far_id => RuleId
     },
    [PDR | PDRs];

update_pdr({_RuleId, _OldIn, _NewIn}, PDRs) ->
    PDRs.

update_far({RuleId,
	    #context{version = OldVersion,
		     data_port = #gtp_port{name = OldOutPortName},
		     remote_data_ip = OldPeerIP,
		     remote_data_tei = OldRemoteTEI},
	    #context{version = NewVersion,
		     data_port = #gtp_port{name = NewOutPortName},
		     remote_data_ip = NewPeerIP,
		     remote_data_tei = NewRemoteTEI}},
	   FARs)
  when OldOutPortName /= NewOutPortName;
       OldPeerIP /= NewPeerIP;
       OldRemoteTEI /= NewRemoteTEI ->
    FAR0 = #{
      far_id => RuleId,
      apply_action => [forward],
      update_forwarding_parameters => #{
	destination_interface => NewOutPortName,
	outer_header_creation => #f_teid{ipv4 = NewPeerIP, teid = NewRemoteTEI}
       }
     },
    FAR = if v2 =:= NewVersion andalso
	     v2 =:= OldVersion ->
		  FAR0#{sxsmreq_flags => [sndem]};
	     true ->
		  FAR0
	  end,
    [FAR | FARs];

update_far({_RuleId, _OldOut, _NewOut}, FARs) ->
    FARs.

create_forward_session(#context{local_data_tei = SEID} = Left, Right) ->
    Req = #{
      cp_f_seid  => SEID,
      create_pdr => lists:foldl(fun create_pdr/2, [], [{1, Left}, {2, Right}]),
      create_far => lists:foldl(fun create_far/2, [], [{2, Left}, {1, Right}])
     },
    ergw_sx:call(Left, session_establishment_request, Req).

modify_forward_session(OldLeft, #context{local_data_tei = NewSEID} = NewLeft,
		       OldRight, NewRight) ->
    Req = #{
      cp_f_seid => NewSEID,
      update_pdr => lists:foldl(fun update_pdr/2, [],
				[{1, OldLeft, NewLeft}, {2, OldRight, NewRight}]),
      update_far => lists:foldl(fun update_far/2, [],
				[{2, OldLeft, NewLeft}, {1, OldRight, NewRight}])
     },
    ergw_sx:call(NewLeft, session_modification_request, Req).

delete_forward_session(Left, _Right) ->
    ergw_sx:call(Left, session_deletion_request, #{}).
