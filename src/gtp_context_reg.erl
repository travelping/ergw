%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_context_reg).

-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([register_new/1, register/1, update/2, unregister/1,
	 register/3, unregister/2,
	 lookup_key/2, lookup_keys/2,
	 lookup_teid/2, lookup_teid/3, lookup_teid/4,
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

lookup_key(#gtp_port{name = Name}, Key) ->
    RegKey = {Name, Key},
    case ets:lookup(?SERVER, RegKey) of
	[{RegKey, Pid}] ->
	    Pid;
	_ ->
	    undefined
    end.

lookup_keys(_, []) ->
    throw({error, not_found});
lookup_keys(Port, [H|T]) ->
    case lookup_key(Port, H) of
	Pid when is_pid(Pid) ->
	    Pid;
	_ ->
	    lookup_keys(Port, T)
    end.

lookup_teid(#gtp_port{type = Type} = Port, TEI) ->
    lookup_teid(Port, Type, TEI).

lookup_teid(Port, Type, TEI)
  when is_atom(Type) ->
    lookup_key(Port, {teid, Type, TEI});
lookup_teid(#gtp_port{type = Type} = Port, IP, TEI)
  when is_tuple(IP) andalso (size(IP) == 4 orelse size(IP) == 8) ->
    lookup_teid(Port, Type, IP, TEI).

lookup_teid(Port, Type, IP, TEI) ->
    lookup_key(Port, {teid, Type, IP, TEI}).

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

register(#context{} = Context) ->
    gen_server:call(?SERVER, {register, Context}).

register_new(#context{} = Context) ->
    gen_server:call(?SERVER, {register_new, Context}).

register(#gtp_port{name = Name}, Key, Context) when is_pid(Context) ->
    gen_server:call(?SERVER, {register, {Name, Key}, Context}).

update(#context{} = OldContext, #context{} = NewContext) ->
    gen_server:call(?SERVER, {update, OldContext, NewContext}).

unregister(#context{} = Context) ->
    gen_server:call(?SERVER, {unregister, Context}).

unregister(#gtp_port{name = Name}, Key) ->
    gen_server:call(?SERVER, {unregister, {Name, Key}}).

all() ->
    ets:tab2list(?SERVER).

await_unreg(Key) ->
    gen_server:call(?SERVER, {await_unreg, Key}, 1000).

%%====================================================================
%% TEI registry
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

    case lookup_teid(Port, TEI) of
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

handle_call({register, Context}, {Pid, _Ref}, State) ->
    Keys = context2keys(Context),
    handle_add_keys(fun ets:insert/2, Keys, Pid, State);

handle_call({register_new, Context}, {Pid, _Ref}, State) ->
    Keys = context2keys(Context),
    handle_add_keys(fun ets:insert_new/2, Keys, Pid, State);

handle_call({register, Key, Pid}, _From, State) ->
    handle_add_keys(fun ets:insert/2, [Key], Pid, State);

handle_call({update, OldContext, NewContext}, {Pid, _Ref}, State) ->
    DelKeys = context2keys(OldContext),
    AddKeys = context2keys(NewContext),
    Delete = ordsets:subtract(DelKeys, AddKeys),
    Insert = ordsets:subtract(AddKeys, DelKeys),
    case ets:insert_new(?SERVER, [{Key, Pid} || Key <- Insert]) of
	true ->
	    lists:foreach(fun(Key) -> delete_key(Key, Pid) end, Delete),
	    NKeys = ordsets:union(ordsets:subtract(get_pid(Pid, State), Delete), Insert),
	    {reply, ok, update_pid(Pid, NKeys, State)};
	false ->
	    {reply, {error, duplicate}, State}
    end;

handle_call({unregister, #context{} = Context}, {Pid, _Ref}, State0) ->
    Keys = context2keys(Context),
    State = delete_keys(Keys, Pid, State0),
    {reply, ok, State};

handle_call({unregister, Key}, {Pid, _Ref}, State0) ->
    State = delete_keys([Key], Pid, State0),
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

handle_add_keys(Fun, Keys, Pid, State) ->
    case Fun(?SERVER, [{Key, Pid} || Key <- Keys]) of
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
	[{Key, Pid}] ->
	    ets:take(?SERVER, Key);
	Other ->
	    Other
    end.

context2keys(#context{
		context_id         = ContextId,
		control_port       = #gtp_port{name = CntlPortName},
		local_control_tei  = LocalCntlTEI,
		remote_control_ip  = RemoteCntlIP,
		remote_control_tei = RemoteCntlTEI,
		data_port          = #gtp_port{name = DataPortName},
		local_data_tei     = LocalDataTEI,
		remote_data_ip     = RemoteDataIP,
		remote_data_tei    = RemoteDataTEI}) ->
    ordsets:from_list(
      [{CntlPortName, {teid, 'gtp-c', LocalCntlTEI}},
       {DataPortName, {teid, 'gtp-u', LocalDataTEI}},
       {CntlPortName, {teid, 'gtp-c', RemoteCntlIP, RemoteCntlTEI}},
       {DataPortName, {teid, 'gtp-u', RemoteDataIP, RemoteDataTEI}}]
      ++ [{CntlPortName, ContextId} || ContextId /= undefined]).
