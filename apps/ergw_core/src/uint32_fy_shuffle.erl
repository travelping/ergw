-module(uint32_fy_shuffle).

-export([shuffle/1]).

-on_load(init/0).

-define(APPNAME, ergw_core).
-define(LIBNAME, ergw_core).

shuffle(_) ->
    not_loaded(?LINE).

init() ->
    SoName = case code:priv_dir(?APPNAME) of
		 {error, bad_name} ->
		     case filelib:is_dir(filename:join(["..", priv])) of
			 true ->
			     filename:join(["..", priv, ?LIBNAME]);
			 _ ->
			     filename:join([priv, ?LIBNAME])
		     end;
		 Dir ->
		     filename:join(Dir, ?LIBNAME)
	     end,
    erlang:load_nif(SoName, 0).

not_loaded(Line) ->
    erlang:nif_error({not_loaded, [{module, ?MODULE}, {line, Line}]}).
