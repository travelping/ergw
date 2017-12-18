%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_redirector_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").

-include("../include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include("ergw_ggsn_test_lib.hrl").

-define(TIMEOUT, 2000).
-define(HUT, ggsn_gn).              %% Handler Under Test

%%%===================================================================
%%% API
%%%===================================================================

suite() ->
    [{timetrap,{seconds,30}}].

init_per_suite(Config0) ->
    AppCfg = inject_redirector(ggsn_SUITE:get_test_config()),
    Config = [{handler_under_test, ?HUT},
              {app_cfg, AppCfg}
              | Config0],
    Config1 = lib_init_per_suite(Config),
    % we need this timeout (2 times of Keep-Alive timeout) to be sure 
    % that nodes which are not available will be removed
    timer:sleep(1100),
    Config1.

inject_redirector(Config) ->
    ModifyIRX = 
        fun({irx, _}) -> 
                IRX = [{type, 'gtp-c'},
                       {ip,  ?TEST_GSN_R}, % 127.0.0.1 -> 127.0.1.1
                       {reuseaddr, true}],
                {irx, IRX};
           (Other) -> Other
        end,
    RRX = {rrx, [{type, 'gtp-c'},
                 {ip,  ?TEST_GSN},
                 {reuseaddr, true},
                 {redirector, [
                               {keep_alive_timeout, 500},
                               {retransmit_timeout, 10000},
                               {lb_type, random},
                               {nodes, [
                                        {node, [{name, <<"gsn">>},
                                                {keep_alive_version, v1},
                                                {address, ?TEST_GSN_R}
                                               ]},
                                        {node, [{name, <<"broken">>},
                                                {keep_alive_version, v1},
                                                {address, {10,0,0,1}}
                                               ]}
                                       ]},
                               {rules, [
                                        % this rule should never happen by sgsn_ip
                                        {rule, [
                                                {conditions, [{sgsn_ip, {192, 255, 127, 127}},
                                                              {version, [v1, v2]}
                                                             ]},
                                                {nodes, [<<"gsn">>]}
                                               ]},
                                        % to ggsn
                                        {rule, [% when ip and imsi are matched
                                                {conditions, [{sgsn_ip, {127, 127, 127, 127}},
                                                              {imsi, <<"111111111111111">>},
                                                              {version, [v1]}
                                                             ]},
                                                {nodes, [<<"gsn">>, <<"broken">>]}
                                               ]},
                                        % to pgw
                                        {rule, [% when ip and imsi are matched
                                                {conditions, [{sgsn_ip, {127, 127, 127, 127}},
                                                              {imsi, <<"111111111111111">>},
                                                              {version, [v2]}
                                                             ]},
                                                {nodes, [<<"gsn">>, <<"broken">>]}
                                               ]},
                                        {rule, [% TODO: some request like delete_pdp_context_request
                                                %       go to this rule. we do it because now test helpers are
                                                %       not able to change destination api to send requests.
                                                {conditions, []},
                                                {nodes, [<<"gsn">>]}
                                               ]}
                                       ]} 
                              ]}
                ]},
    S5S8 = {s5s8, [{handler, pgw_s5s8},
                   {sockets, [irx]},
                   {data_paths, [grx]},
                   {aaa, [{'Username',
                           [{default, ['IMSI',   <<"/">>,
                                       'IMEI',   <<"/">>,
                                       'MSISDN', <<"/">>,
                                       'ATOM',   <<"/">>,
                                       "TEXT",   <<"/">>,
                                       12345,
                                       <<"@">>, 'APN']}]}]}
                  ]},
    ModifySocketsAndHandlers = 
        fun({sockets, Sockets}) -> {sockets, lists:map(ModifyIRX, [RRX | Sockets])};
           ({handlers, Handlers}) -> {handlers, [S5S8 | Handlers]};
           (Other) -> Other
        end,
    lists:map(fun({ergw, Ergw}) -> 
                      {ergw, lists:map(ModifySocketsAndHandlers, Ergw)};
                 (Other) -> Other
             end, Config).

end_per_suite(Config) ->
    ok = lib_end_per_suite(Config),
    ok.

all() ->
    [
     invalid_gtp_pdu,
     invalid_gtp_msg,
     simple_pdp_context_request,
     create_pdp_context_request_resend,
     keep_alive
    ].

%%%===================================================================
%%% Tests
%%%===================================================================
init_per_testcase(create_pdp_context_request_resend, Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    ok = meck:new(ergw_cache, [passthrough, no_link]),
    meck_reset(Config),
    Config;

init_per_testcase(_, Config) ->
    ct:pal("Sockets: ~p", [gtp_socket_reg:all()]),
    meck_reset(Config),
    Config.

end_per_testcase(create_pdp_context_request_resend, Config) ->
    meck:unload(ergw_cache),
    Config;

end_per_testcase(_, Config) ->
    Config.

%%--------------------------------------------------------------------
invalid_gtp_pdu() ->
    [{doc, "Test that an invalid PDU is silently ignored "
           "and that the GTP Redirector socket is not crashing"}].
invalid_gtp_pdu(Config) ->
    ggsn_SUITE:invalid_gtp_pdu(Config).

%%--------------------------------------------------------------------
invalid_gtp_msg() ->
    [{doc, "Test that an invalid message is silently ignored"
      " and that the GTP socket is not crashing"}].
invalid_gtp_msg(Config) ->
    ggsn_SUITE:invalid_gtp_msg(Config).

%%--------------------------------------------------------------------
simple_pdp_context_request() ->
    [{doc, "Check simple Create PDP Context and Delete PDP Context sequence "
           "through GTP Redirector"}].
simple_pdp_context_request(Config) ->
    ggsn_SUITE:simple_pdp_context_request(Config).

%%--------------------------------------------------------------------
create_pdp_context_request_resend() ->
    [{doc, "Check that a retransmission cache of some request works"}].
create_pdp_context_request_resend(Config) ->
    % We are going to check how much times ergw_cache:enter will be called to storing 
    % a node for the particular create_pdp_context_request in redirector mode.
    % `ggsn_SUITE:create_pdp_context_request_resend` sends `create_pdp_context_request` twice
    % but because rederector socket has some retransmission cache we expect that `enter`
    % will be called just once, and the seconds request will be processed to node 
    % which was cached before
    Count = get_count(),
    ggsn_SUITE:create_pdp_context_request_resend(Config),
    ?equal(1, get_count() - Count).

get_count() ->
    Id = {'_', '_', '_', create_pdp_context_request, '_'},
    Node = {'_', '_'},
    meck:num_calls(ergw_cache, enter, [Id, Node, '_', '_']).

%%--------------------------------------------------------------------
keep_alive() ->
    [{doc, "All backend GTP-C should answer on echo_request which sent by timeout"}].
keep_alive(_Config) ->
    Id = [path, irx, {127,0,0,1}, tx, v1, echo_response],
    Cnt0 = get_value(exometer:get_value(Id)),
    timer:sleep(1000),
    Cnt = get_value(exometer:get_value(Id)),
    ?match(true, Cnt > Cnt0),
    ok.

get_value({ok, DPs}) -> proplists:get_value(value, DPs, -1);
get_value(_) -> -1.
