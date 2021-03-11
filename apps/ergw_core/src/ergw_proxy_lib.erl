%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_proxy_lib).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([validate_options/3, validate_option/2,
	 forward_request/3, forward_request/8, forward_request/10,
	 get_seq_no/3,
	 select_gw/5,
	 select_gtp_proxy_sockets/2,
	 select_sx_proxy_candidate/3]).
-export([proxy_info/4, proxy_pcc/0]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts32_299.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% API
%%%===================================================================

%% forward_request/10
forward_request(Direction, #tunnel{socket = Socket}, Src, DstIP, DstPort,
		Request, ReqKey, SeqNo, NewPeer, OldState) ->
    {ReqId, ReqInfo} = make_proxy_request(Direction, ReqKey, SeqNo, NewPeer, OldState),
    ?LOG(debug, "Invoking Context Send Request: ~p", [Request]),
    gtp_context:send_request(Socket, Src, DstIP, DstPort, ReqId, Request, ReqInfo).

%% forward_request/8
forward_request(Direction, #tunnel{remote = #fq_teid{ip = IP}} = Tunnel,
		Src, Request, ReqKey, SeqNo, NewPeer, OldState) ->
    forward_request(Direction, Tunnel, Src, IP, ?GTP1c_PORT,
		    Request, ReqKey, SeqNo, NewPeer, OldState).

%% forward_request/3
forward_request(Tunnel, ReqKey, Request)
  when is_record(Tunnel, tunnel) ->
    ReqId = make_request_id(ReqKey, Request),
    gtp_context:resend_request(Tunnel, ReqId).

get_seq_no(#tunnel{socket = Socket}, ReqKey, Request) ->
    ReqId = make_request_id(ReqKey, Request),
    ergw_gtp_c_socket:get_seq_no(Socket, ReqId).

%% choose_gw/4
choose_gw([], _NodeSelect, _Version, #socket{}) ->
    {error, ?CTX_ERR(?FATAL, no_resources_available)};
choose_gw(Nodes, NodeSelect, Version, #socket{name = Name} = Socket) ->
    {Candidate, Next} = ergw_node_selection:snaptr_candidate(Nodes),
    do([error_m ||
	   {Node, IP} <- resolve_gw(Candidate, NodeSelect),
	   begin
	       case gtp_path_reg:state({Name, Version, IP}) of
		   down ->
		       choose_gw(Next, NodeSelect, Version, Socket);
		   State when State =:= undefined; State =:= up ->
		       return({Node, IP})
	       end
	   end]).

%% select_gw/5
select_gw(#{imsi := IMSI, gwSelectionAPN := APN}, Version, Services, NodeSelect, Socket) ->
    FQDN = ergw_node_selection:apn_to_fqdn(APN, IMSI),
    case ergw_node_selection:candidates(FQDN, Services, NodeSelect) of
	[_|_] = Nodes ->
	    choose_gw(Nodes, NodeSelect, Version, Socket);
	_ ->
	    {error, ?CTX_ERR(?FATAL, system_failure)}
    end;
select_gw(_ProxyInfo, _Version, _Services, _NodeSelect, _Socket) ->
    {error, ?CTX_ERR(?FATAL, system_failure)}.

lb(L) when is_list(L) ->
    lists:nth(rand:uniform(length(L)), L).

%% plain A/AAA record
resolve_gw({Node, IP4, IP6}, _NodeSelect)
  when length(IP4) /= 0; length(IP6) /= 0 ->
    {ok, {Node, select_gw_ip(IP4, IP6)}};
resolve_gw({Node, _, _}, NodeSelect) ->
    case ergw_node_selection:lookup(Node, NodeSelect) of
	{_, IP4, IP6}
	  when length(IP4) /= 0; length(IP6) /= 0 ->
	    {ok, {Node, select_gw_ip(IP4, IP6)}};
	{error, _} ->
	    {error, ?CTX_ERR(?FATAL, system_failure)}
    end.

select_gw_ip(IP4, _IP6) when length(IP4) /= 0 ->
    lb(IP4);
select_gw_ip(_IP4, IP6) when length(IP6) /= 0 ->
    lb(IP6);
select_gw_ip(_IP4, _IP6) ->
    undefined.

select_gtp_proxy_sockets(ProxyInfo, #{contexts := Contexts, proxy_sockets := ProxySockets}) ->
    Context = maps:get(context, ProxyInfo, default),
    Ctx = maps:get(Context, Contexts, #{}),
    if Ctx =:= #{} ->
	    ?LOG(warning, "proxy context ~p not found, using default", [Context]);
       true -> ok
    end,
    Cntl = maps:get(proxy_sockets, Ctx, ProxySockets),
    ergw_socket_reg:lookup('gtp-c', lb(Cntl)).

select_sx_proxy_candidate({GwNode, _}, #{upfSelectionAPN := APN} = ProxyInfo,
			  #{contexts := Contexts, node_selection := ProxyNodeSelect}) ->
    Context = maps:get(context, ProxyInfo, default),
    Ctx = maps:get(Context, Contexts, #{}),
    if Ctx =:= #{} ->
	    ?LOG(warning, "proxy context ~p not found, using default", [Context]);
       true -> ok
    end,
    NodeSelect = maps:get(node_selection, Ctx, ProxyNodeSelect),
    APN_FQDN = ergw_node_selection:apn_to_fqdn(APN),
    Services = [{"x-3gpp-upf", "x-sxa"}],
    Candidates0 = ergw_node_selection:candidates(APN_FQDN, Services, NodeSelect),
    PGWCandidate = [{GwNode, 0, Services, [], []}],
    case ergw_node_selection:topology_match(Candidates0, PGWCandidate) of
	{_, C} when is_list(C), length(C) /= 0 ->
	    C;
	{C, _} when is_list(C), length(C) /= 0 ->
	    C;
	_ ->
	    %% neither colocation, not topology matched
	    Candidates0
    end.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(ProxyDefaults, [{proxy_data_source, gtp_proxy_ds},
			{proxy_sockets,     []},
			{contexts,          []}]).

-define(ContextDefaults, []).

-define(is_opts(X), (is_list(X) orelse is_map(X))).

validate_options(Fun, Opts, Defaults) ->
    gtp_context:validate_options(Fun, Opts, Defaults ++ ?ProxyDefaults).

validate_option(proxy_data_source, Value) ->
    case code:ensure_loaded(Value) of
	{module, _} ->
	    ok;
	_ ->
	    throw({error, {options, {proxy_data_source, Value}}})
    end,
    Value;
validate_option(Opt, Value)
  when Opt == proxy_sockets ->
    validate_context_option(Opt, Value);
validate_option(contexts, Values) when is_list(Values); is_map(Values) ->
    ergw_core_config:opts_fold(fun validate_context/3, #{}, Values);
validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

validate_context_option(proxy_sockets, Value) when is_list(Value), Value /= [] ->
    Value;
validate_context_option(node_selection, [S|_] = Value)
  when is_atom(S) ->
    Value;
validate_context_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_context(Name, Opts0, Acc)
  when is_binary(Name) andalso ?is_opts(Opts0) ->
    Opts = ergw_core_config:validate_options(
	     fun validate_context_option/2, Opts0, ?ContextDefaults, map),
    Acc#{Name => Opts};
validate_context(Name, Opts, _Acc) ->
    throw({error, {options, {contexts, {Name, Opts}}}}).

%%%===================================================================
%%% Helper functions
%%%===================================================================

make_request_id(#request{key = ReqKey}, #gtp{seq_no = SeqNo})
  when is_integer(SeqNo) ->
    {ReqKey, SeqNo};
make_request_id(#request{key = ReqKey}, SeqNo)
  when is_integer(SeqNo) ->
    {ReqKey, SeqNo}.

make_proxy_request(Direction, Request, SeqNo, NewPeer, State) ->
    ReqId = make_request_id(Request, SeqNo),
    ReqInfo = #proxy_request{
		 direction = Direction,
		 request = Request,
		 seq_no = SeqNo,
		 new_peer = NewPeer,
		 right_tunnel = maps:get(right_tunnel, State, undefined)
		},
    {ReqId, ReqInfo}.

proxy_info(Session,
	   #tunnel{version = Version, remote = #fq_teid{ip = GsnC}},
	   #bearer{remote = #fq_teid{ip = GsnU}},
	   #context{apn = APN, imsi = IMSI, imei = IMEI, msisdn = MSISDN}) ->
    Keys = [{'3GPP-RAT-Type', 'ratType'},
	    {'3GPP-User-Location-Info', 'userLocationInfo'},
	    {'RAI', rai}],
    PI = lists:foldl(
	   fun({Key, MapTo}, P) when is_map_key(Key, Session) ->
		   P#{MapTo => maps:get(Key, Session)};
	      (_, P) -> P
	   end, #{}, Keys),
    PI#{version => Version,
	imsi    => IMSI,
	imei    => IMEI,
	msisdn  => MSISDN,
	apn     => ergw_node_selection:expand_apn(APN, IMSI),
	servingGwCip => GsnC,
	servingGwUip => GsnU
       }.

%%%===================================================================
%%% Sx DP API
%%%===================================================================

proxy_pcc() ->
    #pcc_ctx{
       rules =
	   #{<<"r-0001">> =>
		 #{'Charging-Rule-Base-Name' => <<"proxy">>,
		   'Flow-Information' => [],
		   'Metering-Method' => [?'DIAMETER_3GPP_CHARGING_METERING-METHOD_VOLUME'],
		   'Offline' => [0],
		   'Online' => [0],
		   'Precedence' => [100],
		   'Rating-Group' => [3000]}
	    }
      }.
