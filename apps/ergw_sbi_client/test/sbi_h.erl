-module(sbi_h).

-export([init/2, allowed_methods/2, content_types_accepted/2, to_json/2]).

init(Req, State) ->
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

    JsonHeaders = #{<<"content-type">> => <<"application/json;charset=utf-8">>},
    ProblemHeaders = #{<<"content-type">> => <<"application/problem+json">>},

    case JSON of
	#{<<"gpsi">> := <<"msisdn-440000000000">>} ->
	    Body = jsx:encode(#{<<"ipv4Addr">> => <<"127.0.0.1">>}),
	    Resp = cowboy_req:reply(200, JsonHeaders, Body, Req1),
	    {stop, Resp, State};
	#{<<"gpsi">> := <<"msisdn-440000000001">>} ->
	    Body = jsx:encode(#{<<"ipv6Addr">> => <<"::1">>}),
	    Resp = cowboy_req:reply(200, JsonHeaders, Body, Req1),
	    {stop, Resp, State};
	#{<<"gpsi">> := <<"msisdn-440000000002">>} ->
	    Body = jsx:encode(#{<<"fqdn">> => <<"test.node.epc">>}),
	    Resp = cowboy_req:reply(200, JsonHeaders, Body, Req1),
	    {stop, Resp, State};
	_ ->
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
	    Resp = cowboy_req:reply(404, ProblemHeaders, Body, Req1),
	    {stop, Resp, State}
    end.
