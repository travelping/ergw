%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_reg).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([register/3, register_new/3, update/4, unregister/3,
	 lookup/1,
	 match_key/2, match_keys/2,
	 await_unreg/1]).
-export([all/0]).
-export([alloc_tei/1]).

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

match_key(#gtp_port{name = Name}, Key) ->
    RegKey = {Name, Key},
    ets:select(?SERVER, [{{RegKey, '$1'},[],['$1']}]).

match_keys(_, []) ->
    throw({error, not_found});
match_keys(Port, [H|T]) ->
    case match_key(Port, H) of
	[_|_] = Match ->
	    Match;
	_ ->
	    match_keys(Port, T)
    end.

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

%%====================================================================
%% TEI registry
%% TODO: move this out of here
%%====================================================================

-define(MAX_TRIES, 32).

alloc_tei(Port) ->
    alloc_tei(Port, ?MAX_TRIES).

alloc_tei(_Port, 0) ->
    {error, no_tei};
alloc_tei(#gtp_port{name = Name} = Port, Cnt) ->
    Key = {Name, tei},

    %% 32bit maxint = 4294967295
    TEI = ets:update_counter(?SERVER, Key, {2, 1, 4294967295, 1}, {Key, 0}),

    case lookup(gtp_context:port_teid_key(Port, TEI)) of
	undefined ->
	    {ok, TEI};
	_ ->
	    alloc_tei(Port, Cnt - 1)
    end.

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
	Other ->
	    Other
    end.
