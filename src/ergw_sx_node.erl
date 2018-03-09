%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sx_node).

-behavior(gen_statem).

-compile({parse_transform, cut}).

%% API
-export([select_sx_node/2, select_sx_node/3]).
-export([start_link/3, send/4, call/2, get_network_instances/1,
	 handle_request/2, response/3]).

%% gen_server callbacks
-export([init/1, callback_mode/0, handle_event/4,
	 terminate/2, code_change/3]).

-include_lib("kernel/include/inet.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

-record(data, {timeout, cp, dp, network_instances, call_q}).

%%====================================================================
%% API
%%====================================================================

select_sx_node(Candidates, Context) ->
    case connect_sx_node(Candidates) of
	{ok, Pid} ->
	    {ok, Port} = gen_statem:call(Pid, get_port),
	    Context#context{dp_node = Pid, data_port = Port};
	_ ->
	    throw(?CTX_ERR(?FATAL, system_failure, Context))
    end.

select_sx_node(APN, Services, NodeSelect) ->
    case ergw_node_selection:candidates(APN, Services, NodeSelect) of
	Nodes when is_list(Nodes), length(Nodes) /= 0 ->
	    connect_sx_node(Nodes);
	Other ->
	    lager:error("No Sx node for APN '~w', got ~p", [APN, Other]),
	    {error, not_found}
    end.

start_link(Node, IP4, IP6) ->
    gen_statem:start_link(?MODULE, [Node, IP4, IP6], []).

send(GtpPort, IP, Port, Data) ->
    cast(GtpPort, {send, IP, Port, Data}).

call(#context{dp_node = Pid}, Request)
  when is_pid(Pid) ->
    lager:debug("DP Server Call ~p: ~p", [Pid, lager:pr(Request, ?MODULE)]),
    gen_statem:call(Pid, Request).

get_network_instances(Context) ->
    call(Context, get_network_instances).

response(Pid, Type, Response) ->
    gen_statem:cast(Pid, {Type, Response}).

handle_request(ReqKey, #pfcp{type = session_report_request, seq_no = SeqNo} = Report) ->
    case gtp_context:session_report(ReqKey, Report) of
	ok ->
	    ok;
	{error, not_found} ->
	    session_not_found(ReqKey, session_report_response, SeqNo)
    end.

%%%===================================================================
%%% call/cast wrapper for gtp_port
%%%===================================================================

%% TODO: GTP data path handler is currently not working!!
cast(#gtp_port{pid = Handler}, Request)
  when is_pid(Handler) ->
    gen_statem:cast(Handler, Request);
cast(GtpPort, Request) ->
    lager:warning("GTP DP Port ~p, CAST Request ~p not implemented yet",
		  [lager:pr(GtpPort, ?MODULE), lager:pr(Request, ?MODULE)]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%% callback_mode() -> [handle_event_function, state_enter].
callback_mode() -> handle_event_function.

init([Node, IP4, _IP6]) ->
    {ok, CP} = ergw_sx_socket:id(),
    Data = #data{timeout = 10,
		 cp = CP,
		 dp = #node{node = Node, ip = hd(IP4)},
		 network_instances = #{},
		 call_q = queue:new()
		},
    {ok, disconnected, Data, [{next_event, internal, setup}]}.

handle_event(_, setup, disconnected, #data{cp = CP, dp = #node{ip = IP}}) ->
    IEs = [node_id(CP),
	   #recovery_time_stamp{
	      time = seconds_to_sntp_time(gtp_config:get_start_time())}],
    Req = #pfcp{version = v1, type = association_setup_request, ie = IEs},
    ergw_sx_socket:call(IP, 500, 5, Req, response_cb(association_setup_request)),
    keep_state_and_data;

handle_event(cast, {association_setup_request, timeout}, disconnected, _Data) ->
    {keep_state_and_data, [{state_timeout, 5000, setup}]};

handle_event(cast, {_, #pfcp{version = v1, type = association_setup_response, ie = IEs}},
	     disconnected, #data{call_q = Q} = Data0) ->
    case IEs of
	#{pfcp_cause := #pfcp_cause{cause = 'Request accepted'}} ->
	    Data = handle_nodeup(IEs, Data0),
	    Actions = [{next_event, {call, From}, Request} ||
			  {_, From, Request} <- queue:to_list(Q)],
	    {next_state, connected, Data#data{call_q = queue:new()},
	     [next_heartbeat(Data) | Actions]};
	Other ->
	    lager:warning("Other: ~p", [lager:pr(Other, ?MODULE)]),
	    {keep_state_and_data, [{state_timeout, 5000, setup}]}
    end;

%%
%% heartbeat logic
%%
handle_event(state_timeout, heartbeat, connected, Data) ->
    lager:warning("sending heartbeat"),
    send_heartbeat(Data),
    keep_state_and_data;

handle_event(cast, {heartbeat, timeout}, connected, Data0) ->
    Data = handle_nodedown(Data0),
    {next_state, disconnected, Data, [{next_event, internal, setup}]};

handle_event(cast, {_, #pfcp{version = v1, type = heartbeat_response}}, connected, Data) ->
    {next_state, connected, Data, [next_heartbeat(Data)]};

handle_event({call, From}, get_port, _, #data{dp = #node{node = Node}}) ->
    Port = #gtp_port{name = Node, type = 'gtp-u', pid = self()},
    {keep_state_and_data, [{reply, From, {ok, Port}}]};

handle_event({call, From}, get_network_instances, connected,
	     #data{network_instances = NWIs}) ->
    {keep_state_and_data, [{reply, From, {ok, NWIs}}]};

handle_event({call, From}, #pfcp{} = Request, connected, #data{dp = #node{ip = IP}}) ->
    lager:debug("DP Call ~p", [lager:pr(Request, ?MODULE)]),
    Reply = ergw_sx_socket:call(IP, Request),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({timeout, {call, _}}, {_, From, _} = Item, _, #data{call_q = QIn} = Data) ->
    case queue:member(Item, QIn) of
	true ->
	    QOut = queue:filter(fun(X) -> X /= Item end, QIn),
	    {keep_state, Data#data{call_q = QOut}, [{reply, From, {error, timeout}}]};
	_ ->
	    keep_state_and_data
    end;

handle_event({call, From}, Request, _, #data{call_q = QIn} = Data)
  when is_record(Request, pfcp);
       Request == get_network_instances ->
    Ref = make_ref(),
    Item = {Ref, From, Request},
    QOut = queue:in(Item, QIn),
    {keep_state, Data#data{call_q = QOut}, [{{timeout, {call, Ref}}, 1000, Item}]}.

%% handle_event({call, From}, #pfcp{} = Request, _, Data) ->
%%     Reply = {error, not_connected},
%%     {keep_state_and_data, [{reply, From, Reply}]};

%% handle_event(cast, {send, _IP, _Port, _Data} = Msg, _, #data{pid = Pid}) ->
%%     lager:debug("DP Cast ~p: ~p", [Pid, Msg]),
%%     gen_server:cast(Pid, Msg),
%%     keep_state_and_data.

terminate(_Reason, _Data) ->
    ok.

code_change(_OldVsn, Data, _Extra) ->
    {ok, Data}.

%%%===================================================================
%%% Sx Msg handler functions
%%%===================================================================

%% handle_msg(#pfcp{type = heartbeat_response},
%% 	   #data{state = disconnected} = Data0) ->
%%     Data1 = cancel_timeout(Data0),
%%     Data2 = handle_nodeup(Data1),
%%     Data = shedule_next_heartbeat(Data2),
%%     {noreply, Data};

%% handle_msg(#pfcp{type = heartbeat_response}, Data0) ->
%%     Data1 = cancel_timeout(Data0),
%%     Data = shedule_next_heartbeat(Data1),
%%     {noreply, Data};

%% handle_msg(#pfcp{type = session_report_request} = Report,
%% 	   #data{gtp_port = GtpPort} = Data) ->
%%     lager:debug("handle_info: ~p, ~p",
%% 		[lager:pr(Report, ?MODULE), lager:pr(Data, ?MODULE)]),
%%     gtp_context:session_report(GtpPort, Report),
%%     {noreply, Data};

%% handle_msg(Msg, #data{pending = From} = Data0)
%%   when From /= undefined ->
%%     Data = cancel_timeout(Data0),
%%     gen_server:reply(From, Msg),
%%     {noreply, Data#data{pending = undefined}};

%% handle_msg(Msg, Data) ->
%%     lager:error("handle_msg: unknown ~p, ~p", [Msg, lager:pr(Data, ?MODULE)]),
%%     {noreply, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% sntp_time_to_seconds(Time) ->
%%      case Time band 16#80000000 of
%% 	 0 -> Time + 2085978496; % use base: 7-Feb-2036 @ 06:28:16 UTC
%% 	 _ -> Time - 2208988800  % use base: 1-Jan-1900 @ 01:00:00 UTC
%%      end.

connect_sx_node([]) ->
    {error, not_found};
connect_sx_node([{Node, _, _, IP4, IP6}|Next]) ->
    case connect_sx_node(Node, IP4, IP6) of
	{ok, _Pid} = Result ->
	    Result;
	_ ->
	    connect_sx_node(Next)
    end.

connect_sx_node(Node, IP4, IP6) ->
    case ergw_sx_node_reg:lookup(Node) of
	{ok, _} = Result ->
	    Result;
	_ ->
	    ergw_sx_node_sup:new(Node, IP4, IP6)
    end.

response_cb(Type) ->
    {?MODULE, response, [self(), Type]}.

seconds_to_sntp_time(Sec) ->
    if Sec >= 2085978496 ->
	    Sec - 2085978496;
       true ->
	    Sec + 2208988800
    end.

next_heartbeat(_Data) ->
    {state_timeout, 5000, heartbeat}.

node_id(#node{node = Node})
  when is_atom(Node) ->
    #node_id{id = string:split(atom_to_binary(Node, utf8), ".", all)}.

send_heartbeat(#data{dp = #node{ip = IP}}) ->
    IEs = [#recovery_time_stamp{
	      time = seconds_to_sntp_time(gtp_config:get_start_time())}],
    Req = #pfcp{version = v1, type = heartbeat_request, ie = IEs},
    ergw_sx_socket:call(IP, 500, 5, Req, response_cb(heartbeat)).

handle_nodeup(#{user_plane_ip_resource_information := UPIPResInfo} = _IEs,
	      #data{dp = #node{node = Node, ip = IP}} = Data) ->
    lager:warning("Node ~s (~s) is up", [Node, inet:ntoa(IP)]),
    lager:warning("Node IEs: ~p", [lager:pr(_IEs, ?MODULE)]),

    %% {ok, RCnt} = gtp_config:get_restart_counter(),
    %% GtpPort = #gtp_port{name = Node, type = 'gtp-u', pid = self(), restart_counter = RCnt},
    ergw_sx_node_reg:register(Node, self()),

    Data#data{
      timeout = 100,
      network_instances =
	  init_network_instance(Data#data.network_instances, UPIPResInfo)
     }.

label2name(Label) when is_list(Label) ->
    binary_to_atom(iolist_to_binary(lists:join($., Label)), latin1);
label2name(Name) when is_binary(Name) ->
    binary_to_atom(Name, latin1).

init_network_instance(NetworkInstances, UPIPResInfo)
    when is_list(UPIPResInfo) ->
    lists:foldl(fun(I, Acc) ->
			init_network_instance(Acc, I)
		end, NetworkInstances, UPIPResInfo);
init_network_instance(NetworkInstances,
		      #user_plane_ip_resource_information{
			 network_instance = NetworkInstance
			} = UPIPResInfo) ->
    NwInstName = label2name(NetworkInstance),
    NetworkInstances#{NwInstName => UPIPResInfo}.

handle_nodedown(#data{dp = #node{node = Node}} = Data) ->
    ergw_sx_node_reg:unregister(Node),
    Data#data{network_instances = #{}}.

session_not_found(ReqKey, Type, SeqNo) ->
    Response =
	#pfcp{version = v1, type = Type, seq_no = SeqNo, seid = 0,
	      ie = #{pfcp_cause => #pfcp_cause{cause = 'Session context not found'}}},
    ergw_sx_socket:send_response(ReqKey, Response, true),
    ok.

%%%===================================================================
%%% F-TEID Ch handling...
%%%===================================================================

%% choose_f_teids(NWIs, Contexts0, #pfcp{ie = IEs0} = Req) ->
%%     {IEs, {TEIDbyChId, TEIDbyNWIs}} =
%% 	lists:mapfold(choose_f_teid(NWIs, _, _), {#{}, #{}}, IEs0),
%%     lager:warning("NWIs: ~p", [NWIs]),
%%     {Req#pfcp{ie = IEs}, Contexts0}.


%% choose_pdi_f_teid(NWIs, #f_teid{teid = choose, choose_id = ChId}, NWI, PDI0,
%% 		  {TEIDbyChId0, TEIDbyNWI0} = State0)
%%   when ChId /= undefined ->
%%     case TEIDbyChId0 of
%% 	#{ChId := TEID} ->
%% 	    {lists:keystore(f_teid, 1, TEID, PDI0), State0};
%% 	_ ->
	    
%% 	    ok
%%     end;
%% choose_pdi_f_teid(_, _, _, PDI, State) ->
%%     {PDI, State}.

%% choose_pdr_f_teid(NWIs, PDR0, State0) ->
%%     case lists:keyfind(pdi, PDR0) of
%% 	#pdi{group = IEs} = PDI0 ->
%% 	    TEID = lists:keyfind(f_teid, 1, PDI0),
%% 	    NWI = lists:keyfind(network_instance, 1, PDI0),
%% 	    {PDI, State} = choose_pdi_f_teid(NWIs, TEID, NWI, PDI0, State0),
%% 	    {lists:keystore(pdi, 1, PDR0, PDI), State};
%% 	_ ->
%% 	    {PDR0, State0}
%%     end.

%% choose_f_teid(NWIs, #create_pdr{group = PDR0} = Create, State0) ->
%%     {PDR, State} = choose_pdr_f_teid(NWIs, PDR0, State0),
%%     {Create#create_pdr{group = PDR}, State};
%% choose_f_teid(NWIs, #update_pdr{group = PDR0} = Create, State0) ->
%%     {PDR, State} = choose_pdr_f_teid(NWIs, PDR0, State0),
%%     {Create#update_pdr{group = PDR}, State};
%% choose_f_teid(_, IE, State) ->
%%     {IE, State}.
