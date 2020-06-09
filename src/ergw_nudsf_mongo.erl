%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% simple implementation of 3GPP TS 29.598 Nudsf service
%% - functional API according to TS
%% - not optimized for anything

-module(ergw_nudsf_mongo).

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

-include_lib("kernel/include/logger.hrl").

%%%=========================================================================
%%%  mongo stuff
%%%=========================================================================

-include_lib("mongodb/include/mongoc.hrl").
-include_lib("mongodb/include/mongo_protocol.hrl").

-define(SERVER, ergw_nudsf_mongo_srv).
-define(POOL, ergw_nudsf_mongo_pool).

%%%=========================================================================
%%%  API
%%%=========================================================================

get_childspecs(AppConfig) ->
    Config = proplists:get_value(udsf, AppConfig),
    DB0 = maps:get(database, Config),
    Pool = maps:get(pool, Config),

    DB = maps:to_list(maps:remove(host, DB0)),
    Seeds = {unknown, [maps:get(host, DB0)]},
    Options = [{name, {local, ?POOL}},
	       {register, ?SERVER}
	      | maps:to_list(Pool)],
    ?LOG(debug, "DB: ~p~nSeeds: ~p~nOptions: ~p~n", [DB, Seeds, Options]),

    [#{id       => ?SERVER,
       start    => {mongoc, connect, [Seeds, Options, DB]},
       restart  => permanent,
       shutdown =>  5000,
       type     => supervisor,
       modules  => [mongoc]}].

%% TS 29.598, 5.2.2.2 Query

get(record, RecordId) ->
    ?LOG(debug, "get(block, ~p)", [RecordId]),
    Selector = #{<<"_id">> => RecordId},
    Projection = #{},
    ?LOG(debug, "get(..): ~p, ~p", [Selector, Projection]),
    case mongo_api:find_one(?SERVER, <<"Nudfs">>, Selector, Projection) of
	#{<<"meta">> := Meta, <<"blocks">> := Blocks} = R ->
	    ?LOG(debug, "get(..) -> ~p", [R]),
	    {ok, Meta, maps:map(fun get_block/2, Blocks)};
	_Other ->
	    ?LOG(debug, "get(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.findOne() failed with ~p", [_Other]),
	    {error, not_found}
    end;
get(meta, RecordId) ->
    ?LOG(debug, "get(block, ~p)", [RecordId]),
    Selector = #{<<"_id">> => RecordId},
    Projection = #{<<"meta">> => 1},
    ?LOG(debug, "get(..): ~p, ~p", [Selector, Projection]),
    case mongo_api:find_one(?SERVER, <<"Nudfs">>, Selector, Projection) of
	#{<<"meta">> := Meta} = R ->
	    ?LOG(debug, "get(..) -> ~p", [R]),
	    {ok, Meta};
	_Other ->
	    ?LOG(debug, "get(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.findOne() failed with ~p", [_Other]),
	    {error, not_found}
    end;
get(blocks, RecordId) ->
    ?LOG(debug, "get(block, ~p)", [RecordId]),
    Selector = #{<<"_id">> => RecordId},
    Projection = #{"blocks" => 1},
    ?LOG(debug, "get(..): ~p, ~p", [Selector, Projection]),
    case mongo_api:find_one(?SERVER, <<"Nudfs">>, Selector, Projection) of
	#{<<"blocks">> := Blocks} = R ->
	    ?LOG(debug, "get(..) -> ~p", [R]),
	    {ok, maps:map(fun get_block/2, Blocks)};
	_Other ->
	    ?LOG(debug, "get(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.findOne() failed with ~p", [_Other]),
	    {error, not_found}
    end.

get(block, RecordId, BlockId) ->
    ?LOG(debug, "get(block, ~p, ~p)", [RecordId, BlockId]),
    Selector = #{<<"_id">> => RecordId},
    Projection = #{<<"blocks.", BlockId/binary>> => 1},
    ?LOG(debug, "get(..): ~p, ~p", [Selector, Projection]),
    case mongo_api:find_one(?SERVER, <<"Nudfs">>, Selector, Projection) of
	#{<<"blocks">> := #{BlockId := Block}} = R ->
	    ?LOG(debug, "get(..) -> ~p", [R]),
	    {ok, get_block(BlockId, Block)};
	_Other ->
	    ?LOG(debug, "get(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.findOne() failed with ~p", [_Other]),
	    {error, not_found}
    end.

%% TS 29.598, 5.2.2.2.6	Search

search(Filter) ->
    search(Filter, #{}).

search(Filter, #{count := true}) ->
    ?LOG(debug, "search(~p)", [Filter]),
    Selector = search_expr(Filter),
    ?LOG(debug, "search(..): ~p", [Selector]),
    Count = mongo_api:count(?SERVER, <<"Nudfs">>, Selector, 0),
    {Count, []};
search(Filter, #{range := Range} = Opts) ->
    ?LOG(debug, "search(~p, ~p)", [Filter, Opts]),
    Selector = search_expr(Filter),
    Page = maps:get(page, Opts, 1),
    Ref = [{<<"$skip">>, (Page - 1) * Range}, {<<"$limit">>, Range},
	   {<<"$group">>, #{<<"_id">> => null,
			    <<"refs">> =>
				#{<<"$push">> => <<"$$CURRENT._id">>}}}],

    Pipeline = [
		{<<"$match">>, Selector},
		{<<"$facet">>, #{<<"count">> => [{<<"$count">>, <<"value">>}],
				 <<"ref">>   => Ref}}
	       ],
    ?LOG(debug, "search(..): ~p", [Pipeline]),
    case aggregate(?SERVER, <<"Nudfs">>, Pipeline) of
	{ok, Cursor} = R ->
	    ?LOG(debug, "search(..) -> ~p", [R]),
	    Result =
		case mc_cursor:rest(Cursor) of
		    [#{<<"count">> := [#{<<"value">> := Count}],
		       <<"ref">>   := [#{<<"refs">> := Refs}]}] ->
			{Count, Refs};
		    [#{<<"count">> := [],
		       <<"ref">>   := [#{<<"refs">> := Refs}]}] ->
			{0, Refs};
		    _Other ->
			?LOG(error, "MongoDB.find() failed with ~p", [_Other]),
			{0, []}
		end,
	    mc_cursor:close(Cursor),
	    ?LOG(debug, "search(..) -> ~p", [Result]),
	    Result;
	_Other ->
	    ?LOG(debug, "get(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.findOne() failed with ~p", [_Other]),
	    {error, not_found}
    end;
search(Filter, _Opts) ->
    ?LOG(debug, "search(~p)", [Filter]),
    Selector = search_expr(Filter),
    Projection = #{<<"_id">> => 1},
    ?LOG(debug, "get(..): ~p, ~p", [Selector, Projection]),
    case mongo_api:find(?SERVER, <<"Nudfs">>, Selector, Projection) of
	{ok, Cursor} = R ->
	    ?LOG(debug, "search(..) -> ~p", [R]),
	    Result =
		case mc_cursor:rest(Cursor) of
		    List when is_list(List) ->
			[Id || #{<<"_id">> := Id} <- List];
		    _Other ->
			?LOG(error, "MongoDB.find() failed with ~p", [_Other]),
			[]
		end,
	    mc_cursor:close(Cursor),
	    ?LOG(debug, "search(..) -> ~p", [Result]),
	    {length(Result), Result};
	_Other ->
	    ?LOG(debug, "get(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.findOne() failed with ~p", [_Other]),
	    {error, not_found}
    end.

%% TS 29.598, 5.2.2.3 Create

create(RecordId, Meta, Blocks) ->
    ?LOG(debug, "create(~p, ~p, ~p)", [RecordId, Meta, Blocks]),
    Doc = #{<<"_id">> => RecordId,
	    <<"meta">> => Meta,
	    <<"blocks">> => maps:map(fun put_block/2, Blocks)
	   },
    ?LOG(debug, "create(..): ~p", [Doc]),
    R = (catch mongo_api:insert(?SERVER, <<"Nudfs">>, Doc)),
    ?LOG(debug, "create(..) -> ~p", [R]),
    ok.

create(block, RecordId, BlockId, Block) ->
    ?LOG(debug, "create(block, ~p, ~p, ~p)", [block, RecordId, BlockId, Block]),
    put(block, RecordId, BlockId, Block).

%% TS 29.598, 5.2.2.4 Update
put(record, RecordId, Meta, Blocks) ->
    ?LOG(debug, "put(record, ~p, ~p, ~p)", [RecordId, Meta, Blocks]),
    Selector = #{<<"_id">> => RecordId},
    Doc = #{<<"_id">> => RecordId,
	    <<"meta">> => Meta,
	    <<"blocks">> => maps:map(fun put_block/2, Blocks)
	   },
    update_one(Selector, Doc);

put(block, RecordId, BlockId, Block) ->
    ?LOG(debug, "put(block, ~p, ~p, ~p)", [RecordId, BlockId, Block]),
    Selector = #{<<"_id">> => RecordId},
    Blocks = #{<<"blocks.", BlockId/binary>> => Block},
    Doc = #{<<"$set">> => maps:map(fun put_block/2, Blocks)},
    update_one(Selector, Doc).

put(meta, RecordId, Meta) ->
    ?LOG(debug, "put(meta, ~p, ~p)", [RecordId, Meta]),
    Selector = #{<<"_id">> => RecordId},
    Doc = #{<<"$set">> => #{<<"meta">> => Meta}},
    update_one(Selector, Doc).

%% TS 29.598, 5.2.2.5 Delete

delete(record, RecordId) ->
   ?LOG(debug, "delete(record, ~p)", [RecordId]),
    Selector = #{<<"_id">> => RecordId},
    ?LOG(debug, "delete(..): ~p, ~p", [Selector]),
    case mongo_api:delete(?SERVER, <<"Nudfs">>, Selector) of
	{true, #{<<"n">> := 1}} = R ->
	    ?LOG(debug, "put(..) -> ~p", [R]),
	    ok;
	{_, Result} = R ->
	    ?LOG(debug, "put(..) -> ~p", [R]),
	    ?LOG(error, "MongoDB.delete() failed with ~p", [Result]),
	    {error, failed}
    end.

delete(block, RecordId, BlockId) ->
    ?LOG(debug, "delete(block, ~p, ~p)", [RecordId, BlockId]),
    Selector = #{<<"_id">> => RecordId},
    Doc = #{<<"$unset">> => [<<"blocks.", BlockId/binary>>]},
    update_one(Selector, Doc).

all() ->
    ?LOG(debug, "all()"),
    Selector = #{},
    Projection = #{},
    ?LOG(debug, "all(..): ~p, ~p", [Selector, Projection]),
    case mongo_api:find(?SERVER, <<"Nudfs">>, Selector, Projection) of
	{ok, Cursor} = R ->
	    ?LOG(debug, "all(..) -> ~p", [R]),
	    Result = mc_cursor:rest(Cursor),
	    mc_cursor:close(Cursor),
	    ?LOG(debug, "all(..) -> ~p", [Result]),
	    Result;
	_Other ->
	    ?LOG(debug, "all(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.find() failed with ~p", [_Other]),
	    {error, not_found}
    end.

wipe() ->
    ?LOG(debug, "wipe()"),
    Selector = #{},
    ?LOG(debug, "wipe(..): ~p", [Selector]),
    case mongo_api:delete(?SERVER, <<"Nudfs">>, Selector) of
	{true, Result} ->
	    ?LOG(debug, "wipe(..) -> ~p", [Result]),
	    ok;
	_Other ->
	    ?LOG(debug, "wipe(..) -> ~p", [_Other]),
	    ?LOG(error, "MongoDB.delete() failed with ~p", [_Other]),
	    {error, failed}
    end.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(Defaults, [{pool, []}, {database, []}]).
-define(DefaultsPool, [{size, 5}, {max_overflow, 10}]).
-define(DefaultsDB, [{host, <<"localhost:27017">>},
		     {database, <<"ergw">>},
		     {login, undefined},
		     {password, undefined}]).

validate_options(Values) ->
    ?LOG(debug, "Mongo Options: ~p", [Values]),
    ergw_config:validate_options(fun validate_option/2, Values, ?Defaults, map).

validate_option(handler, Value) ->
    Value;
validate_option(pool, Values) ->
    ergw_config:validate_options(fun validate_pool_option/2, Values, ?DefaultsPool, map);
validate_option(database, Values) ->
    ergw_config:validate_options(fun validate_database_option/2, Values, ?DefaultsDB, map);

validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_pool_option(size, Value) when is_integer(Value) ->
    Value;
validate_pool_option(max_overflow, Value) when is_integer(Value) ->
    Value;
validate_pool_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_database_option(host, Value) when is_binary(Value) ->
    Value;
validate_database_option(database, Value) when is_binary(Value) ->
    Value;
validate_database_option(login, Value) when is_binary(Value); Value =:= undefined ->
    Value;
validate_database_option(password, Value) when is_binary(Value); Value =:= undefined ->
    Value;
validate_database_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%=========================================================================
%%%  internal functions
%%%=========================================================================

put_block(_, V) ->
    {bin, bin, V}.

get_block(_, {bin, bin, V}) ->
    V.

update_one(Selector, Doc) ->
    ?LOG(debug, "put(..): ~p, ~p", [Selector, Doc]),
    case mongo_api:update(?SERVER, <<"Nudfs">>, Selector, Doc, #{}) of
	{true, #{<<"n">> := 1}} = R ->
	    ?LOG(debug, "put(..) -> ~p", [R]),
	    ok;
	{_, Result} = R ->
	    ?LOG(debug, "put(..) -> ~p", [R]),
	    ?LOG(error, "MongoDB.update() failed with ~p", [Result]),
	    {error, failed}
    end.

search_expr(Expr) ->
    search_expr(Expr, #{}).

search_expr(#{'cond' := Cond, units := Units}, Query) ->
    search_expr(Cond, Units, Query);

search_expr(#{tag := Tag, value := Value} = Cond, Query) ->
    search_cond(Tag, Value, maps:get(op, Cond, 'EQ'), Query).

search_expr('NOT', [Expr], Query) ->
    Query#{<<"$nor">> => search_expr(Expr)};

search_expr('OR', Exprs, Query) ->
    Query#{<<"$or">> => lists:map(fun search_expr/1, Exprs)};

search_expr('AND', Exprs, Query) ->
    Query#{<<"$and">> => lists:map(fun search_expr/1, Exprs)}.

meta_tag_query(Tag, Value, Query) ->
    Key = iolist_to_binary(io_lib:format("meta.tags.~s", [Tag])),
    maps:put(Key, Value, Query).

search_cond(Tag, Value, 'EQ', Query)  -> meta_tag_query(Tag, Value, Query);
search_cond(Tag, Value, 'NEQ', Query) -> meta_tag_query(Tag, #{<<"$ne">> => Value}, Query);
search_cond(Tag, Value, 'GT', Query)  -> meta_tag_query(Tag, #{<<"$gt">> => Value}, Query);
search_cond(Tag, Value, 'GTE', Query) -> meta_tag_query(Tag, #{<<"$gte">> => Value}, Query);
search_cond(Tag, Value, 'LT', Query)  -> meta_tag_query(Tag, #{<<"$lt">> => Value}, Query);
search_cond(Tag, Value, 'LTE', Query) -> meta_tag_query(Tag, #{<<"$lte">> => Value}, Query).

%%%=========================================================================
%%%  mongo API wrapper
%%%=========================================================================

-type pipeline() :: list().

-spec aggregate(atom() | pid(), collection(), pipeline()) ->
  {ok, cursor()} | [].
aggregate(Topology, Collection, Pipeline) ->
  mongoc:transaction_query(Topology,
    fun(Conf = #{pool := Worker}) ->
      Query = mongoc_aggregate_query(Conf, Collection, Pipeline),
      mc_worker_api:find(Worker, Query)
    end, #{}).

%%%=========================================================================
%%%  mongoc wrapper
%%%=========================================================================

-spec mongoc_aggregate_query(map(), collection(), pipeline()) -> query().
mongoc_aggregate_query(#{server_type := ServerType, read_preference := RPrefs},
		       Coll, Pipeline) ->
    Command =
	{<<"aggregate">>, mc_utils:value_to_binary(Coll),
	 <<"pipeline">>, Pipeline,
	 <<"cursor">>,   {} },
    Q = #'query'{
	   collection = <<"$cmd">>,
	   selector = Command,
	   batchsize = 1
	  },
    mongos_query_transform(ServerType, Q, RPrefs).

%%%===================================================================
%%% mongoc - Internal functions
%%%===================================================================


%% @private
mongos_query_transform(mongos, #'query'{selector = S} = Q, #{mode := primary}) ->
  Q#'query'{selector = S, slaveok = false, sok_overriden = true};
mongos_query_transform(mongos, #'query'{selector = S} = Q, #{mode := primaryPreferred, tags := []}) ->
  Q#'query'{selector = S, slaveok = true, sok_overriden = true};
mongos_query_transform(mongos, #'query'{selector = S} = Q, #{mode := primaryPreferred, tags := Tags}) ->
  Q#'query'{
    selector = mongoc:append_read_preference(S, #{mode => <<"primaryPreferred">>, <<"tags">> => bson:document(Tags)}),
    slaveok = true,
    sok_overriden = true};
mongos_query_transform(mongos, #'query'{selector = S} = Q, #{mode := secondary, tags := []}) ->
  Q#'query'{
    selector = mongoc:append_read_preference(S, #{mode => <<"secondary">>}),
    slaveok = true,
    sok_overriden = true};
mongos_query_transform(mongos, #'query'{selector = S} = Q, #{mode := secondary, tags := Tags}) ->
  Q#'query'{
    selector = mongoc:append_read_preference(S, #{mode => <<"secondary">>, <<"tags">> => bson:document(Tags)}),
    slaveok = true,
    sok_overriden = true};
mongos_query_transform(mongos, #'query'{selector = S} = Q, #{mode := secondaryPreferred, tags := []}) ->
  Q#'query'{
    selector = mongoc:append_read_preference(S, #{mode => <<"secondaryPreferred">>}),
    slaveok = true,
    sok_overriden = true};
mongos_query_transform(mongos, #'query'{selector = S} = Q, #{mode := secondaryPreferred, tags := Tags}) ->
  Q#'query'{
    selector = mongoc:append_read_preference(S, #{mode => <<"secondaryPreferred">>, <<"tags">> => bson:document(Tags)}),
    slaveok = true,
    sok_overriden = true};
mongos_query_transform(mongos, #'query'{selector = S} = Q, #{mode := nearest, tags := []}) ->
  Q#'query'{
    selector = mongoc:append_read_preference(S, #{mode => <<"nearest">>}),
    slaveok = true,
    sok_overriden = true};
mongos_query_transform(mongos, #'query'{selector = S} = Q, #{mode := nearest, tags := Tags}) ->
  Q#'query'{
    selector = mongoc:append_read_preference(S, #{mode => <<"nearest">>, tags => bson:document(Tags)}),
    slaveok = true,
    sok_overriden = true};
mongos_query_transform(_, Q, #{mode := primary}) ->
  Q#'query'{slaveok = false, sok_overriden = true};
mongos_query_transform(_, Q, _) ->
  Q#'query'{slaveok = true, sok_overriden = true}.
