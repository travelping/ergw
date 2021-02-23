%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw).

-behavior(gen_statem).

%% API
-export([start_link/1]).
-export([start_socket/2, start_ip_pool/2,
	 connect_sx_node/2,
	 attach_tdf/2, attach_protocol/5]).
-export([handler/2, config/0]).
-export([get_plmn_id/0, get_node_id/0, get_accept_new/0]).
-export([system_info/0, system_info/1, system_info/2]).
-export([i/0, i/1, i/2]).

-ignore_xref([start_link/1, config/0, i/0, i/1, i/2]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-export([ready/0]).

-ifdef(TEST).
-export([start/1, wait_till_ready/0]).
-else.
-export([wait_till_ready/0]).
-ignore_xref([wait_till_ready/0]).
-endif.

-include_lib("kernel/include/logger.hrl").
-include("include/ergw.hrl").

-define(SERVER, ?MODULE).

-record(protocol_key, {socket, protocol}).
-record(protocol, {key, name, handler, options}).

%%====================================================================
%% API
%%====================================================================

-ifdef(TEST).
start(Config) ->
    gen_statem:start({local, ?SERVER}, ?MODULE, [Config], []).
-endif.

start_link(Config) ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [Config], []).

%% get global PLMN Id (aka MCC/MNC)
get_plmn_id() ->
    {ok, #{mcc := MCC, mnc := MNC}} = application:get_env(ergw, plmn_id),
    {MCC, MNC}.

get_node_id() ->
    {ok, Id} = application:get_env(ergw, node_id),
    Id.
get_accept_new() ->
    {ok, Value} = application:get_env(ergw, accept_new),
    Value.

system_info() ->
    [{K, system_info(K)} || K <- [plmn_id, node_id, accept_new]].

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
    ok = ergw_config:put(accept_new, New),
    Old;
system_info(Key, Value) ->
    error(badarg, [Key, Value]).

%%
%% Initialize a new PFCP, GTPv1/v2-c or GTPv1-u socket
%%
start_socket(Name, #{type := Type} = Opts) ->
    ergw_socket_sup:new(Name, Type, Opts).

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
attach_protocol(Socket, Name, Protocol, Handler, Opts) ->
    Key = #protocol_key{socket = Socket, protocol = Protocol},
    case code:ensure_loaded(Handler) of
	{module, _} ->
	    Meta = Handler:config_meta(),
	    true = ergw_config:validate_config([], Meta, Opts),
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

config() ->
    gen_server:call(?SERVER, config).

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

wait_till_ready() ->
    ok = gen_statem:call(?SERVER, wait_till_ready, infinity).

ready() ->
    gen_statem:call(?SERVER, ready).

%%%===================================================================
%%% gen_statem callbacks
%%%===================================================================

callback_mode() -> [handle_event_function].

init([Config]) ->
    process_flag(trap_exit, true),
    Now = erlang:monotonic_time(),

    ets:new(?SERVER, [ordered_set, named_table, public,
		      {keypos, 2}, {read_concurrency, true}]),

    Pid = proc_lib:spawn_link(fun startup/0),
    {ok, startup, #{init => Now, config => Config, startup => Pid}}.

handle_event({call, From}, wait_till_ready, ready, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, _From}, wait_till_ready, _State, _Data) ->
    {keep_state_and_data, [postpone]};

handle_event({call, From}, ready, State, _Data) ->
    Reply = {reply, From, State == ready},
    {keep_state_and_data, [Reply]};

handle_event({call, From}, config, _, #{config := Config}) ->
    Reply = {reply, From, Config},
    {keep_state_and_data, [Reply]};

handle_event(info, {'EXIT', Pid, ok}, startup,
	     #{init := Now, config := Config, startup := Pid} = Data) ->
    ergw_config:apply(Config),
    ?LOG(info, "ergw: ready to process requests, cluster started in ~w ms",
	 [erlang:convert_time_unit(erlang:monotonic_time() - Now, native, millisecond)]),
    {next_state, ready, maps:remove(startup, Data)};

handle_event(info, {'EXIT', Pid, Reason}, startup, #{startup := Pid}) ->
    ?LOG(critical, "cluster support failed to start with ~0p", [Reason]),
    init:stop(1),
    {stop, {shutdown, Reason}};

handle_event(Event, Info, _State, _Data) ->
    ?LOG(error, "~p: ~w: handle_event(~p, ...): ~p", [self(), ?MODULE, Event, Info]),
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ergw_cluster:stop(),
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

startup() ->
    %% undocumented, see stdlib's shell.erl
    case init:notify_when_started(self()) of
	started ->
	    ok;
	_ ->
	    init:wait_until_started()
    end,
    exit(ergw_cluster:start()).
