-module(ergw_test_sx_up).

-behaviour(gen_server).

%% API
-export([start/2, stop/1, restart/1,
	 send/2, usage_report/4,
	 reset/1, history/1, history/2,
	 accounting/2,
	 enable/1, disable/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").

-define(SERVER, ?MODULE).

-record(state, {sx, gtp, accounting, enabled,
		record,
		cp_ip, cp_seid,
		up_ip, up_seid,
		cp_recovery_ts,
		dp_recovery_ts,
		seq_no, history}).

%%%===================================================================
%%% API
%%%===================================================================

start(Role, IP) ->
    gen_server:start({local, server_name(Role)}, ?MODULE, [IP], []).

stop(Role) ->
    gen_server:call(server_name(Role), stop).

restart(Role) ->
    gen_server:call(server_name(Role), restart).

send(Role, Msg) ->
    gen_server:call(server_name(Role), {send, Msg}).

usage_report(Role, PCtx, MatchSpec, Report) ->
    gen_server:call(server_name(Role), {usage_report, PCtx, MatchSpec, Report}).

reset(Role) ->
    gen_server:call(server_name(Role), reset).

history(Role) ->
    gen_server:call(server_name(Role), history).

history(Role, Record) ->
    gen_server:call(server_name(Role), {history, Record}).

accounting(Role, Acct) ->
    gen_server:call(server_name(Role), {accounting, Acct}).

enable(Role) ->
    gen_server:call(server_name(Role), {enabled, true}).

disable(Role) ->
    gen_server:call(server_name(Role), {enabled, false}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([IP]) ->
    process_flag(trap_exit, true),

    SockOpts = [binary, {ip, IP}, {active, true}, {reuseaddr, true}],
    {ok, GtpSocket} = gen_udp:open(?GTP1u_PORT, SockOpts),
    {ok, SxSocket} = gen_udp:open(8805, SockOpts),
    State = #state{
	       sx = SxSocket,
	       gtp = GtpSocket,
	       accounting = on,
	       enabled = true,
	       record = true,
	       cp_seid = 0,
	       up_ip = ergw_inet:ip2bin(IP),
	       up_seid = ergw_sx_socket:seid(),
	       cp_recovery_ts = undefined,
	       dp_recovery_ts = erlang:system_time(seconds),
	       seq_no = erlang:unique_integer([positive]) band 16#ffffff,
	       history = []
	      },
    {ok, State}.

handle_call(reset, _From, State0) ->
    State = State0#state{
	      accounting = on,
	      enabled = true,
	      cp_ip = undefined,
	      cp_seid = 0,
	      up_seid = ergw_sx_socket:seid(),
	      history = []
	     },
    {reply, ok, State};

handle_call({enabled, Bool}, _From, State) ->
    {reply, ok, State#state{enabled = Bool}};

handle_call(restart, _From, State0) ->
    State = State0#state{
	      accounting = on,
	      enabled = true,
	      cp_ip = undefined,
	      cp_seid = 0,
	      up_seid = ergw_sx_socket:seid(),
	      cp_recovery_ts = undefined,
	      dp_recovery_ts = erlang:system_time(seconds),
	      seq_no = erlang:unique_integer([positive]) band 16#ffffff,
	      history = []
	     },
    {reply, ok, State};

handle_call(history, _From, #state{history = Hist} = State) ->
    {reply, lists:reverse(Hist), State};
handle_call({history, Record}, _From, State) ->
    {reply, ok, State#state{record = Record, history = []}};

handle_call({accounting, Acct}, _From, State) ->
    {reply, ok, State#state{accounting = Acct}};

handle_call({send, #pfcp{} = Msg}, _From, #state{cp_seid = SEID} = State0) ->
    State = do_send(SEID, Msg, State0),
    {reply, ok, State};

handle_call({send, Msg}, _From,
	    #state{gtp = GtpSocket, cp_ip = IP} = State)
  when is_binary(Msg) ->
    [[SxTEI, _SxPid]] = ets:match(gtp_context_reg, {{'cp-socket',{teid,'gtp-u','$1'}},'$2'}),
    BinMsg = gtp_packet:encode(#gtp{version = v1, type = g_pdu, tei = SxTEI, ie = Msg}),
    ok = gen_udp:send(GtpSocket, IP, ?GTP1u_PORT, BinMsg),
    {reply, ok, State};

handle_call({usage_report, #pfcp_ctx{seid = #seid{cp = SEID}, urr_by_id = Rules} = PCtx,
	     MatchSpec, Report}, _From, State0) ->
    Ids = ets:match_spec_run(maps:to_list(Rules), ets:match_spec_compile(MatchSpec)),
    URRs = [#usage_report_srr{group = [#urr_id{id = Id}|Report]} || Id <- Ids],
    IEs = [#report_type{usar = 1}|URRs],
    SRreq = #pfcp{version = v1, type = session_report_request, ie = IEs},
    State = do_send(SEID, SRreq, State0),
    {reply, ok, State};


handle_call(stop, _From, State) ->
    {stop, normal, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({udp, _, _, _, _}, #state{enabled = false} = State) ->
    {noreply, State};

handle_info({udp, SxSocket, IP, InPortNo, Packet},
	    #state{sx = SxSocket} = State0) ->
    try
	Msg = pfcp_packet:decode(Packet),
	?match(ok, (catch pfcp_packet:validate('Sxb', Msg))),
	{Reply, State} = handle_message(Msg, record(Msg, State0)),
	case Reply of
	    #pfcp{} ->
		BinReply = pfcp_packet:encode(Reply#pfcp{seq_no = Msg#pfcp.seq_no}),
		ok = gen_udp:send(SxSocket, IP, InPortNo, BinReply);
	    _ ->
		ok
	end,
	{noreply, State}
    catch
	Class:Error ->
	    ct:fail("Sx Socket Error: ~p:~p~n~p", [Class, Error, erlang:get_stacktrace()]),
	    {stop, error, State0}
    end;
handle_info({udp, GtpSocket, IP, InPortNo, Packet} = Msg,
	    #state{gtp = GtpSocket} = State) ->
    {noreply, record(Msg, State)}.

terminate(_Reason, #state{sx = SxSocket}) ->
    catch gen_udp:close(SxSocket),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

server_name(Role) ->
    binary_to_atom(
      << (atom_to_binary(?SERVER, latin1))/binary, $_, (atom_to_binary(Role, latin1))/binary>>,
      latin1).

make_sx_response(heartbeat_request)             -> heartbeat_response;
make_sx_response(pfd_management_request)        -> pfd_management_response;
make_sx_response(association_setup_request)     -> association_setup_response;
make_sx_response(association_update_request)    -> association_update_response;
make_sx_response(association_release_request)   -> association_release_response;
make_sx_response(node_report_request)           -> node_report_response;
make_sx_response(session_set_deletion_request)  -> session_set_deletion_response;
make_sx_response(session_establishment_request) -> session_establishment_response;
make_sx_response(session_modification_request)  -> session_modification_response;
make_sx_response(session_deletion_request)      -> session_deletion_response;
make_sx_response(session_report_request)        -> session_report_response.

f_seid(SEID, IP) when size(IP) == 4 ->
    #f_seid{seid = SEID, ipv4 = IP};
f_seid(SEID, IP) when size(IP) == 16 ->
    #f_seid{seid = SEID, ipv6 = IP}.

choose_control_ip(IP4, _IP6, #state{up_ip = IP})
  when size(IP) == 4, is_binary(IP4) ->
    IP4;
choose_control_ip(_IP4, IP6, #state{up_ip = IP})
  when size(IP) == 16, is_binary(IP6) ->
    IP6.

user_plane_ip_resource_information(VRF, #state{up_ip = IP})
  when size(IP) == 4 ->
    #user_plane_ip_resource_information{
       network_instance = vrf:normalize_name(VRF),
       ipv4 = ergw_inet:ip2bin(?LOCALHOST_IPv4)
      };
user_plane_ip_resource_information(VRF, #state{up_ip = IP})
  when size(IP) == 16 ->
    #user_plane_ip_resource_information{
       network_instance = vrf:normalize_name(VRF),
       ipv6 = ergw_inet:ip2bin(?LOCALHOST_IPv6)
      }.

sx_reply(Type, State) ->
    sx_reply(Type, undefined, [], State).
sx_reply(Type, IEs, State) ->
    sx_reply(Type, undefined, IEs, State).
sx_reply(Type, SEID, IEs, State) ->
    {#pfcp{version = v1, type = Type, seid = SEID, ie = IEs}, State}.

do_send(SEID, #pfcp{} = Msg, #state{sx = SxSocket, cp_ip = IP, seq_no = SeqNo} = State) ->
    BinMsg = pfcp_packet:encode(Msg#pfcp{seid = SEID, seq_no = SeqNo}),
    ok = gen_udp:send(SxSocket, IP, 8805, BinMsg),
    State#state{seq_no = (SeqNo + 1) band 16#ffffff}.

handle_message(#pfcp{type = heartbeat_request,
		     ie = #{recovery_time_stamp :=
				#recovery_time_stamp{time = InCpRecoveryTS}}},
	       #state{dp_recovery_ts = RecoveryTS,
		      cp_recovery_ts = CpRecoveryTS} = State0) ->
    IEs = [#recovery_time_stamp{
	      time = ergw_sx_node:seconds_to_sntp_time(RecoveryTS)}],
    State =
	if InCpRecoveryTS =/= CpRecoveryTS ->
		State0#state{cp_recovery_ts = undefined};
	   true ->
		State0
	end,
    sx_reply(heartbeat_response, undefined, IEs, State);

handle_message(#pfcp{type = association_setup_request,
		     ie = #{recovery_time_stamp :=
				#recovery_time_stamp{time = CpRecoveryTS}}},
	       #state{dp_recovery_ts = RecoveryTS} = State0) ->
    RespIEs =
	[#node_id{id = [<<"test">>, <<"server">>]},
	 #pfcp_cause{cause = 'Request accepted'},
	 #recovery_time_stamp{
	    time = ergw_sx_node:seconds_to_sntp_time(RecoveryTS)},
	 user_plane_ip_resource_information([<<"cp">>], State0),
	 user_plane_ip_resource_information([<<"irx">>], State0),
	 user_plane_ip_resource_information([<<"proxy-irx">>], State0),
	 user_plane_ip_resource_information([<<"remote-irx">>], State0)
	],
    State = State0#state{cp_recovery_ts = CpRecoveryTS},
    sx_reply(association_setup_response, RespIEs, State);

handle_message(#pfcp{type = Type}, #state{cp_recovery_ts = undefined} = State)
when Type =:= pfd_management_request;
     Type =:= association_update_request;
     Type =:= association_release_request;
     Type =:= node_report_request;
     Type =:= session_set_deletion_request;
     Type =:= session_establishment_request;
     Type =:= session_modification_request;
     Type =:= session_deletion_request;
     Type =:= session_report_request ->
    RespIEs =
	[#node_id{id = [<<"test">>, <<"server">>]},
	 #pfcp_cause{cause = 'No established Sx Association'}],
     sx_reply(pfcp_response(Type), RespIEs, State);

handle_message(#pfcp{type = session_establishment_request, seid = 0,
		     ie = #{f_seid := #f_seid{seid = ControlPlaneSEID,
					      ipv4 = ControlPlaneIP4,
					      ipv6 = ControlPlaneIP6}}},
	       #state{up_ip = IP, up_seid = UserPlaneSEID} = State0) ->
    ControlPlaneIP = choose_control_ip(ControlPlaneIP4, ControlPlaneIP6, State0),
    RespIEs =
	[#pfcp_cause{cause = 'Request accepted'},
	 f_seid(UserPlaneSEID, IP)],
    State = State0#state{cp_ip = ergw_inet:bin2ip(ControlPlaneIP),
			 cp_seid = ControlPlaneSEID},
    sx_reply(session_establishment_response, ControlPlaneSEID, RespIEs, State);

handle_message(#pfcp{type = session_modification_request, seid = UserPlaneSEID, ie = ReqIEs},
	      #state{accounting = Acct,
		     cp_seid = ControlPlaneSEID,
		     up_seid = UserPlaneSEID} = State) ->
    RespIEs =
	case {Acct, maps:get(query_urr, ReqIEs, [])} of
	    {on, Query} ->
		Response =
		    fun Answer(#query_urr{group = #{urr_id := #urr_id{id = Id}}}) ->
			    #usage_report_smr{
			       group =
				   [#urr_id{id = Id},
				    #usage_report_trigger{immer = 1},
				    #volume_measurement{
				       total = 6,
				       uplink = 4,
				       downlink = 2
				      },
				    #tp_packet_measurement{
				       total = 4,
				       uplink = 3,
				       downlink = 1
				      }
				   ]
			      };
			Answer([])  -> [];
			Answer([H|T]) -> [Answer(H) | Answer(T)]
		    end(Query),
		lists:flatten([#pfcp_cause{cause = 'Request accepted'}, Response]);
	    _ ->
		[#pfcp_cause{cause = 'Request accepted'}]
	end,
    sx_reply(session_modification_response, ControlPlaneSEID, RespIEs, State);

handle_message(#pfcp{type = session_deletion_request, seid = UserPlaneSEID},
	       #state{cp_seid = ControlPlaneSEID,
		      up_seid = UserPlaneSEID} = State) ->
    RespIEs = [#pfcp_cause{cause = 'Request accepted'}],
    sx_reply(session_deletion_response, ControlPlaneSEID, RespIEs, State);

handle_message(#pfcp{type = ReqType, seid = SendingUserPlaneSEID},
	      #state{cp_seid = ControlPlaneSEID,
		     up_seid = OurUserPlaneSEID} = State)
  when
      ReqType == session_set_deletion_request orelse
      ReqType == session_establishment_request orelse
      ReqType == session_modification_request orelse
      ReqType == session_deletion_request ->
    {SEID, RespIEs} =
	if SendingUserPlaneSEID /= OurUserPlaneSEID ->
		{0, [#pfcp_cause{cause = 'Session context not found'}]};
	   true ->
		{ControlPlaneSEID, [#pfcp_cause{cause = 'System failure'}]}
	end,
    sx_reply(make_sx_response(ReqType), SEID, RespIEs, State);

handle_message(#pfcp{type = ReqType}, State)
  when
      ReqType == heartbeat_response orelse
      ReqType == pfd_management_response orelse
      ReqType == association_setup_response orelse
      ReqType == association_update_response orelse
      ReqType == association_release_response orelse
      ReqType == version_not_supported_response orelse
      ReqType == node_report_response orelse
      ReqType == session_set_deletion_response orelse
      ReqType == session_establishment_response orelse
      ReqType == session_modification_response orelse
      ReqType == session_deletion_response orelse
      ReqType == session_report_response ->
    {noreply, State}.


pfcp_response(heartbeat_request) -> heartbeat_response;
pfcp_response(pfd_management_request) -> pfd_management_response;
pfcp_response(association_setup_request) -> association_setup_response;
pfcp_response(association_update_request) -> association_update_response;
pfcp_response(association_release_request) -> association_release_response;
pfcp_response(node_report_request) -> node_report_response;
pfcp_response(session_set_deletion_request) -> session_set_deletion_response;
pfcp_response(session_establishment_request) -> session_establishment_response;
pfcp_response(session_modification_request) -> session_modification_response;
pfcp_response(session_deletion_request) -> session_deletion_response;
pfcp_response(session_report_request) -> session_report_response.

record(Msg, #state{record = true, history = Hist} = State) ->
    State#state{history = [Msg|Hist]};
record(_Msg, State) ->
    State.
