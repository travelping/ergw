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
	 attach_protocol/4, attach_data_path/2, attach_vrf/3]).
-export([handler/2, vrf/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-record(state, {tid :: ets:tid()}).

-record(protocol_key, {socket, protocol}).
-record(protocol, {key, handler, options}).
-record(route, {key, vrf, options}).

%%====================================================================
%% API
%%====================================================================

start_link() ->
    gen_server:start_link(?MODULE, [], []).

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
attach_protocol(Socket, Protocol, Handler, Opts0) ->
    Key = #protocol_key{socket = Socket, protocol = Protocol},
    case code:ensure_loaded(Handler) of
	{module, _} ->
	    Opts = Handler:validate_options(Opts0),
	    P = #protocol{
		   key = Key,
		   handler = Handler,
		   options = Opts},
	    case ets:insert_new(?SERVER, P) of
		true ->
		    {ok, Key};
		false ->
		    {error, {duplicate, Socket, Protocol}}
	    end;
	_ ->
	    {error, {invalid_handler, Handler}}
    end.

attach_data_path(#protocol_key{} = Key, DataPath) ->
    case ets:lookup(?SERVER, Key) of
	[#protocol{options = Opts0}] ->
	    Opts = maps:update_with(data_paths, fun(DPs) -> [DataPath | DPs] end, {data_paths, [DataPath]}, Opts0),
	    ets:update_element(?SERVER, Key, {#protocol.options, Opts}),
	    ok;
	_ ->
	    {error, {invalid, Key}}
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
	    {error, duplicate}
    end.

handler(Socket, Protocol) ->
    Key = #protocol_key{socket = Socket, protocol = Protocol},
    case ets:lookup(?SERVER, Key) of
	[#protocol{handler = Handler, options = Opts}] ->
	    {ok, Handler, Opts};
	_ ->
	    {error, not_found}
    end.

vrf(APN) ->
    case ets:lookup(?SERVER, APN) of
	[#route{vrf = VRF, options = Options}] ->
	    {ok, {VRF, Options}};
	_ ->
	    {error, not_found}
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    TID = ets:new(?SERVER, [ordered_set, named_table, public,
			    {keypos, 2}, {read_concurrency, true}]),
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
