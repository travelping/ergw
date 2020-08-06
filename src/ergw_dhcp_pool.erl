%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_dhcp_pool).

-behavior(gen_server).

-compile([{parse_transform, cut}]).

%% API
-export([start_ip_pool/2, send_pool_request/2, wait_pool_response/1, release/1, ip/1, opts/1]).
-export([start_link/3, start_link/4]).
-export([validate_options/1, validate_option/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-record(pool, {id, socket, servers}).
-record(state, {name, ipv4, ipv6, outstanding}).
%% -record(lease, {ip, client_id}).

-include_lib("kernel/include/logger.hrl").
-include_lib("dhcp/include/dhcp.hrl").

-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

-define(ZERO_IPv4, {0,0,0,0}).
-define(ZERO_IPv6, {0,0,0,0,0,0,0,0}).
-define(UE_INTERFACE_ID, {0,0,0,0,0,0,0,1}).

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

release({_, Server, {IP, _}, SrvId, _Opts}) ->
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

handle_call({get, _ClientId, IP, PrefixLen, _ReqOpts}, _From, State) ->
    Error = {unsupported, {IP, PrefixLen}},
    {reply, {error, Error}, State};

handle_call(Request, _From, State) ->
    ?LOG(warning, "handle_call: ~p", [Request]),
    {reply, error, State}.

handle_cast({release, IP, SrvId}, State) ->
    dhcpv4_release(IP, SrvId, State),
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

dhcpv4_init_f(ClientId, ReqIP, PrefixLen, ReqOpts, #pool{servers = Srvs} = Pool) ->
    Srv = choose_server(Srvs),
    Opts = dhcpv4_opts(ClientId, ReqIP, PrefixLen, ReqOpts),
    case dhcpv4_discover(Pool, Srv, Opts) of
	#dhcp{} = Offer ->
	    dhcpv4_request(Pool, ClientId, Opts, Offer);
	Other ->
	    Other
    end.

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
	{ok, #dhcp{options = #{?DHO_DHCP_MESSAGE_TYPE := ?DHCPOFFER}} = Answer} ->
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
	{ok, #dhcp{options = #{?DHO_DHCP_MESSAGE_TYPE := Type}} = Answer}
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
dhcpv4_resp_opts(_K, _V, Opts) ->
    Opts.

dhcpv4_resp_opts(Opts) ->
    maps:fold(fun dhcpv4_resp_opts/3, #{}, Opts).
