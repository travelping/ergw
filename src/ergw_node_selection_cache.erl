-module(ergw_node_selection_cache).
-export([
    init/0,
    resolve/3
]).

init() ->
    ?MODULE = ets:new(?MODULE, [named_table, public, ordered_set, {read_concurrency, true}]),
    ok.

resolve(Name, Type, NsOpts) ->
    Now = erlang:system_time(second),
    case ets:lookup(?MODULE, {Name, Type}) of
        [{_, Update, Result}] when Update == Now orelse Update == updating ->
            Result;
        [{_, _, Result}] ->
            ets:update_element(?MODULE, {Name, Type}, {2, updating}),
            % optimistic async update, won't hold up queries
            spawn(fun() -> 
                do_update(Name, Type, NsOpts, Now)
            end),
            Result;
        [] ->
            do_update(Name, Type, NsOpts, Now)
    end.

do_update(Name, Type, NsOpts, Now) ->
    %% 3GPP DNS answers are almost always large, use TCP by default....
    case inet_res:resolve(Name, in, Type, [{usevc, true} | NsOpts]) of
        {error, _} = Error ->
            Error;
        {ok, Msg} ->
            ets:insert(?MODULE, {{Name, Type}, Now, {ok, Msg}}),
            {ok, Msg}
    end.
