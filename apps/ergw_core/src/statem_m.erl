-module(statem_m).

-compile([{parse_transform, do}]).
-ignore_xref([?MODULE]).

-behaviour(monad).
-export(['>>='/2,
	 return/1, return/0, fail/1,
	 return/3, fail/3,
	 get/0, put/2,
	 get_state/0, put_state/1,
	 get_data/0, get_data/1, put_data/1,
	 modify_data/1, modify_state/1,
	 lift/1,
	 wait/1, response/4,
	 run/3]).

'>>='(X, Fun) ->
    fun (S, D) ->
	    case X(S, D) of
		{error, _} = Error ->
		    {Error, S, D};
		{{error, _}, _S1, _D1} = Error ->
		    Error;
		{{ok, Result}, S1, D1} ->
		    F = Fun(Result),
		    F(S1, D1);
		{ok, S1, D1} ->
		    F = Fun(ok),
		    F(S1, D1);
		{{wait, ReqId, Q}, S1, D1} ->
		    {{wait, ReqId, [Fun|Q]}, S1, D1}
	    end
    end.

return(X, S, D) -> {{ok, X}, S, D}.
fail(X, S, D) -> {{error, X}, S, D}.

return()  -> return(ok).
return(X) -> fun (S, D) -> {{ok, X}, S, D} end.
fail(X) -> fun (S, D) -> {{error, X}, S, D} end.

lift(X) -> fun (S, D) -> {X, S, D} end.

get()     -> fun (S, D) -> {{ok, {S, D}}, S, D} end.
put(S, D) -> fun (_, _) -> {{ok, ok}, S, D} end.

get_state()  -> fun (S, D) -> {{ok, S}, S, D} end.
put_state(S) -> fun (_, D) -> {{ok, ok}, S, D} end.

get_data()  -> fun (S, D) -> {{ok, D}, S, D} end.
put_data(D) -> fun (S, _) -> {{ok, ok}, S, D} end.

get_data(Fun)  -> fun (S, D) -> {{ok, Fun(D)}, S, D} end.

modify_data(Fun)   -> fun (S, D) -> {{ok, ok}, S, Fun(D)} end.
modify_state(Fun)  -> fun (S, D) -> {{ok, ok}, Fun(S), D} end.

wait(ReqId) when is_reference(ReqId); is_pid(ReqId) ->
    fun (S, D) -> {{wait, ReqId, []}, S, D} end.

run(SM, State, Data) ->
    SM(State, Data).

response([Fun], Response) ->
    do([?MODULE || Fun(Response)]);
response([Fun|Next], Response) ->
    do([?MODULE || R <- response(Next, Response), Fun(R)]).

response(Q, Response, S, D) ->
    run(response(Q, Response), S, D).
