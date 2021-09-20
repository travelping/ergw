%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_otel_gtp_sampler).

-behaviour(gen_server).
-behaviour(otel_sampler).

%% API
-export([start_link/0, trace/2]).
-export([description/1, setup/1, should_sample/7]).

-ignore_xref([start_link/0, trace/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("opentelemetry/include/otel_sampler.hrl").

-define(SERVER, ?MODULE).

-record(state, {}).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

trace(Type, Key) ->
    ets:insert(?SERVER, {{Type, Key}}).

%%%===================================================================
%%% OTEL Sampler
%%%===================================================================

%% sampler returns the value from the Opts map based on the SpanName or `NOT_RECORD'
setup(Opts) -> Opts.

description(_) -> <<"ergwGTPsampler">>.

should_sample(Ctx, _TraceId, _Links, _SpanName, _SpanKind, Attributes, _Opts) ->
    ct:pal("SampleAttrs: ~p~n", [Attributes]),
    case proplists:get_value('gtp.imsi', Attributes) of
	IMSI when is_binary(IMSI) ->
	    case ets:member(?SERVER, {imsi, IMSI}) of
		true ->
		    SpanCtx = otel_tracer:current_span_ctx(Ctx),
		    {?RECORD_AND_SAMPLE, [], otel_span:tracestate(SpanCtx)};
		false ->
		    {?DROP, [], []}
	    end;
	_ ->
	    {?DROP, [], []}
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    ets:new(?SERVER, [ordered_set, named_table, public,
		      {keypos, 1}, {read_concurrency, true}]),
    {ok, #state{}}.

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================
