-module(ergw_core_sbi_chf_h).

-export([init/2, allowed_methods/2, content_types_accepted/2, to_json/2]).

init(Req, State) ->
    ct:pal("CHF-req: ~p", [Req]),
    {cowboy_rest, Req, State}.

allowed_methods(Req, State) ->
    {[<<"POST">>], Req, State}.

content_types_accepted(Req, State) ->
    {[{{<<"application">>, <<"json">>, '*'}, to_json}],
     Req, State}.

read_body(Req0, Acc) ->
    case cowboy_req:read_body(Req0) of
	{ok, Data, Req} -> {ok, <<Acc/binary, Data/binary>>, Req};
	{more, Data, Req} -> read_body(Req, <<Acc/binary, Data/binary>>)
    end.

to_json(Req0, State) ->
    {ok, Data, Req1} = read_body(Req0, <<>>),
    JSON = jsx:decode(Data, [{labels, binary}, return_maps]),
    case JSON of
	#{<<"invocationSequenceNumber">> := SeqNo} ->
	    Headers = #{<<"content-type">> => <<"application/json">>},
	    Response = #{<<"invocationTimestamp">> => strtime(erlang:monotonic_time()),
			 <<"invocationSequenceNumber">> => SeqNo},

	    case cowboy_req:binding(action, Req0, create) of
		create ->
		    Path = cowboy_req:path(Req0),
		    SessionId = "testSession1234",
		    Resource = iolist_to_binary(io_lib:format("~s/~s", [Path, SessionId])),
		    LocHeaders = Headers#{<<"location">> =>
					      cowboy_req:uri(Req0, #{path => Resource})},
		    Body = jsx:encode(Response),
		    Resp = cowboy_req:reply(201, LocHeaders, Body, Req1),
		    {stop, Resp, State};
		<<"update">> ->
		    Body = jsx:encode(Response),
		    Resp = cowboy_req:reply(200, Headers, Body, Req1),
		    {stop, Resp, State};
		<<"release">> ->
		    Body = jsx:encode(Response),
		    Resp = cowboy_req:reply(200, Headers, Body, Req1),
		    {stop, Resp, State}
	    end;
	_ ->
	    Headers = #{<<"content-type">> => <<"application/problem+json">>},
	    Error =
		#{<<"type">>     => <<"type">>,
		  <<"titel">>    => <<"title">>,
		  <<"status">>   => 404,
		  <<"detail">>   => <<"detail">>,
		  <<"instance">> => <<"instance">>,
		  <<"cause">>    => <<"cause">>,
		  <<"invalidParams">> =>
		      []
		 },
	    Body = jsx:encode(Error),
	    Resp = cowboy_req:reply(404, Headers, Body, Req1),
	    {stop, Resp, State}
    end.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

strtime(Time) ->
    strtime(Time, millisecond).

strtime(Time, Unit) ->
    SysTime = Time + erlang:time_offset(),
    iolist_to_binary(
      calendar:system_time_to_rfc3339(
	erlang:convert_time_unit(SysTime, native, Unit), [{unit, Unit}])).
