-module(ergw_test_sx_up).

-behaviour(gen_server).
-compile({parse_transform, cut}).
-compile({parse_transform, exprecs}).

%% API
-export([start/2, stop/1, restart/1,
	 send/2, send/3, usage_report/4,
	 up_inactivity_timer_expiry/2,
	 reset/1, history/1, history/2,
	 accounting/2,
	 enable/1, disable/1,
	 feature/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, format_status/2, code_change/3]).

-include("include/ergw.hrl").
-include("ergw_test_lib.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").

-define(SERVER, ?MODULE).

-record(state, {sx, gtp, accounting, enabled,
		record, features,
		cp_ip, cp_seid,
		up_ip, up_seid,
		cp_recovery_ts,
		dp_recovery_ts,
		seq_no, urrs, teids,
		history}).

-export_records([up_function_features]).

%%%===================================================================
%%% API
%%%===================================================================

start(Role, IP) when is_tuple(IP) ->
    gen_server:start({local, server_name(Role)}, ?MODULE, [IP], []);
start(_, undefined) ->
    {ok, ignored}.

stop(Role) ->
    try
	gen_server:call(server_name(Role), stop)
    catch
	exit:{noproc,_} ->
	    ok
    end.

restart(Role) ->
    gen_server:call(server_name(Role), restart).

send(Role, Msg) ->
    gen_server:call(server_name(Role), {send, Msg}).

send(Role, SEID, Msg) ->
    gen_server:call(server_name(Role), {send, SEID, Msg}).

usage_report(Role, PCtx, MatchSpec, Report) ->
    gen_server:call(server_name(Role), {usage_report, PCtx, MatchSpec, Report}).

up_inactivity_timer_expiry(Role, PCtx) ->
    gen_server:call(server_name(Role), {up_inactivity_timer_expiry, PCtx}).

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

feature(Role, Feature, V) ->
    gen_server:call(server_name(Role), {feature, Feature, V}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([IP]) ->
    process_flag(trap_exit, true),

    SockOpts = [binary, {ip, IP}, {active, true}, {reuseaddr, true}, {buffer, 65536}],
    {ok, GtpSocket} = gen_udp:open(?GTP1u_PORT, SockOpts),
    {ok, SxSocket} = gen_udp:open(8805, SockOpts),
    State = #state{
	       sx = SxSocket,
	       gtp = GtpSocket,
	       accounting = on,
	       enabled = true,
	       record = true,
	       features = #up_function_features{ftup = 1, treu = 1, empu = 1,
						ueip = 1, mnop = 1, ip6pl = 1},
	       cp_seid = 0,
	       up_ip = ergw_inet:ip2bin(IP),
	       up_seid = ergw_sx_socket:seid(),
	       cp_recovery_ts = undefined,
	       dp_recovery_ts = erlang:system_time(seconds),
	       seq_no = erlang:unique_integer([positive]) band 16#ffffff,
	       urrs = #{},
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
	      urrs = #{},
	      history = []
	     },
    {reply, ok, State};

handle_call({enabled, Bool}, _From, State) ->
    {reply, ok, State#state{enabled = Bool}};

handle_call({feature, Feature, V}, _From, #state{features = UpFF0} = State) ->
    UpFF = '#set-'([{Feature, V}], UpFF0),
    OldV = '#get-'(Feature, UpFF0),
    {reply, {ok, OldV}, State#state{features = UpFF}};

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
	      urrs = #{},
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

handle_call({send, SEID, #pfcp{} = Msg}, _From, State0) ->
    State = do_send(SEID, Msg, State0),
    {reply, ok, State};

handle_call({send, Msg}, _From,
	    #state{gtp = GtpSocket, cp_ip = IP, up_ip = UpIP} = State)
  when is_binary(Msg) ->
    {ok, SxPid} = ergw_sx_node_reg:lookup(ergw_inet:bin2ip(UpIP)),
    TEIDMatch = #socket_teid_key{name = 'cp-socket', type = 'gtp-u', teid = '$1', _ = '_'},
    [[SxTEI]] = ets:match(gtp_context_reg, {TEIDMatch, {'_',SxPid}}),
    BinMsg = gtp_packet:encode(#gtp{version = v1, type = g_pdu, tei = SxTEI, ie = Msg}),
    ok = gen_udp:send(GtpSocket, IP, ?GTP1u_PORT, BinMsg),
    {reply, ok, State};

handle_call({usage_report, #pfcp_ctx{seid = #seid{cp = SEID}, urr_by_id = Rules},
	     MatchSpec, Report}, _From, State0) ->
    Ids = ets:match_spec_run(maps:to_list(Rules), ets:match_spec_compile(MatchSpec)),
    URRs =
	if is_function(Report, 2) ->
		lists:foldl(Report, [], Ids);
	   true ->
		[#usage_report_srr{group = [#urr_id{id = Id}|Report]} || Id <- Ids]
	end,
    IEs = [#report_type{usar = 1}|URRs],
    SRreq = #pfcp{version = v1, type = session_report_request, ie = IEs},
    State = do_send(SEID, SRreq, State0),
    {reply, ok, State};

%% only one mandatory 'Report Type' IE is present in this scenario
handle_call({up_inactivity_timer_expiry,
	     #pfcp_ctx{seid = #seid{cp = SEID},
		       up_inactivity_timer = _UP_Inactivity_Timer}},
	    _From, State0) ->
    %% Ignore the up inactivity timer, fire an 'upir' session report request
    IE = [#report_type{upir = 1}],
    SRreq = #pfcp{version = v1, type = session_report_request, ie = IE},
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
	Class:Error:ST ->
	    ct:pal("Sx Socket Error: ~p:~p~n~p", [Class, Error, ST]),
	    ct:fail("Sx Socket Error"),
	    {stop, error, State0}
    end;
handle_info({udp, GtpSocket, _, _, _} = Msg,
	    #state{gtp = GtpSocket} = State) ->
    {noreply, record(Msg, State)}.

terminate(_Reason, #state{sx = SxSocket}) ->
    catch gen_udp:close(SxSocket),
    ok.

format_status(terminate, [_PDict, #state{history = H} = State]) ->
    [{data, [{"State", State#state{history = length(H)}}]}];
format_status(_Opts, [_PDict, State]) ->
    [{data, [{"State", State}]}].

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
	      time = ergw_gsn_lib:seconds_to_sntp_time(RecoveryTS)}],
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
	       #state{features = UpFF, dp_recovery_ts = RecoveryTS} = State0) ->
    UpIPRes =
	case UpFF of
	    #up_function_features{ftup = 1} ->
		[];
	    _ ->
		[user_plane_ip_resource_information([<<"cp">>], State0),
		 user_plane_ip_resource_information([<<"irx">>], State0),
		 user_plane_ip_resource_information([<<"proxy-irx">>], State0),
		 user_plane_ip_resource_information([<<"remote-irx">>], State0),
		 user_plane_ip_resource_information([<<"remote-irx2">>], State0)]
	end,

    RespIEs =
	[#node_id{id = [<<"test">>, <<"server">>]},
	 #pfcp_cause{cause = 'Request accepted'},
	 #recovery_time_stamp{
	    time = ergw_gsn_lib:seconds_to_sntp_time(RecoveryTS)},
	 UpFF
	 | UpIPRes ],
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
					      ipv6 = ControlPlaneIP6}} = ReqIEs},
	       #state{up_ip = IP, up_seid = UserPlaneSEID} = State0) ->
    ControlPlaneIP = choose_control_ip(ControlPlaneIP4, ControlPlaneIP6, State0),
    RespIEs0 =
	[#pfcp_cause{cause = 'Request accepted'},
	 f_seid(UserPlaneSEID, IP)],
    {RespIEs, State1} = process_request(ReqIEs, RespIEs0, State0),
    State = State1#state{cp_ip = ergw_inet:bin2ip(ControlPlaneIP),
			 cp_seid = ControlPlaneSEID},
    sx_reply(session_establishment_response, ControlPlaneSEID, RespIEs, State);

handle_message(#pfcp{type = session_modification_request, seid = UserPlaneSEID, ie = ReqIEs},
	      #state{cp_seid = ControlPlaneSEID,
		     up_seid = UserPlaneSEID} = State0) ->
    RespIEs0 = [#pfcp_cause{cause = 'Request accepted'}],
    {RespIEs, State} = process_request(ReqIEs, RespIEs0, State0),
    sx_reply(session_modification_response, ControlPlaneSEID, RespIEs, State);

handle_message(#pfcp{type = session_deletion_request, seid = UserPlaneSEID},
	       #state{cp_seid = ControlPlaneSEID,
		      up_seid = UserPlaneSEID} = State0) ->
    RespIEs0 = [#pfcp_cause{cause = 'Request accepted'}],
    RespIEs = report_urrs(State0, RespIEs0),
    State = State0#state{urrs = #{}},
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

process_ies(Fun, Acc, IE) when is_tuple(IE) ->
    Fun(IE, Acc);
process_ies(_Fun, Acc, []) ->
    Acc;
process_ies(Fun, Acc, [H|T]) ->
    process_ies(Fun, Fun(H, Acc), T).

choose_up_ip(choose, _, #state{up_ip = IP})
  when size(IP) ==  4 ->
    {ergw_inet:ip2bin(?LOCALHOST_IPv4), undefined};
choose_up_ip(_, choose, #state{up_ip = IP})
  when size(IP) == 16 ->
    {undefined, ergw_inet:ip2bin(?LOCALHOST_IPv6)}.

process_f_teid(_, #f_teid{teid = choose},
	       _, {RespIEs0, #state{features = #up_function_features{ftup = FTUP}}} = State)
  when FTUP =/= 1 ->
    %% choose when FTUP is not set is not allowed
    Cause = #pfcp_cause{cause = 'Invalid F-TEID allocation option'},
    RespIEs = lists:keystore(pfcp_cause, 1, RespIEs0, Cause),
    {RespIEs, State};

process_f_teid(Id, #f_teid{teid = choose, choose_id = ChId},
	       _, {RespIEs, #state{teids = TEIDs} = State})
  when is_map_key(ChId, TEIDs) ->
    {TEID, IP4, IP6} = maps:get(ChId, TEIDs),
    FqTEID = #f_teid{teid = TEID, ipv4 = IP4, ipv6 = IP6},
    Create = #created_pdr{group = [Id, FqTEID]},
    {[Create | RespIEs], State};

process_f_teid(Id, #f_teid{teid = choose, choose_id = ChId, ipv4 = IPv4, ipv6 = IPv6},
	       _, {RespIEs, #state{teids = TEIDs} = State}) ->
    {IP4, IP6} = choose_up_ip(IPv4, IPv6, State),
    TEID = rand:uniform(16#fffffffe),
    FqTEID = #f_teid{teid = TEID, ipv4 = IP4, ipv6 = IP6},
    Create = #created_pdr{group = [Id, FqTEID]},
    {[Create | RespIEs], State#state{teids = maps:put(ChId, {TEID, IP4, IP6}, TEIDs)}};

process_f_teid(_, _, _, Acc) ->
    Acc.

%% process_request_ie/3
process_request_ie(#create_pdr{group = #{pdr_id := Id, pdi := #pdi{group = PDI}}}, RESTI, Acc) ->
    process_f_teid(Id, maps:get(f_teid, PDI, undefined), RESTI, Acc);

process_request_ie(#query_urr{group = #{urr_id := #urr_id{id = Id}}},
		   _, {RespIEs, #state{accounting = on} = State}) ->
    Report =
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
	  },
    {[Report | RespIEs], State};

process_request_ie(#remove_urr{group = #{urr_id := #urr_id{id = Id}}},
		   _, {RespIEs, #state{accounting = on} = State}) ->
    Report =
	#usage_report_smr{
	   group =
	       [#urr_id{id = Id},
		#usage_report_trigger{termr = 1},
		#volume_measurement{
		   total = 5,
		   uplink = 2,
		   downlink = 3
		  },
		#tp_packet_measurement{
		   total = 12,
		   uplink = 5,
		   downlink = 7
		  }
	       ]
	  },
    {[Report | RespIEs], State};

process_request_ie(#remove_urr{group = #{urr_id := #urr_id{id = Id}}},
		   _, {RespIEs, #state{urrs = URRs} = State}) ->
    {RespIEs, State#state{urrs = maps:remove(Id, URRs)}};

process_request_ie(#create_urr{group = #{urr_id := #urr_id{id = Id}}},
		   _, {RespIEs, #state{urrs = URRs} = State}) ->
    {RespIEs, State#state{urrs = maps:put(Id, on, URRs)}};

process_request_ie(_IE, _, Acc) ->
    Acc.

%% process_request_ies/3
process_request_ies(IEs, RESTI, Acc) ->
    process_ies(process_request_ie(_, RESTI, _), Acc, IEs).

%% process_request/3
process_request(ReqIEs, RespIEs, State0) ->
    %% ct:pal("Process Req: ~p", [ReqIEs]),
    State = State0#state{teids = #{}},
    #pfcpsereq_flags{resti = RESTI} =
	maps:get(pfcpsereq_flags, ReqIEs, #pfcpsereq_flags{resti = 0}),
    maps:fold(fun(_K,V,Acc) -> process_request_ies(V, RESTI, Acc) end,
	      {RespIEs, State}, ReqIEs).

report_urrs(#state{accounting = on, urrs = URRs}, RespIEs) ->
    maps:fold(
      fun(Id, _, IEs) ->
	      [#usage_report_sdr{
		  group =
		      [#urr_id{id = Id},
		       #usage_report_trigger{termr = 1},
		       #volume_measurement{
			  total = 5,
			  uplink = 2,
			  downlink = 3
			 },
		       #tp_packet_measurement{
			  total = 12,
			  uplink = 5,
			  downlink = 7
			 }
		      ]
		 } | IEs]
      end, RespIEs, URRs);
report_urrs(_, RespIEs) ->
    RespIEs.
