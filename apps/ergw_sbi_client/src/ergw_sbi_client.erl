-module(ergw_sbi_client).

-export([
    start_link/0
]).

-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2
]).

-export([
    setup/1,
    upf_selection/1
]).

-ifdef(TEST).
-export([from_session/1]).
-endif.

-ignore_xref([?MODULE]).

%%% ============================================================================
%%% API functions
%%% ============================================================================

start_link() ->
    Opts = [{hibernate_after, 5000}, {spawn_opt, [{fullsweep_after, 0}]}],
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], Opts).

upf_selection(Session) ->
    Query = from_session(Session),
    gen_server:call(?MODULE, {upf_selection, Query}).

setup(Config) ->
    gen_server:call(?MODULE, {setup, Config}).

%%% ============================================================================
%%% gen_server callbacks functions
%%% ============================================================================

init([]) ->
    {ok, #{}}.

handle_call({setup, Config}, _From, _State) ->
    _ = ergw_sbi_client_config:validate_options(
	  fun ergw_sbi_client_config:validate_option/2, Config),
    {reply, ok, #{}};
handle_call({upf_selection, Data}, _From, State) ->
    {Result, NewState} = upf_selection(Data, State),
    {reply, Result, NewState};
handle_call(_Request, _From, State) ->
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

put_kv([K], V, M) ->
    M#{K => V};
put_kv([H|T], V, M) ->
    maps:put(H, put_kv(T, V, maps:get(H, M, #{})), M).

from_ip({_, _, _, _} = IP) ->
    #{<<"ipv4Addr">> => iolist_to_binary(inet:ntoa(IP))};
from_ip({_, _, _, _,_, _, _, _} = IP) ->
    #{<<"ipv6Addr">> => iolist_to_binary(inet:ntoa(IP))}.

split_location_info(<<MCC:3/bytes, MNC:3/bytes, Rest/binary>> = Bin, Size)
  when byte_size(Bin) == Size ->
    {{MCC, MNC}, Rest};
split_location_info(<<MCC:3/bytes, MNC:2/bytes, Rest/binary>>, _Size) ->
    {{MCC, MNC}, Rest}.

from_session(Session) ->
    maps:fold(fun from_session/3, #{}, Session).

from_session('APN', [H|_] = V, Req) when is_binary(H) ->
    Req#{<<"accessPointName">> => iolist_to_binary(lists:join($., V))};
from_session('3GPP-IMSI', V, Req) ->
    Req#{<<"supi">> => <<"imsi-", V/binary>>};
from_session('3GPP-SGSN-MCC-MNC', <<MCC:3/bytes, MNC/binary>>, Req) ->
    put_kv([<<"vPlmn">>, <<"plmnId">>], #{<<"mcc">> => MCC, <<"mnc">> => MNC}, Req);
from_session('3GPP-SGSN-Address', V, Req) ->
    put_kv([<<"vPlmn">>, <<"cpAddress">>], from_ip(V), Req);
from_session('3GPP-SGSN-IPv6-Address', V, Req) ->
    put_kv([<<"vPlmn">>, <<"cpAddress">>], from_ip(V), Req);
from_session('3GPP-SGSN-UP-Address', V, Req) ->
    put_kv([<<"vPlmn">>, <<"upAddress">>], from_ip(V), Req);
from_session('3GPP-SGSN-UP-IPv6-Address', V, Req) ->
    put_kv([<<"vPlmn">>, <<"upAddress">>], from_ip(V), Req);
from_session('GTP-Version', v1, Req) ->
    Req#{<<"protocolType">> => <<"GTPv1">>};
from_session('GTP-Version', v2, Req) ->
    Req#{<<"protocolType">> => <<"GTPv2">>};
from_session('3GPP-MSISDN', V, Req) ->
    Req#{<<"gpsi">> => <<"msisdn-", V/binary>>};
from_session('3GPP-IMEISV' , V, Req) ->
    Req#{<<"pei">> => <<"imeisv-", V/binary>>};

from_session('CGI', V, Req) when is_binary(V) ->
    case split_location_info(V, 10) of
	{{MCC, MNC}, <<LAC:16, CI:16>>} ->
	    Id = #{<<"plmnId">> => #{<<"mcc">> => MCC, <<"mnc">> => MNC},
		   <<"lac">> => LAC,
		   <<"cellId">> => CI},
	    put_kv([<<"userLocationInfo">>, <<"cgi">>], Id, Req);
	_ ->
	    %% unable do decode CGI
	    Req
    end;
from_session('SAI', V, Req) when is_binary(V) ->
    case split_location_info(V, 10) of
	{{MCC, MNC}, <<LAC:16, SAC:16>>} ->
	    Id = #{<<"plmnId">> => #{<<"mcc">> => MCC, <<"mnc">> => MNC},
		   <<"lac">> => LAC,
		   <<"sac">> => SAC},
	    put_kv([<<"userLocationInfo">>, <<"sai">>], Id, Req);
	_ ->
	    %% unable do decode SAI
	    Req
    end;
from_session('RAI', V, Req) when is_binary(V) ->
    case split_location_info(V, 9) of
	{{MCC, MNC}, <<LAC:16, RAC:8>>} ->
	    Id = #{<<"plmnId">> => #{<<"mcc">> => MCC, <<"mnc">> => MNC},
		   <<"lac">> => LAC,
		   <<"rac">> => RAC},
	    put_kv([<<"userLocationInfo">>, <<"rai">>], Id, Req);
	_ ->
	    %% unable do decode RAI
	    Req
    end;

from_session('QoS-Information' = K, V, Req) ->
    Req#{K => V};
from_session(_, _, Req) ->
    Req.

upf_selection(Data, #{upf_selection :=
  #{timeout := Timeout,uri := #{path := Path}} = Config} = State) ->
    case gun_open(Config) of
	{ok, Pid} ->
	    Headers = [{<<"content-type">>, <<"application/json">>}],
	    Body = jsx:encode(Data),
	    StreamRef = gun:post(Pid, Path, Headers, Body),
	    Resp = get_reponse(#{timeout => Timeout,
				 stream_ref => StreamRef,
				 pid => Pid,
				 acc => <<>>}),
	    {Resp, State#{upf_selection => Config#{pid => Pid}}};
	{error, timeout} = Resp ->
	    {Resp, State};
	{error, _Reason} = Resp ->
	    {Resp, State}
    end;
upf_selection(Data, State) ->
    case application:get_env(ergw_sbi_client, upf_selection, #{}) of
	#{endpoint := Endpoint} = Config ->
	    case parse_uri(Endpoint) of
		#{} = URI ->
		    upf_selection(Data, State#{upf_selection => Config#{uri => URI}});
		Error ->
		    {Error, State}
	    end;
	_ ->
	    {{error, not_configured}, State}
    end.

gun_open(#{pid := Pid} = Opts) when is_pid(Pid) ->
    case is_process_alive(Pid) of
	true ->
	    {ok, Pid};
	false ->
	    gun_open(maps:remove(pid, Opts))
    end;
gun_open(#{uri := #{host := Host, port := Port}, timeout := Timeout}) ->
    GunOpts = #{http2_opts => #{keepalive => infinity},
		protocols => [http2]},
    case gun:open(Host, Port, GunOpts) of
	{ok, Pid} ->
	    case gun:await_up(Pid, Timeout) of
		{ok, _} ->
		    {ok, Pid};
		{error, timeout} = Resp ->
		    Resp;
		{error, _Reason} = Resp ->
		    Resp
	    end;
	Error ->
	    Error
    end;
gun_open(_) ->
    {error, badarg}.

get_reponse(#{pid := Pid, stream_ref := StreamRef, timeout := Timeout, acc := Acc} = Opts) ->
    %% @TODO: fix correct 'Timeout' calculation issue and add time of request finished
    case gun:await(Pid, StreamRef, Timeout) of
	{response, fin, Status, Headers} ->
	    handle_response(#{status => Status, headers => Headers}, Acc);
	{response, nofin, Status, Headers} ->
	    get_reponse(Opts#{status => Status, headers => Headers});
	{data, nofin, Data} ->
	    get_reponse(Opts#{acc => <<Acc/binary, Data/binary>>});
	{data, fin, Data} ->
	    handle_response(Opts, <<Acc/binary, Data/binary>>);
	{error, timeout} = Response ->
	    Response;
	{error, _Reason} = Response->
	    Response
    end.

handle_response(#{status := 200, headers := Headers}, Data) ->
    case lists:keyfind(<<"content-type">>, 1, Headers) of
	{<<"content-type">>, ContentType} ->
	    case cow_http_hd:parse_content_type(ContentType) of
		{<<"application">>, <<"json">>, _Param} ->
		    case jsx:decode(Data, [{labels, binary}, return_maps]) of
			#{<<"ipv4Addr">> := IP} when is_binary(IP) ->
			    inet:parse_ipv4_address(binary_to_list(IP));
			#{<<"ipv6Addr">> := IP} when is_binary(IP) ->
			    inet:parse_ipv6_address(binary_to_list(IP));
			#{<<"fqdn">> := FQDN} when is_binary(FQDN) ->
			    {ok, FQDN};
			_ ->
			    {error, invalid_payload}
		    end;
		_ ->
		    {error, invalid_content_type}
	    end;
	_ ->
	    {error, no_content_type}
    end;
handle_response(_, _) ->
    {error, invalid_response}.

parse_uri(URI) when is_list(URI) ->
    case uri_string:parse(URI) of
	#{host := _, port := _, path := _, scheme := _} = ParsedUri ->
	    ParsedUri;
	#{} = ParsedUri ->
	    ParsedUri#{port => 443};
	Error ->
	    Error
    end;
parse_uri(URI) when is_binary(URI) ->
    parse_uri(binary_to_list(URI));
parse_uri(_) ->
    {error, parse}.
