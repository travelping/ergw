%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_apns).

-behaviour(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_link/0, all/0, apn/1, handler/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {tid :: ets:tid()}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

all() ->
    ets:tab2list(?SERVER).

apn(APN) ->
    ets:lookup(?SERVER, {apn, APN}).

handler(Socket, Proto, APN) ->
    Key = {spa, Socket, Proto, APN},
    ets:lookup(?SERVER, Key).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    TID = ets:new(?SERVER, [ordered_set, named_table, public,
			    {keypos, 1}, {read_concurrency, true}]),
    load_config(TID),
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

load_config(TID) ->
    {ok, Routes} = application:get_env(apns),
    lists:foreach(load_apn(TID, _), Routes).

load_apn(TID, {APN, Opts})
  when is_list(APN), is_list(Opts) ->
    case lists:keytake(protocols, 1, Opts) of
	{value, {_, Protocols}, APNOpts}
	  when is_list(Protocols) ->
	    lists:foreach(load_protocol(TID, APN, _, APNOpts), Protocols);
	_ ->
	    lager:error("invalid value for protocols on APN ~s: ~p, ~p", [APN])
    end;
load_apn(_TID, {APN, _Opts}) ->
    lager:error("invalid setting on APN ~s", [APN]).

load_protocol(TID, APN, {Proto, ProtoOpts}, APNOpts)
  when is_atom(Proto), is_list(ProtoOpts) ->
    ets:insert(TID, {{apn, APN}, APNOpts}),
    case lists:keytake(handler, 1, ProtoOpts) of
	{value, {_, Handler}, HandlerOpts0}
	  when is_atom(Handler), is_list(HandlerOpts0) ->
	    case lists:keytake(sockets, 1, HandlerOpts0) of
		{value, {_, Sockets}, HandlerOpts}
		  when is_list(Sockets) ->
		    lists:foreach(load_sockets(TID, APN, Proto, Handler, _, HandlerOpts), Sockets);
		_ ->
		    lager:warning("no or invalid sockets for APN ~s, protocol ~s", [APN, Proto])
	    end;
	_ ->
	    lager:error("invalid value for handler on APN ~s, protocol ~s", [APN, Proto])
    end;
load_protocol(_TIP, APN, _Protocol, _APNOpts) ->
    lager:error("invalid protocol setting on APN ~s", [APN]).

load_sockets(TID, APN, Proto, Handler, Socket, HandlerOpts) ->
    Key = {spa, Socket, Proto, APN},
    ets:insert(TID, {Key, Handler, HandlerOpts}).
