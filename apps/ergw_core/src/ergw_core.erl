%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_core).

-compile({parse_transform, cut}).

-behavior(gen_server).

%% API
-export([start_link/0, start_node/1, validate_options/1]).
-export([setopts/2,
	 add_socket/2,
	 add_handler/2,
	 add_ip_pool/2,
	 add_sx_node/2]).
-export([handler/2]).
-export([get_plmn_id/0, get_node_id/0, get_accept_new/0]).
-export([system_info/0, system_info/1, system_info/2]).
-export([i/0, i/1, i/2]).

-ignore_xref([start_link/0, i/0, i/1, i/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").
-include("include/ergw.hrl").

-define(SERVER, ?MODULE).

-record(protocol_key, {socket, protocol}).
-record(protocol, {key, name, handler, options}).

%%====================================================================
%% API
%%====================================================================

start_node(Config) ->
    case ergw_cluster:is_ready() of
	true ->
	    Cnf = validate_options(Config),
	    ok = load_config(Cnf),
	    true = ets:insert(?SERVER, {state, is_running, true}),
	    ok;
	false ->
	    {error, cluster_not_ready}
    end.

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% get global PLMN Id (aka MCC/MNC)
get_plmn_id() ->
    [{config, plmn_id, MCC, MNC}] = ets:lookup(?SERVER, plmn_id),
    {MCC, MNC}.
get_node_id() ->
    {ok, Id} = application:get_env(ergw_core, node_id),
    Id.
get_accept_new() ->
    [{config, accept_new, Value}] = ets:lookup(?SERVER, accept_new),
    Value.

system_info() ->
    [{K,system_info(K)} || K <- [plmn_id, node_id, accept_new]].

system_info(accept_new) ->
    get_accept_new();
system_info(node_id) ->
    get_node_id();
system_info(plmn_id) ->
    get_plmn_id();
system_info(Arg) ->
    error(badarg, [Arg]).

system_info(accept_new, New) when is_boolean(New) ->
    Old = get_accept_new(),
    true = ets:insert(?SERVER, {config, accept_new, New}),
    Old;
system_info(Key, Value) ->
    error(badarg, [Key, Value]).

setopts(Opt, Value) ->
    when_running(
      fun() -> do_setopts(Opt, Value) end).

do_setopts(node_selection, Opts) ->
    ergw_inet_res:load_config(Opts).

%%
%% Initialize a new PFCP, GTPv1/v2-c or GTPv1-u socket
%%
add_socket(Name, Opts0) ->
    Opts = ergw_socket:validate_options(Name, Opts0),
    when_running(
      fun() -> ergw_socket:add_socket(Name, Opts) end).

%%
%% add a protocol handler
%%
add_handler(Name, Opts0) ->
    Opts = ergw_context:validate_options(Name, Opts0),
    when_running(
      fun() -> do_add_handler(Name, Opts) end).

do_add_handler(_Name, #{protocol := ip, nodes := Nodes} = Opts0) ->
    Opts = maps:without([protocol, nodes], Opts0),
    lists:foreach(attach_tdf(_, Opts), Nodes);

do_add_handler(Name, #{handler  := Handler,
		    protocol := Protocol,
		    sockets  := Sockets} = Opts0) ->
    Opts = maps:without([handler, sockets], Opts0),
    lists:foreach(attach_protocol(_, Name, Protocol, Handler, Opts), Sockets).

%%
%% start IP_POOL instance
%%
add_ip_pool(Name, Opts0) ->
    Opts = ergw_ip_pool:validate_options(Name, Opts0),
    when_running(
      fun() -> ergw_ip_pool:start_ip_pool(Name, Opts) end).

add_sx_node(Name, Opts0) ->
    Opts = ergw_sx_node:validate_options(Opts0),
    when_running(
      fun() -> do_add_sx_node(Name, Opts) end).

do_add_sx_node(default, _) ->
    ok;
do_add_sx_node(Name, Opts) ->
    connect_sx_node(Name, Opts).

%%
%% start a TDF instance
%%
%% attach_tdf/2
attach_tdf(SxNode, Opts) ->
    Result = ergw_sx_node_reg:lookup(SxNode),
    attach_tdf(SxNode, Opts, Result, true).

%% attach_tdf/4
attach_tdf(_SxNode, Opts, {ok, Pid} = Result, _) when is_pid(Pid) ->
    ergw_sx_node:attach_tdf(Pid, Opts),
    Result;
attach_tdf(_SxNode, _Opts, Result, false) ->
    Result;
attach_tdf(SxNode, #{node_selection := NodeSelections} = Opts, _, true) ->
    Result =
	(fun NodeLookup([]) ->
		 {error, not_found};
	     NodeLookup([NodeSelection | NextSelection]) ->
		 case ergw_node_selection:lookup(SxNode, NodeSelection) of
		     {Node, IP4, IP6} ->
			 ergw_sx_node_mngr:connect(Node, NodeSelection, IP4, IP6);
		     _Other ->
			 ?LOG(warning, "TDF lookup for ~p failed ~p", [SxNode, _Other]),
			 NodeLookup(NextSelection)
		 end
	 end)(NodeSelections),
    attach_tdf(SxNode, Opts, Result, false).

%%
%% connect UPF node
%%
connect_sx_node(_Node, #{connect := false}) ->
    ok;
connect_sx_node(Node, #{raddr := IP4} = _Opts) when tuple_size(IP4) =:= 4 ->
    ergw_sx_node_mngr:connect(Node, default, [IP4], []);
connect_sx_node(Node, #{raddr := IP6} = _Opts) when tuple_size(IP6) =:= 8 ->
    ergw_sx_node_mngr:connect(Node, default, [], [IP6]);
connect_sx_node(Node, #{node_selection := NodeSelect} = Opts) ->
    case ergw_node_selection:lookup(Node, NodeSelect) of
	{_, IP4, IP6} ->
	    ergw_sx_node_mngr:connect(Node, NodeSelect, IP4, IP6);
	_Other ->
	    %% TBD:
	    erlang:error(badarg, [Node, Opts])
    end.

%%
%% attach a GTP protocol (Gn, S5, S2a...) to a socket
%%
attach_protocol(Socket, Name, Protocol, Handler, Opts0) ->
    Key = #protocol_key{socket = Socket, protocol = Protocol},
    case code:ensure_loaded(Handler) of
	{module, _} ->
	    Opts = Handler:validate_options(Opts0),
	    P = #protocol{
		   key = Key,
		   name = Name,
		   handler = Handler,
		   options = Opts},
	    case ets:insert_new(?SERVER, P) of
		true ->
		    {ok, Key};
		false ->
		    throw({error, {duplicate, Socket, Protocol}})
	    end;
	_ ->
	    throw({error, {invalid_handler, Handler}})
    end.

handler(Socket, Protocol) ->
    Key = #protocol_key{socket = Socket, protocol = Protocol},
    case ets:lookup(?SERVER, Key) of
	[#protocol{handler = Handler, options = Opts}] ->
	    {ok, Handler, Opts};
	_ ->
	    {error, not_found}
    end.

i() ->
    lists:map(fun i/1, [memory]).

i(memory) ->
    {memory, lists:map(fun(X) -> i(memory, X) end, [socket, path, context])}.

i(memory, socket) ->
    MemUsage =
	lists:foldl(fun({_, Pid, _}, Mem) ->
			    {memory, M} = erlang:process_info(Pid, memory),
			    Mem + M
		    end, 0, ergw_socket_reg:all()),
    {socket, MemUsage};
i(memory, path) ->
    MemUsage =
	lists:foldl(fun({_, Pid, _}, Mem) ->
			    {memory, M} = erlang:process_info(Pid, memory),
			    Mem + M
		    end, 0, gtp_path_reg:all()),
    {path, MemUsage};

i(memory, context) ->
    MemUsage =
	lists:foldl(fun({#seid_key{}, {_, Pid}}, Mem) ->
			    {memory, M} = erlang:process_info(Pid, memory),
			    Mem + M;
		       (_, Mem) ->
			    Mem
		    end, 0, gtp_context_reg:all()),
    {context, MemUsage}.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(is_opts(X), (is_list(X) orelse is_map(X))).

-define(DefaultOptions, [{plmn_id, {<<"001">>, <<"01">>}},
			 {node_id, undefined},
			 {teid, {0, 0}},
			 {accept_new, true}
			]).

validate_options(Config) when ?is_opts(Config) ->
    ergw_core_config:validate_options(fun validate_option/2, Config, ?DefaultOptions).

validate_option(plmn_id, {MCC, MNC} = Value) ->
    case validate_mcc_mcn(MCC, MNC) of
       ok -> Value;
       _  -> throw({error, {options, {plmn_id, Value}}})
    end;
validate_option(node_id, Value) when is_binary(Value) ->
    Value;
validate_option(node_id, Value) when is_list(Value) ->
    binary_to_atom(iolist_to_binary(Value));
validate_option(accept_new, Value) when is_boolean(Value) ->
    Value;
validate_option(teid, Value) ->
    ergw_tei_mngr:validate_option(Value);
validate_option(_Opt, Value) ->
    Value.

validate_mcc_mcn(MCC, MNC)
  when is_binary(MCC) andalso size(MCC) == 3 andalso
       is_binary(MNC) andalso (size(MNC) == 2 orelse size(MNC) == 3) ->
    try {binary_to_integer(MCC), binary_to_integer(MNC)} of
	_ -> ok
    catch
	error:badarg -> error
    end;
validate_mcc_mcn(_, _) ->
    error.

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

init([]) ->
    ets:new(?SERVER, [ordered_set, named_table, public,
		      {keypos, 2}, {read_concurrency, true}]),
    load_config(#{plmn_id => {<<"001">>, <<"001">>}, accept_new => false}),
    {ok, state}.

handle_call(Request, _From, State) ->
    ?LOG(error, "handle_call: unknown ~p", [Request]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    ?LOG(error, "handle_cast: unknown ~p", [Msg]),
    {noreply, State}.

handle_info(Info, State) ->
    ?LOG(error, "handle_info: unknown ~p, ~p", [Info, State]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

load_config(#{plmn_id := {MCC, MNC}, accept_new := Value}) ->
    true = ets:insert(?SERVER, {config, plmn_id, MCC, MNC}),
    true = ets:insert(?SERVER, {config, accept_new, Value}),
    ok.

when_running(Fun) ->
    case ets:lookup(?SERVER, is_running) of
	[{state, is_running, true}] ->
	    Fun();
	_ ->
	    {error, node_not_running}
    end.
