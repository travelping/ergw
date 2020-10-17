%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(sbi_nbsf_handler).

-export([init/2,
	 allowed_methods/2,
	 content_types_provided/2,
	 malformed_request/2,
	 resource_exists/2,
	 to_json/2]).

-include("include/ergw.hrl").

-define(FIELDS_MAPPING, [{accept_new, 'acceptNewRequests'},
			 {plmn_id, 'plmnId'}]).

init(Req0, State) ->
    case cowboy_req:version(Req0) of
	'HTTP/2' ->
	    {cowboy_rest, Req0, State};
	_ ->
	    ProblemDetails =
		#{title  => <<"HTTP/2 is mandatory.">>,
		  status => 400,
		  cause  => <<"UNSUPPORTED_HTTP_VERSION">>
		 },
	    Req = problem(400, ProblemDetails, Req0),
	    {ok, Req, done}
    end.

allowed_methods(Req, State) ->
    %% only GET for now
    {[<<"GET">>], Req, State}.

content_types_provided(Req, State) ->
    {[{<<"application/json">>, to_json}], Req, State}.

%% content_types_accepted(Req, State) ->
%%     {[{'*', create_json}], Req, State}.

malformed_request(Req0, _State) ->
    try
	Match =
	    [{'ipv4Addr', [fun qs_ipv4/2], undefined},
	     {'ipv6Prefix', [fun qs_ipv6/2], undefined},
	     {'dnn', [], undefined},
	     {'snssai', [fun qs_snssai/2], undefined},
	     {'ipDomain', [], undefined}],
	#{'ipv4Addr' := IP4, 'ipv6Prefix' := IP6} =
	    Q = cowboy_req:match_qs(Match, Req0),

	if (IP4 /= undefined andalso IP6 =:= undefined)
	   orelse (IP4 =:= undefined andalso IP6 /= undefined) ->
		{false, Req0, Q};
	   true ->
		ProblemDetails =
		    #{title  => <<"Either ipv4Addr or ip6Prefix need to be specified.">>,
		      status => 400,
		      cause  => <<"INVALID_QUERY_PARAM">>
		     },
		Req = problem(400, ProblemDetails, Req0),
		{stop, Req, done}
	end
    catch
	exit:{request_error, {match_qs, Error}, Title} ->
	    Param =
		maps:fold(
		  fun(Field, {Fun, Code, V}, Acc) ->
			  [#{param => Field,
			     reason => iolist_to_binary(Fun(format_error, {Code, V}))} | Acc]
		  end, [], Error),
	    ErrorDetails =
		    #{title  => Title,
		      status => 400,
		      cause  => <<"INVALID_QUERY_PARAM">>,
		      invalidParams => Param
		     },
	    ErrorReq = problem(400, ErrorDetails, Req0),
	    {stop, ErrorReq, done}
    end.

resource_exists(Req, Query) ->
    Filter = maps:fold(fun query_filter/3, #bsf{_ = '_'}, Query),
    Obj = gtp_context_reg:select(Filter),
    Result = length(Obj) > 0,
    {Result, Req, Obj}.

to_json(Req0, ObjList) when length(ObjList) /= 1 ->
    ProblemDetails =
	#{title  => <<"Multiple binding_info_found.">>,
	  status => 400,
	  cause  => <<"MULTIPLE_BINDING_INFO_FOUND">>
	 },
    Req = problem(400, ProblemDetails, Req0),
    {stop, Req, done};

to_json(Req, [{gtp_context, Pid}]) ->
    #{context := Context} = gtp_context:info(Pid),
    Keys = [apn, imsi, msisdn, vrf, ms_v4, ms_v6],
    Obj = lists:foldl(fun(K, B) -> context2binding(K, Context, B) end, #{}, Keys),
    Response = jsx:encode(Obj),
    {Response, Req, done}.

context2binding(apn, #context{apn = APN}, B) ->
    B#{dnn => iolist_to_binary(lists:join($. , APN))};
context2binding(imsi, #context{imsi = IMSI}, B) ->
    B#{supi => <<"imsi-", IMSI/binary>>};
context2binding(msisdn, #context{msisdn = MSISDN}, B) ->
    B#{gpsi => <<"msisdn-", MSISDN/binary>>};
context2binding(vrf, #context{right = #bearer{local = #ue_ip{}, vrf = VRF}}, B) ->
    B#{ipDomain =>
	   iolist_to_binary(lists:join($. , [ Part || <<Len:8, Part:Len/bytes>> <= VRF ]))};
context2binding(ms_v4, #context{ms_ip = #ue_ip{v4 = AI}}, B) when AI /= undefined ->
    B#{'ipv4Addr' => iolist_to_binary(inet:ntoa(ergw_ip_pool:addr(AI)))};
context2binding(ms_v6, #context{ms_ip = #ue_ip{v6 = AI}}, B) when AI /= undefined ->
    {IP, Len} = ergw_ip_pool:ip(AI),
    B#{'ipv6Prefix' => iolist_to_binary([inet:ntoa(IP), $/, integer_to_list(Len)])};
context2binding(_, _, B) ->
    B.

%%%===================================================================
%%% Internal functions
%%%===================================================================

problem(Code, Details, Req) ->
    cowboy_req:reply(
      Code, #{<<"content-type">> => "application/problem+json"}, jsx:encode(Details), Req).

qs_ipv4(forward, V) ->
    inet:parse_ipv4strict_address(binary_to_list(V));
qs_ipv4(reverse, V) ->
    inet:ntoa(V);
qs_ipv4(format_error, {einval, V}) ->
    io_lib:format("The value ~p is not an IPv4 address.", [V]).

qs_ipv6(forward, V) ->
    case binary:split(V, <<"/">>, [global]) of
	[BinIP, <<"128">>] ->
	    inet:parse_ipv6strict_address(binary_to_list(BinIP));
	_ ->
	    {error, einval}
    end;
qs_ipv6(reverse, V) ->
    <<(list_to_binary(inet:ntoa(V)))/binary, "/128">>;
qs_ipv6(format_error, {einval, V}) ->
    io_lib:format("The value ~p is not an IPv6 prefix.", [V]).

qs_snssai(forward, V) ->
    try
	case jsx:decode(V, [return_maps, {labels, existing_atom}]) of
	    #{sst := SST} = SNSSAI when is_integer(SST), SST >= 0, SST =< 255 ->
		{ok, SNSSAI};
	    #{sst := SST, sd := SD} = SNSSAI
	      when is_integer(SST), SST >= 0, SST =< 255,
		   byte_size(SD) =< 6 ->
		{ok, SNSSAI#{sd => binary_to_integer(SD, 16)}};
	    _O ->
		{error, einval}
	end
    catch
	_:_ ->
	    {error, einval}
    end;
qs_snssai(reverse, V) ->
    try
	{ok, jsx:encode(V)}
    catch
	_:_ ->
	    {error, einval}
    end;
qs_snssai(format_error, {einval, V}) ->
    io_lib:format("The value ~p is not an valid SNSSAI.", [V]).

query_filter(_, undefined, Filter) ->
    Filter;
query_filter('ipv4Addr', IP4, Filter) ->
    Filter#bsf{ip = {IP4, 32}};
query_filter('ipv6Prefix', IP6, Filter) ->
    Filter#bsf{ip = ergw_inet:ipv6_prefix({IP6, 128}, 64)};
query_filter(dnn, DNN, #bsf{} = Filter)
  when is_binary(DNN) ->
    Filter#bsf{dnn = binary:split(DNN, <<".">>, [global, trim_all])};
query_filter('ipDomain', Domain, #bsf{} = Filter)
  when is_binary(Domain) ->
    Filter#bsf{
      ip_domain =
	  << <<(size(Part)):8, Part/binary>> ||
	      Part <- binary:split(Domain, <<".">>, [global, trim_all]) >>};
query_filter(snssai, #{sst := SST, sd := SD}, Filter) ->
    Filter#bsf{snssai = {SST, SD}};
query_filter(snssai, #{sst := SST}, Filter) ->
    Filter#bsf{snssai = {SST, '_'}};
query_filter(_, _, Filter) ->
    Filter.
