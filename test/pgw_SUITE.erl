%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at http://mozilla.org/MPL/2.0/.

%% Copyright 2017, Travelping GmbH <info@travelping.com>

-module(pgw_SUITE).

-compile(export_all).

-include_lib("common_test/include/ct.hrl").
-include("../include/ergw.hrl").

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
			       [{[<<"example">>, <<"net">>], [{vrf, upstream}]},
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
    Config.

end_per_suite(_) ->
    ct:pal("DP: ~p", [meck:history(gtp_dp)]),
    meck:unload(gtp_dp),
    application:stop(ergw),
    ok.

all() ->
    [invalid_gtp_pdu].

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
    {ok, S} = gen_udp:open(0, [{ip, {127,0,0,1}}, {active, false}, {reuseaddr, true}]),
    ct:pal("S: ~p", [S]),
    gen_udp:send(S, {127,0,0,1}, ?GTP1c_PORT, <<"TESTDATA">>),

    ?equal({error,timeout}, gen_udp:recv(S, 4096, 1000)),
    ?equal(true, meck:validate(gtp_socket)),
    ok.

%%%===================================================================
%%% Meck functions for fake the GTP sockets
%%%===================================================================

meck_dp() ->
    ok = meck:new(gtp_dp, [passthrough, no_link]),
    ok = meck:expect(gtp_dp, start_link, fun(_Args) -> ok end),
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
