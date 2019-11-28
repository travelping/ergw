-module(ergw_control).

-export([authenticate/1]).

-include_lib("kernel/include/logger.hrl").

%%====================================================================
%% API
%%====================================================================

authenticate(Context) ->
    control(authenticate, [Context]).

%%%===================================================================
%%% Internal functions
%%%===================================================================

control(Function, Args) ->
    control(application:get_env(ergw, control_node, undefined), Function, Args).

control(undefined, Function, Args) ->
    ?LOG(debug, "erGW control Node undefined"),
    default(Function, Args);
control(Node, Function, Args) ->
    ?LOG(debug, "erGW control Node ~p", [Node]),
%%    case rpc:call(Node, scg_control_ergw, Function, Args) of
    R = rpc:call(Node, scg_control_ergw, Function, Args),
    ?LOG(debug, "erGW control: ~p", [R]),
    case R of
	{badrpc, _} ->
	    default(Function, Args);
	Other ->
	    Other
    end.

default(_Function, Args) ->
    {accept, Args}.
