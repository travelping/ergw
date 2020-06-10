%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw).

-behavior(gen_server).

%% API
-export([start_link/0]).
-export([start_socket/1, start_ip_pool/2,
	 connect_sx_node/2,
	 attach_tdf/2, attach_protocol/5]).
-export([handler/2]).
-export([load_config/1]).
-export([get_plmn_id/0, get_node_id/0, get_accept_new/0]).
-export([system_info/0, system_info/1, system_info/2]).
-export([i/0, i/1, i/2]).

-ignore_xref([start_link/0, i/0, i/1, i/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-record(state, {tid :: ets:tid()}).

-record(protocol_key, {socket, protocol}).
-record(protocol, {key, name, handler, options}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link(?MODULE, [], []).

%% get global PLMN Id (aka MCC/MNC)
get_plmn_id() ->
    [{config, plmn_id, MCC, MNC}] = ets:lookup(?SERVER, plmn_id),
    {MCC, MNC}.
get_node_id() ->
    {ok, Id} = application:get_env(ergw, node_id),
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

load_config([]) ->
    ok;
load_config([{plmn_id, {MCC, MNC}} | T]) ->
    true = ets:insert(?SERVER, {config, plmn_id, MCC, MNC}),
    load_config(T);
load_config([{node_id, Value} | T]) ->
    true = ets:insert(?SERVER, {config, node_id, Value}),
    load_config(T);
load_config([{accept_new, Value} | T]) ->
    true = ets:insert(?SERVER, {config, accept_new, Value}),
    load_config(T);
load_config([{Key, Value} | T])
  when Key =:= path_management;
       Key =:= node_selection;
       Key =:= nodes;
       Key =:= ip_pools;
       Key =:= apns;
       Key =:= charging;
       Key =:= proxy_map;
       Key =:= teid ->
    ok = application:set_env(ergw, Key, Value),
    load_config(T);
load_config([_ | T]) ->
    load_config(T).

%%
%% Initialize a new PFCP, GTPv1/v2-c or GTPv1-u socket
%%
start_socket({_Name, #{type := Type} = Opts}) ->
    ergw_socket_sup:new(Type, Opts).

%%
%% start IP_POOL instance
%%
start_ip_pool(Name, Options) ->
    ergw_ip_pool:start_ip_pool(Name, Options).

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
	lists:foldl(fun({{seid, _}, {_, Pid}}, Mem) ->
			    {memory, M} = erlang:process_info(Pid, memory),
			    Mem + M;
		       (_, Mem) ->
			    Mem
		    end, 0, gtp_context_reg:all()),
    {context, MemUsage}.


%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    TID = ets:new(?SERVER, [ordered_set, named_table, public,
			    {keypos, 2}, {read_concurrency, true}]),
    true = ets:insert(TID, {config, plmn_id, <<"001">>, <<"01">>}),
    true = ets:insert(TID, {config, accpept_new, true}),
    {ok, #state{tid = TID}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
