%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw).

-behavior(gen_server).

%% API
-export([start_link/0]).
-export([start_socket/2, start_vrf/2,
	 attach_protocol/5, attach_data_path/2, attach_vrf/3]).
-export([handler/2, vrf/1]).
-export([load_config/1]).
-export([get_plmn_id/0, get_accept_new/0]).
-export([system_info/0, system_info/1, system_info/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-record(state, {tid :: ets:tid()}).

-record(protocol_key, {socket, protocol}).
-record(protocol, {key, name, handler, options}).
-record(route, {key, vrf, options}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link(?MODULE, [], []).

%% get global PLMN Id (aka MCC/MNC)
get_plmn_id() ->
    [{config, plmn_id, MCC, MNC}] = ets:lookup(?SERVER, plmn_id),
    {MCC, MNC}.
get_accept_new() ->
    [{config, accept_new, Value}] = ets:lookup(?SERVER, accept_new),
    Value.

system_info() ->
    [{K,system_info(K)} || K <- [plmn_id, accept_new]].

system_info(accept_new) ->
    get_accept_new();
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
load_config([{accept_new, Value} | T]) ->
    true = ets:insert(?SERVER, {config, accept_new, Value}),
    load_config(T);
load_config([_ | T]) ->
    load_config(T).

%%
%% Initialize a new GTPv1/v2-c or GTPv1-u socket
%%
start_socket(Name, Options) ->
    gtp_socket:start_socket(Name, Options).

%%
%% start VRF instance
%%
start_vrf(Name, Options) ->
    vrf:start_vrf(Name, Options).

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

attach_data_path(#protocol_key{} = Key, DataPath) ->
    case ets:lookup(?SERVER, Key) of
	[#protocol{options = Opts0}] ->
	    Opts = maps:update_with(data_paths, fun(DPs) -> [DataPath | DPs] end, {data_paths, [DataPath]}, Opts0),
	    ets:update_element(?SERVER, Key, {#protocol.options, Opts}),
	    ok;
	_ ->
	    throw({error, {invalid, Key}})
    end.

attach_vrf(APN, VRF, Options0) ->
    Options =
	case vrf:get_opts(VRF) of
	    {ok, Opts} when is_map(Opts) ->
		maps:merge(Opts, Options0);
	    _Other ->
		Options0
	end,
    Route = #route{key = APN, vrf = VRF, options = Options},
    case ets:insert_new(?SERVER, Route) of
	true -> ok;
	false ->
	    throw({error, duplicate})
    end.

handler(Socket, Protocol) ->
    Key = #protocol_key{socket = Socket, protocol = Protocol},
    case ets:lookup(?SERVER, Key) of
	[#protocol{handler = Handler, options = Opts}] ->
	    {ok, Handler, Opts};
	_ ->
	    {error, not_found}
    end.

vrf_lookup(APN0) ->
    APN = (catch gtp_c_lib:normalize_labels(APN0)),
    case ets:lookup(?SERVER, APN) of
	[#route{vrf = VRF, options = Options}] ->
	    {ok, {VRF, Options}};
	_ ->
	    {error, not_found}
    end.

expand_apn(<<"gprs">>, APN) when length(APN) > 3 ->
    {ShortAPN, _} = lists:split(length(APN) - 3, APN),
    ShortAPN;
expand_apn(_, APN) ->
    {MCC, MNC} = get_plmn_id(),
    MNCpart = if (size(MNC) == 2) -> <<"mnc0", MNC/binary>>;
		 true             -> <<"mnc",  MNC/binary>>
	      end,
    APN ++ [MNCpart, <<"mcc", MCC/binary>>, <<"gprs">>].

vrf(APN) ->
    case vrf_lookup(APN) of
	{ok, _} = Result ->
	    Result;
	_ ->
	    case vrf_lookup(expand_apn(lists:last(APN), APN)) of
		{ok, _} = Result ->
		    Result;
		_ ->
		    vrf_lookup('_')
	    end
    end.

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
