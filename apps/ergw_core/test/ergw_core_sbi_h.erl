-module(ergw_core_sbi_h).

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
    case JSON of
	%% #{<<"gpsi">> := <<"msisdn-440000000000">>} ->
	%%     Headers = #{<<"content-type">> => <<"application/json">>},
	%%     Body = jsx:encode(#{<<"ipv4Addr">> => <<"127.0.0.1">>}),
	%%     Resp = cowboy_req:reply(200, Headers, Body, Req1),
	%%     {stop, Resp, State};
	%% #{<<"gpsi">> := <<"msisdn-440000000001">>} ->
	%%     Headers = #{<<"content-type">> => <<"application/json">>},
	%%     Body = jsx:encode(#{<<"ipv6Addr">> => <<"::1">>}),
	%%     Resp = cowboy_req:reply(200, Headers, Body, Req1),
	%%     {stop, Resp, State};
	#{<<"gpsi">> := <<"msisdn-440000000000">>} ->
	    Headers = #{<<"content-type">> => <<"application/json">>},
	    Body = jsx:encode(#{<<"fqdn">> => <<"topon.sx.prox03.epc.mnc001.mcc001.3gppnetwork.org">>}),
	    Resp = cowboy_req:reply(200, Headers, Body, Req1),
	    {stop, Resp, State};
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
