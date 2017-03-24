%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

%% Copyright 2017, Travelping GmbH <info@travelping.com>

-module(pgw_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include("../include/ergw.hrl").

-define(LOCALHOST, {127,0,0,1}).

-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).

-define('APN-EXAMPLE', [<<"example">>, <<"net">>]).

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
                      V -> ct:pal("MISMATCH(~s:~b, ~s)~nExpected: ~p~nActual:   ~p~n",
                                   [?FILE, ?LINE, ??Expr, ??Guard, V]),
                            error(badmatch)
                  end
          end)())).

%%%===================================================================
%%% API
%%%===================================================================

-define(TEST_CONFIG, [{ergw, [{sockets,
			       [{irx, [{type, 'gtp-c'},
				       {ip,  {127,0,0,1}}
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
			       [{gn, [{handler, pgw_s5s8},
				      {sockets, [irx]},
				      {data_paths, [grx]},
				      {aaa, [{'Username',
					      [{default, ['IMSI', <<"@">>, 'APN']}]}]}
				     ]},
				{s5s8, [{handler, pgw_s5s8},
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

init_per_suite(Config) ->
    application:load(ergw),
    ok = meck_dp(),
    lists:foreach(fun({App, Settings}) ->
			  ct:pal("App: ~p, S: ~p", [App, Settings]),
			  lists:foreach(fun({K,V}) ->
						ct:pal("App: ~p, K: ~p, V: ~p", [App, K, V]),
						application:set_env(App, K, V)
					end, Settings)
		  end, ?TEST_CONFIG),
    {ok, _} = application:ensure_all_started(ergw),
    ok = meck:wait(gtp_dp, start_link, '_', 1000),
    ct:pal("Meck H: ~p", [meck:history(gtp_dp)]),
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    Config.

end_per_suite(_) ->
    ct:pal("DP: ~p", [meck:history(gtp_dp)]),
    meck:unload(gtp_dp),
    application:stop(ergw),
    ok.

all() ->
    [invalid_gtp_pdu,
     create_session_request_missing_ie, create_session_request,
     create_session_request_resend,
     delete_session_request, delete_session_request_resend].

%%%===================================================================
%%% Tests
%%%===================================================================

init_per_testcase(invalid_gtp_pdu, Config) ->
    ok = meck:new(gtp_socket, [passthrough]),
    Config;
init_per_testcase(_, Config) ->
    Config.

end_per_testcase(invalid_gtp_pdu, Config) ->
    meck:unload(gtp_socket),
    Config;
end_per_testcase(_, Config) ->
    Config.

%%--------------------------------------------------------------------
invalid_gtp_pdu() ->
    [{doc, "Test that an invalid PDU is silently ignored"
      " and that the GTP socket is not crashing"}].
invalid_gtp_pdu(_Config) ->
    S = make_gtp_socket(),
    gen_udp:send(S, ?LOCALHOST, ?GTP2c_PORT, <<"TESTDATA">>),

    ?equal({error,timeout}, gen_udp:recv(S, 4096, 1000)),
    ?equal(true, meck:validate(gtp_socket)),
    ok.

%%--------------------------------------------------------------------
create_session_request_missing_ie() ->
    [{doc, "Check that Create Session Request IE validation works"}].
create_session_request_missing_ie(_Config) ->
    S = make_gtp_socket(),

    SeqNo = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    IEs = #{},
    Msg = #gtp{version = v2, type = create_session_request, tei = 0,
	       seq_no = SeqNo, ie = IEs},
    ok = send_pdu(S, Msg),

    Response =
	case gen_udp:recv(S, 4096, 1000) of
	    {ok, {?LOCALHOST, ?GTP2c_PORT, R}} ->
		R;
	    Unexpected ->
		ct:fail(Unexpected)
	end,

    ?match(#gtp{type = create_session_response,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = mandatory_ie_missing}}},
	   gtp_packet:decode(Response)),
    ok.

create_session_request() ->
    [{doc, "Check that Create Session Request works"}].
create_session_request(_Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(),

    SeqNo = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg = make_create_session_request(LocalCntlTEI, LocalDataTEI, SeqNo),
    ok = send_pdu(S, Msg),

    Response =
	case gen_udp:recv(S, 4096, 1000) of
	    {ok, {?LOCALHOST, ?GTP2c_PORT, R}} ->
		R;
	    Unexpected ->
		ct:fail(Unexpected)
	end,

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo,
     		ie = #{{v2_cause, 0} := #v2_cause{v2_cause = request_accepted}}},
	   gtp_packet:decode(Response)),
    ok.

create_session_request_resend() ->
    [{doc, "Check that a retransmission of a Create Session Request works"}].
create_session_request_resend(_Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(),

    SeqNo = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg = make_create_session_request(LocalCntlTEI, LocalDataTEI, SeqNo),
    Resp = send_recv_pdu(S, Msg),

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo,
		ie = #{{v2_cause, 0} := #v2_cause{v2_cause = request_accepted}}},
	   Resp),
    ?match(Resp, send_recv_pdu(S, Msg)),
    ok.

delete_session_request() ->
    [{doc, "Check that Delete Session Request works"}].
delete_session_request(_Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(),

    SeqNo1 = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg1 = make_create_session_request(LocalCntlTEI, LocalDataTEI, SeqNo1),
    Resp1 = send_recv_pdu(S, Msg1),

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo1,
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

    SeqNo2 = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    Msg2 = make_delete_session_request(LocalCntlTEI, RemoteCntlTEI, SeqNo2),
    Resp2 = send_recv_pdu(S, Msg2),

    ?match(#gtp{type = delete_session_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo2,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	       }, Resp2),
    ok.

delete_session_request_resend() ->
    [{doc, "Check that a retransmission of a Delete Session Request works"}].
delete_session_request_resend(_Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(),

    SeqNo1 = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg1 = make_create_session_request(LocalCntlTEI, LocalDataTEI, SeqNo1),
    Resp1 = send_recv_pdu(S, Msg1),

    ?match(#gtp{type = create_session_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo1,
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

    SeqNo2 = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    Msg2 = make_delete_session_request(LocalCntlTEI, RemoteCntlTEI, SeqNo2),
    Resp2 = send_recv_pdu(S, Msg2),

    ?match(#gtp{type = delete_session_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo2,
		ie = #{{v2_cause,0} := #v2_cause{v2_cause = request_accepted}}
	       }, Resp2),
    ?match(Resp2, send_recv_pdu(S, Msg2)),
    ok.

%%%===================================================================
%%% Meck functions for fake the GTP sockets
%%%===================================================================

meck_dp() ->
    ok = meck:new(gtp_dp, [passthrough, no_link]),
    ok = meck:expect(gtp_dp, start_link, fun({Name, _SocketOpts}) ->
						 RCnt =  erlang:unique_integer([positive, monotonic]) rem 256,
						 GtpPort = #gtp_port{name = Name,
								     type = 'gtp-u',
								     pid = self(),
								     ip = ?LOCALHOST,
								     restart_counter = RCnt},
						 gtp_socket_reg:register(Name, GtpPort),
						 {ok, self()}
					 end),
    ok = meck:expect(gtp_dp, send, fun(_GtpPort, _IP, _Port, _Data) -> ok end),
    ok = meck:expect(gtp_dp, get_id, fun(_GtpPort) -> self() end),
    ok = meck:expect(gtp_dp, create_pdp_context, fun(_Context, _Args) -> ok end),
    ok = meck:expect(gtp_dp, update_pdp_context, fun(_Context, _Args) -> ok end),
    ok = meck:expect(gtp_dp, delete_pdp_context, fun(_Context, _Args) -> ok end),
    ok.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% hexstr2bin from otp/lib/crypto/test/crypto_SUITE.erl
hexstr2bin(S) ->
    list_to_binary(hexstr2list(S)).

hexstr2list([X,Y|T]) ->
    [mkint(X)*16 + mkint(Y) | hexstr2list(T)];
hexstr2list([]) ->
    [].
mkint(C) when $0 =< C, C =< $9 ->
    C - $0;
mkint(C) when $A =< C, C =< $F ->
    C - $A + 10;
mkint(C) when $a =< C, C =< $f ->
    C - $a + 10.

make_create_session_request(LocalCntlTEI, LocalDataTEI, SeqNo) ->
    IEs = [#v2_access_point_name{apn = ?'APN-EXAMPLE'},
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

make_delete_session_request(LocalCntlTEI, RemoteCntlTEI, SeqNo) ->
    IEs = [%%{170,0} => {170,0,<<220,126,139,67>>},
	   #v2_eps_bearer_id{eps_bearer_id = 5},
	   #v2_fully_qualified_tunnel_endpoint_identifier{
	      interface_type = ?'S5/S8-C SGW',
	      key = LocalCntlTEI,
	      ipv4 = gtp_c_lib:ip2bin(?LOCALHOST)},
	   #v2_user_location_information{tai = <<3,2,22,214,217>>,
					 ecgi = <<3,2,22,8,71,9,92>>}],

    #gtp{version = v2, type = delete_session_request,
	 tei = RemoteCntlTEI, seq_no = SeqNo, ie = IEs}.

make_gtp_socket() ->
    {ok, S} = gen_udp:open(0, [{ip, ?LOCALHOST}, {active, false},
			       binary, {reuseaddr, true}]),
    S.

send_pdu(S, Msg) ->
    Data = gtp_packet:encode(Msg),
    gen_udp:send(S, ?LOCALHOST, ?GTP2c_PORT, Data).

send_recv_pdu(S, Msg) ->
    ok = send_pdu(S, Msg),

    Response =
	case gen_udp:recv(S, 4096, 1000) of
	    {ok, {?LOCALHOST, ?GTP2c_PORT, R}} ->
		R;
	    Unexpected ->
		ct:fail(Unexpected)
	end,
    gtp_packet:decode(Response).
