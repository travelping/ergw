%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% simple implementation of 3GPP TS 29.598 Nudsf service
%% - functional API according to TS
%% - not optimized for anything

-module(ergw_nudsf_ets).

-behavior(gen_server).
-behavior(ergw_nudsf_api).

-compile({parse_transform, cut}).

%% API
-export([get_childspecs/1,
	 get/2, get/3,
	 search/1, search/2,
	 create/3, create/4,
	 put/3, put/4,
	 delete/2, delete/3,
	 all/0,
	 validate_options/1]).
-export([wipe/0]).

-ignore_xref([start_link/0]).

%% gen_server callbacks
-export([start_link/0, init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").

-define(SERVER, ?MODULE).
-record(entry, {key, meta, blocks}).

%%%=========================================================================
%%%  API
%%%=========================================================================

get_childspecs(_Config) ->
    [#{id       => ?MODULE,
       start    => {?MODULE, start_link, []},
       restart  => permanent,
       shutdown =>  5000,
       type     => worker,
       modules  => [?MODULE]}].

%% TS 29.598, 5.2.2.2 Query

get(record, RecordId) ->
    gen_server:call(?SERVER, {get, record, RecordId});

get(meta, RecordId) ->
    gen_server:call(?SERVER, {get, meta, RecordId});

get(blocks, RecordId) ->
    gen_server:call(?SERVER, {get, blocks, RecordId}).

get(block, RecordId, BlockId) ->
    gen_server:call(?SERVER, {get, block, RecordId, BlockId}).

%% TS 29.598, 5.2.2.2.6	Search

search(Filter) ->
    search(Filter, #{}).

search(Filter, Opts) ->
    gen_server:call(?SERVER, {search, Filter, Opts}).

%% TS 29.598, 5.2.2.3 Create

create(RecordId, Meta, Blocks) ->
    gen_server:call(?SERVER, {create, record, RecordId, Meta, Blocks}).

create(block, RecordId, BlockId, Block) ->
    gen_server:call(?SERVER, {create, block, RecordId, BlockId, Block}).

%% TS 29.598, 5.2.2.4 Update

put(record, RecordId, Meta, Blocks) ->
    gen_server:call(?SERVER, {put, record, RecordId, Meta, Blocks});

put(block, RecordId, BlockId, Block) ->
    gen_server:call(?SERVER, {put, block, RecordId, BlockId, Block}).

put(meta, RecordId, Meta) ->
    gen_server:call(?SERVER, {put, meta, RecordId, Meta}).

%% TS 29.598, 5.2.2.5 Delete

delete(record, RecordId) ->
    gen_server:call(?SERVER, {delete, record, RecordId}).

delete(block, RecordId, BlockId) ->
    gen_server:call(?SERVER, {delete, block, RecordId, BlockId}).

all() ->
    gen_server:call(?SERVER, all).

wipe() ->
    gen_server:call(?SERVER, wipe).

%%%===================================================================
%%% Options Validation
%%%===================================================================

validate_options(Values) ->
     ergw_config:validate_options(fun validate_option/2, Values, [], map).

validate_option(handler, Value) ->
    Value;
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

init([]) ->
    process_flag(trap_exit, true),
    ets:new(?SERVER, [ordered_set, named_table, public, {keypos, #entry.key}]),
    {ok, #{}}.

handle_call({get, record, RecordId}, _Form, State) ->
    Reply =
	case ets:lookup(?SERVER, RecordId) of
	    [#entry{meta = Meta, blocks = Blocks}] ->
		{ok, Meta, Blocks};
	    _ ->
		{error, not_found}
	end,
    {reply, Reply, State};

handle_call({get, meta, RecordId}, _Form, State) ->
    Reply =
	case ets:lookup(?SERVER, RecordId) of
	    [#entry{meta = Meta}] ->
		{ok, Meta};
	    _ ->
		{error, not_found}
	end,
    {reply, Reply, State};

handle_call({get, blocks, RecordId}, _Form, State) ->
    Reply =
	case ets:lookup(?SERVER, RecordId) of
	    [#entry{blocks = Blocks}] ->
		{ok, Blocks};
	    _ ->
		{error, not_found}
	end,
    {reply, Reply, State};

handle_call({get, block, RecordId, BlockId}, _Form, State) ->
    Reply =
	case ets:lookup(?SERVER, RecordId) of
	    [#entry{blocks = #{BlockId := Block}}] ->
		{ok, Block};
	    _ ->
		{error, not_found}
	end,
    {reply, Reply, State};

handle_call({search, Filter, Opts}, _Form, State) ->
    try
	ResM = ets:foldl(search(_, Filter, _), [], ?SERVER),
	Reply = search_reply(ResM, Opts),
	{reply, Reply, State}
    catch
	Class:Error:ST ->
	    ?LOG(error, "Nudsf search failed with ~p:~p (~p)",
		 [Class, Error, ST]),
	    {reply, {error, invalid_filter}, State}
    end;

handle_call({create, record, RecordId, Meta, Blocks}, _Form, State) ->
    Entry = #entry{key = RecordId, meta = Meta, blocks = Blocks},
    Reply =
	case ets:insert_new(?SERVER, Entry) of
	    true ->
		ok;
	    false ->
		{error, already_exists}
	end,
    {reply, Reply, State};

handle_call({create, block, RecordId, BlockId, Block}, _Form, State) ->
    Reply =
	case ets:lookup(?SERVER, RecordId) of
	    [#entry{blocks = #{BlockId := _}}] ->
		{error, already_exists};
	    [#entry{blocks = Blocks}] ->
		Update = {#entry.blocks, Blocks#{BlockId => Block}},
		ets:update_element(?SERVER, RecordId, Update),
		ok;
	    _ ->
		{error, not_found}
	end,
    {reply, Reply, State};

handle_call({put, record, RecordId, Meta, Blocks}, _Form, State) ->
    Update = [{#entry.meta, Meta}, {#entry.blocks, Blocks}],
    Reply =
	case ets:update_element(?SERVER, RecordId, Update) of
	    true -> ok;
	    false -> {error, not_found}
	end,
    {reply, Reply, State};

handle_call({put, meta, RecordId, Meta}, _Form, State) ->
    Update = [{#entry.meta, Meta}],
    Reply =
	case ets:update_element(?SERVER, RecordId, Update) of
	    true -> ok;
	    false -> {error, not_found}
	end,
    {reply, Reply, State};

handle_call({put, block, RecordId, BlockId, Block}, _Form, State) ->
    Reply =
	case ets:lookup(?SERVER, RecordId) of
	    [#entry{blocks = #{BlockId := _} = Blocks}] ->
		Update = {#entry.blocks, Blocks#{BlockId => Block}},
		ets:update_element(?SERVER, RecordId, Update),
		ok;
	    _ ->
		{error, not_found}
	end,
    {reply, Reply, State};

handle_call({delete, record, RecordId}, _Form, State) ->
    Reply =
	case ets:take(?SERVER, RecordId) of
	    [#entry{}] ->
		ok;
	    _ ->
		{error, not_found}
	end,
    {reply, Reply, State};

handle_call({delete, block, RecordId, BlockId}, _Form, State) ->
    Reply =
	case ets:lookup(?SERVER, RecordId) of
	    [#entry{blocks = #{BlockId := _} = Blocks}] ->
		Update = {#entry.blocks, maps:remove(BlockId, Blocks)},
		ets:update_element(?SERVER, RecordId, Update),
		ok;
	    _ ->
		{error, not_found}
	end,
    {reply, Reply, State};

handle_call(all, _From, State) ->
    Reply = ets:tab2list(?SERVER),
    {reply, Reply, State};

handle_call(wipe, _From, State) ->
    ets:delete_all_objects(?SERVER),
    {reply, ok, State};

handle_call(Request, _From, State) ->
    Reply = {error, {badarg, Request}},
    {reply, Reply, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%=========================================================================
%%%  internal functions
%%%=========================================================================

search_reply(ResM, #{count := true}) ->
    {length(ResM), []};
search_reply(ResM, #{range := Range} = Opts) ->
    Page = maps:get(page, Opts, 1),
    {ResL, _} = lists:split(Range, lists:nthtail((Range - 1) * Page, ResM)),
    {length(ResM), ResL};
search_reply(ResM, _Opts) ->
    {length(ResM), ResM}.

search(#entry{key = Key, meta = Meta}, Expr, Acc) ->
    case search_expr(Expr, maps:get(tags, Meta, #{})) of
	true  -> [Key | Acc];
	false -> Acc
    end.

search_expr(#{'cond' := Cond, units := Units}, Tags) ->
    search_expr(Cond, Units, Tags);

search_expr(#{tag := Tag, value := Value} = Cond, Tags) ->
    search_cond(maps:get(Tag, Tags, undefined), Value, maps:get(op, Cond, 'EQ')).

search_expr('NOT', [Expr], Tags) ->
    not search_expr(Expr, Tags);

search_expr('OR', [], _) ->
    false;
search_expr('OR', [Expr|Units], Tags) ->
    search_expr(Expr, Tags) orelse search_expr('OR', Units, Tags);

search_expr('AND', [], _) ->
    true;
search_expr('AND', [Expr|Units], Tags) ->
    search_expr(Expr, Tags) andalso search_expr('AND', Units, Tags).

search_cond(V1, V2, 'EQ')  -> V1 =:= V2;
search_cond(V1, V2, 'NEQ') -> V1 =/= V2;
search_cond(V1, V2, 'GT')  -> V1 > V2;
search_cond(V1, V2, 'GTE') -> V1 >= V2;
search_cond(V1, V2, 'LT')  -> V1 < V2;
search_cond(V1, V2, 'LTE') -> V1 =< V2.
