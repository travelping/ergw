%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_reg).

-behaviour(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_link/0]).
-export([register/3, register_new/3, update/4, unregister/3,
	 lookup/1, select/1, global_lookup/1,
	 await_unreg/1]).
-export([register_name/3, unregister_name/2, whereis_name/1]).
-export([all/0]).

-ignore_xref([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include("include/ergw.hrl").

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

lookup(#context_key{id = {Type, _, _}} = Key)
  when Type == imei; Type == imsi ->
    case global_lookup(Key) of
	[Value|_] ->
	    Value;
	_ ->
	    undefined
    end;
lookup(Key) when is_tuple(Key) ->
    case ets:lookup(?SERVER, Key) of
	[{Key, Value}] ->
	    Value;
	_ ->
	    undefined
    end.

select(Key) ->
    ets:select(?SERVER, [{{Key, '$1'},[],['$1']}]).

register_name(Name, Handler, Pid) ->
    register_new([Name], Handler, Pid).

unregister_name(Name, Handler) ->
    unregister([Name], Handler, self()).

whereis_name(Name) ->
    case select(Name) of
	[{_, Pid}] when is_pid(Pid) ->
	    Pid;
	_Other ->
	    undefined
    end.

register(Keys, Handler, Pid)
  when is_list(Keys), is_atom(Handler), is_pid(Pid) ->
    register(fun ets:insert/2, Keys, Handler, Pid).

register_new(Keys, Handler, Pid)
  when is_list(Keys), is_atom(Handler), is_pid(Pid) ->
    register(fun ets:insert_new/2, Keys, Handler, Pid).

update(Delete, Insert, Handler, Pid)
  when is_list(Delete), is_list(Insert), is_atom(Handler), is_pid(Pid) ->
    RegV = {Handler, Pid},
    [global_del_key(DKey, RegV) || DKey <- Delete],
    [global_add_key(IKey, RegV) || IKey <- Insert],

    ets_delete_objects(?SERVER, mk_reg_objects(Delete, Handler, Pid)),
    add_keys(fun ets:insert/2, Insert, Handler, Pid).

unregister(Keys, Handler, Pid)
  when is_list(Keys), is_atom(Handler), is_pid(Pid) ->
    RegV = {Handler, Pid},
    [global_del_key(Key, RegV) || Key <- Keys],

    ets_delete_objects(?SERVER, mk_reg_objects(Keys, Handler, Pid)),
    ok.

all() ->
    ets:tab2list(?SERVER).

await_unreg(Key) ->
    gen_server:call(?SERVER, {await_unreg, Key}, 1000).

%%%===================================================================
%%% regine callbacks
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),

    ets:new(?SERVER, [bag, named_table, public, {keypos, 1},
		      {decentralized_counters, true},
		      {write_concurrency, true}, {read_concurrency, true}]),
    {ok, #{}}.

handle_call({await_unreg, Pid}, From, State0)
  when is_pid(Pid) ->
    link(Pid),
    State = maps:update_with(Pid, fun(V) -> [From|V] end, [From], State0),
    {noreply, State}.

handle_cast({link, Pid}, State) ->
    link(Pid),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, _Reason}, State) ->
    Notify = maps:get(Pid, State, []),
    proc_lib:spawn(
      fun() ->
	      Objs = ets:lookup(?SERVER, Pid),
	      ets_delete_objects(?SERVER, Objs ++ mk_reg_pids(Objs)),
	      [global_del_key(Key, {Handler, Pid}) || {_, {Handler, Key}} <- Objs],
	      [gen_server:reply(From, ok) || From <- Notify],
	      ok
      end),

    {noreply, maps:remove(Pid, State)}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

register(InsFun, Keys, Handler, Pid) ->
    RegV = {Handler, Pid},
    [global_add_key(Key, RegV) || Key <- Keys],
    Return = add_keys(InsFun, Keys, Handler, Pid),

    %% if we are registering for a different Pid (not self()), then the
    %% process could have crashed and existed already when we arrive here.
    %% By doing the link this late, we make sure that a `EXIT` signal will
    %% be delivered to the monitor in any case.
    case self() of
	Pid -> link(whereis(?SERVER));
	_   -> gen_server:cast(?SERVER, {link, Pid})
    end,

    Return.

mk_reg_keys(Keys, Handler, Pid) ->
    [{Key, {Handler, Pid}} || Key <- Keys].

mk_reg_objects([], _Handler, _Pid) ->
    [];
mk_reg_objects([Key|T], Handler, Pid) ->
    [{Key, {Handler, Pid}}, {Pid, {Handler, Key}} | mk_reg_objects(T, Handler, Pid)].

mk_reg_pids(Objs) ->
    [{Pid, {Handler, Key}} || {Key, {Handler, Pid}} <- Objs].

ets_delete_objects(Tab, Objects) ->
    [ets:delete_object(Tab, Obj) || Obj <-Objects].

add_keys(InsFun, Keys, Handler, Pid) ->
    Insert = mk_reg_keys(Keys, Handler, Pid),
    ets:insert(?SERVER, mk_reg_pids(Insert)),
    case InsFun(?SERVER, Insert) of
	true  ->
	    ok;
	false ->
	    ets_delete_objects(?SERVER, mk_reg_pids(Insert)),
	    {error, duplicate}
    end.

global_add_key(#context_key{id = {Type, _, _}} = Key, RegV)
  when Type == imei; Type == imsi ->
    gtp_context_reg_vnode:put(<<"context">>, Key, RegV);
global_add_key(_, _) ->
    ok.

global_del_key(#context_key{id = {Type, _, _}} = Key, RegV)
  when Type == imei; Type == imsi ->
    gtp_context_reg_vnode:delete(<<"context">>, Key, RegV);
global_del_key(_, _) ->
    ok.

global_lookup(Key) ->
    case gtp_context_reg_vnode:get(<<"context">>, Key) of
	{ok, #{reason := finished, result := Result}} ->
	    lists:usort([Value || {_Location, {ok, Value}} <- Result]);
	_ ->
	    []
    end.
