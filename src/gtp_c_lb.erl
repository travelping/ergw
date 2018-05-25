%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_c_lb).

-behaviour(gen_server).

-compile({parse_transform, cut}).

-export([validate_options/1, attach_protocol/4,
	 start_link/3, get_context/1, handle_message/3]).
-ifdef(TEST).
-export([get_request_q/1]).
-endif.

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-record(state, {version        :: 'v1' | 'v2',
		protocol       :: 'gn' | 's5s8',
		port           :: #gtp_port{},
		forward_ports  :: [atom()],
		rules          :: list(),
		requests         % :: ergw_cache:cache(),
	       }).

-define(T3, 10 * 1000).
-define(N3, 5).
-define(REQUEST_TIMEOUT, (?T3 * ?N3 + (?T3 div 2))).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).
-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).
-define(IS_IP(X), (?IS_IPv4(X) orelse ?IS_IPv6(X))).

-define(Defaults, [{forward, []},
		   {rules, []}]).
-define(RulesDefaults, [{conditions, []}]).

validate_options(Opts) ->
    lager:debug("GTP-C Load Balancer Options: ~p", [Opts]),
    ergw_config:validate_options(fun validate_option/2, Opts, ?Defaults, map).

validate_option(forward, Value)
  when is_list(Value) andalso length(Value) /= 0 ->
    lists:foreach(fun(V) when is_atom(V) ->
			  ok;
		     (V) ->
			  throw({error, {options, {nodes, V}}})
		  end, Value),
    Value;
validate_option(rules, Rules)
  when ?non_empty_opts(Rules) ->
    ergw_config:check_unique_keys(rules, Rules),
    ergw_config:validate_options(fun validate_rules/2, Rules, [], map);
validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

validate_rules(Name, Opts)
  when is_atom(Name) ->
    ergw_config:validate_options(fun validate_rules_option/2, Opts, ?RulesDefaults, map);
validate_rules(Name, Opts) ->
    throw({error, {options, {Name, Opts}}}).

validate_rules_option(conditions, Opts)
  when is_list(Opts) ->
    ergw_config:validate_options(fun validate_conditions/2, Opts, [], list);
validate_rules_option(strategy, Value)
  when Value =:= random;
       Value =:= round_robin ->
    Value;
validate_rules_option(nodes, Value)
  when ?non_empty_opts(Value) ->
    lists:foreach(fun(V) when ?IS_IP(V) ->
			  ok;
		     (V) ->
			  throw({error, {options, {nodes, V}}})
		  end, Value),
    Value;
validate_rules_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).

validate_conditions(src_ip, Value)
  when ?IS_IP(Value) ->
    Value;
validate_conditions(peer_ip, Value)
  when ?IS_IP(Value) ->
    Value;
validate_conditions(imsi, Value)
  when is_binary(Value) ->
    Value;
validate_conditions(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%====================================================================
%% API
%%====================================================================

attach_protocol(Socket, Name, Protocol, Opts0) ->
    ok = enable(),
    Opts = validate_options(Opts0),
    {ok, _} = gtp_c_lb_sup:new(Socket, Protocol, Opts),
    ergw:attach_protocol(Socket, Name, Protocol, ?MODULE, Opts).

start_link(Socket, Protocol, Opts) ->
    gen_server:start_link(?MODULE, [Socket, Protocol, Opts], []).

get_context(GtpPort) ->
    gtp_context_reg:lookup_key(GtpPort, lb).

handle_message(Server, ReqKey, Msg) ->
    gen_server:cast(Server, {handle_message, ReqKey, Msg}).

-ifdef(TEST).
get_request_q(Server) ->
    gen_server:call(Server, get_request_q).
-endif.

%%====================================================================
%% gen_server API
%%====================================================================

init([Socket, Protocol,
      #{forward := FwdPorts, rules := Rules} = Opts]) ->
    lager:debug("LB ~p Opts: ~p", [Protocol, Opts]),
    Port = ergw_gtp_socket_reg:lookup(Socket),
    gtp_context_reg:register(Port, lb, self()),

    Version = protocol_version(Protocol),
    State = #state{
	       version = Version,
	       protocol = Protocol,
	       port = Port,
	       forward_ports = FwdPorts,
	       rules = Rules,
	       requests = ergw_cache:new(?T3 * 4, requests)
	      },

    Nodes = maps:fold(fun(_K, #{nodes := Ns}, Acc) -> Ns ++ Acc end, [], Rules),
    lists:foreach(gtp_path:maybe_new_path(Port, Version, _, persistent), Nodes),

    {ok, State}.

handle_call(get_request_q, _From, #state{requests = Requests} = State) ->
    {reply, ergw_cache:to_list(Requests), State};

handle_call(Request, _From, State) ->
    lager:debug("~w: handle_call: ~p", [?MODULE, Request]),
    {reply, ok, State}.

handle_cast({handle_message, ReqKey, Msg}, #state{requests = Requests} = State0) ->
    lager:debug("HandleMessage: ~p", [ReqKey]),
    case ergw_cache:get(ReqKey#request.key, Requests) of
	{value, {FwdPort, Peer}} ->
	    lager:debug("Cache Fwd: ~p, ~p", [FwdPort, Peer]),
	    ergw_gtp_raw_socket:forward(FwdPort, ReqKey, Peer, ?GTP1c_PORT, Msg),
	    {noreply, State0};
	_Other ->
	    lager:debug("HandleMessage: ~p", [_Other]),
	    State = handle_message_1(ReqKey, Msg, State0),
	    {noreply, State}
    end;
handle_cast(Msg, State) ->
    lager:debug("~w: handle_cast: ~p", [?MODULE, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info({timeout, TRef, requests}, #state{requests = Requests} = State) ->
    {noreply, State#state{requests = ergw_cache:expire(TRef, Requests)}};

handle_info(Info, State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

enable() ->
    ChildSpec = #{id       => gtp_c_lb_sup,
		  start    => {gtp_c_lb_sup, start_link, []},
		  restart  => permanent,
		  shutdown => 5000,
		  type     => supervisor,
		  modules  => [gtp_c_lb_sup]},
    ergw_sup:ensure_child(ChildSpec).

protocol_version('gn') -> v1;
protocol_version(_)    -> v2.

handle_message_1(ReqKey, Msg0, #state{forward_ports = FwdPorts,
				      requests = Requests} = State0) ->
    Msg = gtp_packet:decode_ies(Msg0),
    lager:debug("~w: handle_message: ~p, ~p",
		[?MODULE, lager:pr(ReqKey, ?MODULE), lager:pr(Msg, ?MODULE)]),

    Rule = match(ReqKey, Msg, State0),
    case route(Rule, State0) of
	{none, State} ->
	    lager:warning("no available LB peers"),
	    State;

	{Peer, State} when is_tuple(Peer) ->
	    FwdPort = ergw_gtp_socket_reg:lookup(hd(FwdPorts)),
	    lager:debug("FwdPort: ~p", [FwdPort]),
	    ergw_gtp_raw_socket:forward(FwdPort, ReqKey, Peer, ?GTP1c_PORT, Msg),

	    State#state{
	      requests =
		  ergw_cache:enter(ReqKey#request.key, {FwdPort, Peer},
				   ?REQUEST_TIMEOUT, Requests)}
    end.

cond_filter({src_ip, MatchIP}, #request{ip = ReqSrcIP}, _) ->
    MatchIP =:= ReqSrcIP;
cond_filter({peer_ip, MatchIP}, _,
	    #gtp{version = v1, ie =
		     #{{gsn_address, 0} := #gsn_address{address = PeerIP}}}) ->
    MatchIP =:= PeerIP;
cond_filter({peer_ip, MatchIP}, _,
	    #gtp{version = v2, ie =
		     #{{v2_fully_qualified_tunnel_endpoint_identifier, 0} :=
			   #v2_fully_qualified_tunnel_endpoint_identifier{ipv4 = PeerIP}}})
  when ?IS_IPv4(MatchIP) ->
    MatchIP =:= PeerIP;
cond_filter({peer_ip, MatchIP}, _,
	    #gtp{version = v2, ie =
		     #{{v2_fully_qualified_tunnel_endpoint_identifier, 0} :=
			   #v2_fully_qualified_tunnel_endpoint_identifier{ipv6 = PeerIP}}})
  when ?IS_IPv6(MatchIP) ->
    MatchIP =:= PeerIP;
cond_filter({imsi, MatchIMSI}, _,
	    #gtp{version = v1, ie =
		     #{{international_mobile_subscriber_identity, 0} :=
			   #international_mobile_subscriber_identity{imsi = IMSI}}}) ->
    MatchIMSI =:= IMSI;
cond_filter({imsi, MatchIMSI}, _,
	    #gtp{version = v2, ie =
		     #{{v2_international_mobile_subscriber_identity, 0} :=
			   #v2_international_mobile_subscriber_identity{imsi = IMSI}}}) ->
    MatchIMSI =:= IMSI;
cond_filter(_Cond, _, _Req) ->
    lager:debug("Cond no match: ~p -> ~p", [_Cond, _Req]),
    false.

rule_filter(_, #{conditions := Conditions}, ReqKey, Request) ->
    lists:all(cond_filter(_, ReqKey, Request), Conditions).

match(ReqKey, Request, #state{rules = Rules}) ->
    %%hd(maps:to_list(Rules)).
    Matching = maps:filter(rule_filter(_, _, ReqKey, Request), Rules),
    lager:debug("Matching Rules: ~p", [Matching]),
    hd(maps:to_list(Matching)).

filter(Nodes, #state{version = Version, port = #gtp_port{name = Name}}) ->
    Available = gtp_path_reg:available(Name, Version),
    lists:splitwith(lists:member(_, Available), Nodes).

route({_, #{nodes := Nodes}} = Rule, State) ->
    route(Rule, filter(Nodes, State), State).

route(_, {[], _}, State) ->
    {none, State};
route({_, #{strategy := random}}, {AliveNodes, _}, State) ->
    Index = rand:uniform(length(AliveNodes)),
    {lists:nth(Index, AliveNodes), State};
route({Id, #{strategy := round_robin}} = Rule0,
	{[Node | AliveNodes], DeadNodes}, #state{rules = Rules0} = State) ->
    %% keep the dead nodes last, so that when they come back they are not used immediatly
    Rule = Rule0#{nodes => AliveNodes ++ [Node] ++ DeadNodes},
    Rules = Rules0#{Id => Rule},
    {Node, State#state{rules = Rules}}.
