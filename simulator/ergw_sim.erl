%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sim).

-export([start/1, start/2, reply/2, s11/7]).

-include("include/ergw.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").

-define(CONFIG,
	[
	 {lager, [{colored, true},
		  {error_logger_redirect, true},
		  %% force lager into async logging, otherwise
		  %% the test will timeout randomly
		  {async_threshold, undefined},
		  {handlers, [{lager_console_backend, [{level, info}]}]}
		 ]},

	 {ergw, [{'$setup_vars',
		  [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
		 {sockets, []},
		 {vrfs, []},
		 {handlers, []},
		 {node_selection, []},
		 {sx_socket, #{node => 'ergw', name => 'ergw', ip => {127,127,127,127}}},
		 {apns, []}
		]},
	 {ergw_aaa, [{ergw_aaa_provider, {ergw_aaa_mock, [{shared_secret, <<"MySecret">>}]}}]}
	]).

-define(T3, 10 * 1000).
-define(N3, 5).

-define('S1-U eNode-B', 0).
-define('S1-U SGW',     1).
-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).
-define('S11-C MME',    10).
-define('S11/S4-C SGW', 11).

%%%===================================================================
%%% API
%%%===================================================================

start(IP) ->
    start(IP, IP).

start(CpIP0, UpIP0) ->
    CpIP = parse_ip(CpIP0),
    UpIP = parse_ip(UpIP0),
    lists:foreach(
      fun({App, Cnf}) ->
	      application:load(App),
	      lists:foreach(fun({K,V}) ->
				    application:set_env(App, K, V)
			    end, Cnf)
      end, ?CONFIG),
    {ok, _} = application:ensure_all_started(ergw),

    CpOpts = #{type => 'gtp-c',
	       ip   => CpIP,
	       freebind => true},
    {ok, _} = ergw:start_socket('gtp-c', CpOpts),
    {ok, _} = ergw_sim_up:start_socket(UpIP),
    ok.

s11(IP, modify_bearer, RemoteCntlTEI, DpTEI) ->
    CntlPort = #gtp_port{ip = LocalIP} = gtp_socket_reg:lookup('gtp-c'),

    IEs = [#v2_recovery{restart_counter = 1},
	   #v2_bearer_context{
	      group = [#v2_eps_bearer_id{eps_bearer_id = 5},
		       #v2_fully_qualified_tunnel_endpoint_identifier{
			  instance = 0,
			  interface_type = ?'S1-U eNode-B',
			  key = DpTEI,
			  ipv4 = gtp_c_lib:ip2bin(LocalIP)}
		      ]}
	  ],

    Msg = #gtp{version = v2, type = modify_bearer_request, tei = RemoteCntlTEI,
	       seq_no = 2, ie = IEs},

    request(CntlPort, IP, Msg).

s11(IP, initial_attachment, APN, IMEI, IMSI, MSISDN, PdnType) ->
    CntlPort = #gtp_port{ip = LocalIP} = gtp_socket_reg:lookup('gtp-c'),
    {ok, CpTEI} = gtp_context_reg:alloc_tei(CntlPort),
    {ok, DpTEI} = gtp_context_reg:alloc_tei(CntlPort),
    Peer = parse_ip(IP),
    SeqNo = 1,

    BearerContexts =
	[#v2_bearer_level_quality_of_service{
	    pci = 1, pl = 10, pvi = 0, label = 8,
	    maximum_bit_rate_for_uplink      = 0,
	    maximum_bit_rate_for_downlink    = 0,
	    guaranteed_bit_rate_for_uplink   = 0,
	    guaranteed_bit_rate_for_downlink = 0},
	 #v2_eps_bearer_id{eps_bearer_id = 5}],
    IEs0 =
	[#v2_recovery{restart_counter = 1},
	 #v2_access_point_name{apn = gprs_apn(APN)},
	 #v2_aggregate_maximum_bit_rate{uplink = 48128, downlink = 1704125},
	 #v2_apn_restriction{restriction_type_value = 0},
	 #v2_bearer_context{group = BearerContexts},
	 #v2_fully_qualified_tunnel_endpoint_identifier{
	    instance = 0,
	    interface_type = ?'S11-C MME',
	    key = CpTEI,
	    ipv4 = gtp_c_lib:ip2bin(LocalIP)},
	 #v2_fully_qualified_tunnel_endpoint_identifier{
	    instance = 1,
	    interface_type = ?'S5/S8-C PGW',
	    key = 0,
	    ipv4 = gtp_c_lib:ip2bin(Peer)},
	 #v2_international_mobile_subscriber_identity{imsi = IMSI},
	 #v2_mobile_equipment_identity{mei = IMEI},
	 #v2_msisdn{msisdn = MSISDN},
	 #v2_rat_type{rat_type = 6},
	 #v2_selection_mode{mode = 0},
	 #v2_serving_network{mcc = <<"001">>, mnc = <<"001">>},
	 #v2_ue_time_zone{timezone = 10, dst = 0},
	 #v2_user_location_information{tai = <<3,2,22,214,217>>,
				       ecgi = <<3,2,22,8,71,9,92>>}],
    IEs = make_pdn_type(PdnType, IEs0),
    Msg = #gtp{version = v2, type = create_session_request, tei = 0,
	       seq_no = SeqNo, ie = IEs},

    NextReq =
	fun(#gtp{ie = #{
		   {v2_cause,0} :=
		       #v2_cause{v2_cause = request_accepted},
		   {v2_fully_qualified_tunnel_endpoint_identifier,0} :=
		       #v2_fully_qualified_tunnel_endpoint_identifier{
			  interface_type = 11, key = RemoteCntlTEI,
			  ipv4 = RemoteCntlIP}
		  }}) ->
		s11(RemoteCntlIP, modify_bearer, RemoteCntlTEI, DpTEI)
	end,
    request(CntlPort, IP, Msg, NextReq).

reply({Pid, Ref}, Reply) ->
    Pid ! {'$reply', Ref, Reply}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

parse_ip({_,_,_,_} = IP) -> IP;
parse_ip({_,_,_,_,_,_,_,_} = IP) -> IP;
parse_ip(IP)
  when is_binary(IP) andalso
       (size(IP) == 4 orelse size(IP) == 16) ->
    gtp_c_lib:bin2ip(IP);
parse_ip(IP) when is_binary(IP) ->
    parse_ip(binary_to_list(IP));
parse_ip(IP) when is_list(IP) ->
    {ok, V} = inet:parse_address(IP),
    V.

make_label(L) when is_list(L) ->
    list_to_binary(L);
make_label(B) when is_binary(B) ->
    B.

request(CtrlPort, IP, Msg) ->
    request(CtrlPort, IP, Msg, fun(Reply) -> {ok, Reply} end).

request(CntlPort, IP, Msg, Fun) ->
    Peer = parse_ip(IP),
    io:format("Request: ~s~n", [gtp_packet:pretty_print(Msg)]),

    Ref = make_ref(),
    gtp_socket:send_request(CntlPort, Peer, ?GTP1c_PORT, ?T3, ?N3, Msg,
			    {?MODULE, reply, [{self(), Ref}]}),

    response(Ref, Fun, 5000).

response(Ref, Fun, Timeout) ->
    receive
	{'$reply', Ref, Reply0 = #gtp{}} ->
	    Reply = gtp_packet:decode_ies(Reply0),
	    io:format("Reply: ~s~n", [gtp_packet:pretty_print(Reply)]),
	    Fun(Reply);
	{'$reply', Ref, Reply} ->
	    io:format("Reply: ~s~n", [gtp_packet:pretty_print(Reply)]),
	    {ok, Reply}
    after
	Timeout ->
	    {error, timeout}
    end.

gprs_apn([Label|_] = APN0) when is_list(Label); is_binary(Label) ->
    APN =
	case lists:reverse(APN0) of
	    [H|_] when H == <<"gprs">>;
		       H == "gprs" ->
		APN0;
	    _ ->
		{MCC, MNC} = ergw:get_plmn_id(),
		APN0 ++
		    [lists:flatten(io_lib:format("mcc~3..0s", [MCC])),
		     lists:flatten(io_lib:format("mnc~3..0s", [MNC])),
		     "gprs"]
	end,
    [make_label(X) || X <- APN];
gprs_apn(APN) when is_list(APN); is_binary(APN) ->
    gprs_apn(string:split(APN, ".", all)).

make_pdn_type(ipv6, IEs) ->
    PrefixLen = 64,
    Prefix = gtp_c_lib:ip2bin({0,0,0,0,0,0,0,0}),
    [#v2_pdn_address_allocation{
	type = ipv6,
	address = <<PrefixLen, Prefix/binary>>},
     #v2_pdn_type{pdn_type = ipv6},
     #v2_protocol_configuration_options{
	config = {0, [{1,<<>>}, {3,<<>>}, {10,<<>>}]}}
     | IEs];
make_pdn_type(ipv4v6, IEs) ->
    PrefixLen = 64,
    Prefix = gtp_c_lib:ip2bin({0,0,0,0,0,0,0,0}),
    RequestedIP = gtp_c_lib:ip2bin({0,0,0,0}),
    [#v2_pdn_address_allocation{
	type = ipv4v6,
	address = <<PrefixLen, Prefix/binary, RequestedIP/binary>>},
     #v2_pdn_type{pdn_type = ipv4v6},
     #v2_protocol_configuration_options{
	config = {0, [{ipcp,'CP-Configure-Request',0,
		       [{ms_dns1, <<0,0,0,0>>},
			{ms_dns2, <<0,0,0,0>>}]},
		      {13,<<>>},{10,<<>>},{5,<<>>},
		      {1,<<>>}, {3,<<>>}, {10,<<>>}]}}
     | IEs];
make_pdn_type(_, IEs) ->
    RequestedIP = gtp_c_lib:ip2bin({0,0,0,0}),
    [#v2_pdn_address_allocation{type = ipv4,
				address = RequestedIP},
     #v2_pdn_type{pdn_type = ipv4},
     #v2_protocol_configuration_options{
	config = {0, [{ipcp,'CP-Configure-Request',0,
		       [{ms_dns1, <<0,0,0,0>>},
			{ms_dns2, <<0,0,0,0>>}]},
		      {13,<<>>},{10,<<>>},{5,<<>>}]}}
     | IEs].
