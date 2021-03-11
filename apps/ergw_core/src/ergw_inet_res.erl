%% Copyright 2021 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_inet_res).

-behaviour(gen_server).

-compile({parse_transform, cut}).

%% API
-export([start_link/0, resolve/4]).

-ifdef(TEST).
-export([start/0]).
-endif.

-ignore_xref([start_link/0, start/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-define(NEG_CACHE_TTL, 900).       %% 900 seconds = 15min, for nxdomain

-record(state, {config, outstanding, cache_timer}).
-record(entry, {key, ttl, answer}).

%%%===================================================================
%%% API
%%%===================================================================

-ifdef(TEST).
start() ->
    gen_server:start({local, ?SERVER}, ?MODULE, [], []).
-endif.

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

resolve(Name, Selection, Class, Type) when is_binary(Name) ->
    case match(make_rr_key(Name, Selection, Class, Type)) of
	false ->
	    gen_server:call(?SERVER, {resolve, Name, Selection, Class, Type});
	Answer ->
	    Answer
    end.

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    process_flag(trap_exit, true),
    ets:new(?MODULE, [named_table, public, set, {keypos, #entry.key}, {read_concurrency, true}]),
    State = #state{
	       config = load_config(),
	       outstanding = #{},
	       cache_timer = init_timer()},
    {ok, State}.

handle_call({resolve, Name, Selection, Class, Type},
	    From, #state{config = Config, outstanding = Outstanding} = State)
  when is_map_key(Selection, Config)  ->
    Key = make_rr_key(Name, Selection, Class, Type),
    case match(Key) of
	false ->
	    case maps:is_key(Key, Outstanding) of
		true ->
		    {noreply, State#state{outstanding = maps:update_with(Key, [From|_], Outstanding)}};
		_ ->
		    case maps:get(Selection, Config) of
			{dns, NsOpts} ->
			    Owner = self(),
			    Pid = proc_lib:spawn_link(
				    fun () -> Owner ! {self(), res_resolve(Name, Selection, Class, Type, NsOpts)} end),
			    {noreply, State#state{outstanding = Outstanding#{Key => [From], Pid => Key}}};
			_ ->
			    {reply, {error, nxdomain}, State}
		    end
	    end;
	Answer ->
	    {reply, Answer, State}
    end;
handle_call(_, _From, State) ->
    {reply, {error, nxdomain}, State}.

handle_cast(_Request, State) ->
    {noreply, State}.

handle_info({Pid, Response}, State) when is_pid(Pid) ->
    response(Pid, Response, State);
handle_info({'EXIT', _, normal}, State) ->
    {noreply, State};
handle_info({'EXIT', Pid, _}, State) ->
    response(Pid, {error, nxdomain}, State);
handle_info(refresh_timeout, State) ->
    do_refresh_cache(),
    {noreply, State#state{cache_timer = init_timer()}};
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Config Support
%%%===================================================================

load_config() ->
    {ok, Config} = application:get_env(ergw_core, node_selection),
    maps:map(fun load_config/2, Config).

load_config(Name, {static, Entries}) ->
    DB = lists:foldl(load_static(Name, _, _), #{}, Entries),
    ets:insert(?SERVER, maps:values(DB)),
    {static, []};
load_config(_, {dns, NameServers}) ->
    {dns, nsopts(NameServers)}.

load_static(Selection, {Host, {Order, Pref}, Services, Replacement}, Entries) ->
    Data = {Order, Pref, a, Services, "", Replacement},
    RR = inet_dns:make_rr([{domain, Host}, {class, in}, {type, naptr},
			   {ttl, infinity}, {data, Data}]),
    make_cache_entry(Selection, RR, Entries);
load_static(Selection, {Host, IP4, IP6}, Entries0) ->
    Entries1 = lists:foldl(load_static(Selection, Host, a, _, _), Entries0, IP4),
    _Entries = lists:foldl(load_static(Selection, Host, aaaa, _, _), Entries1, IP6).

load_static(Selection, Host, Type, IP, Entries) ->
    RR = inet_dns:make_rr([{domain, Host}, {class, in}, {type, Type},
			   {ttl, infinity}, {data, IP}]),
    make_cache_entry(Selection, RR, Entries).

nsopts({_,_} = NameServers) ->
    [{nameservers, [NameServers]}];
nsopts(_) ->
    [].

%%%===================================================================
%%% Internal functions
%%%===================================================================

response(Pid, Response, #state{outstanding = Outstanding0} = State)
  when is_map_key(Pid, Outstanding0) ->
    {Key, Outstanding1} = maps:take(Pid, Outstanding0),
    {FromList, Outstanding} = maps:take(Key, Outstanding1),
    [gen_server:reply(From, Response) || From <- FromList],
    {noreply, State#state{outstanding = Outstanding}};
response(_Pid, _Response, State) ->
    {noreply, State}.

match(Key) ->
    Now = erlang:monotonic_time(second),
    case ets:lookup(?MODULE, Key) of
	[#entry{ttl = TTL}] when TTL /= infinity, TTL < Now ->
	    ets:delete(?MODULE, Key),
	    false;
	[#entry{answer = Answer}] ->
	    Answer;
	[] ->
	    false
    end.

update_cache_entry(#entry{ttl = TA} = A, #entry{ttl = TB} = B) when TA > TB ->
    update_cache_entry(B, A);
update_cache_entry(#entry{answer = AA} = A, #entry{answer = AB}) ->
    A#entry{answer = AA ++ AB}.

lowercase(Host) when is_list(Host) ->
    string:lowercase(iolist_to_binary(Host));
lowercase(Host) when is_binary(Host) ->
    string:lowercase(Host).

lower_rr(RR) ->
    Domain = inet_dns:rr(RR, domain),
    inet_dns:make_rr(RR, domain, lowercase(Domain)).

normalize_rr(RR0) ->
    RR = lower_rr(RR0),
    normalize_rr(inet_dns:rr(RR, class), inet_dns:rr(RR, type), inet_dns:rr(RR, data), RR).

normalize_naptr_flag([$a]) -> a;
normalize_naptr_flag([$A]) -> a;
normalize_naptr_flag([$s]) -> s;
normalize_naptr_flag([$S]) -> s;
normalize_naptr_flag(Flag) -> Flag.

%% 3GPP TS 23.003, Sect. 19.4.3.
tggp_service("x-3gpp-amf") -> 'x-3gpp-amf';
tggp_service("x-3gpp-ggsn") -> 'x-3gpp-ggsn';
tggp_service("x-3gpp-mme") -> 'x-3gpp-mme';
tggp_service("x-3gpp-msc") -> 'x-3gpp-msc';
tggp_service("x-3gpp-pgw") -> 'x-3gpp-pgw';
tggp_service("x-3gpp-sgsn") -> 'x-3gpp-sgsn';
tggp_service("x-3gpp-sgw") -> 'x-3gpp-sgw';
tggp_service("x-3gpp-ucmf") -> 'x-3gpp-ucmf';
tggp_service("x-3gpp-upf") -> 'x-3gpp-upf';
tggp_service(List) when is_list(List) ->
    list_to_binary(List).

tggp_protocol("x-gn") -> 'x-gn';
tggp_protocol("x-gp") -> 'x-gp';
tggp_protocol("x-n2") -> 'x-n2';
tggp_protocol("x-n26") -> 'x-n26';
tggp_protocol("x-n4") -> 'x-n4';
tggp_protocol("x-n55") -> 'x-n55';
tggp_protocol("x-nqprime") -> 'x-nqprime';
tggp_protocol("x-s1-u") -> 'x-s1-u';
tggp_protocol("x-s10") -> 'x-s10';
tggp_protocol("x-s11") -> 'x-s11';
tggp_protocol("x-s12") -> 'x-s12';
tggp_protocol("x-s16") -> 'x-s16';
tggp_protocol("x-s2a-gtp") -> 'x-s2a-gtp';
tggp_protocol("x-s2a-mipv4") -> 'x-s2a-mipv4';
tggp_protocol("x-s2a-pmip") -> 'x-s2a-pmip';
tggp_protocol("x-s2b-gtp") -> 'x-s2b-gtp';
tggp_protocol("x-s2b-pmip") -> 'x-s2b-pmip';
tggp_protocol("x-s2c-dsmip") -> 'x-s2c-dsmip';
tggp_protocol("x-s3") -> 'x-s3';
tggp_protocol("x-s4") -> 'x-s4';
tggp_protocol("x-s5-gtp") -> 'x-s5-gtp';
tggp_protocol("x-s5-pmip") -> 'x-s5-pmip';
tggp_protocol("x-s6a") -> 'x-s6a';
tggp_protocol("x-s8-gtp") -> 'x-s8-gtp';
tggp_protocol("x-s8-pmip") -> 'x-s8-pmip';
tggp_protocol("x-sv") -> 'x-sv';
tggp_protocol("x-sxa") -> 'x-sxa';
tggp_protocol("x-sxb") -> 'x-sxb';
tggp_protocol("x-sxc") -> 'x-sxc';
tggp_protocol("x-urcmp") -> 'x-urcmp';
tggp_protocol(List) when is_list(List) ->
    list_to_binary(List).

normalize_naptr_services(Services) ->
    [Service | Protocols] = string:tokens(Services, ":"),
    [{tggp_service(Service), tggp_protocol(P)} || P <- Protocols].

normalize_rr(in, naptr, {Order, Pref, Flag, Services, RegExp, Host}, RR)
  when is_list(Host), is_list(RegExp) ->
    Data = {Order, Pref, normalize_naptr_flag(Flag),
	    normalize_naptr_services(Services), list_to_binary(RegExp), lowercase(Host)},
    inet_dns:make_rr(RR, data, Data);
normalize_rr(in, srv, {Prio, Weight, Port, Host}, RR) when is_list(Host) ->
    Data = {Prio, Weight, Port, lowercase(Host)},
    inet_dns:make_rr(RR, data, Data);
normalize_rr(in, ns, Host, RR) when is_list(Host) ->
    inet_dns:make_rr(RR, data, lowercase(Host));
normalize_rr(_Class, _Type, _Data, RR) ->
    RR.

msg_rr_list(Msg, List) ->
    lists:map(fun normalize_rr/1, inet_dns:msg(Msg, List)).

make_rr_key(Name, Selection, Class, Type) when is_list(Name) ->
    {iolist_to_binary(Name), Selection, Class, Type};
make_rr_key(Name, Selection, Class, Type) when is_binary(Name) ->
    {Name, Selection, Class, Type}.

make_rr_key(Selection, RR) ->
    make_rr_key(inet_dns:rr(RR, domain), Selection,
		inet_dns:rr(RR, class), inet_dns:rr(RR, type)).

make_cache_entry(Selection, RR0, Entries) ->
    RR = lower_rr(RR0),
    Key = make_rr_key(Selection, RR),
    Entry = #entry{key = Key, ttl = inet_dns:rr(RR, ttl), answer = [RR]},
    maps:update_with(Key, update_cache_entry(Entry, _), Entry, Entries).

make_cache_entries(Selection, List, Entries) ->
    lists:foldl(make_cache_entry(Selection, _, _), Entries, List).

res_resolve(Name, Selection, Class, Type, NsOpts) ->
    case inet_res:resolve(binary_to_list(Name), Class, Type, [{usevc, true} | NsOpts]) of
	{error, nxdomain} = Error ->
	    res_neg_cache_answer(Name, Selection, Class, Type, Error),
	    Error;
	{error, _} = Error ->
	    %% TBD: negative caching for servfail ???
	    %% TTL = erlang:monotonic_time(second) + MIN_NEG_CACHE_TTL,
	    %% res_neg_cache_rr(Name, Selection, Class, Type, TTL, Error),
	    Error;
	{ok, Msg} ->
	    res_cache_answer(Selection, Msg)
    end.

res_cache_answer(Selection, Msg) ->
    Now = erlang:monotonic_time(second),
    AN = msg_rr_list(Msg, anlist),
    Entries0 = make_cache_entries(Selection, AN, #{}),
    Entries1 = make_cache_entries(Selection, msg_rr_list(Msg, arlist), Entries0),
    Entries2 = make_cache_entries(Selection, msg_rr_list(Msg, nslist), Entries1),
    Entries = maps:map(fun(_, #entry{ttl = TTL} = E) -> E#entry{ttl = TTL + Now} end, Entries2),
    ets:insert(?SERVER, maps:values(Entries)),
    AN.

%% inet_res does not give us access to the SOA in the error message
res_neg_cache_answer(Name, Selection, Class, Type, Answer) ->
    Now = erlang:monotonic_time(second),
    TTL = find_cached_soa_ttl(Now, Name, Selection),
    res_neg_cache_rr(Name, Selection, Class, Type, TTL, Answer).

res_neg_cache_rr(Name, Selection, Class, Type, TTL, Answer) ->
    Entry = #entry{
	       key = make_rr_key(Name, Selection, Class, Type),
	       ttl = TTL,
	       answer = Answer},
    ets:insert(?SERVER, Entry).

find_cached_soa_ttl(Now, [], _) ->
    Now + ?NEG_CACHE_TTL;
find_cached_soa_ttl(Now, Name, Selection) ->
    case match(make_rr_key(Name, Selection, in, soa)) of
	false ->
	    [_|Next] = string:split(Name, "."),
	    find_cached_soa_ttl(Now, Next, Selection);
	[RR] ->
	    TTL = inet_dns:rr(RR, ttl), %% this value is already adjusted
	    {_, _, _Serial, _Refresh, _Retry, _Expire, Minimum} = inet_dns:rr(RR, data),
	    TTL, Now + Minimum
    end.

%% -------------------------------------------------------------------
%% Refresh cache at regular intervals, i.e. delete expired #dns_rr's.
%% -------------------------------------------------------------------

-define(CACHE_REFRESH,         60*60*1000).

init_timer() ->
    erlang:send_after(cache_refresh(), self(), refresh_timeout).

cache_refresh() ->
    ?CACHE_REFRESH.

%% Delete all entries with expired TTL.
%% Returns the access time of the entry with the oldest access time
%% in the cache.
do_refresh_cache() ->
    Now = erlang:monotonic_time(second),
    do_refresh_cache(ets:first(?MODULE), Now).

do_refresh_cache('$end_of_table', _) ->
    ok;
do_refresh_cache(Key, Now) ->
    Next = ets:next(?MODULE, Key),
    case ets:lookup(?MODULE, Key) of
	[#entry{ttl = TTL}] when TTL /= infinity, TTL < Now ->
	    ets:delete(?MODULE, Key);
	_ ->
	    ok
    end,
    do_refresh_cache(Next, Now).
