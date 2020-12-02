%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sx_node).

-behavior(gen_statem).
-behavior(ergw_context).

-compile({parse_transform, cut}).

%% API
-export([request_connect/3, request_connect/5, wait_connect/1,
	 attach/1, attach_tdf/2, notify_up/2]).
-export([start_link/5, send/4, call/2,
	 handle_request/3, response/3]).
-ifdef(TEST).
-export([test_cmd/2]).
-endif.

%% ergw_context callbacks
-export([sx_report/2, port_message/2, port_message/4]).


-ignore_xref([start_link/5,
	      request_connect/5,		% used in spawn from request_connect/3
	      response/3			% used through apply from response_cb
	     ]).

%% gen_statem callbacks
-export([init/1, callback_mode/0, handle_event/4,
	 terminate/3, code_change/4]).

-include_lib("kernel/include/logger.hrl").
-include_lib("kernel/include/inet.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-record(data, {cfg,
	       mode = transient  :: 'transient' | 'persistent',
	       node_select       :: atom(),
	       retries = 0       :: non_neg_integer(),
	       features          :: #up_function_features{},
	       recovery_ts       :: undefined | non_neg_integer(),
	       pfcp_ctx          :: #pfcp_ctx{},
	       bearer            :: #{atom() := #bearer{}},
	       cp_socket         :: #socket{},
	       cp_info           :: #gtp_socket_info{},
	       cp,
	       dp,
	       ip_pools,
	       vrfs,
	       tdf,
	       notify_up = []    :: [{pid(), reference()}]}).

-ifdef(TEST).
-define(AssocReqTimeout, 2).
-define(AssocReqRetries, 5).
-define(AssocTimeout, 5).
-define(AssocRetries, 10).
-define(MaxRetriesScale, 5).
-else.
-define(AssocReqTimeout, 200).
-define(AssocReqRetries, 5).
-define(AssocTimeout, 500).
-define(AssocRetries, 10).
-define(MaxRetriesScale, 5).
-endif.

-define(TestCmdTag, '$TestCmd').

%%====================================================================
%% API
%%====================================================================

%% attach/1
attach(Node) when is_pid(Node) ->
    monitor(process, Node),
    gen_statem:call(Node, attach).

%% attach_tdf/2
attach_tdf(Node, Tdf) when is_pid(Node) ->
    gen_statem:call(Node, {attach_tdf, Tdf}).

start_link(Node, NodeSelect, IP4, IP6, NotifyUp) ->
    proc_lib:start_link(?MODULE, init, [[self(), Node, NodeSelect, IP4, IP6, NotifyUp]]).

-ifdef(TEST).

test_cmd(Pid, stop) when is_pid(Pid) ->
    gen_statem:call(Pid, {?TestCmdTag, stop});
test_cmd(Pid, Cmd) when is_pid(Pid) ->
    gen_statem:call(Pid, {?TestCmdTag, Cmd}).

-endif.

send(#pfcp_ctx{node = Handler}, Intf, VRF, Data)
  when is_pid(Handler), is_atom(Intf), is_binary(Data) ->
    gen_statem:cast(Handler, {send, Intf, VRF, Data}).

%% call/2
call(#pfcp_ctx{node = Node, seid = #seid{dp = SEID}}, #pfcp{} = Request) ->
    gen_statem:call(Node, Request#pfcp{seid = SEID});
call(#pfcp_ctx{node = Node}, Request) ->
    gen_statem:call(Node, Request).

response(Pid, CbData, Response) ->
    gen_statem:cast(Pid, {response, CbData, Response}).

handle_request(ReqKey, IP, #pfcp{type = heartbeat_request} = Request) ->
    case ergw_sx_node_reg:lookup(IP) of
	{ok, Pid} when is_pid(Pid) ->
	    ?LOG(debug, "cast HB request to ~p", [Pid]),
	    gen_statem:cast(Pid, {request, ReqKey, Request});
	_Other ->
	    ?LOG(error, "lookup for ~p failed with ~p", [IP, _Other]),
	    heartbeat_response(ReqKey, Request)
    end,
    ok;
handle_request(ReqKey, _IP, #pfcp{type = session_report_request} = Report) ->
    spawn(fun() -> handle_request_fun(ReqKey, Report) end),
    ok.

handle_request_fun(ReqKey, #pfcp{type = session_report_request} = Report) ->
    {Ctx, IEs} =
	case ergw_context:sx_report(Report) of
	    {ok, Ctx0} ->
		{Ctx0, #{pfcp_cause => #pfcp_cause{cause = 'Request accepted'}}};
	    {ok, Ctx0, Cause}
	      when is_atom(Cause) ->
		{Ctx0, #{pfcp_cause => #pfcp_cause{cause = Cause}}};
	    {ok, Ctx0, IEs0}
	      when is_map(IEs0) ->
		{Ctx0, IEs0};
	    {error, not_found} ->
		{0, #{pfcp_cause => #pfcp_cause{cause = 'Session context not found'}}}
	end,

    Response = make_response(session_report_response, Ctx, Report, IEs),
    ergw_sx_socket:send_response(ReqKey, Response, true),
    ok.

%%====================================================================
%% ergw_context API
%%====================================================================

sx_report(Server, Report) ->
    gen_statem:call(Server, {sx, Report}).

port_message(Request, Msg) ->
    ?LOG(error, "unhandled port message (~p, ~p)", [Request, Msg]),
    erlang:error(badarg, [Request, Msg]).

port_message(Server, Request, #gtp{type = g_pdu} = Msg, _Resent) ->
    gen_server:cast(Server, {handle_pdu, Request, Msg});
port_message(_Server, Request, Msg, _Resent) ->
    ?LOG(error, "unhandled port message (~p, ~p)", [Request, Msg]),
    erlang:error(badarg, [Request, Msg]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

callback_mode() -> [handle_event_function, state_enter].

init([Parent, Node, NodeSelect, IP4, IP6, NotifyUp]) ->
    ergw_sx_node_reg:register(Node, self()),

    {ok, CP, Socket, SockInfo} = ergw_sx_socket:id(),
    {ok, TEI} = ergw_tei_mngr:alloc_tei(Socket),
    SEID = ergw_sx_socket:seid(),

    PCtx = #pfcp_ctx{
	      name = Node,
	      node = self(),
	      seid = #seid{cp = SEID},
	      cp_bearer = make_cp_bearer(TEI, SockInfo)
	     },

    RegKeys =
	[gtp_context:socket_teid_key(Socket, TEI),
	 {seid, SEID}],
    gtp_context_reg:register(RegKeys, ?MODULE, self()),

    Nodes = setup:get_env(ergw, nodes, #{}),
    Cfg = maps:get(Node, Nodes, maps:get(default, Nodes, #{})),
    IP = select_node_ip(IP4, IP6),
    Data0 = #data{cfg = Cfg,
		  mode = mode(Cfg),
		  node_select = NodeSelect,
		  retries = 0,
		  recovery_ts = undefined,
		  pfcp_ctx = PCtx,
		  bearer = #{dp => #bearer{interface = 'CP-function'}},
		  cp_socket = Socket,
		  cp_info = SockInfo,
		  cp = CP,
		  tdf = #{},
		  notify_up = NotifyUp
		 },
    Data = init_node_cfg(Data0),
    proc_lib:init_ack(Parent, {ok, self()}),

    resolve_and_enter_loop(Node, IP, Data).

handle_event(enter, _OldState, {connected, ready},
	     #data{dp = #node{node = Node}} = Data0) ->
    NodeCaps = node_caps(Data0),
    ok = ergw_sx_node_reg:up(Node, NodeCaps),
    Data = send_notify_up(up, Data0#data{retries = 0}),
    {keep_state, Data, [next_heartbeat(Data)]};

handle_event(enter, {connected, _}, dead, #data{dp = #node{node = Node}} = Data) ->
    ergw_sx_node_reg:down(Node),
    {keep_state, Data#data{recovery_ts = undefined}, [{state_timeout, 0, connect}]};

handle_event(enter, _, dead, #data{retries = Retries} = Data0) ->
    Data = send_notify_up(dead, Data0),
    Timeout = (1 bsl min(Retries, ?MaxRetriesScale)) * ?AssocTimeout,
    ?LOG(debug, "Timeout: ~w/~w", [Retries, Timeout]),
    {keep_state, Data, [{state_timeout, Timeout, connect}]};

handle_event(state_timeout, connect, dead, Data) ->
    {next_state, connecting, Data};

handle_event(enter, _, connecting, #data{dp = #node{ip = IP}} = Data) ->
    ergw_sx_node_reg:register(IP, self()),

    Req0 = #pfcp{version = v1, type = association_setup_request, ie = []},
    Req = augment_mandatory_ie(Req0, Data),
    ergw_sx_socket:call(IP, ?AssocReqTimeout, ?AssocReqRetries, Req,
			response_cb(association_setup_request)),
    {keep_state, Data};

handle_event(enter, _OldState, _State, _Data) ->
    keep_state_and_data;

handle_event({call, From}, {?TestCmdTag, pfcp_ctx}, _, #data{pfcp_ctx = PCtx}) ->
    {keep_state_and_data, [{reply, From, PCtx}]};
handle_event({call, From}, {?TestCmdTag, reconnect}, dead, Data) ->
    {next_state, connecting, Data#data{retries = 0}, [{reply, From, ok}]};
handle_event({call, From}, {?TestCmdTag, reconnect}, connecting, _) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, From}, {?TestCmdTag, reconnect}, {connected, _}, Data) ->
    {next_state, dead, handle_nodedown(Data#data{retries = 0}), [{reply, From, ok}]};
handle_event({call, From}, {?TestCmdTag, wait4nodeup}, {connected, _}, _) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, _From}, {?TestCmdTag, wait4nodeup}, _, _) ->
    {keep_state_and_data, [postpone]};

handle_event({call, From}, {?TestCmdTag, stop}, _, Data) ->
    {stop_and_reply, normal, [{reply, From, ok}], Data};

handle_event({call, From}, {attach_tdf, Tdf}, _, Data) ->
    {keep_state, Data#data{tdf = Tdf}, [{reply, From, ok}]};

handle_event({call, From}, _Evt, dead, _Data) ->
    ?LOG(warning, "Call from ~p, ~p failed with {error, dead}", [From, _Evt]),
    {keep_state_and_data, [{reply, From, {error, dead}}]};

handle_event(cast, {response, association_setup_request, Error},
	     connecting, #data{mode = transient, retries = Retries, dp = #node{ip = IP}})
  when is_atom(Error), Retries >= ?AssocRetries ->
    ?LOG(debug, "~s Association Setup ~p, ~w tries, shutdown", [inet:ntoa(IP), Error, Retries]),
    {stop, normal};

handle_event(cast, {response, association_setup_request, Error},
	     connecting, #data{retries = Retries, dp = #node{ip = IP}} = Data)
  when is_atom(Error) ->
    ?LOG(debug, "~s Association Setup ~p, ~w tries", [inet:ntoa(IP), Error, Retries]),
    {next_state, dead, Data#data{retries = Retries + 1}};

handle_event(cast, {response, _, #pfcp{version = v1, type = association_setup_response, ie = IEs}},
	     connecting, Data0) ->
    case IEs of
	#{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} ->
	    Data = handle_nodeup(IEs, Data0),
	    {next_state, {connected, init}, Data};
	Other ->
	    ?LOG(debug, "Other: ~p", [Other]),
	    {next_state, dead, Data0}
    end;

handle_event(cast, {send, 'Access', _VRF, Data}, {connected, _},
	     #data{cp_socket = Socket, dp = #node{ip = IP},
		   bearer = #{dp := #bearer{local = #fq_teid{teid = TEI}}}}) ->

    Msg = #gtp{version = v1, type = g_pdu, tei = TEI, ie = Data},
    Bin = gtp_packet:encode(Msg),
    ergw_gtp_u_socket:send(Socket, gtp, IP, ?GTP1u_PORT, Bin),

    keep_state_and_data;

%%
%% heartbeat logic
%%
handle_event(state_timeout, heartbeat, {connected, _}, Data) ->
    ?LOG(debug, "sending heartbeat"),
    send_heartbeat(Data),
    keep_state_and_data;

handle_event(cast, {heartbeat, timeout}, {connected, _}, Data) ->
    {next_state, dead, handle_nodedown(Data)};

handle_event(cast, {request, ReqKey,
		    #pfcp{type = heartbeat_request,
			  ie = #{recovery_time_stamp :=
				     #recovery_time_stamp{time = RecoveryTS}}} = Request},
	     _, #data{recovery_ts = StoredRecoveryTS} = Data0)
  when is_integer(StoredRecoveryTS) andalso RecoveryTS > StoredRecoveryTS ->
    heartbeat_response(ReqKey, Request),
    Data = Data0#data{recovery_ts = RecoveryTS},
    {next_state, dead, handle_nodedown(Data)};
handle_event(cast, {request, _,
		    #pfcp{type = heartbeat_request,
			  ie = #{recovery_time_stamp :=
				     #recovery_time_stamp{time = RecoveryTS}}}},
	     _, #data{recovery_ts = StoredRecoveryTS})
  when is_integer(StoredRecoveryTS) andalso RecoveryTS < StoredRecoveryTS ->
    keep_state_and_data;
handle_event(cast, {request, ReqKey,
		    #pfcp{type = heartbeat_request,
			  ie = #{recovery_time_stamp :=
				     #recovery_time_stamp{time = RecoveryTS}}} = Request},
	     State, #data{recovery_ts = StoredRecoveryTS} = Data)
  when not is_integer(StoredRecoveryTS) ->
    heartbeat_response(ReqKey, Request),
    {next_state, State, Data#data{recovery_ts = RecoveryTS}};
handle_event(cast, {request, ReqKey, #pfcp{type = heartbeat_request} = Request}, _, _) ->
    heartbeat_response(ReqKey, Request),
    keep_state_and_data;

handle_event(cast, {response, _, #pfcp{version = v1, type = heartbeat_response,
				       ie = #{recovery_time_stamp :=
						  #recovery_time_stamp{time = RecoveryTS}} = IEs}},
	     {connected, _}, #data{recovery_ts = RecoveryTS} = Data) ->
    ?LOG(debug, "PFCP OK Response: ~s", [pfcp_packet:pretty_print(IEs)]),
    {keep_state, Data, [next_heartbeat(Data)]};
handle_event(cast, {response, _, #pfcp{version = v1, type = heartbeat_response, ie = _IEs}},
	     {connected, _}, Data) ->
    ?LOG(warning, "PFCP Fail Response: ~s", [pfcp_packet:pretty_print(_IEs)]),
    {next_state, dead, handle_nodedown(Data)};

handle_event(cast, {response, from_cp_rule,
		    #pfcp{version = v1, type = session_establishment_response,
			  ie = #{pfcp_cause :=
				     #pfcp_cause{cause = 'Request accepted'}} = IEs}} = R,
	     {connected, init}, #data{pfcp_ctx = PCtx0, bearer = Bearer0} = Data0) ->
    ?LOG(debug, "Response: ~p", [R]),
    PCtx1 = ergw_pfcp_context:update_dp_seid(IEs, PCtx0),
    {Bearer, PCtx} = ergw_pfcp_context:update_bearer(IEs, Bearer0, PCtx1),
    ergw_pfcp_context:register_ctx_ids(?MODULE, Bearer, PCtx),
    Data = Data0#data{pfcp_ctx = PCtx, bearer = Bearer},
    {next_state, {connected, ready}, Data};

handle_event({call, From}, attach, _, #data{pfcp_ctx = PNodeCtx} = Data) ->
    PCtx = #pfcp_ctx{
	      name = PNodeCtx#pfcp_ctx.name,
	      node = PNodeCtx#pfcp_ctx.node,
	      features = PNodeCtx#pfcp_ctx.features,
	      seid = #seid{cp = ergw_sx_socket:seid()},

	      cp_bearer = PNodeCtx#pfcp_ctx.cp_bearer
	     },
    NodeCaps = node_caps(Data),
    Reply = {ok, {PCtx, NodeCaps}},
    {keep_state_and_data, [{reply, From, Reply}]};

%% send 'up' when we are ready, only wait if this is the first connect attempt
%% or if we are already connected and just waiting for some rules to get installed
handle_event(cast, {notify_up, NotifyUp}, {connected, ready}, _Data) ->
    send_notify_up(up, NotifyUp),
    keep_state_and_data;
handle_event(cast, {notify_up, NotifyUp}, {connected, _}, #data{notify_up = Up} = Data) ->
    {keep_state, Data#data{notify_up = Up ++ NotifyUp}};
handle_event(cast, {notify_up, NotifyUp}, connecting,
	     #data{retries = 0, notify_up = Up} = Data) ->
    {keep_state, Data#data{notify_up = Up ++ NotifyUp}};
handle_event(cast, {notify_up, NotifyUp}, _State, _Data) ->
    send_notify_up(dead, NotifyUp),
    keep_state_and_data;

handle_event(cast, {response, {call, _} = Evt,
		    #pfcp{
		       ie = #{pfcp_cause :=
				  #pfcp_cause{cause = 'No established Sx Association'}}} =
			Reply}, _, Data) ->
    Actions = pfcp_reply_actions(Evt, Reply),
    {next_state, dead, handle_nodedown(Data), Actions};

handle_event(cast, {response, {call, _} = Evt, Reply}, _, _Data) ->
    Actions = pfcp_reply_actions(Evt, Reply),
    {keep_state_and_data, Actions};

handle_event(cast, {response, heartbeat, timeout} = R, _, Data) ->
    ?LOG(warning, "PFCP Timeout: ~p", [R]),
    {next_state, dead, handle_nodedown(Data)};

handle_event(cast, {response, _, _} = R, _, _Data) ->
    ?LOG(debug, "Response: ~p", [R]),
    keep_state_and_data;

handle_event({call, _} = Evt, #pfcp{} = Request0, {connected, _},
	     #data{dp = #node{ip = IP}} = Data) ->
    Request = augment_mandatory_ie(Request0, Data),
    ?LOG(debug, "DP Call ~p", [Request]),
    ergw_sx_socket:call(IP, Request, response_cb(Evt)),
    keep_state_and_data;

handle_event({call, _}, Request, _, _Data)
  when is_record(Request, pfcp) ->
    {keep_state_and_data, postpone};

handle_event(cast, {handle_pdu, _Request, #gtp{type=g_pdu, ie = PDU}}, _, Data) ->
    try
	handle_ip_pdu(PDU, Data)
    catch
	throw:{error, Error}:ST ->
	    ?LOG(error, "handler for GTP-U failed with: ~p @ ~p", [Error, ST]);
	Class:Error:ST ->
	    ?LOG(error, "handler for GTP-U failed with: ~p:~p @ ~p", [Class, Error, ST])
    end,
    keep_state_and_data;

handle_event({call, From},
	     {sx, #pfcp{
		     type = session_report_request,
		     ie =
			 #{report_type := #report_type{usar = 1},
			   usage_report_srr :=
			       #usage_report_srr{
				  group =
				      #{urr_id := #urr_id{id = Id},
					usage_report_trigger :=
					    #usage_report_trigger{start = 1},
					ue_ip_address :=
					    #ue_ip_address{
					       type = src,
					       ipv4 = IP4,
					       ipv6 = IP6}
				       }
				 }
			  }
		    }
	     },
	     _State,
	     #data{pfcp_ctx = #pfcp_ctx{seid = #seid{dp = SEID}} = PCtx, tdf = Tdf}) ->
    {ok, {tdf, VRF}} = ergw_pfcp:find_urr_by_id(Id, PCtx),
    ?LOG(debug, "Sx Node TDF Report on ~p for UE IPv4 ~s IPv6 ~s",
         [VRF, bin2ntoa(IP4), bin2ntoa(IP6)]),

    Handler = maps:get(handler, Tdf, tdf),
    try
	Handler:unsolicited_report(self(), VRF, IP4, IP6, Tdf)
    catch
	Class:Error:ST ->
	    ?LOG(error, "Unsolicited Report Handler '~p' failed with ~p:~p~n~p",
			[Handler, Class, Error, ST])
    end,

    {keep_state_and_data, [{reply, From, {ok, SEID}}]};
handle_event({call, From}, {sx, Report}, _State,
	     #data{pfcp_ctx = #pfcp_ctx{seid = #seid{dp = SEID}}}) ->
    ?LOG(error, "Sx Node Session Report unexpected: ~p", [Report]),
    {keep_state_and_data, [{reply, From, {ok, SEID}}]}.

terminate(_Reason, _State, Data) ->
    send_notify_up(terminate, Data),
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

pfcp_reply_actions({call, {Pid, Tag}}, Reply)
  when Pid =:= self() ->
    [{next_event, internal, {Tag, Reply}}];
pfcp_reply_actions({call, From}, Reply) ->
    [{reply, From, Reply}].

make_request(IP, Port, Msg, #data{cp_socket = Socket, cp_info = Info}) ->
    ergw_gtp_socket:make_request(0, sx, IP, Port, Msg, Socket, Info).

%% IPv4, non fragmented, UDP packet
handle_ip_pdu(<<Version:4, IHL:4, _TOS:8, TotLen:16, _Id:16, _:2, 0:1, 0:13,
		_TTL:8, Proto:8, _HdrCSum:16,
		SrcIP:4/bytes, DstIP:4/bytes, _/binary>> = PDU, Data)
  when Version == 4, Proto == 17 ->
    HeaderLen = IHL * 4,
    UDPLen = TotLen - HeaderLen,
    <<_:HeaderLen/bytes, UDP:UDPLen/bytes, _/binary>> = PDU,
    ?LOG(debug, "IPv4 UDP: ~p", [UDP]),
    handle_udp_gtp(SrcIP, DstIP, UDP, Data);
%% IPv6, non fragmented, UDP packet
handle_ip_pdu(<<Version:4, _TC:8, _Label:20, PayloadLen:16, NextHeader:8, _TTL:8,
		SrcIP:16/bytes, DstIP:16/bytes, UDP:PayloadLen/bytes, _/binary>>, Data)
  when Version == 6, NextHeader == 17  ->
    ?LOG(debug, "IPv6 UDP: ~p", [UDP]),
    handle_udp_gtp(SrcIP, DstIP, UDP, Data);
handle_ip_pdu(PDU, _Data) ->
    ?LOG(debug, "unexpected GTP-U payload: ~p", [PDU]),
    ok.

handle_udp_gtp(SrcIP, DstIP, <<SrcPort:16, DstPort:16, _:16, _:16, PayLoad/binary>>,
	       #data{dp = #node{node = Node}} = Data)
  when DstPort =:= ?GTP1u_PORT ->
    Msg = gtp_packet:decode(PayLoad),
    ?LOG(debug, "GTP-U ~s:~w -> ~s:~w: ~p", [bin2ntoa(SrcIP), SrcPort, bin2ntoa(DstIP), DstPort, Msg]),
    ReqKey = make_request(SrcIP, SrcPort, Msg, Data),
    Socket = #socket{name = Node, type = 'gtp-u'},
    TEID = #fq_teid{ip = ergw_inet:bin2ip(DstIP), teid = Msg#gtp.tei},
    ergw_context:port_message(gtp_context:socket_teid_key(Socket, TEID), ReqKey, Msg, false),
    ok;
handle_udp_gtp(SrcIP, DstIP, <<SrcPort:16, DstPort:16, _:16, _:16, PayLoad/binary>>, _Data) ->
    ?LOG(debug, "unexpected UDP ~s:~w -> ~s:~w: ~p",
		[bin2ntoa(SrcIP), SrcPort, bin2ntoa(DstIP), DstPort, PayLoad]),
    ok.

%% request_connect/2
request_connect(Candidates, NodeSelect, Timeout) ->
    AbsTimeout = erlang:monotonic_time()
	+ erlang:convert_time_unit(Timeout, millisecond, native),
    Ref = make_ref(),
    Pid = proc_lib:spawn(?MODULE, ?FUNCTION_NAME, [Candidates, NodeSelect, AbsTimeout, Ref, self()]),
    {Pid, Ref, AbsTimeout}.

%% request_connect/5
request_connect(Candidates, NodeSelect, AbsTimeout, Ref, Owner) ->
    Available = ergw_sx_node_reg:available(),
    Expects = connect_nodes(Candidates, NodeSelect, Available, []),
    Result =
	fun ExpectFun([], _) ->
		ok;
	    ExpectFun(_More, Now) when Now >= AbsTimeout ->
		timeout;
	    ExpectFun([{_, Tag}|More], Now) ->
		Timeout = erlang:convert_time_unit(AbsTimeout - Now, native, millisecond),
		receive {Tag, _} -> ExpectFun(More, erlang:monotonic_time())
		after Timeout -> timeout
		end
	end(Expects, erlang:monotonic_time()),
    Owner ! {'$', Ref, Result}.

wait_connect({Pid, Ref, AbsTimeout}) ->
    Timeout = erlang:convert_time_unit(
		AbsTimeout - erlang:monotonic_time(), native, millisecond),
    receive
	{'$', Ref, Result} -> Result;
	{'EXIT', Pid, Reason} -> Reason
    after Timeout -> timeout
    end.

connect_nodes([], _NodeSelect, _Available, Expects) -> Expects;
connect_nodes([H|T], NodeSelect, Available, Expects) ->
    connect_nodes(T, NodeSelect, Available, connect_node(H, NodeSelect, Available, Expects)).

connect_node({Name, _, _, _, _}, _NodeSelect, Available, Expects)
  when is_map_key(Name, Available) ->
    Expects;
connect_node({Node, _, _, IP4, IP6}, NodeSelect, _Available, Expects) ->
    NotifyUp = {self(), make_ref()},
    ergw_sx_node_mngr:connect(Node, NodeSelect, IP4, IP6, [NotifyUp]),
    [NotifyUp | Expects].

notify_up(Server, [{Pid, Ref}|_] = NotifyUp) when is_pid(Pid), is_reference(Ref) ->
    gen_statem:cast(Server, {notify_up, NotifyUp});
notify_up(Server, {Pid, Ref} = NotifyUp) when is_pid(Pid), is_reference(Ref) ->
    gen_statem:cast(Server, {notify_up, [NotifyUp]}).

lb(first, [H|T]) -> {H, T};
lb(random, [H]) -> {H, []};
lb(random, L) when is_list(L) ->
    Index = rand:uniform(length(L)),
    Item = lists:nth(Index, L),
    {Item, lists:delete(Item, L)}.

response_cb(CbData) ->
    {?MODULE, response, [self(), CbData]}.

next_heartbeat(_Data) ->
    {state_timeout, 5000, heartbeat}.

put_ie(IE, IEs) when is_map(IEs) ->
    maps:put(element(1, IE), IE, IEs);
put_ie(IE, IEs) when is_list(IEs) ->
    [IE | IEs];
put_ie(IE, _IEs) ->
    [IE].

put_node_id(R = #pfcp{ie = IEs}, #data{cp = #node{node = Node}}) ->
    NodeId = #node_id{id = string:split(atom_to_binary(Node, utf8), ".", all)},
    R#pfcp{ie = put_ie(NodeId, IEs)}.

put_build_id(R = #pfcp{ie = IEs}) ->
    {ok, Version} = application:get_key(ergw, vsn),
    VStr = io_lib:format("erGW ~s on Erlang/OTP ~s [erts ~s]",
			 [Version, erlang:system_info(otp_release),
			  erlang:system_info(version)]),
    Id = #tp_build_identifier{id = iolist_to_binary(VStr)},
    R#pfcp{ie = put_ie(Id, IEs)}.

put_recovery_time_stamp(R = #pfcp{ie = IEs}) ->
    TS = #recovery_time_stamp{
	    time = ergw_gsn_lib:seconds_to_sntp_time(gtp_config:get_start_time())},
    R#pfcp{ie = put_ie(TS, IEs)}.

augment_mandatory_ie(R = #pfcp{type = Type}, _Data)
  when Type == heartbeat_request orelse
       Type == heartbeat_response ->
    put_recovery_time_stamp(R);
augment_mandatory_ie(R = #pfcp{type = Type}, Data)
  when Type == association_update_request orelse
       Type == association_update_response orelse
       Type == association_release_request orelse
       Type == association_release_response orelse
       Type == node_report_request orelse
       Type == node_report_response orelse
       Type == session_set_deletion_request orelse
       Type == session_set_deletion_response orelse
       Type == session_establishment_request orelse
       Type == session_establishment_response ->
    put_build_id(put_node_id(R, Data));
augment_mandatory_ie(R = #pfcp{type = Type}, Data)
  when Type == association_setup_request orelse
       Type == association_setup_response ->
    put_recovery_time_stamp(put_build_id(put_node_id(R, Data)));
augment_mandatory_ie(Request, _Data) ->
    Request.

make_response(Type, #pfcp_ctx{seid = #seid{dp = SEID}}, Request, IEs) ->
    make_response(Type, SEID, Request, IEs);
make_response(Type, SEID, #pfcp{version = v1, seq_no = SeqNo}, IEs) ->
    #pfcp{version = v1, type = Type, seid = SEID, seq_no = SeqNo, ie = IEs}.


send_heartbeat(#data{dp = #node{ip = IP}}) ->
    IEs = [#recovery_time_stamp{
	      time = ergw_gsn_lib:seconds_to_sntp_time(gtp_config:get_start_time())}],
    Req = #pfcp{version = v1, type = heartbeat_request, ie = IEs},
    ergw_sx_socket:call(IP, 500, 5, Req, response_cb(heartbeat)).

heartbeat_response(ReqKey, #pfcp{type = heartbeat_request} = Request) ->
    Response = put_recovery_time_stamp(
		 make_response(heartbeat_response, undefined, Request, [])),
    ergw_sx_socket:send_response(ReqKey, Response, true).

handle_nodeup(#{recovery_time_stamp := #recovery_time_stamp{time = RecoveryTS}} = IEs,
	      #data{pfcp_ctx = PNodeCtx,
		    dp = #node{node = Node, ip = IP},
		    vrfs = VRFs} = Data0) ->
    ?LOG(debug, "Node ~s (~s) is up", [Node, inet:ntoa(IP)]),
    ?LOG(debug, "Node IEs: ~s", [pfcp_packet:pretty_print(IEs)]),

    UPFeatures = maps:get(up_function_features, IEs, #up_function_features{_ = 0}),
    UPIPResInfo = maps:get(user_plane_ip_resource_information, IEs, []),
    Data = Data0#data{
	     pfcp_ctx = PNodeCtx#pfcp_ctx{features = UPFeatures},
	     recovery_ts = RecoveryTS,
	     features = UPFeatures,
	     vrfs = init_vrfs(VRFs, UPIPResInfo)
	    },
    install_cp_rules(Data).

init_node_cfg(#data{cfg = Cfg} = Data) ->
    Data#data{
      features = #up_function_features{_ = 0},
      ip_pools = maps:get(ip_pools, Cfg, []),
      vrfs = maps:map(
	       fun(Id, #{features := Features}) ->
		       #vrf{name = Id, features = Features}
	       end, maps:get(vrfs, Cfg, #{}))}.

init_vrfs(VRFs, UPIPResInfo)
  when is_list(UPIPResInfo) ->
    lists:foldl(fun(I, Acc) ->
			init_vrfs(Acc, I)
		end, VRFs, UPIPResInfo);
init_vrfs(VRFs,
	  #user_plane_ip_resource_information{
	     network_instance = NetworkInstance,
	     teid_range = Range, ipv4 = IP4, ipv6 = IP6}) ->
    Name = vrf:normalize_name(NetworkInstance),
    case VRFs of
	#{Name := VRF0} ->
	    VRF = VRF0#vrf{teid_range = Range, ipv4 = IP4, ipv6 = IP6},
	    VRFs#{Name => VRF};
	_ ->
	    ?LOG(warning, "UP Nodes reported unknown Network Instance '~p'", [Name]),
	    VRFs
    end.

mode(#{connect := true}) -> persistent;
mode(_) -> transient.

handle_nodedown(#data{pfcp_ctx = PCtx, bearer = Bearer} = Data) ->
    ergw_pfcp_context:unregister_ctx_ids(?MODULE, Bearer, PCtx),
    Self = self(),
    {monitored_by, Notify} = process_info(Self, monitored_by),
    ?LOG(debug, "Node Down Monitor Notify: ~p", [Notify]),
    lists:foreach(fun(Pid) -> Pid ! {'DOWN', undefined, pfcp, Self, undefined} end, Notify),
    init_node_cfg(Data).

%%%===================================================================
%%% CP to Access Interface forwarding
%%%===================================================================

update_m_rec(Record, Map) when is_tuple(Record) ->
    maps:update_with(element(1, Record), [Record | _], [Record], Map).

make_cp_bearer(TEI,  #gtp_socket_info{vrf = VRF, ip = IP}) ->
    FqTEID = #fq_teid{ip = IP, teid = TEI},
    #bearer{interface = 'CP-function', vrf = VRF, remote = FqTEID}.

assign_local_data_teid(Key, PCtx, #node{ip = NodeIP}, VRFs, Bearer) ->
    [VRF|_] =
	lists:filter(fun(#vrf{features = Features}) ->
			     lists:member('CP-Function', Features)
		     end, maps:values(VRFs)),
    ergw_gsn_lib:assign_local_data_teid(Key, PCtx, VRF, NodeIP, Bearer).

generate_pfcp_rules(_Key, #vrf{features = Features} = VRF, Bearer, Acc) ->
    lists:foldl(generate_per_feature_pfcp_rule(_, VRF, Bearer, _), Acc, Features).

generate_per_feature_pfcp_rule('Access', #vrf{name = Name} = VRF, Bearer, PCtx0) ->
    Key = {Name, 'Access'},
    {PdrId, PCtx1} = ergw_pfcp:get_id(pdr, Key, PCtx0),
    {FarId, PCtx2} = ergw_pfcp:get_id(far, Key, PCtx1),
    {BearerReq, PCtx} = ergw_pfcp_context:make_request_bearer(PdrId, Bearer, PCtx2),

    %% GTP-U encapsulated packet from CP
    PDI = #pdi{group = ergw_pfcp:traffic_endpoint(BearerReq, [])},
    PDR = [#pdr_id{id = PdrId},
	   #precedence{precedence = 100},
	   PDI,
	   ergw_pfcp:outer_header_removal(Bearer),
	   #far_id{id = FarId}],
    %% forward to Access intefaces
    FAR = [#far_id{id = FarId},
	   #apply_action{forw = 1},
	   #forwarding_parameters{
	      group =
		  [#destination_interface{interface = 'Access'},
		   ergw_pfcp:network_instance(VRF)]
	     }
	  ],

    ergw_pfcp_rules:add(
      [{pdr, PdrId, PDR},
       {far, FarId, FAR}], PCtx);
generate_per_feature_pfcp_rule('TDF-Source', #vrf{name = Name} = VRF, _Bearer, PCtx0) ->
    Key = {tdf, Name},
    {PdrId, PCtx1} = ergw_pfcp:get_id(pdr, Key, PCtx0),
    {FarId, PCtx2} = ergw_pfcp:get_id(far, Key, PCtx1),
    {UrrId, PCtx} = ergw_pfcp:get_urr_id(Key, [], Key, PCtx2),

    %% detect traffic from Access interface (TDF)
    PDI = #pdi{
	     group =
		 [#source_interface{interface = 'Access'},
		  ergw_pfcp:network_instance(VRF),
		  %% WildCard SDF
		  #sdf_filter{
		     flow_description =
			 <<"permit out ip from any to any">>}
		 ]},
    PDR = [#pdr_id{id = PdrId},
	   #precedence{precedence = 65000},
	   PDI,
	   #far_id{id = FarId},
	   #urr_id{id = UrrId}],
    %% default drop rule for TDF
    FAR = [#far_id{id = FarId},
	   #apply_action{drop = 1}],
    %% Start of Traffic report rule
    URR = [#urr_id{id = UrrId},
	   #measurement_method{event = 1},
	   #reporting_triggers{start_of_traffic = 1},
	   #time_quota{quota = 60}],

    ergw_pfcp_rules:add(
      [{pdr, PdrId, PDR},
       {far, FarId, FAR},
       {urr, UrrId, URR}], PCtx);
generate_per_feature_pfcp_rule(_, _VRF, _DpGtpIP, Acc) ->
    Acc.

install_cp_rules(#data{pfcp_ctx = PCtx0,
		       bearer = Bearer0,
		       cp = CntlNode,
		       dp = #node{ip = DpNodeIP} = DpNode,
		       vrfs = VRFs} = Data) ->
    {ok, Bearer} = assign_local_data_teid(dp, PCtx0, DpNode, VRFs, Bearer0),
    DpBearer = maps:get(dp, Bearer),

    PCtx1 = ergw_pfcp:init_ctx(PCtx0),
    PCtx = maps:fold(generate_pfcp_rules(_, _, DpBearer, _), PCtx1, VRFs),
    Rules = ergw_pfcp:update_pfcp_rules(PCtx1, PCtx, #{}),
    IEs = update_m_rec(ergw_pfcp:f_seid(PCtx, CntlNode), Rules),

    Req0 = #pfcp{version = v1, type = session_establishment_request, seid = 0, ie = IEs},
    Req = augment_mandatory_ie(Req0, Data),
    ergw_sx_socket:call(DpNodeIP, Req, response_cb(from_cp_rule)),

    Data#data{pfcp_ctx = PCtx, bearer = Bearer}.

send_notify_up(Notify, NotifyUp) when is_list(NotifyUp) ->
    [Pid ! {Tag, Notify} || {Pid, Tag} <- NotifyUp, is_pid(Pid), is_reference(Tag)];
send_notify_up(Notify, #data{notify_up = NotifyUp} = Data) ->
    send_notify_up(Notify, NotifyUp),
    Data#data{notify_up = []}.

node_caps(#data{ip_pools = Pools, vrfs = VRFs}) ->
    {VRFs, ordsets:from_list(Pools)}.

select_node_ip(IP4, _IP6) when length(IP4) /= 0 ->
    {IP, _} = lb(random, IP4),
    IP;
select_node_ip(_IP4, IP6) when length(IP6) /= 0 ->
    {IP, _} = lb(random, IP6),
    IP;
select_node_ip(_IP4, _IP6) ->
    undefined.

enter_loop(Node, IP, Data) ->
    gen_statem:enter_loop(
      ?MODULE, [], connecting, Data#data{dp = #node{node = Node, ip = IP}}).

resolve_and_enter_loop(Node, IP, Data)
  when is_tuple(IP) ->
    enter_loop(Node, IP, Data);
resolve_and_enter_loop(Node, _, #data{node_select = NodeSelect} = Data) ->
    case ergw_node_selection:lookup(Node, NodeSelect) of
	{_, IP4, IP6}
	  when length(IP4) /= 0; length(IP6) /= 0 ->
	    IP = select_node_ip(IP4, IP6),
	    enter_loop(Node, IP, Data);
	{_, [], []} ->
	    terminate(normal, init, Data);
	{error, _} ->
	    terminate(normal, init, Data),
	    ok
    end.

bin2ntoa(IP) when is_binary(IP) ->
    inet:ntoa(ergw_inet:bin2ip(IP));
bin2ntoa(IP) ->
    io_lib:format("~p", [IP]).
