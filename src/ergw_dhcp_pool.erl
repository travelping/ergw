%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_dhcp_pool).

-behavior(gen_server).
-behavior(ergw_ip_pool).

-compile([{parse_transform, cut}]).

%% API
-export([start_ip_pool/2, send_pool_request/2, wait_pool_response/1, release/1,
	 ip/1, opts/1, timeouts/1, handle_event/2]).
-export([start_link/3, start_link/4]).
-export([validate_options/1]).

-ignore_xref([start_link/3, start_link/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(pool, {id, socket, servers}).
-record(state, {name, ipv4, ipv6, outstanding}).
%% -record(lease, {ip, client_id}).

-include_lib("kernel/include/logger.hrl").
-include_lib("dhcp/include/dhcp.hrl").
-include_lib("dhcpv6/include/dhcpv6.hrl").
-include("include/3gpp.hrl").

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

-define(ZERO_IPv4, {0,0,0,0}).
-define(ZERO_IPv6, {0,0,0,0,0,0,0,0}).
-define(UE_INTERFACE_ID, {0,0,0,0,0,0,0,1}).
-define(IAID, 1).

-define(IPv4Opts, ['Framed-Pool',
		   'MS-Primary-DNS-Server',
		   'MS-Secondary-DNS-Server',
		   'MS-Primary-NBNS-Server',
		   'MS-Secondary-NBNS-Server']).
-define(IPv6Opts, ['Framed-IPv6-Pool',
		   'DNS-Server-IPv6-Address',
		   '3GPP-IPv6-DNS-Servers']).

%%====================================================================
%% API
%%====================================================================

start_ip_pool(Name, Opts0)
  when is_binary(Name) ->
    Opts = validate_options(Opts0),
    ergw_ip_pool_sup:start_dhcp_pool_sup(),
    ergw_dhcp_pool_sup:start_ip_pool(Name, Opts).

start_link(PoolName, Pool, Opts) ->
    gen_server:start_link(?MODULE, [PoolName, Pool], Opts).

start_link(ServerName, PoolName, Pool, Opts) ->
    gen_server:start_link(ServerName, ?MODULE, [PoolName, Pool], Opts).

send_pool_request(ClientId, {Pool, IP, PrefixLen, Opts}) when is_pid(Pool) ->
    send_request(Pool, {get, ClientId, IP, PrefixLen, Opts});
send_pool_request(ClientId, {Pool, IP, PrefixLen, Opts}) ->
    send_request(ergw_dhcp_pool_reg:lookup(Pool), {get, ClientId, IP, PrefixLen, Opts}).

wait_pool_response(ReqId) ->
    case wait_response(ReqId, 1000) of
	%% {reply, {error, _}} ->
	%%     undefined;
	{reply, Reply} ->
	    Reply;
	timeout ->
	    {error, timeout};
	{error, _} = Error ->
	    Error
    end.

release({_, Server, {_, _} = IP, SrvId, _Opts}) ->
    %% see alloc_reply
    gen_server:cast(Server, {release, IP, SrvId}).

-if(?OTP_RELEASE >= 23).
send_request(Server, Request) ->
    gen_server:send_request(Server, Request).

wait_response(Mref, Timeout) ->
    gen_server:wait_response(Mref, Timeout).
-else.
send_request(Server, Request) ->
    ReqF = fun() -> exit({reply, gen_server:call(Server, Request)}) end,
    try spawn_monitor(ReqF) of
	{_, Mref} -> Mref
    catch
	error: system_limit = E ->
	    %% Make send_request async and fake a down message
	    Ref = erlang:make_ref(),
	    self() ! {'DOWN', Ref, process, Server, {error, E}},
	    Ref
    end.

wait_response(Mref, Timeout)
  when is_reference(Mref) ->
    receive
	{'DOWN', Mref, _, _, Reason} ->
	    Reason
    after Timeout ->
	    timeout
    end.

-endif.

ip({?MODULE, _, IP, _, _}) -> IP.
opts({?MODULE, _, _, _, Opts}) -> Opts.

timeouts({?MODULE, _, _, _, Opts}) ->
    Keys = [renewal, rebinding, lease],
    lists:foldl(fun(K, M) -> M#{K => maps:get(K, Opts, infinity)} end, #{}, Keys).

handle_event({?MODULE, Server, _, _, _} = AI, Ev) ->
    gen_server:call(Server, {handle_event, AI, Ev}).

%%====================================================================
%%% Options Validation
%%%===================================================================

-define(DefaultOptions, [{handler, ?MODULE}]).
-define(DefaultIPv4Opts, [{socket, "undefined"}, {servers, []}, {id, undefined}]).
-define(DefaultIPv6Opts, [{socket, "undefined"}, {servers, []}, {id, undefined}]).

validate_options(Options) ->
    ?LOG(debug, "IP Pool Options: ~p", [Options]),
    ergw_config:validate_options(fun validate_option/2, Options, ?DefaultOptions, map).

validate_server(ipv4, IP) when ?IS_IPv4(IP) ->
    IP;
validate_server(ipv6, IP) when ?IS_IPv6(IP) ->
    IP;
validate_server(_, broadcast = Value) ->
    Value;
validate_server(ipv6, local = Value) ->
    Value;
validate_server(Type, Value) ->
    throw({error, {options, {Type, {servers, Value}}}}).

validate_ip_option(_, socket, Value) when is_atom(Value)->
    Value;
validate_ip_option(Type, servers, Servers)
  when is_list(Servers), length(Servers) /= 0 ->
    ergw_config:check_unique_elements(servers, Servers),
    [validate_server(Type, Server) || Server <- Servers];
validate_ip_option(ipv4, id, Value) when ?IS_IPv4(Value) ->
    Value;
validate_ip_option(ipv6, id, Value) when ?IS_IPv6(Value) ->
    Value;
validate_ip_option(Type, Opt, Value) ->
    throw({error, {options, {Type, {Opt, Value}}}}).

validate_option(handler, Value) ->
    Value;
validate_option(ipv4, Opts) ->
    ergw_config:validate_options(validate_ip_option(ipv4, _, _), Opts, ?DefaultIPv4Opts, map);
validate_option(ipv6, Opts) ->
    ergw_config:validate_options(validate_ip_option(ipv6, _, _), Opts, ?DefaultIPv6Opts, map);
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([Name, Opts]) ->
    ergw_dhcp_pool_reg:register(Name),
    State = #state{name = Name,
		   ipv4 = init_pool(maps:get(ipv4, Opts, undefined)),
		   ipv6 = init_pool(maps:get(ipv6, Opts, undefined)),
		   outstanding = #{}},
    ?LOG(debug, "init Pool state: ~p", [State]),
    {ok, State}.

handle_call({get, ClientId, ipv4, PrefixLen, ReqOpts}, From, State) ->
    dhcpv4_init(ClientId, undefined, PrefixLen, ReqOpts, From, State);
handle_call({get, ClientId, {_,_,_,_} = IP, PrefixLen, ReqOpts}, From, State) ->
    dhcpv4_init(ClientId, IP, PrefixLen, ReqOpts, From, State);

handle_call({get, ClientId, ipv6, PrefixLen, ReqOpts}, From, State) ->
    dhcpv6_init(ClientId, undefined, PrefixLen, ReqOpts, From, State);
handle_call({get, ClientId, {_,_,_,_,_,_,_,_} = IP, PrefixLen, ReqOpts}, From, State) ->
    dhcpv6_init(ClientId, IP, PrefixLen, ReqOpts, From, State);

handle_call({get, _ClientId, IP, PrefixLen, _ReqOpts}, _From, State) ->
    Error = {unsupported, {IP, PrefixLen}},
    {reply, {error, Error}, State};

handle_call({handle_event, {_, _, {IP, PrefixLen}, {Srv, ClientId}, Opts}, renewal},
	    From, State)
  when ?IS_IPv4(IP) ->
    dhcpv4_renew(ClientId, IP, PrefixLen, Opts, Srv, From, State);

handle_call({handle_event, {_, _, {IP, PrefixLen}, {_Srv, ClientId}, Opts}, rebinding},
	    From, State)
  when ?IS_IPv4(IP) ->
    dhcpv4_rebind(ClientId, IP, PrefixLen, Opts, From, State);

handle_call({handle_event, {_, _, {IP, PrefixLen}, {Server, SrvId, ClientId}, Opts}, renewal},
	    From, State)
  when ?IS_IPv6(IP) ->
    dhcpv6_renew(ClientId, IP, PrefixLen, Opts, SrvId, Server, From, State);

handle_call({handle_event, {_, _, {IP, PrefixLen}, {_, _, ClientId}, Opts}, rebinding},
	    From, State)
  when ?IS_IPv6(IP) ->
    dhcpv6_rebind(ClientId, IP, PrefixLen, Opts, From, State);

handle_call({handle_event, {_, _, IP, SrvId, Opts}, Ev}, _From, State) ->
    ?LOG(error, "unhandled DHCP event: ~p, (~p, ~p, ~p)", [Ev, IP, SrvId, Opts]),
    {reply, ok, State};

handle_call(Request, _From, State) ->
    ?LOG(warning, "handle_call: ~p", [Request]),
    {reply, error, State}.

handle_cast({release, {IP, 32}, SrvId}, State)
  when ?IS_IPv4(IP) ->
    dhcpv4_release(IP, SrvId, State),
    {noreply, State};

handle_cast({release, {IP, _} = Addr, SrvId}, State)
  when ?IS_IPv6(IP) ->
    dhcpv6_release(Addr, SrvId, State),
    {noreply, State};

handle_cast(Msg, State) ->
    ?LOG(debug, "handle_cast: ~p", [Msg]),
    {noreply, State}.

handle_info({'DOWN', Mref, _, _, Reason}, #state{outstanding = OutS0} = State)
  when is_map_key(Mref, OutS0) ->
    {From, OutS} = maps:take(Mref, OutS0),
    handle_reply(From, Reason),
    {noreply, State#state{outstanding = OutS}};

handle_info(Info, State) ->
    ?LOG(debug, "handle_info: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

init_pool(#{id := Id, socket := Socket, servers := Srvs}) ->
    #pool{id = Id, socket = Socket, servers = Srvs};
init_pool(_) ->
    undefined.

handle_reply(From, {reply, {ok, IP, SrvId, Opts}}) ->
    gen_server:reply(From, {?MODULE, self(), IP, SrvId, Opts});
handle_reply(From, {reply, Reply}) ->
    gen_server:reply(From, Reply);
handle_reply(From, Reason) ->
    gen_server:reply(From, {error, Reason}).

%%%===================================================================
%%% DHCPv4 functions
%%%===================================================================

%% dhcpv4_spawn/3
dhcpv4_spawn(Fun, From, #state{outstanding = OutS} = State) ->
    ReqF = fun() -> exit({reply, Fun()}) end,
    {_, Mref} = spawn_monitor(ReqF),
    {noreply, State#state{outstanding = maps:put(Mref, From, OutS)}}.

%% dhcpv4_init/6
dhcpv4_init(ClientId, IP, PrefixLen, ReqOpts, From, #state{ipv4 = Pool} = State)
  when is_record(Pool, pool) ->
    ReqF = fun() -> dhcpv4_init_f(ClientId, IP, PrefixLen, ReqOpts, Pool) end,
    dhcpv4_spawn(ReqF, From, State).

%% dhcpv4_renew/6
dhcpv4_renew(ClientId, IP, PrefixLen, Opts, Srv, From, #state{ipv4 = Pool} = State) ->
    ReqF = fun() -> dhcpv4_renew_f(ClientId, IP, PrefixLen, Opts, Srv, Pool) end,
    dhcpv4_spawn(ReqF, From, State).

%% dhcpv4_rebind/6
dhcpv4_rebind(ClientId, IP, PrefixLen, Opts, From, #state{ipv4 = Pool} = State) ->
    ReqF = fun() -> dhcpv4_rebind_f(ClientId, IP, PrefixLen, Opts, Pool) end,
    dhcpv4_spawn(ReqF, From, State).

dhcpv4_init_f(ClientId, ReqIP, PrefixLen, ReqOpts, #pool{servers = Srvs} = Pool) ->
    Srv = choose_server(Srvs),
    Opts = dhcpv4_opts(ClientId, ReqIP, PrefixLen, ReqOpts),
    case dhcpv4_discover(Pool, Srv, Opts) of
	#dhcp{} = Offer ->
	    dhcpv4_request(Pool, ClientId, Opts, Offer);
	Other ->
	    Other
    end.

dhcpv4_renew_f(ClientId, IP, PrefixLen, ReqOpts, Srv, Pool) ->
    Opts = dhcpv4_opts(ClientId, IP, PrefixLen, ReqOpts),
    dhcpv4_renew(Pool, Srv, ClientId, IP, Opts).

dhcpv4_rebind_f(ClientId, IP, PrefixLen, ReqOpts, #pool{servers = Srvs} = Pool) ->
    Srv = choose_server(Srvs),
    Opts = dhcpv4_opts(ClientId, IP, PrefixLen, ReqOpts),
    dhcpv4_rebind(Pool, Srv, ClientId, IP, Opts).

dhcpv4_discover(Pool, Srv, Opts) ->
    DHCP = #dhcp{
	      op = ?BOOTREQUEST,
	      options = Opts#{?DHO_DHCP_MESSAGE_TYPE => ?DHCPDISCOVER}
	     },
    ReqId = dhcpv4_send_request(Pool, Srv, DHCP),

    TimeOut = erlang:monotonic_time(millisecond) + 1000,  %% 1 sec
    dhcpv4_offer(ReqId, {abs, TimeOut}).

dhcpv4_offer(ReqId, Timeout) ->
    case ergw_dhcp_socket:wait_response(ReqId, Timeout) of
	{ok, _Srv, #dhcp{options = #{?DHO_DHCP_MESSAGE_TYPE := ?DHCPOFFER}} = Answer} ->
	    Answer;
	{error, timeout} = Error ->
	    Error;
	{error, _} ->
	    dhcpv4_offer(ReqId, Timeout)
    end.

dhcpv4_request(Pool, ClientId, Opts, #dhcp{siaddr = SiAddr0} = Offer) ->
    OptsFilter = [?DHO_DHCP_SERVER_IDENTIFIER],
    SiAddr = maps:get(?DHO_DHCP_SERVER_IDENTIFIER, Offer#dhcp.options, SiAddr0),

    DHCP = Offer#dhcp{
	     op = ?BOOTREQUEST,
	     ciaddr = {0, 0, 0, 0},
	     yiaddr = {0, 0, 0, 0},
	     siaddr = {0, 0, 0, 0},
	     options =
		 maps:merge(
		   Opts#{?DHO_DHCP_MESSAGE_TYPE => ?DHCPREQUEST,
			 ?DHO_DHCP_REQUESTED_ADDRESS => Offer#dhcp.yiaddr},
		   maps:with(OptsFilter, Offer#dhcp.options))
	    },
    ReqId = dhcpv4_send_request(Pool, SiAddr, DHCP),

    ReqTimeOut = erlang:monotonic_time(millisecond) + 1000,  %% 1 sec
    case dhcpv4_answer(ReqId, {abs, ReqTimeOut}) of
	#dhcp{yiaddr = IP,
	      options = #{?DHO_DHCP_MESSAGE_TYPE := ?DHCPACK} = RespOpts} = Answer ->
	    SrvId = choose_next(Answer, SiAddr),
	    {ok, {IP, 32}, {SrvId, ClientId}, dhcpv4_resp_opts(RespOpts)};
	#dhcp{} ->
	    {error, failed};
	{error, _} = Error ->
	    Error
    end.

dhcpv4_renew(Pool, Srv, ClientId, IP, Opts) ->
    DHCP = #dhcp{
	     op = ?BOOTREQUEST,
	     ciaddr = IP,
	     yiaddr = {0, 0, 0, 0},
	     siaddr = {0, 0, 0, 0},
	     options = Opts#{?DHO_DHCP_MESSAGE_TYPE => ?DHCPREQUEST}
	    },
    ReqId = dhcpv4_send_request(Pool, Srv, DHCP),

    ReqTimeOut = erlang:monotonic_time(millisecond) + 1000,  %% 1 sec
    case dhcpv4_answer(ReqId, {abs, ReqTimeOut}) of
	#dhcp{yiaddr = IP,
	      options = #{?DHO_DHCP_MESSAGE_TYPE := ?DHCPACK} = RespOpts} = Answer ->
	    SrvId = choose_next(Answer, Srv),
	    {ok, {IP, 32}, {SrvId, ClientId}, dhcpv4_resp_opts(RespOpts)};
	#dhcp{} ->
	    {error, failed};
	{error, _} = Error ->
	    Error
    end.

%% TBD: in REBIND we should broadcast the request (or send to all configured servers)
dhcpv4_rebind(Pool, Srv, ClientId, IP, Opts) ->
    DHCP = #dhcp{
	     op = ?BOOTREQUEST,
	     ciaddr = IP,
	     yiaddr = {0, 0, 0, 0},
	     siaddr = {0, 0, 0, 0},
	     options = Opts#{?DHO_DHCP_MESSAGE_TYPE => ?DHCPREQUEST}
	    },
    ReqId = dhcpv4_send_request(Pool, Srv, DHCP),

    ReqTimeOut = erlang:monotonic_time(millisecond) + 1000,  %% 1 sec
    case dhcpv4_answer(ReqId, {abs, ReqTimeOut}) of
	#dhcp{yiaddr = IP,
	      options = #{?DHO_DHCP_MESSAGE_TYPE := ?DHCPACK} = RespOpts} = Answer ->
	    SrvId = choose_next(Answer, Srv),
	    {ok, {IP, 32}, {SrvId, ClientId}, dhcpv4_resp_opts(RespOpts)};
	#dhcp{} ->
	    {error, failed};
	{error, _} = Error ->
	    Error
    end.

dhcpv4_release(IP, {Srv, ClientId}, #state{ipv4 = Pool}) ->
    Opts = #{?DHO_DHCP_MESSAGE_TYPE => ?DHCPRELEASE,
	     ?DHO_DHCP_SERVER_IDENTIFIER => Srv,
	     ?DHO_DHCP_CLIENT_IDENTIFIER => client_id(ClientId)},
    DHCP = #dhcp{
	      op = ?BOOTREQUEST,
	      ciaddr = IP,
	      options = Opts
	     },
    _ReqId = dhcpv4_send_request(Pool, Srv, DHCP).

dhcpv4_answer(ReqId, Timeout) ->
    case ergw_dhcp_socket:wait_response(ReqId, Timeout) of
	{ok, _Srv, #dhcp{options = #{?DHO_DHCP_MESSAGE_TYPE := Type}} = Answer}
	  when Type =:= ?DHCPDECLINE;
	       Type =:= ?DHCPACK;
	       Type =:= ?DHCPNAK ->
	    Answer;
	{ok, #dhcp{} = Answer} ->
	    ?LOG(debug, "unexpected DHCP response ~p", [Answer]),
	    dhcpv4_answer(ReqId, Timeout);
	{error, timeout} = Error ->
	    Error;
	{error, _} ->
	    dhcpv4_answer(ReqId, Timeout)
    end.

dhcpv4_send_request(#pool{id = GiAddr, socket = Socket}, Srv, DHCP) ->
    ergw_dhcp_socket:send_request(Socket, Srv, DHCP#dhcp{giaddr = GiAddr}).

dhcpv4_req_list('MS-Primary-DNS-Server', _, Opts) ->
    ordsets:add_element(?DHO_DOMAIN_NAME_SERVERS, Opts);
dhcpv4_req_list('MS-Secondary-DNS-Server', _, Opts) ->
    ordsets:add_element(?DHO_DOMAIN_NAME_SERVERS, Opts);
dhcpv4_req_list('MS-Primary-NBNS-Server', _, Opts) ->
    ordsets:add_element(?DHO_NETBIOS_NAME_SERVERS, Opts);
dhcpv4_req_list('MS-Secondary-NBNS-Server', _, Opts) ->
    ordsets:add_element(?DHO_NETBIOS_NAME_SERVERS, Opts);
dhcpv4_req_list('SIP-Servers-IPv4-Address-List', _, Opts) ->
    ordsets:add_element(?DHO_SIP_SERVERS, Opts);
dhcpv4_req_list(_, _, Opts) ->
    Opts.

dhcpv4_opts(ClientId, _ReqIP, _PrefixLen, ReqOpts) ->
    ReqList0 = ordsets:from_list([?DHO_DHCP_LEASE_TIME]),
    ReqList = ordsets:to_list(maps:fold(fun dhcpv4_req_list/3, ReqList0, ReqOpts)),
    #{?DHO_DHCP_CLIENT_IDENTIFIER => client_id(ClientId),
      ?DHO_DHCP_PARAMETER_REQUEST_LIST => ReqList}.

choose_server(Srvs) when is_list(Srvs) ->
    lists:nth(rand:uniform(length(Srvs)), Srvs).

choose_next(#dhcp{siaddr = ?ZERO_IPv4, options = #{?DHO_DHCP_SERVER_IDENTIFIER := Srv}}, _) ->
    Srv;
choose_next(#dhcp{siaddr = Srv}, _) when ?IS_IPv4(Srv) ->
    Srv;
choose_next(_, Srv) ->
    %% fallback, but not having siaddr and Server Id options violates RFC 2131.
    Srv.

client_id(ClientId) when is_binary(ClientId) ->
    ClientId;
client_id(ClientId) when is_integer(ClientId) ->
    integer_to_binary(ClientId);
client_id(ClientId) when is_list(ClientId) ->
    iolist_to_binary(ClientId).

set_time(K, V, #{'Base-Time' := Now} = Opts) ->
    Opts#{K => Now + V}.

maybe_set_time(K, V, Opts) when not is_map_key(K, Opts) ->
    set_time(K, V, Opts);
maybe_set_time(_, _, Opts) ->
    Opts.

dhcpv4_resp_opts(?DHO_DOMAIN_NAME_SERVERS, [Prim, Sec | _], Opts) ->
    Opts#{'MS-Primary-DNS-Server' => Prim, 'MS-Secondary-DNS-Server' => Sec};
dhcpv4_resp_opts(?DHO_DOMAIN_NAME_SERVERS, [Prim | _], Opts) ->
    Opts#{'MS-Primary-DNS-Server' => Prim};
dhcpv4_resp_opts(?DHO_NETBIOS_NAME_SERVERS, [Prim, Sec | _], Opts) ->
    Opts#{'MS-Primary-NBNS-Server' => Prim, 'MS-Secondary-NBNS-Server' => Sec};
 dhcpv4_resp_opts(?DHO_NETBIOS_NAME_SERVERS, [Prim | _], Opts) ->
    Opts#{'MS-Primary-NBNS-Server' => Prim};
dhcpv4_resp_opts(?DHO_SIP_SERVERS, V, Opts) ->
    Opts#{'SIP-Servers-IPv4-Address-List' => V};
dhcpv4_resp_opts(?DHO_DHCP_LEASE_TIME, V, Opts0) ->
    Opts1 = set_time(lease, V, Opts0),
    Opts2 = maybe_set_time(renewal, round(V * 0.5), Opts1),
    _Opts = maybe_set_time(rebinding, round(V * 0.875), Opts2);
dhcpv4_resp_opts(?DHO_DHCP_RENEWAL_TIME, V, Opts) ->
    set_time(renewal, V, Opts);
dhcpv4_resp_opts(?DHO_DHCP_REBINDING_TIME, V, Opts) ->
    set_time(rebinding, V, Opts);
dhcpv4_resp_opts(_K, _V, Opts) ->
    Opts.

dhcpv4_resp_opts(Opts) ->
    Now = erlang:system_time(second),
    maps:fold(fun dhcpv4_resp_opts/3, #{'Base-Time' => Now}, Opts).

%%%===================================================================
%%% DHCPv6 functions
%%%===================================================================

time_default(0, Default) ->
    Default;
time_default(Time, _) ->
    Time.

%% dhcpv6_spawn/3
dhcpv6_spawn(Fun, From, #state{outstanding = OutS} = State) ->
    ReqF = fun() -> exit({reply, Fun()}) end,
    {_, Mref} = spawn_monitor(ReqF),
    {noreply, State#state{outstanding = maps:put(Mref, From, OutS)}}.

%% dhcpv6_init/6
dhcpv6_init(ClientId, IP, PrefixLen, ReqOpts, From, #state{ipv6 = Pool} = State)
  when is_record(Pool, pool) ->
    ReqF = fun() -> dhcpv6_init_f(ClientId, IP, PrefixLen, ReqOpts, Pool) end,
    dhcpv6_spawn(ReqF, From, State).

%% dhcpv6_renew/6
dhcpv6_renew(ClientId, IP, PrefixLen, Opts, SrvId, Srv, From, #state{ipv6 = Pool} = State) ->
    ReqF = fun() -> dhcpv6_renew_f(ClientId, IP, PrefixLen, Opts, SrvId, Srv, Pool) end,
    dhcpv6_spawn(ReqF, From, State).

%% dhcpv6_rebind/6
dhcpv6_rebind(ClientId, IP, PrefixLen, Opts, From, #state{ipv6 = Pool} = State) ->
    ReqF = fun() -> dhcpv6_rebind_f(ClientId, IP, PrefixLen, Opts, Pool) end,
    dhcpv6_spawn(ReqF, From, State).

dhcpv6_init_f(ClientId, ReqIP, PrefixLen, ReqOpts, #pool{servers = Srvs} = Pool) ->
    Srv = choose_server(Srvs),
    Opts = dhcpv6_opts(ClientId, ReqIP, PrefixLen, ReqOpts),
    case dhcpv6_solicit(Pool, Srv, Opts) of
	{ok, Server, #dhcpv6{} = Advertise} ->
	    dhcpv6_request(Pool, ClientId, Opts, Server, Advertise);
	Other ->
	    Other
    end.

dhcpv6_renew_f(ClientId, IP, PrefixLen, ReqOpts, SrvId, Srv, Pool) ->
    Opts = dhcpv6_opts(ClientId, IP, PrefixLen, ReqOpts),
    dhcpv6_renew(Pool, Srv, ClientId, Opts, SrvId).

dhcpv6_rebind_f(ClientId, IP, PrefixLen, ReqOpts, #pool{servers = Srvs} = Pool) ->
    Srv = choose_server(Srvs),
    Opts = dhcpv6_opts(ClientId, IP, PrefixLen, ReqOpts),
    dhcpv6_rebind(Pool, Srv, ClientId, Opts).

dhcpv6_solicit(Pool, Srv, Opts) ->
    DHCP = #dhcpv6{op = ?DHCPV6_SOLICIT, options = Opts},
    ReqId = dhcpv6_send_request(Pool, Srv, DHCP),

    TimeOut = erlang:monotonic_time(millisecond) + 1000,  %% 1 sec
    dhcpv6_advertise(ReqId, {abs, TimeOut}).

dhcpv6_advertise(ReqId, Timeout) ->
    case ergw_dhcp_socket:wait_response(ReqId, Timeout) of
	{ok, _, #dhcpv6{op = ?DHCPV6_ADVERTISE}} = Answer ->
	    Answer;
	{error, timeout} = Error ->
	    Error;
	{error, _} ->
	    dhcpv6_advertise(ReqId, Timeout)
    end.

dhcpv6_request(Pool, ClientId, Opts, Server,
	       #dhcpv6{options = #{?D6O_SERVERID := SrvId} = AdvOpts} = Advertise) ->
    DHCP = Advertise#dhcpv6{op = ?DHCPV6_REQUEST, options = maps:merge(Opts, AdvOpts)},
    ReqId = dhcpv6_send_request(Pool, Server, DHCP),

    ReqTimeOut = erlang:monotonic_time(millisecond) + 1000,  %% 1 sec
    case dhcpv6_reply(ReqId, {abs, ReqTimeOut}) of
	{ok, Server, #dhcpv6{options = #{?D6O_SERVERID := SrvId}} = Reply} ->
	    dhcpv6_resp_ia(ClientId, Server, Reply);
	{error, _} = Error ->
	    Error
    end.

dhcpv6_renew(Pool, Srv, ClientId, Opts, SrvId) ->
    DHCP = #dhcpv6{op = ?DHCPV6_RENEW, options = Opts#{?D6O_SERVERID => SrvId}},
    ReqId = dhcpv6_send_request(Pool, Srv, DHCP),

    ReqTimeOut = erlang:monotonic_time(millisecond) + 1000,  %% 1 sec
    case dhcpv6_reply(ReqId, {abs, ReqTimeOut}) of
	{ok, Server, #dhcpv6{options = #{?D6O_SERVERID := SrvId}} = Reply} ->
	    dhcpv6_resp_ia(ClientId, Server, Reply);
	{error, _} = Error ->
	    Error
    end.

dhcpv6_rebind(Pool, Srv, ClientId, Opts) ->
    DHCP = #dhcpv6{op = ?DHCPV6_REBIND, options = maps:remove(?D6O_SERVERID, Opts)},
    ReqId = dhcpv6_send_request(Pool, Srv, DHCP),

    ReqTimeOut = erlang:monotonic_time(millisecond) + 1000,  %% 1 sec
    case dhcpv6_reply(ReqId, {abs, ReqTimeOut}) of
	{ok, Server, #dhcpv6{} = Reply} ->
	    dhcpv6_resp_ia(ClientId, Server, Reply);
	{error, _} = Error ->
	    Error
    end.

dhcpv6_release({IP, PrefixLen}, {Srv, SrvId, ClientId}, #state{ipv6 = Pool}) ->
    Opts0 = #{?D6O_SERVERID => SrvId,
	      ?D6O_CLIENTID => dhcpv6_client_id(ClientId)},
    Opts = dhcpv6_ia(IP, PrefixLen, [], Opts0),
    DHCP = #dhcpv6{op = ?DHCPV6_RELEASE, options = Opts},
    _ReqId = dhcpv6_send_request(Pool, Srv, DHCP).

dhcpv6_reply(ReqId, Timeout) ->
    case ergw_dhcp_socket:wait_response(ReqId, Timeout) of
	{ok, _, #dhcpv6{op = ?DHCPV6_REPLY}} = Answer ->
	    Answer;
	{ok, _, #dhcpv6{} = Answer} ->
	    ?LOG(debug, "unexpected DHCP response ~p", [Answer]),
	    dhcpv6_reply(ReqId, Timeout);
	{error, timeout} = Error ->
	    Error;
	{error, _} ->
	    dhcpv6_reply(ReqId, Timeout)
    end.

dhcpv6_send_request(#pool{socket = Socket}, Srv, DHCP) ->
    ergw_dhcp_socket:send_request(Socket, Srv, DHCP).

%% 'Framed-IPv6-Pool'

dhcpv6_req_list('DNS-Server-IPv6-Address', _, Opts) ->
    ordsets:add_element(?D6O_NAME_SERVERS, Opts);
dhcpv6_req_list('3GPP-IPv6-DNS-Servers', _, Opts) ->
    ordsets:add_element(?D6O_NAME_SERVERS, Opts);
dhcpv6_req_list('SIP-Servers-IPv6-Address-List', _, Opts) ->
    ordsets:add_element(?D6O_SIP_SERVERS_ADDR, Opts);
dhcpv6_req_list(_, _, Opts) ->
    Opts.

dhcpv6_opts(ClientId, ReqIP, PrefixLen, ReqOpts) ->
    ReqList0 = ordsets:from_list([?D6O_SOL_MAX_RT]),
    ReqList = ordsets:to_list(maps:fold(fun dhcpv6_req_list/3, ReqList0, ReqOpts)),
    Opts =
	#{?D6O_CLIENTID => dhcpv6_client_id(ClientId),
	  ?D6O_ELAPSED_TIME => 0,
	  ?D6O_ORO => ReqList},
    dhcpv6_ia(ReqIP, PrefixLen, ReqOpts, Opts).

dhcpv6_ia_na(?ZERO_IPv6, Opts) -> Opts;
dhcpv6_ia_na(IP, Opts) when ?IS_IPv6(IP) ->
    Opts#{?D6O_IAADDR => #{IP => {0, 0, #{}}}};
dhcpv6_ia_na(_, Opts) ->
    Opts.

dhcpv6_ia_pd(IP, PrefixLen, Opts) when PrefixLen /= 0, ?IS_IPv6(IP) ->
    Opts#{?D6O_IAPREFIX => #{{IP, PrefixLen} => {0, 0, #{}}}};
dhcpv6_ia_pd(_, _, Opts) ->
    Opts.

dhcpv6_ia(ReqIP, 128, _ReqOpts, Opts) ->
    IAOpts = dhcpv6_ia_na(ReqIP, #{}),
    IA = #{?IAID => {0, 0, IAOpts}},
    Opts#{?D6O_IA_NA => IA};

dhcpv6_ia(ReqIP, PrefixLen, _ReqOpts, Opts) ->
    IAOpts = dhcpv6_ia_pd(ReqIP, PrefixLen, #{}),
    IA = #{?IAID => {0, 0, IAOpts}},
    Opts#{?D6O_IA_PD => IA}.

dhcpv6_client_id(ClientId) when is_binary(ClientId) ->
    {2, ?VENDOR_ID_3GPP, ClientId};
dhcpv6_client_id(ClientId) when is_integer(ClientId) ->
    {2, ?VENDOR_ID_3GPP, integer_to_binary(ClientId)};
dhcpv6_client_id(ClientId) when is_list(ClientId) ->
    {2, ?VENDOR_ID_3GPP, iolist_to_binary(ClientId)}.

dhcpv6_resp_ia(ClientId, Server,
	       #dhcpv6{options =
			   #{?D6O_SERVERID := SrvId,
			     ?D6O_IA_PD :=
				 #{?IAID := {T1, T2,
					     #{?D6O_IAPREFIX := IAPref}}} = IAOpts
			    } = RespOpts}) ->
    case hd(maps:to_list(IAPref)) of
	{{_,_} = PD, {_PrefLife, ValidLife, PDOpts}} ->
	    FinalOpts0 =
		maps:merge(
		  maps:merge(dhcpv6_resp_opts(RespOpts), dhcpv6_resp_opts(IAOpts)),
		  dhcpv6_resp_opts(PDOpts)),
	    FinalOpts =
		FinalOpts0#{lease => ValidLife,
			    renewal => time_default(T1, 3600),
			    rebinding => time_default(T2, 7200)},
	    {ok, PD, {Server, SrvId, ClientId}, FinalOpts};
	_ ->
	    {error, failed}
    end;
dhcpv6_resp_ia(_, _, _) ->
    {error, failed}.

dhcpv6_resp_opts(?D6O_NAME_SERVERS, V, Opts) ->
    Opts#{'DNS-Server-IPv6-Address' => V};
dhcpv6_resp_opts(?D6O_SIP_SERVERS_ADDR, V, Opts) ->
    Opts#{'SIP-Servers-IPv6-Address-List' => V};
dhcpv6_resp_opts(Opt, V, Opts)
  when Opt =:= lease;
       Opt =:= renewal;
       Opt =:= rebinding ->
    set_time(Opt, V, Opts);
dhcpv6_resp_opts(_K, _V, Opts) ->
    Opts.

dhcpv6_resp_opts(Opts) ->
    Now = erlang:system_time(second),
    maps:fold(fun dhcpv6_resp_opts/3, #{'Base-Time' => Now}, Opts).
