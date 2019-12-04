%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sx_node_mngr).

-behaviour(gen_server).

%% API
-export([start_link/0, connect/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

connect(Node, IP4, IP6) ->
    case ergw_sx_node_reg:lookup(Node) of
	{ok, _Pid} = Result ->
	    Result;
	_ ->
	    gen_server:call(?SERVER, {connect, Node, IP4, IP6})
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    {ok, #state{}}.

%% serialize lockup/new
handle_call({connect, Node, IP4, IP6}, _From, State) ->
    case ergw_sx_node_reg:lookup(Node) of
	{ok, _Pid} = Result ->
	    {reply, Result, State};
	_ ->
	    Result = ergw_sx_node_sup:new(Node, IP4, IP6),
	    {reply, Result, State}
    end;
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Request, State) ->
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
