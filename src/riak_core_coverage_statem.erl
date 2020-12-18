-module(riak_core_coverage_statem).

-behaviour(gen_statem).

-export([start_link/7, coverage_request/5]).
-export([init/1, callback_mode/0, terminate/3]).
-export([handle_event/4]).

-ignore_xref([?MODULE]).

start_link(Command, N, ServiceMod, VNodeMasterMod, Ref, From, Opts) ->
    proc_lib:start_link(?MODULE, init, [[self(), Command, N, ServiceMod, VNodeMasterMod, Ref, From, Opts]]).

coverage_request(Command, N, ServiceMod, VNodeMasterMod,
		 #{wait_timeout_ms := WaitTimeoutMs} = Opts) ->
    Ref = rand:uniform(1000),
    case start_link(Command, N, ServiceMod, VNodeMasterMod, Ref, self(), Opts) of
	{ok, _Pid} ->
	    receive
		{Ref, Result} ->
		    Result
	    after WaitTimeoutMs ->
		    {error, timeout}
	    end;
	Other ->
	    Other
    end.

%

callback_mode() ->
    handle_event_function.

init([Parent, Command, N, ServiceMod, VNodeMasterMod, Ref, From,
      #{pvc := PVC, vnode_selector := VNodeSelector,
	wait_timeout_ms := WaitTimeoutMs} = Opts]) ->

    case riak_core_coverage_plan:create_plan(VNodeSelector, N, PVC, Ref, ServiceMod) of
	{error, Reason} ->
	    exit(Reason);
	{CoverageVNodes, FilterVNodes} ->
	    proc_lib:init_ack(Parent, {ok, self()}),
	    riak_core_vnode_master:coverage
	      (Command, CoverageVNodes, FilterVNodes, {raw, Ref, self()}, VNodeMasterMod),
	    Data = Opts#{coverage_vnodes => CoverageVNodes, ref => Ref, from => From, result => []},
	    gen_statem:enter_loop(
	      ?MODULE, [], waiting, Data, [{state_timeout, WaitTimeoutMs, waiting}])
    end.

handle_event(info, {{_, VNode}, ResVal}, waiting,
	     #{coverage_vnodes := CoverageVNodes, result := Result} = Data) ->
    NewResult = [ResVal | Result],
    case lists:delete(VNode, CoverageVNodes) of
	[] ->
	    reply({ok, #{reason => finished, result => NewResult}}, Data),
	    {stop, normal};
	UpdatedVNodes ->
	    {keep_state, Data#{coverage_vnodes => UpdatedVNodes, result => NewResult}}
    end;

handle_event(info, {_ReqId, {ok, _Pid}}, _State, _Data) ->
    %% Received a message from a coverage node that
    %% did not start up within the timeout. Just ignore
    %% the message and move on.
    keep_state_and_data;

handle_event(info, {timeout, _, _}, _State, #{result := Result} = Data) ->
    reply({error, #{reason => timeout, result => Result}}, Data),
    {stop, normal};
handle_event(state_timeout, waiting, _State, #{result := Result} = Data) ->
    reply({error, #{reason => timeout, result => Result}}, Data),
    {stop, normal}.

terminate(_Reason, _State, _Data) ->
    ok.

%

reply(Result, #{ref := Ref, from := From}) ->
    From ! {Ref, Result}.
