%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_SUITE).

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
				       {ip,  {127,0,0,1}},
				       {reuseaddr, true}
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
     create_pdp_context_request_missing_ie, create_pdp_context_request,
     create_pdp_context_request_resend,
     delete_pdp_context_request, delete_pdp_context_request_resend].

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
create_pdp_context_request_missing_ie() ->
    [{doc, "Check that Create Session Request IE validation works"}].
create_pdp_context_request_missing_ie(_Config) ->
    S = make_gtp_socket(),

    SeqNo = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    IEs = #{},
    Msg = #gtp{version = v1, type = create_pdp_context_request, tei = 0,
	       seq_no = SeqNo, ie = IEs},
    ok = send_pdu(S, Msg),

    Response =
	case gen_udp:recv(S, 4096, 1000) of
	    {ok, {?LOCALHOST, ?GTP2c_PORT, R}} ->
		R;
	    Unexpected ->
		ct:fail(Unexpected)
	end,

    ?match(#gtp{type = create_pdp_context_response,
		ie = #{{cause,0} := #cause{value = mandatory_ie_missing}}},
	   gtp_packet:decode(Response)),
    ok.

create_pdp_context_request() ->
    [{doc, "Check that Create Session Request works"}].
create_pdp_context_request(_Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(),

    SeqNo = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg = make_create_pdp_context_request(LocalCntlTEI, LocalDataTEI, SeqNo),
    ok = send_pdu(S, Msg),

    Response =
	case gen_udp:recv(S, 4096, 1000) of
	    {ok, {?LOCALHOST, ?GTP2c_PORT, R}} ->
		R;
	    Unexpected ->
		ct:fail(Unexpected)
	end,

    ?match(#gtp{type = create_pdp_context_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo,
     		ie = #{{cause, 0} := #cause{value = request_accepted}}},
	   gtp_packet:decode(Response)),
    ok.

create_pdp_context_request_resend() ->
    [{doc, "Check that a retransmission of a Create Session Request works"}].
create_pdp_context_request_resend(_Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(),

    SeqNo = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg = make_create_pdp_context_request(LocalCntlTEI, LocalDataTEI, SeqNo),
    Resp = send_recv_pdu(S, Msg),

    ?match(#gtp{type = create_pdp_context_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo,
		ie = #{{cause, 0} := #cause{value = request_accepted}}},
	   Resp),
    ?match(Resp, send_recv_pdu(S, Msg)),
    ok.

delete_pdp_context_request() ->
    [{doc, "Check that Delete Session Request works"}].
delete_pdp_context_request(_Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(),

    SeqNo1 = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg1 = make_create_pdp_context_request(LocalCntlTEI, LocalDataTEI, SeqNo1),
    Resp1 = send_recv_pdu(S, Msg1),

    ?match(#gtp{type = create_pdp_context_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo1,
		ie = #{{cause,0} := #cause{value = request_accepted},
		       {charging_id,0} := #charging_id{},
		       {end_user_address,0} :=
			   #end_user_address{pdp_type_organization = 1,
					     pdp_type_number = 33},
		       {gsn_address,0} := #gsn_address{},
		       {gsn_address,1} := #gsn_address{},
		       {protocol_configuration_options,0} :=
			   #protocol_configuration_options{
			      config = {0,[{ipcp,'CP-Configure-Nak',1,[{ms_dns1,_},
								       {ms_dns2,_}]},
					   {13, _},
					   {13, _}]}},
		       {quality_of_service_profile,0} :=
			   #quality_of_service_profile{priority = 2},
		       {reordering_required,0} :=
			   #reordering_required{required = no},
		       {tunnel_endpoint_identifier_control_plane,0} :=
			   #tunnel_endpoint_identifier_control_plane{},
		       {tunnel_endpoint_identifier_data_i,0} :=
			   #tunnel_endpoint_identifier_data_i{}
		      }}, Resp1),

    #gtp{ie = #{{tunnel_endpoint_identifier_control_plane,0} :=
		    #tunnel_endpoint_identifier_control_plane{
		       tei = RemoteCntlTEI}
	       }} = Resp1,

    SeqNo2 = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    Msg2 = make_delete_pdp_context_request(LocalCntlTEI, RemoteCntlTEI, SeqNo2),
    Resp2 = send_recv_pdu(S, Msg2),

    ?match(#gtp{type = delete_pdp_context_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo2,
		ie = #{{cause,0} := #cause{value = request_accepted}}
	       }, Resp2),
    ok.

delete_pdp_context_request_resend() ->
    [{doc, "Check that a retransmission of a Delete Session Request works"}].
delete_pdp_context_request_resend(_Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    S = make_gtp_socket(),

    SeqNo1 = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    LocalCntlTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
    LocalDataTEI = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,

    Msg1 = make_create_pdp_context_request(LocalCntlTEI, LocalDataTEI, SeqNo1),
    Resp1 = send_recv_pdu(S, Msg1),

    ?match(#gtp{type = create_pdp_context_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo1,
		ie = #{{cause,0} := #cause{value = request_accepted},
		       {charging_id,0} := #charging_id{},
		       {end_user_address,0} :=
			   #end_user_address{pdp_type_organization = 1,
					     pdp_type_number = 33},
		       {gsn_address,0} := #gsn_address{},
		       {gsn_address,1} := #gsn_address{},
		       {protocol_configuration_options,0} :=
			   #protocol_configuration_options{
			      config = {0,[{ipcp,'CP-Configure-Nak',1,[{ms_dns1,_},
								       {ms_dns2,_}]},
					   {13, _},
					   {13, _}]}},
		       {quality_of_service_profile,0} :=
			   #quality_of_service_profile{priority = 2},
		       {reordering_required,0} :=
			   #reordering_required{required = no},
		       {tunnel_endpoint_identifier_control_plane,0} :=
			   #tunnel_endpoint_identifier_control_plane{},
		       {tunnel_endpoint_identifier_data_i,0} :=
			   #tunnel_endpoint_identifier_data_i{}
		      }}, Resp1),

    #gtp{ie = #{{tunnel_endpoint_identifier_control_plane,0} :=
		    #tunnel_endpoint_identifier_control_plane{
		       tei = RemoteCntlTEI}
	       }} = Resp1,

    SeqNo2 = erlang:unique_integer([positive, monotonic]) rem 16#7fffff,
    Msg2 = make_delete_pdp_context_request(LocalCntlTEI, RemoteCntlTEI, SeqNo2),
    Resp2 = send_recv_pdu(S, Msg2),

    ?match(#gtp{type = delete_pdp_context_response,
		tei = LocalCntlTEI,
		seq_no = SeqNo2,
		ie = #{{cause,0} := #cause{value = request_accepted}}
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

make_create_pdp_context_request(LocalCntlTEI, LocalDataTEI, SeqNo) ->
    IEs = [#access_point_name{apn = ?'APN-EXAMPLE'},
	   #end_user_address{pdp_type_organization = 1,
			     pdp_type_number = 16#21,
			     pdp_address = <<>>},
	   #gsn_address{instance = 0, address = gtp_c_lib:ip2bin(?LOCALHOST)},
	   #gsn_address{instance = 1, address = gtp_c_lib:ip2bin(?LOCALHOST)},
	   #imei{imei = <<"1234567890123456">>},
	   #international_mobile_subscriber_identity{imsi = <<"111111111111111">>},
	   #ms_international_pstn_isdn_number{msisdn = {isdn_address,1,1,1,
							<<"449999999999">>}},
	   #nsapi{nsapi = 5},
	   #protocol_configuration_options{
	      config = {0, [{ipcp,'CP-Configure-Request',1,[{ms_dns1,<<0,0,0,0>>},
							    {ms_dns2,<<0,0,0,0>>}]},
			    {13,<<>>}]}},
	   #quality_of_service_profile{
	      priority = 2,
	      data = <<19,146,31,113,150,254,254,116,250,255,255,0,142,0>>},
	   #rat_type{rat_type = 1},
	   #selection_mode{mode = 0},
	   #tunnel_endpoint_identifier_control_plane{tei = LocalCntlTEI},
	   #tunnel_endpoint_identifier_data_i{tei = LocalDataTEI},
	   #user_location_information{type = 1,
				      mcc = <<"001">>,
				      mnc = <<"001">>,
				      lac = 11,
				      ci  = 0,
				      sac = 20263,
				      rac = 0}],

    #gtp{version = v1, type = create_pdp_context_request, tei = 0,
	 seq_no = SeqNo, ie = IEs}.

make_delete_pdp_context_request(_LocalCntlTEI, RemoteCntlTEI, SeqNo) ->
    IEs = [#nsapi{nsapi=5},
	   #teardown_ind{value=1}],

    #gtp{version = v1, type = delete_pdp_context_request,
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
