%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_core).

-compile({parse_transform, cut}).

-behavior(gen_statem).

%% API
-export([start_link/0, start_node/1]).
-export([wait_till_running/0, is_running/0]).
-export([setopts/2,
	 add_socket/2,
	 add_handler/2,
	 add_ip_pool/2,
	 add_sx_node/2,
	 set_gtp_peer_opts/2,
	 add_apn/2,
	 add_charging_profile/2,
	 add_charging_rule/2,
	 add_charging_rulebase/2
	]).
-export([handler/2]).
-export([get_plmn_id/0, get_node_id/0, get_accept_new/0, get_teid_config/0]).
-export([system_info/0, system_info/1, system_info/2]).
-export([i/0, i/1, i/2]).

-ifdef(TEST).
-export([start/0, validate_options/1]).
-endif.

-ignore_xref([start_link/0, i/0, i/1, i/2, is_running/0, get_teid_config/0]).

%% gen_statem callbacks
-export([callback_mode/0, init/1, handle_event/4,
	 terminate/3, code_change/4]).

-include_lib("kernel/include/logger.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("ergw_core_config.hrl").
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
	    gen_statem:call(?SERVER, {start, Cnf});
	false ->
	    {error, cluster_not_ready}
    end.

-ifdef(TEST).
start() ->
    gen_statem:start({local, ?SERVER}, ?MODULE, [], []).
-endif.

start_link() ->
    gen_statem:start_link({local, ?SERVER}, ?MODULE, [], []).

wait_till_running() ->
    ok = gen_statem:call(?SERVER, wait_till_running, infinity).

is_running() ->
    gen_statem:call(?SERVER, is_running).

%% get global PLMN Id (aka MCC/MNC)
get_plmn_id() ->
    {ok, #{mcc := MCC, mnc := MNC}} = ergw_core_config:get([plmn_id], undefined),
    {MCC, MNC}.
get_node_id() ->
    {ok, Id} = ergw_core_config:get([node_id], <<"ergw">>),
    Id.
get_accept_new() ->
    {ok, Value} = ergw_core_config:get([accept_new], true),
    Value.
get_teid_config() ->
    {ok, Value} = ergw_core_config:get([teid], undefined),
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
    ok = ergw_core_config:put(accept_new, New),
    Old;
system_info(Key, Value) ->
    error(badarg, [Key, Value]).

setopts(node_selection = What, Opts0) ->
    Opts = ergw_node_selection:validate_options(Opts0),
    gen_statem:call(?SERVER, {setopts, What, Opts});
setopts(sx_defaults = What, Opts0) ->
    Opts = ergw_sx_node:validate_defaults(Opts0),
    gen_statem:call(?SERVER, {setopts, What, Opts});
setopts(required_upff = What, Opts) when is_record(Opts, up_function_features) ->
    gen_statem:call(?SERVER, {setopts, What, Opts});
setopts(path_management = What, Opts0) ->
    Opts = gtp_path:validate_options(Opts0),
    gen_statem:call(?SERVER, {setopts, What, Opts});
setopts(proxy_map = What, Opts0) ->
    Opts = gtp_proxy_ds:validate_options(Opts0),
    gen_statem:call(?SERVER, {setopts, What, Opts});
setopts(What, Opts) ->
    error(badarg, [What, Opts]).

%%
%% Initialize a new PFCP, GTPv1/v2-c or GTPv1-u socket
%%
add_socket(Name, Opts0) ->
    Opts = ergw_socket:validate_options(Name, Opts0),
    gen_statem:call(?SERVER, {add_socket, Name, Opts}).

%%
%% add a protocol handler
%%
add_handler(Name, Opts0) ->
    Opts = ergw_context:validate_options(Name, Opts0),
    gen_statem:call(?SERVER, {add_handler, Name, Opts}).

do_add_handler(_Name, #{protocol := ip, nodes := Nodes} = Opts) ->
    lists:foreach(attach_tdf(_, Opts), Nodes);

do_add_handler(Name, #{handler  := Handler,
		       protocol := Protocol,
		       sockets  := Sockets} = Opts) ->
    lists:foreach(attach_protocol(_, Name, Protocol, Handler, Opts), Sockets).

%%
%% start IP_POOL instance
%%
add_ip_pool(Name, Opts0) ->
    Opts = ergw_ip_pool:validate_options(Name, Opts0),
    gen_statem:call(?SERVER, {add_ip_pool, Name, Opts}).

%%
%% add a new UP node
%%
add_sx_node(Name, Opts0) ->
    Opts = ergw_sx_node:validate_options(Name, Opts0),
    gen_statem:call(?SERVER, {add_sx_node, Name, Opts}).

do_add_sx_node(Name, Opts) ->
    ergw_sx_node:add_sx_node(Name, Opts).

%%
%% add a new GTP peer
%%
set_gtp_peer_opts(Peer, Opts0) ->
    Opts = gtp_path:validate_options(Peer, Opts0),
    gen_statem:call(?SERVER, {set_gtp_peer_opts, Peer, Opts}).

do_set_gtp_peer_opts(Peer, Opts) ->
    gtp_path:set_peer_opts(Peer, Opts).

add_apn(Name0, Opts0) ->
    {Name, Opts} = ergw_apn:validate_options({Name0, Opts0}),
    gen_statem:call(?SERVER, {add_apn, Name, Opts}).

add_charging_profile(Name, Opts0) ->
    Opts = ergw_charging:validate_profile(Name, Opts0),
    gen_statem:call(?SERVER, {add_charging_profile, Name, Opts}).

add_charging_rule(Name, Opts0) ->
    Opts = ergw_charging:validate_rule(Name, Opts0),
    gen_statem:call(?SERVER, {add_charging_rule, Name, Opts}).

add_charging_rulebase(Name, Opts0) ->
    Opts = ergw_charging:validate_rulebase(Name, Opts0),
    gen_statem:call(?SERVER, {add_charging_rulebase, Name, Opts}).

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
			 ergw_sx_node_reg:connect(Node, NodeSelection, IP4, IP6);
		     _Other ->
			 ?LOG(warning, "TDF lookup for ~p failed ~p", [SxNode, _Other]),
			 NodeLookup(NextSelection)
		 end
	 end)(NodeSelections),
    attach_tdf(SxNode, Opts, Result, false).

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
		    erlang:error(badarg, [duplicate, Socket, Protocol])
	    end;
	_ ->
	    erlang:error(badarg, [invalid_handler, Handler])
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

-define(DefaultOptions, #{plmn_id => #{mcc => <<"001">>, mnc => <<"01">>},
			  node_id => undefined,
			  teid => #{prefix => 0, len => 0},
			  accept_new => true}).

validate_options(Opts) when is_map(Opts) ->
    ergw_core_config:mandatory_keys([node_id], Opts),
    ergw_core_config:validate_options(fun validate_option/2, Opts, ?DefaultOptions);
validate_options(Opts) when is_list(Opts) ->
    validate_options(ergw_core_config:to_map(Opts));
validate_options(Opts) ->
    erlang:error(badarg, [Opts]).

validate_option(plmn_id, #{mcc := MCC, mnc := MNC} = Opts) ->
    case validate_mcc_mcn(MCC, MNC) of
	ok -> Opts;
	_  -> erlang:error(badarg, [plmn_id, Opts])
    end;
validate_option(plmn_id, Opts) when is_list(Opts) ->
    validate_option(plmn_id, ergw_core_config:to_map(Opts));
validate_option(node_id, Value) when is_binary(Value) ->
    Value;
validate_option(node_id, Value) when is_list(Value) ->
    to_atom(iolist_to_binary(Value));
validate_option(accept_new, Value) when is_boolean(Value) ->
    Value;
validate_option(teid, Value) ->
    ergw_tei_mngr:validate_option(Value);
validate_option(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

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

callback_mode() -> [handle_event_function].

init([]) ->
    ets:new(?SERVER, [ordered_set, named_table, public,
		      {keypos, 2}, {read_concurrency, true}]),
    load_config(?DefaultOptions),
    {ok, startup, data}.

handle_event({call, From}, wait_till_running, running, _Data) ->
    {keep_state_and_data, [{reply, From, ok}]};
handle_event({call, _From}, wait_till_running, _State, _Data) ->
    {keep_state_and_data, [postpone]};

handle_event({call, From}, is_running, State, _Data) ->
    Reply = {reply, From, State == running},
    {keep_state_and_data, [Reply]};

handle_event({call, From}, {start, Config}, _State, Data) ->
    load_config(Config),
    true = ets:insert(?SERVER, {state, is_running, true}),
    {next_state, running, Data, [{reply, From, ok}]};

handle_event({call, From}, {add_socket, Name, Opts}, running, _) ->
    Reply = ergw_socket:add_socket(Name, Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {add_handler, Name, Opts}, running, _) ->
    Reply = do_add_handler(Name, Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {add_ip_pool, Name, Opts}, running, _) ->
    Reply = ergw_ip_pool:start_ip_pool(Name, Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {add_sx_node, Name, Opts}, running, _) ->
    Reply = do_add_sx_node(Name, Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {set_gtp_peer_opts, Peer, Opts}, running, _) ->
    Reply = do_set_gtp_peer_opts(Peer, Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {add_apn, Name, Opts}, running, _) ->
    Reply = ergw_apn:add(Name, Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {add_charging_profile, Name, Opts}, running, _) ->
    Reply = ergw_charging:add_profile(Name, Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {add_charging_rule, Name, Opts}, running, _) ->
    Reply = ergw_charging:add_rule(Name, Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {add_charging_rulebase, Name, Opts}, running, _) ->
    Reply = ergw_charging:add_rulebase(Name, Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {setopts, node_selection, Opts}, running, _) ->
    Reply = ergw_inet_res:load_config(Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {setopts, sx_defaults, Opts}, running, _) ->
    Reply = ergw_sx_node:set_defaults(Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {setopts, required_upff, Opts}, running, _) ->
    Reply = ergw_sx_node:set_required_upff(Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {setopts, path_management, Opts}, running, _) ->
    Reply = gtp_path:setopts(Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, {setopts, proxy_map, Opts}, running, _) ->
    Reply = gtp_proxy_ds:setopts(Opts),
    {keep_state_and_data, [{reply, From, Reply}]};

handle_event({call, From}, _, State, _) when State /= running ->
    {keep_state_and_data, [{reply, From, {error, node_not_running}}]};

handle_event(Event, Info, _State, _Data) ->
    ?LOG(error, "~p: ~w: handle_event(~p, ...): ~p", [self(), ?MODULE, Event, Info]),
    keep_state_and_data.

terminate(_Reason, _State, _Data) ->
    ok.

code_change(_OldVsn, State, Data, _Extra) ->
    {ok, State, Data}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

load_config(#{plmn_id := PlmnId,
	      node_id := NodeId,
	      teid := TEID,
	      accept_new := New}) ->

    ok = ergw_core_config:put(plmn_id, PlmnId),
    ok = ergw_core_config:put(accept_new, New),
    ok = ergw_core_config:put(node_id, NodeId),
    ok = ergw_core_config:put(teid, TEID),
    ok.

to_atom(V) when is_binary(V) ->
    try
        binary_to_existing_atom(V)
    catch
        _:_ ->
            binary_to_atom(V)
    end.
