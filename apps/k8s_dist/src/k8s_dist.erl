%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(k8s_dist).

%% API
-export([nodes/0]).

-ignore_xref([nodes/0]).

-include_lib("kernel/include/logger.hrl").

-define(TIMEOUT, 5000).
-define(JSON_OPTS, [return_maps, {labels, binary}]).

%%%===================================================================
%%% API
%%%===================================================================

nodes() ->
    {ok, Token} = file:read_file(<<"/run/secrets/kubernetes.io/serviceaccount/token">>),
    {ok, Namespace} = file:read_file(<<"/run/secrets/kubernetes.io/serviceaccount/namespace">>),

    CaCertFile = <<"/run/secrets/kubernetes.io/serviceaccount/ca.crt">>,
    Opts = #{connect_timeout => ?TIMEOUT,
	     protocols => [http2],
	     transport => tls,
	     tls_opts => [{cacertfile, CaCertFile}]
	    },

    [Cluster, _] = binary:split(atom_to_binary(node()), <<$@>>),

    {ok, ConnPid} = gun:open("kubernetes.default", 443, Opts),
    {ok, _Protocol} = gun:await_up(ConnPid),

    Resource = [<<"/api/v1/namespaces/">>, Namespace, <<"/pods">>],
    Query =
	uri_string:compose_query(
	  [{<<"labelSelector">>, [<<"erlang.org/cluster=">>, Cluster]}
	   %%,{"timeoutSeconds", "10"}
	  ]),
    Path = uri_string:recompose(#{path => Resource, query => Query}),
    Headers = headers(Token),

    StreamRef = gun:get(ConnPid, Path, Headers),

    Nodes =
	case gun:await(ConnPid, StreamRef) of
	    {response, fin, _Status, Headers} ->
		[];
	    {response, nofin, 200, _Headers} ->
		Names = read_body(ConnPid, StreamRef),
		node_names(erl_dist_mode(), Cluster, Names);
	    {response, nofin, _Status, _Headers} ->
		[]
	end,

    gun:close(ConnPid),
    Nodes.

%%%=========================================================================
%%%  internal functions
%%%=========================================================================

%% from OTPs kernel/src/inet_config.erl
erl_dist_mode() ->
    case init:get_argument(sname) of
	{ok,[[_SName]]} -> shortnames;
	_ ->
	    case init:get_argument(name) of
		{ok,[[_Name]]} -> longnames;
		_ -> nonames
	    end
    end.

headers(Token) ->
    [{<<"authorization">>, iolist_to_binary(["Bearer ", Token])},
     {<<"accept">>, <<"application/json">>}].

read_body(ConnPid, StreamRef) ->
    case gun:await_body(ConnPid, StreamRef) of
	{ok, Body} ->
	    case jsx:decode(Body, ?JSON_OPTS) of
		#{<<"apiVersion">> := <<"v1">>,
		  <<"kind">> := <<"PodList">>,
		  <<"items">> := Items} = _P when is_list(Items) ->
		    lists:foldl(fun read_pods/2, [], Items);
		Other ->
		    ?LOG(error, "k8s API processing failed for ~0p", [Other]),
		    []
	    end;
	Other ->
	    ?LOG(error, "k8s API failed with ~0p", [Other]),
	    []
    end.

read_pods(#{<<"metadata">> := #{<<"name">> := Name}}, Nodes) ->
    [Name|Nodes];
read_pods(_, Nodes) ->
    Nodes.

node_names(longnames, Cluster, Names) ->
    [binary_to_atom(<<Cluster/binary, $@, Name/binary>>) || Name <- Names];
node_names(shortnames, Cluster, Names) ->
    [begin
	 [SName|_] =  binary:split(Name, <<$.>>),
	 binary_to_atom(<<Cluster/binary, $@, SName/binary>>)
     end || Name <- Names];
node_names(_, _, _) ->
    [].
