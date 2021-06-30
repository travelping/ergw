-module(ergw_sbi_client_config).

-export([
    validate_options/2,
    validate_option/2
]).

validate_options(Fun, M) when is_map(M) ->
    maps:fold(
      fun(K0, V0, A) ->
	      {K, V} = validate_option(Fun, K0, V0),
	      A#{K => V}
      end, #{}, M);
validate_options(_Fun, []) ->
    [];
validate_options(Fun, [{Opt, Value} | Tail]) ->
    [validate_option(Fun, Opt, Value) | validate_options(Fun, Tail)].

validate_option(Fun, Opt, Value) when is_function(Fun, 2) ->
    {Opt, Fun(Opt, Value)};
validate_option(Fun, Opt, Value) when is_function(Fun, 1) ->
    Fun({Opt, Value}).

validate_option(upf_selection_api = Opt, #{default := [_|_],
                                           endpoint := [_|_] = URI,
                                           timeout := T} = Value)
  when is_integer(T), T > 0->
      case uri_string:parse(URI) of
          #{host := _, path := _, scheme := _} ->
              ok = application:set_env(ergw_sbi_client, Opt, Value),
              Value;
          _ ->
              erlang:error(badarg, [Opt, Value])
      end;
validate_option(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).
