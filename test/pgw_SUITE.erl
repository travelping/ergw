%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").

-define(TIMEOUT, 2000).
-define(HUT, pgw_s5s8).				%% Handler Under Test

-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).

%%%===================================================================
%%% API
%%%===================================================================

-define(TEST_CONFIG, [
		      {lager, [{colored, true},
			       {error_logger_redirect, false},
			       {handlers, [
					   %% lager logging leads to timeouts, disable it
					   {lager_console_backend, emergency},
					   {lager_file_backend, [{file, "error.log"}, {level, error}]},
					   {lager_file_backend, [{file, "console.log"}, {level, emergency}]}
					  ]}
			      ]},

		      {ergw, [{sockets,
			       [{irx, [{type, 'gtp-c'},
				       {ip,  {127,0,0,1}},
				       {reuseaddr, true},
				       {'$remote_port', ?GTP1c_PORT * 4}
				      ]},
				{grx, [{type, 'gtp-u'},
				       {node, 'gtp-u-node@localhost'},
				       {name, 'grx'}]}
			       ]},

			      {vrfs,
			       [{upstream, [{pools,  [{{10, 180, 0, 1}, {10, 180, 255, 254}, 32},
						      {{16#8001, 0, 0, 0, 0, 0, 0, 0}, {16#8001, 0, 0, 16#FFFF, 0, 0, 0, 0}, 64}
						     ]},
					    {'MS-Primary-DNS-Server', {8,8,8,8}},
					    {'MS-Secondary-DNS-Server', {8,8,4,4}},
					    {'MS-Primary-NBNS-Server', {127,0,0,1}},
					    {'MS-Secondary-NBNS-Server', {127,0,0,1}}
					   ]}
			       ]},

			      {handlers,
			       [{gn, [{handler, ?HUT},
				      {sockets, [irx]},
				      {data_paths, [grx]},
				      {aaa, [{'Username',
					      [{default, ['IMSI', <<"@">>, 'APN']}]}]}
				     ]},
				{s5s8, [{handler, ?HUT},
					{sockets, [irx]},
					{data_paths, [grx]}
				       ]},
				{s2a,  [{handler, pgw_s2a},
					{sockets, [irx]},
					{data_paths, [grx]}
				       ]}
			       ]},

			      {apns,
			       [{?'APN-EXAMPLE', [{vrf, upstream}]},
				{[<<"APN1">>], [{vrf, upstream}]}
			       ]}
			     ]},
		      {ergw_aaa, [{ergw_aaa_provider, {ergw_aaa_mock, [{secret, <<"MySecret">>}]}}]}
		     ]).


suite() ->
    [{timetrap,{seconds,30}}].

init_per_suite(Config0) ->
    Config = [{handler_under_test, ?HUT},
	      {app_cfg, ?TEST_CONFIG},
	      {gtp_port, ?GTP2c_PORT * 4}
	      | Config0],

    ok = lib_init_per_suite(Config),
    Config.

end_per_suite(Config) ->
    ok = lib_end_per_suite(Config),
    ok.

all() ->
    [invalid_gtp_pdu,
     create_session_request_missing_ie,
     path_restart, path_restart_recovery,
     simple_session_request,
     create_session_request_resend,
     delete_session_request_resend].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(path_restart, Config) ->
    meck_reset(Config),
    ok = meck:new(gtp_path, [passthrough, no_link]),
    Config;
init_per_testcase(_, Config) ->
    meck_reset(Config),
    true = meck:validate(gtp_dp),
    Config.

end_per_testcase(path_restart, Config) ->
    meck:unload(gtp_path),
    Config;
end_per_testcase(_, Config) ->
    Config.

%%--------------------------------------------------------------------
invalid_gtp_pdu() ->
    [{doc, "Test that an invalid PDU is silently ignored"
      " and that the GTP socket is not crashing"}].
invalid_gtp_pdu(Config) ->
    S = make_gtp_socket(Config),
    gen_udp:send(S, ?LOCALHOST, ?GTP2c_PORT, <<"TESTDATA">>),

    ?equal({error,timeout}, gen_udp:recv(S, 4096, ?TIMEOUT)),
    meck_validate(Config),
    ok.

%%--------------------------------------------------------------------
create_session_request_missing_ie() ->
    [{doc, "Check that Create Session Request IE validation works"}].
create_session_request_missing_ie(Config) ->
    S = make_gtp_socket(Config),

    SeqNo = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    IEs = #{},
    Msg = #gtp{version = v2, type = create_session_request, tei = 0,
	       seq_no = SeqNo, ie = IEs},
    Response = send_recv_pdu(S, Msg),

    ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = mandatory_ie_missing}}},
	   Response),
    meck_validate(Config),
    ok.

path_restart() ->
    [{doc, "Check that Create Session Request works and "
           "that a Path Restart terminates the session"}].
path_restart(Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(Config),

    GtpC = gtp_context(),
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg = make_create_session_request(LocalCntlTEI, LocalDataTEI, GtpC),
    Response = send_recv_pdu(S, Msg),

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
     		ie = #{{v2_cause, 0} := #v2_cause{v2_cause = request_accepted}}},
	   Response),

    %% simulate patch restart to kill the PDP context
    Echo = make_echo_request(
	     gtp_context_inc_seq(
	       gtp_context_inc_restart_counter(GtpC))),
    send_recv_pdu(S, Echo),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

path_restart_recovery() ->
    [{doc, "Check that Create Session Request works and "
           "that a Path Restart terminates the session"}].
path_restart_recovery(Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(Config),

    GtpC1 = gtp_context(),
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg1 = make_create_session_request(LocalCntlTEI, LocalDataTEI, GtpC1),
    Resp1 = send_recv_pdu(S, Msg1),

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
		       {v2_fully_qualified_tunnel_endpoint_identifier,1} :=
			   #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-C PGW'},
		       {v2_bearer_context,0} :=
			   #v2_bearer_context{
			      group = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
					{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
					    #v2_fully_qualified_tunnel_endpoint_identifier{
					       interface_type = ?'S5/S8-U PGW'}}}
		      }}, Resp1),

    #gtp{ie = #{{v2_fully_qualified_tunnel_endpoint_identifier,1} :=
		    #v2_fully_qualified_tunnel_endpoint_identifier{
		       key = RemoteCntlTEI},
		{v2_bearer_context,0} :=
		    #v2_bearer_context{
		       group = #{{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
				     #v2_fully_qualified_tunnel_endpoint_identifier{
					key = _RemoteDataTEI}}}
	       }} = Resp1,

    GtpC2 = gtp_context_inc_seq(gtp_context_inc_restart_counter(GtpC1)),
    LocalCntlTEI2 = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI2 = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg2 = make_create_session_request(LocalCntlTEI2, LocalDataTEI2, GtpC2),
    Resp2 = send_recv_pdu(S, Msg2),

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI2,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
		       {v2_fully_qualified_tunnel_endpoint_identifier,1} :=
			   #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-C PGW'},
		       {v2_bearer_context,0} :=
			   #v2_bearer_context{
			      group = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
					{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
					    #v2_fully_qualified_tunnel_endpoint_identifier{
					       interface_type = ?'S5/S8-U PGW'}}}
		      }}, Resp2),

    #gtp{ie = #{{v2_fully_qualified_tunnel_endpoint_identifier,1} :=
		    #v2_fully_qualified_tunnel_endpoint_identifier{
		       key = RemoteCntlTEI2},
		{v2_bearer_context,0} :=
		    #v2_bearer_context{
		       group = #{{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
				     #v2_fully_qualified_tunnel_endpoint_identifier{
					key = _RemoteDataTEI2}}}
	       }} = Resp2,


    GtpC3 = gtp_context_inc_seq(GtpC2),
    Msg3 = make_delete_session_request(LocalCntlTEI2, RemoteCntlTEI2, GtpC3),
    Resp3 = send_recv_pdu(S, Msg3),

    ?match(#gtp{type = delete_session_response,
		tei = LocalCntlTEI2,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	       }, Resp3),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.


simple_session_request() ->
    [{doc, "Check simple Create Session, Delete Session sequence"}].
simple_session_request(Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(Config),

    GtpC1 = gtp_context(),
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg1 = make_create_session_request(LocalCntlTEI, LocalDataTEI, GtpC1),
    Resp1 = send_recv_pdu(S, Msg1),

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
		       {v2_fully_qualified_tunnel_endpoint_identifier,1} :=
			   #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-C PGW'},
		       {v2_bearer_context,0} :=
			   #v2_bearer_context{
			      group = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
					{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
					    #v2_fully_qualified_tunnel_endpoint_identifier{
					       interface_type = ?'S5/S8-U PGW'}}}
		      }}, Resp1),

    #gtp{ie = #{{v2_fully_qualified_tunnel_endpoint_identifier,1} :=
		    #v2_fully_qualified_tunnel_endpoint_identifier{
		       key = RemoteCntlTEI},
		{v2_bearer_context,0} :=
		    #v2_bearer_context{
		       group = #{{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
				     #v2_fully_qualified_tunnel_endpoint_identifier{
					key = _RemoteDataTEI}}}
	       }} = Resp1,

    GtpC2 = gtp_context_inc_seq(GtpC1),
    Msg2 = make_delete_session_request(LocalCntlTEI, RemoteCntlTEI, GtpC2),
    Resp2 = send_recv_pdu(S, Msg2),

    ?match(#gtp{type = delete_session_response,
		tei = LocalCntlTEI,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	       }, Resp2),
    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

create_session_request_resend() ->
    [{doc, "Check that a retransmission of a Create Session Request works"}].
create_session_request_resend(Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(Config),

    GtpC1 = gtp_context(),
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg1 = make_create_session_request(LocalCntlTEI, LocalDataTEI, GtpC1),
    Resp1 = send_recv_pdu(S, Msg1),

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
		       {v2_fully_qualified_tunnel_endpoint_identifier,1} :=
			   #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-C PGW'},
		       {v2_bearer_context,0} :=
			   #v2_bearer_context{
			      group = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
					{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
					    #v2_fully_qualified_tunnel_endpoint_identifier{
					       interface_type = ?'S5/S8-U PGW'}}}
		      }}, Resp1),

    #gtp{ie = #{{v2_fully_qualified_tunnel_endpoint_identifier,1} :=
		    #v2_fully_qualified_tunnel_endpoint_identifier{
		       key = RemoteCntlTEI},
		{v2_bearer_context,0} :=
		    #v2_bearer_context{
		       group = #{{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
				     #v2_fully_qualified_tunnel_endpoint_identifier{
					key = _RemoteDataTEI}}}
	       }} = Resp1,

    ?match(Resp1, send_recv_pdu(S, Msg1)),

    GtpC2 = gtp_context_inc_seq(GtpC1),
    Msg2 = make_delete_session_request(LocalCntlTEI, RemoteCntlTEI, GtpC2),
    Resp2 = send_recv_pdu(S, Msg2),

    ?match(#gtp{type = delete_session_response,
		tei = LocalCntlTEI,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	       }, Resp2),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

delete_session_request_resend() ->
    [{doc, "Check that a retransmission of a Delete Session Request works"}].
delete_session_request_resend(Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(Config),

    GtpC1 = gtp_context(),
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg1 = make_create_session_request(LocalCntlTEI, LocalDataTEI, GtpC1),
    Resp1 = send_recv_pdu(S, Msg1),

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
		       {v2_fully_qualified_tunnel_endpoint_identifier,1} :=
			   #v2_fully_qualified_tunnel_endpoint_identifier{
			      interface_type = ?'S5/S8-C PGW'},
		       {v2_bearer_context,0} :=
			   #v2_bearer_context{
			      group = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted},
					{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
					    #v2_fully_qualified_tunnel_endpoint_identifier{
					       interface_type = ?'S5/S8-U PGW'}}}
		      }}, Resp1),

    #gtp{ie = #{{v2_fully_qualified_tunnel_endpoint_identifier,1} :=
		    #v2_fully_qualified_tunnel_endpoint_identifier{
		       key = RemoteCntlTEI},
		{v2_bearer_context,0} :=
		    #v2_bearer_context{
		       group = #{{v2_fully_qualified_tunnel_endpoint_identifier,2} :=
				     #v2_fully_qualified_tunnel_endpoint_identifier{
					key = _RemoteDataTEI}}}
	       }} = Resp1,

    GtpC2 = gtp_context_inc_seq(GtpC1),
    Msg2 = make_delete_session_request(LocalCntlTEI, RemoteCntlTEI, GtpC2),
    Resp2 = send_recv_pdu(S, Msg2),

    ?match(#gtp{type = delete_session_response,
		tei = LocalCntlTEI,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	       }, Resp2),
    ?match(Resp2, send_recv_pdu(S, Msg2)),

    ok = meck:wait(?HUT, terminate, '_', ?TIMEOUT),
    meck_validate(Config),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

make_echo_request(#gtpc{restart_counter = RCnt, seq_no = SeqNo}) ->
    IEs = [#v2_recovery{restart_counter = RCnt}],
    #gtp{version = v2, type = echo_request, tei = undefined,
	 seq_no = SeqNo, ie = IEs}.

make_create_session_request(LocalCntlTEI, LocalDataTEI,
			    #gtpc{restart_counter = RCnt,
				  seq_no = SeqNo}) ->
    IEs = [#v2_recovery{restart_counter = RCnt},
	   #v2_access_point_name{apn = ?'APN-EXAMPLE'},
	   #v2_aggregate_maximum_bit_rate{uplink = 48128, downlink = 1704125},
	   #v2_apn_restriction{restriction_type_value = 0},
	   #v2_bearer_context{
	      group = [#v2_bearer_level_quality_of_service{
			  pci = 1, pl = 10, pvi = 0, label = 8,
			  maximum_bit_rate_for_uplink      = 0,
			  maximum_bit_rate_for_downlink    = 0,
			  guaranteed_bit_rate_for_uplink   = 0,
			  guaranteed_bit_rate_for_downlink = 0},
		       #v2_eps_bearer_id{eps_bearer_id = 5},
		       #v2_fully_qualified_tunnel_endpoint_identifier{
			  instance = 2,
			  interface_type = ?'S5/S8-U SGW',
			  key = LocalDataTEI,
			  ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)}
		      ]},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)},
	   #v2_international_mobile_subscriber_identity{
	      imsi = <<"111111111111111">>},
	   #v2_mobile_equipment_identity{mei = <<"AAAAAAAA">>},
	   #v2_msisdn{msisdn = <<"449999999999">>},
	   #v2_pdn_address_allocation{type = ipv4,
				      address = <<0,0,0,0>>},
	   #v2_pdn_type{pdn_type = ipv4},
	   #v2_protocol_configuration_options{
	      config = {0, [{ipcp,'CP-Configure-Request',0,[{ms_dns1,<<0,0,0,0>>},
							    {ms_dns2,<<0,0,0,0>>}]},
			    {13,<<>>},{10,<<>>},{5,<<>>}]}},
	   #v2_rat_type{rat_type = 6},
	   #v2_selection_mode{mode = 0},
	   #v2_serving_network{mcc = <<"001">>, mnc = <<"001">>},
	   #v2_ue_time_zone{timezone = 10, dst = 0},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}],

    #gtp{version = v2, type = create_session_request, tei = 0,
	 seq_no = SeqNo, ie = IEs}.

make_delete_session_request(LocalCntlTEI, RemoteCntlTEI,
			    #gtpc{restart_counter = RCnt,
				  seq_no = SeqNo}) ->
    IEs = [%%{170,0} => {170,0,<<220,126,139,67>>},
	   #v2_recovery{restart_counter = RCnt},
	   #v2_eps_bearer_id{eps_bearer_id = 5},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}],

    #gtp{version = v2, type = delete_session_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs}.
