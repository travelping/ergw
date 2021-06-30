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

-ignore_xref([?MODULE]).

%%% ============================================================================
%%% API functions
%%% ============================================================================

start_link() ->
    Opts = [{hibernate_after, 5000}, {spawn_opt, [{fullsweep_after, 0}]}],
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], Opts).

upf_selection(Data) ->
    gen_server:call(?MODULE, {upf_selection, Data}).

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

upf_selection(Data, #{upf_selection_api :=
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
            {Resp, State#{upf_selection_api => Config#{pid => Pid}}};
        {error, timeout} = Resp ->
            {Resp, #{}};
        {error, _Reason} = Resp ->
            {Resp, #{}}
    end;
upf_selection(Data, State) ->
    Config = #{endpoint := Endpoint} =
        application:get_env(ergw_sbi_client, upf_selection_api, #{}),
    case parse_uri(Endpoint) of
        #{} = URI ->
            upf_selection(Data, State#{upf_selection_api => Config#{uri => URI}});
        Error ->
            {Error, #{}}
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
                protocols => [http2, http]},
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

get_reponse(#{pid := Pid, stream_ref := StreamRef,
  timeout := Timeout, acc := Acc} = Opts) ->
    %% @TODO: fix correct 'Timeout' calculation issue and add time of request finished
    case gun:await(Pid, StreamRef, Timeout) of
        {response, fin, Status, Headers} ->
            {ok, #{status => Status, headers => Headers, response => Acc}};
        {response, nofin, Status, Headers} ->
            get_reponse(Opts#{status => Status, headers => Headers});
        {data, nofin, Data} ->
            get_reponse(Opts#{acc => <<Acc/binary, Data/binary>>});
        {data, fin, Data} ->
            Status = maps:get(status, Opts),
            Headers = maps:get(headers, Opts),
            {ok, #{status => Status, headers => Headers,
                   response => <<Acc/binary, Data/binary>>}};
        {error, timeout} = Response ->
            Response;
        {error, _Reason} = Response->
            Response
    end.

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
