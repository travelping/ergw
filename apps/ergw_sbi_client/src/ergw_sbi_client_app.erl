%%%-------------------------------------------------------------------
%% @doc ergw_sbi_client public API
%% @end
%%%-------------------------------------------------------------------

-module(ergw_sbi_client_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    ergw_sbi_client_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
