%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(k8s_epmd).

-behaviour(gen_statem).

%% epmd API
-export([start_link/0, names/0, names/1, register_node/3,
	 port_please/3, address_please/3, listen_port_please/2]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4, terminate/3, code_change/4]).

-ignore_xref([start_link/0, names/0, names/1, register_node/3,
	      port_please/3, address_please/3, listen_port_please/2]).

-define(SERVER, ?MODULE).

-define(TIMEOUT, 5000).
-define(HTTP_TIMEOUT, 60 * 1000). % milliseconds
-define(JSON_OPTS, [return_maps, {labels, binary}]).

-record(host, {pod, ip, nodes}).
-record(node, {port, restart_count}).

%% uncomment this if tracing is wanted
-define(DEBUG, true).
-ifdef(DEBUG).
-define(trace(T), erlang:display({?MODULE, node(), cs(), T})).
  cs() ->
     {_Big, Small, Tiny} = erlang:timestamp(),
     (Small rem 100) * 100 + (Tiny div 10000).
-else.
-define(trace(_), ok).
-endif.

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).

names() ->
    call(?SERVER, names).

names(Host) ->
    call(?SERVER, {names, to_bin(Host)}).

register_node(_Name, _Port, _Driver) ->
    %% this is called way before we can invoke the k8s API
    ?trace(#{func => register_node, name => _Name, port => _Port, driver => _Driver}),
    {ok, -1}.

port_please(Name, Host, Timeout) ->
    call(?SERVER, {port_please, to_bin(Name), to_bin(Host)}, Timeout).

address_please(Name, Host, AddressFamily) ->
    call(?SERVER, {address_please, to_bin(Name), to_bin(Host), AddressFamily}).

listen_port_please(_Name, _Host) ->
    %% this is called way before we can invoke the k8s API
    Port = list_to_integer(os:getenv("ERL_DIST_PORT", "0")),
    ?trace(#{func => listen_port_please, name => _Name, host => _Host, port => Port}),
    {ok, Port}.

call(Server, Request) ->
    call(Server, Request, 5000).

call(Server, Request, Timeout) ->
    case whereis(Server) of
	Pid when is_pid(Pid) ->
	    ?trace(#{server => Server, pid => Pid, request => Request}),
	    gen_statem:call(Pid, Request, Timeout);
	_ ->
	    ?trace(#{server => Server, pid => failed, request => Request}),
	    {error, nxdomain}
    end.

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

callback_mode() -> [handle_event_function, state_enter].

init([]) ->
    process_flag(trap_exit, true),

    Self = self(),
    spawn(fun() ->
		  ?trace(#{gun => started, epmd => Self, msg => "starting gun..."}),
		  Res = application:ensure_all_started(gun),
		  ?trace(#{gun => started, res => Res}),
		  Self ! {start, Res}
	  end),

    {State, Actions} = check_connect(),
    {ok, State, #{}, Actions}.

handle_event(state_timeout, connect, init, Data) ->
    {State, Actions} = check_connect(),
    {next_state, State, Data, Actions};

handle_event(enter, _, connecting, _) ->
    {ok, Token} = file:read_file(<<"/run/secrets/kubernetes.io/serviceaccount/token">>),
    {ok, Namespace} = file:read_file(<<"/run/secrets/kubernetes.io/serviceaccount/namespace">>),

    Resource = [<<"/api/v1/namespaces/">>, Namespace, <<"/pods">>],

    Selector = {<<"labelSelector">>, [<<"erlang.org/cluster">>]},

    CaCertFile = <<"/run/secrets/kubernetes.io/serviceaccount/ca.crt">>,
    Opts = #{connect_timeout => ?TIMEOUT,
	     protocols => [http2],
	     http2_opts =>
		 #{keepalive => 5000},
	     transport => tls,
	     tls_opts => [{cacertfile, CaCertFile}]
	    },

    {ok, ConnPid} = gun:open("kubernetes.default", 443, Opts),
    ?trace(#{state => connecting, event => enter, conn => ConnPid}),
    MRef = monitor(process, ConnPid),

    Data = #{registry => #{},
	     token => Token,
	     names => erl_dist_mode(),
	     selector => Selector,
	     resource => Resource,
	     version => 0,
	     pending => <<"">>,

	     conn => ConnPid,
	     mref => MRef
	    },
    {keep_state, Data};

handle_event(info, {'DOWN', MRef, process, ConnPid, _Reason} = _Ev, _State,
	     #{mref := MRef, conn := ConnPid}) ->
    ?trace(#{state => _State, event => 'DOWN', reason => _Reason, conn => ConnPid}),
    {stop, normal};

handle_event(info, {gun_up, ConnPid, _Protocol}, connecting,
	     #{token := Token, selector := Selector, resource := Resource,
	       conn := ConnPid} = Data) ->
    Query = uri_string:compose_query([Selector]),
    Path = uri_string:recompose(#{path => Resource, query => Query}),
    Headers = headers(Token),

    StreamRef = gun:get(ConnPid, Path, Headers),
    {next_state, {loading, init}, Data#{stream => StreamRef}};

handle_event(enter, _, {watch, init} = _State, #{pending := Pending})
  when Pending =/= <<>> ->
    ?trace(#{state => _State, event => enter, pending => Pending}),
    {stop, {error, incomplete}};

handle_event(enter, _, {watch, init},
	     #{token := Token,  selector := Selector, resource := Resource,
	       version := Version, conn := ConnPid} = Data) ->
    Query =
	uri_string:compose_query(
	  [Selector,
	   {"resourceVersion", integer_to_list(Version)},
	   {"watch", "true"}
	   %%{"allowWatchBookmarks", "true"}
	   %%,{"timeoutSeconds", "10"}
	  ]),
    Path = uri_string:recompose(#{path => Resource, query => Query}),
    Headers = headers(Token),

    StreamRef = gun:get(ConnPid, Path, Headers),
    {keep_state, Data#{stream => StreamRef}};

handle_event(enter, _, _, _) ->
    keep_state_and_data;

handle_event(info, {gun_response, ConnPid, _StreamRef, nofin, 200, _Headers}, {loading, init},
	     #{conn := ConnPid} = Data) ->
    {next_state, {loading, data}, Data};

handle_event(info, {gun_response, ConnPid, _StreamRef, fin, 200, _Headers}, {loading, _} = State,
	     #{conn := ConnPid} = Data0) ->
    Data = handle_api_data(State, <<>>, Data0),
    {next_state, {watch, init}, Data};

handle_event(info, {gun_data, ConnPid, StreamRef, fin, Bin}, {loading, data} = State,
	     #{conn := ConnPid, stream := StreamRef} = Data0) ->
    Data = handle_api_data(State, Bin, Data0),
    {next_state, {watch, init}, Data};

handle_event(info, {gun_response, ConnPid, StreamRef, nofin, 200, _Headers}, {watch, init},
	     #{conn := ConnPid, stream := StreamRef} = Data) ->
    {next_state, {watch, data}, Data};

handle_event(info, {gun_response, ConnPid, StreamRef, fin, _Status, _Headers}, _State,
	     #{conn := ConnPid, stream := StreamRef}) ->
    ?trace(#{state => _State, event => fin, status => _Status, conn => ConnPid}),
    {stop, normal};

handle_event(info, {gun_data, ConnPid, StreamRef, nofin, Bin}, State,
	     #{conn := ConnPid, stream := StreamRef} = Data0) ->
    Data = handle_api_data(State, Bin, Data0),
    {keep_state, Data};

handle_event(info, {gun_data, ConnPid, StreamRef, fin, Bin}, {watch, data} = State,
	     #{conn := ConnPid, stream := StreamRef} = Data0) ->
    Data = handle_api_data(State, Bin, Data0),
    ?trace(#{state => State, event => fin, conn => ConnPid}),
    {next_state, {watch, init}, maps:remove(stream, Data)};

handle_event(info, {gun_down, ConnPid, _Protocol, _Status, _Streams},
	     _State, #{conn := ConnPid}) ->
    ?trace(#{state => _State, event => close, status => _Status, conn => ConnPid}),
    {stop, normal};

handle_event({call, From}, names, _, #{registry := Registry}) ->
    {keep_state_and_data, [{reply, From, Registry}]};

handle_event({call, _}, _Ev, State, _) when is_atom(State) ->
    ?trace(#{state => State, event => _Ev, what => postpone}),
    {keep_state_and_data, [postpone]};
handle_event({call, _}, _Ev, {Phase, _} = _State, _) when Phase /= watch ->
    ?trace(#{state => _State, event => _Ev, what => postpone}),
    {keep_state_and_data, [postpone]};

handle_event({call, From}, {names, Host} = _Ev, _State, #{registry := Registry})
  when is_map_key(Host, Registry) ->
    #host{nodes = Nodes} = maps:get(Host, Registry),
    Reply = {ok, [{Name, Port} || {Name, #node{port = Port}} <- maps:to_list(Nodes)]},
    ?trace(#{state => _State, event => _Ev, reply => Reply}),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {names, _Host} = _Ev, _State, _) ->
    ?trace(#{state => _State, event => _Ev, reply => {error, nxdomain}}),
    {keep_state_and_data, [{reply, From, {error, nxdomain}}]};

handle_event({call, From}, {port_please, Name, Host} = _Ev, _State, #{registry := Registry}) ->
    #host{nodes = Nodes} = maps:get(Host, Registry, #host{nodes = #{}}),
    Reply =
	case maps:get(Name, Nodes, undefined) of
	    #node{port = Port} ->
		{port, Port, 5};
	    _ ->
		noport
	end,
    ?trace(#{state => _State, event => _Ev, reply => Reply}),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {address_please, Name, Host, _AddressFamily} = _Ev,
	     _State, #{registry := Registry}) ->
    #host{ip = IP, nodes = Nodes} = maps:get(Host, Registry, #host{nodes = #{}}),
    Reply =
	case maps:get(Name, Nodes, undefined) of
	    #node{port = Port} ->
		{ok, IP, Port, 5};
	    _ ->
		{error, nxdomain}
	end,
    ?trace(#{state => _State, event => _Ev, reply => Reply}),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event(_Ev, _Msg, _State, _Data) ->
    ?trace(#{state => _State, event => _Ev, msg => _Msg}),
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%=========================================================================
%%%  internal functions
%%%=========================================================================

to_bin(Host) when is_list(Host) ->
    list_to_binary(Host);
to_bin(Host) when is_atom(Host) ->
    atom_to_binary(Host);
to_bin(Host) when is_binary(Host) ->
    Host.

check_connect() ->
    case lists:keyfind(gun, 1, application:which_applications()) of
	{gun, _, _} ->
	    {connecting, []};
	_ ->
	    {init, [{state_timeout, 100, connect}]}
    end.

name_arg() ->
    case init:get_argument(sname) of
	{ok,[[SName]]} -> {short, SName};
	_ ->
	    case init:get_argument(name) of
		{ok,[[Name]]} -> {long, Name};
		_ -> {none, "nonode"}
	    end
    end.

%% clustername() ->
%%     {_, Name} = name_arg(),
%%     [Cluster|_] = string:split(Name, "@"),
%%     list_to_binary(Cluster).

%% from OTPs kernel/src/inet_config.erl
erl_dist_mode() ->
    {Type, _} = name_arg(),
    Type.

name2host(#{names := short}, Name) ->
    [SName|_] =  binary:split(Name, <<$.>>),
    SName;
name2host(_, Name) ->
    Name.

headers(Token) ->
    [{<<"authorization">>, iolist_to_binary(["Bearer ", Token])},
     {<<"accept">>, <<"application/json">>}].

handle_api_data(State, Bin, #{pending := In} = Data) ->
    handle_api_data(State, Data#{pending := <<In/binary, Bin/binary>>}).

handle_api_data(State, #{pending := In} = Data0) ->
    case binary:split(In, <<$\n>>) of
	[In] -> %% no newline,
	    Data0;
	[Head, Tail] ->
	    Data = process_api_data(State, Head, Data0),
	    handle_api_data(State, Data#{pending => Tail})
    end.

process_api_data(State, Bin, Data0) ->
    case jsx:decode(Bin, ?JSON_OPTS) of
	Object when is_map(Object) ->
	    process_api_object(State, Object, Data0);

	_ ->
	    Data0
    end.

process_api_object({watch, _}, #{<<"type">> := Type,
				 <<"object">> :=
				     #{<<"kind">> := <<"Pod">>,
				       <<"metadata">> := Meta} = Pod}, Data) ->
    handle_pod_event(Type, Pod, set_version(Meta, Data));

process_api_object({loading, _}, #{<<"kind">> := <<"PodList">>,
				   <<"items">> := Pods,
				   <<"metadata">> := Meta}, Data) ->
    lists:foldl(
      fun(Pod, Acc) -> handle_pod_event(<<"ADDED">>, Pod, Acc) end,
      set_version(Meta, Data), Pods).

set_version(#{<<"resourceVersion">> := Version}, Data) ->
    Data#{version => erlang:binary_to_integer(Version)}.

handle_pod_event(Type, #{<<"metadata">> :=
			     #{<<"name">> := PodName,
			       <<"labels">> :=
				   #{<<"erlang.org/cluster">> := Cluster}}} = Pod, Data) ->
    ?trace(#{pod => PodName, cluster => Cluster}),
    Host = name2host(Data, PodName),
    maps:update_with(
      registry, fun (Elem) -> handle_pod_ev(Type, PodName, Host, Cluster, Pod, Elem) end, Data).

handle_pod_ev(<<"DELETED">> = _Type, PodName, HostName, Name, _, Registry)
  when is_map_key(HostName, Registry) ->
    RegOut =
	case maps:get(HostName, Registry) of
	    #host{pod = PodName} = Host ->
		case maps:remove(Name, Host#host.nodes) of
		    Nodes when map_size(Nodes) == 0 ->
			maps:remove(HostName, Registry);
		    Nodes ->
			maps:put(HostName, Host#host{nodes = Nodes}, Registry)
		end;
	    _ ->
		Registry
	end,
    ?trace(#{type => _Type, hostname => HostName, cluster => Name, registry => RegOut}),
    RegOut;

handle_pod_ev(_Type, PodName, HostName, Name,
	      #{<<"status">> :=
		    #{<<"containerStatuses">> := Statuses, <<"podIP">> := PodIP},
		<<"spec">> := #{<<"containers">> := Containers}} = _Pod, Registry) ->
    ?trace(#{type => _Type, name => PodName, hostname => HostName, cluster => Name}),
    {ok, IP} = inet:parse_address(binary_to_list(PodIP)),
    lists:foldl(
      fun(Pod, Acc) -> handle_container_ev(PodName, HostName, Name, IP, Statuses, Pod, Acc) end,
      Registry, Containers);
handle_pod_ev(_Type, _PodName, _HostName, _Name, _Pod, Registry) ->
    ?trace(#{type => _Type, name => _PodName,
	     hostname => _HostName, cluster => _Name, what => unhandled}),
    Registry.

handle_container_ev(PodName, HostName, Cluster, IP, Statuses,
		    #{<<"name">> := ContainerName, <<"ports">> := Ports}, Registry) ->
    RestartCount = restart_count(ContainerName, Statuses),
    lists:foldl(
      fun(#{<<"containerPort">> := Port,
	    <<"name">> := <<"erlang-org-dist">>,
	    <<"protocol">> := <<"TCP">>}, Reg) ->
	      Node = #node{port = Port, restart_count = RestartCount},
	      UpdF = fun(#host{pod = PName, nodes = Nodes} = Host) when PodName == PName ->
			     Host#host{ip = IP, nodes = Nodes#{Cluster => Node}};
			(Host) ->
			     Host
		     end,
	      maps:update_with(HostName, UpdF, #host{ip = IP, nodes = #{Cluster => Node}}, Reg);
	 (_V, N) ->
	      N
      end, Registry, Ports);
handle_container_ev(_, _, _, _, _, _, Registry) ->
    Registry.

restart_count(ContainerName, Statuses) ->
    Pred = fun(#{<<"name">> := Name}) -> Name =:= ContainerName end,
    case lists:search(Pred, Statuses) of
	{value, #{<<"restartCount">> := RestartCount}} ->
	    RestartCount;
	_ ->
	    0
    end.
