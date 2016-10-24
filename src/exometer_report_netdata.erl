-module(exometer_report_netdata).

-behaviour(exometer_report).

%% gen_server callbacks
-export([exometer_init/1,
         exometer_info/2,
         exometer_cast/2,
         exometer_call/3,
         exometer_report/5,
         exometer_subscribe/5,
         exometer_unsubscribe/4,
         exometer_newentry/2,
         exometer_setopts/4,
         exometer_terminate/2]).

-include_lib("exometer_core/include/exometer.hrl").

-type options() :: [{atom(), any()}].
-type value() :: any().
-type callback_result() :: {ok, state()} | any().
-type state() :: any().

%%====================================================================
%% API
%%====================================================================

-spec exometer_init(options()) -> callback_result().
exometer_init(_Opts) ->
    {ok, #{}}.

-spec exometer_report(exometer_report:metric(),
                      exometer_report:datapoint(),
                      exometer_report:extra(),
                      value(),
                      state()) -> callback_result().
exometer_report(_Metric, _DataPoint, _Extra, _Value, State) ->
    {ok, State}.

-spec exometer_subscribe(exometer_report:metric(),
                         exometer_report:datapoint(),
                         exometer_report:interval(),
                         exometer_report:extra(),
                         state()) -> callback_result().
exometer_subscribe(_Metric, _DataPoint, _Interval, _SubscribeOpts, State) ->
    lager:error("NetData Subscribe(~p, ~p, ~p, ~p)", [_Metric, _DataPoint, _Interval, _SubscribeOpts]),
    {ok, State}.

-spec exometer_unsubscribe(exometer_report:metric(),
                           exometer_report:datapoint(),
                           exometer_report:extra(),
                           state()) -> callback_result().
exometer_unsubscribe(_Metric, _DataPoint, _Extra, State) ->
    lager:error("NetData UnSubscribe(~p, ~p, ~p)", [_Metric, _DataPoint, _Extra]),
    {ok, State}.

-spec exometer_call(any(), pid(), state()) ->
    {reply, any(), state()} | {noreply, state()} | any().
exometer_call(_Unknown, _From, State) ->
    {ok, State}.

-spec exometer_cast(any(), state()) -> {noreply, state()} | any().
exometer_cast(_Unknown, State) ->
    {ok, State}.

-spec exometer_info(any(), state()) -> callback_result().
exometer_info(_Unknown, State) ->
    {ok, State}.

-spec exometer_newentry(exometer:entry(), state()) -> callback_result().
exometer_newentry(#exometer_entry{name = [socket, 'gtp-c', PortName | Value] = Name, type = counter}, State) ->
    ChartId = {socket, 'gtp-c', PortName},
    ChartDef0 = case maps:get(ChartId, State, undefined) of
		   undefined -> socket_make_chart(PortName);
		   V         -> V
	       end,
    ChartDef = socket_add_value(Value, Name, ChartDef0),
    netdata:register_chart(ChartDef),
    {ok, State#{ChartId => ChartDef}};
exometer_newentry(_Entry, State) ->
    lager:debug("NetData NewEntry(~p)", [lager:pr(_Entry, ?MODULE)]),
    {ok, State}.


-spec exometer_setopts(exometer:entry(), options(),
                       exometer:status(), state()) -> callback_result().
exometer_setopts(_Metric, _Options, _Status, State) ->
    {ok, State}.

-spec exometer_terminate(any(), state()) -> any().
exometer_terminate(_Reason, _State) ->
    ignore.

%%%===================================================================
%%% Internal functions
%%%===================================================================

exometer_socket_init(Id, _OldValue) ->
    exometer:get_values([socket, 'gtp-c', Id]).

exometer_socket_get(Id, Value) ->
    case lists:keyfind(Id, 1, Value) of
	{_, V} when is_list(V) ->
	    proplists:get_value(value, V, 0);
	_Other ->
	    0
    end.

socket_make_chart(PortName) ->
    #{type   => erlang, id => PortName,
      title  => "Messages",
      units  => "Message per second",
      values => [],
      init   => fun exometer_socket_init/2
     }.

socket_add_value(Value, Name, #{values := Values} = Chart) ->
    V =#{id => lists:flatten(lists:join($_, [atom_to_list(V) || V <- Value])),
	 identifier => Name, algorithm  => incremental,
	 get => fun exometer_socket_get/2},
    Chart#{values => [V | Values]}.
