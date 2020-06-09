%% Copyright 2015, Travelping GmbH <info@travelping.com>

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
	 lookup/1, select/1,
	 await_unreg/1]).
-export([register_name/2, unregister_name/1, whereis_name/1]).
-export([all/0]).

-ignore_xref([start_link/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------
-include("include/ergw.hrl").

-define(SERVER, ?MODULE).
-record(state, {pids, await_unreg}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

lookup(Key) when is_tuple(Key) ->
    case ets:lookup(?SERVER, Key) of
	[{Key, Value}] ->
	    Value;
	_ ->
	    undefined
    end.

select(Key) ->
    ets:select(?SERVER, [{{Key, '$1'},[],['$1']}]).

register_name(Name, Pid) ->
    gen_server:call(?SERVER, {register_name, Name, Pid}).

unregister_name(Name) ->
    gen_server:call(?SERVER, {unregister_name, Name}).

whereis_name(Name) ->
    gen_server:call(?SERVER, {whereis_name, Name}).

register(Keys, Handler, Pid)
  when is_list(Keys), is_atom(Handler), is_pid(Pid) ->
    gen_server:call(?SERVER, {register, Keys, Handler, Pid}).

register_new(Keys, Handler, Pid)
  when is_list(Keys), is_atom(Handler), is_pid(Pid) ->
    gen_server:call(?SERVER, {register_new, Keys, Handler, Pid}).

update(Delete, Insert, Handler, Pid)
  when is_list(Delete), is_list(Insert), is_atom(Handler), is_pid(Pid) ->
    gen_server:call(?SERVER, {update, Delete, Insert, Handler, Pid}).

unregister(Keys, Handler, Pid)
  when is_list(Keys), is_atom(Handler), is_pid(Pid) ->
    gen_server:call(?SERVER, {unregister, Keys, Handler, Pid}).

all() ->
    ets:tab2list(?SERVER).

await_unreg(Key) ->
    gen_server:call(?SERVER, {await_unreg, Key}, 1000).

%%%===================================================================
%%% regine callbacks
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),

    ets:new(?SERVER, [ordered_set, named_table, public, {keypos, 1}]),
    State = #state{
	       pids = #{},
	       await_unreg = #{}
	      },
    {ok, State}.

handle_call({register_name, Name, Pid}, _From, State) ->
    case ets:insert_new(?SERVER, {Name, Pid}) of
	true ->
	    link(Pid),
	    Keys = ordsets:add_element(Name, get_pid(Pid, State)),
	    {reply, yes, update_pid(Pid, Keys, State)};
	_ ->
	    {reply, no, State}
    end;

handle_call({unregister_name, Name}, _From, State) ->
    case ets:take(?SERVER, Name) of
	[{Name, Pid}] ->
	    unlink(Pid),
	    {reply, ok, delete_pid(Pid, State)};
	_ ->
	    {reply, ok, State}
    end;

handle_call({whereis_name, Name}, _From, State) ->
    case ets:lookup(?SERVER, Name) of
	[{Name, Pid}] ->
	    {reply, Pid, State};
	_ ->
	    {reply, undefined, State}
    end;

handle_call({register, Keys, Handler, Pid}, _From, State) ->
    handle_add_keys(fun ets:insert/2, Keys, Handler, Pid, State);

handle_call({register_new, Keys, Handler, Pid}, _From, State) ->
    handle_add_keys(fun ets:insert_new/2, Keys, Handler, Pid, State);

handle_call({update, Delete, Insert, Handler, Pid}, _From, State) ->
    lists:foreach(fun(Key) -> delete_key(Key, Pid) end, Delete),
    NKeys = ordsets:union(ordsets:subtract(get_pid(Pid, State), Delete), Insert),
    handle_add_keys(fun ets:insert/2, Insert, Handler, Pid, update_pid(Pid, NKeys, State));

handle_call({unregister, Keys, _Handler, Pid}, _From, State0) ->
    State = delete_keys(Keys, Pid, State0),
    {reply, ok, State};

handle_call({await_unreg, Pid}, From, #state{pids = Pids, await_unreg = AWait} = State0)
  when is_pid(Pid) ->
    case maps:is_key(Pid, Pids) of
	true ->
	    State = State0#state{
		      await_unreg =
			  maps:update_with(Pid, fun(V) -> [From|V] end, [From], AWait)},
	    {noreply, State};
	_ ->
	    {reply, ok, State0}
    end.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({'EXIT', Pid, _Reason}, State0) ->
    Keys = get_pid(Pid, State0),
    State = delete_keys(Keys, Pid, State0),
    {noreply, State}.

terminate(_Reason, _State) ->
	ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_pid(Pid, #state{pids = Pids}) ->
    maps:get(Pid, Pids, []).

update_pid(Pid, Keys, #state{pids = Pids} = State) ->
    State#state{pids = Pids#{Pid => Keys}}.

delete_pid(Pid, #state{pids = Pids} = State) ->
    notify_unregister(Pid, State#state{pids = maps:remove(Pid, Pids)}).

notify_unregister(Pid, #state{await_unreg = AWait} = State) ->
    Reply = maps:get(Pid, AWait, []),
    lists:foreach(fun(From) -> gen_server:reply(From, ok) end, Reply),
    State#state{await_unreg = maps:remove(Pid, AWait)}.

handle_add_keys(Fun, Keys, Handler, Pid, State) ->
    RegV = {Handler, Pid},
    case Fun(?SERVER, [{Key, RegV} || Key <- Keys]) of
	true ->
	    link(Pid),
	    NKeys = ordsets:union(Keys, get_pid(Pid, State)),
	    {reply, ok, update_pid(Pid, NKeys, State)};
	_ ->
	    {reply, {error, duplicate}, State}
    end.

delete_keys(Keys, Pid, State) ->
    lists:foreach(fun(Key) -> delete_key(Key, Pid) end, Keys),
    case ordsets:subtract(get_pid(Pid, State), Keys) of
	[] ->
	    unlink(Pid),
	    delete_pid(Pid, State);
	Rest ->
	    update_pid(Pid, Rest, State)
    end.

%% this is not the same a ets:take, the object will only
%% be delete if Key and Pid match.....
delete_key(Key, Pid) ->
    case ets:lookup(?SERVER, Key) of
	[{Key, {_, Pid}}] ->
	    ets:take(?SERVER, Key);
	[{Key, Pid}] ->
	    ets:take(?SERVER, Key);
	Other ->
	    Other
    end.
