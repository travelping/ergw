%% Copyright 2018,2019 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% @doc
%% This modules implements DNS-based Node Discovery according to 3GPP TS 29.303.
%% Right now this makes decission by lookup NAPTR record for given name. This
%% understands service and protocol names which are described in section
%% 19.4.3 of 3GPP TS 23.003.

-module(ergw_node_selection).

-compile({parse_transform, cut}).

-export([validate_options/1, expand_apn/2, split_apn/1,
	 apn_to_fqdn/2, apn_to_fqdn/1,
	 topology_match/2,
	 candidates/3, snaptr_candidate/1, topology_select/4,
	 lookup/2]).

-include_lib("kernel/include/logger.hrl").
-include("ergw_core_config.hrl").

-ifdef(TEST).
-export([lookup_naptr/3, colocation_match/2, naptr/2]).
-define(NAPTR, ?MODULE:naptr).
-else.
-define(NAPTR, naptr).
-endif.

-define(TIMEOUT, 1000).

%%====================================================================
%% API
%%====================================================================

-ifdef(TEST).
%% currently unused, but worth keeping arround
colocation_match(CandidatesA, CandidatesB) ->
    Tree0 = #{},
    Tree1 = lists:foldl(insert_colo_candidates(_, 1, _), Tree0, CandidatesA),
    Tree = lists:foldl(insert_colo_candidates(_, 2, _), Tree1, CandidatesB),
    filter_tree(Tree).
-endif.

topology_match(CandidatesA, CandidatesB) ->
    Tree0 = {#{}, #{}},
    Tree1 = lists:foldl(insert_topo_candidates(_, 1, _), Tree0, CandidatesA),
    {MatchTree, PrefixTree} = lists:foldl(insert_topo_candidates(_, 2, _), Tree1, CandidatesB),

    case filter_tree(MatchTree) of
	[] ->
	    filter_tree(PrefixTree);
	L ->
	    L
    end.

%% topology_select/3
topology_select(Candidates, Services, MatchPeers)
  when is_list(MatchPeers), length(MatchPeers) /= 0 ->
    TopoM = [{FQDN, 0, Services, [], []} || FQDN <- MatchPeers],
    case ergw_node_selection:topology_match(Candidates, TopoM) of
	{_, C} when is_list(C), length(C) /= 0 ->
	    C;
	{C, _} when is_list(C), length(C) /= 0 ->
	    C;
	_ ->
	    %% neither colocation, nor topology matched
	    Candidates
    end;
topology_select(Candidates, _, _) ->
    Candidates.

%% topology_select/4
topology_select(FQDN, MatchPeers, Services, NodeSelect) ->
    topology_select(candidates(FQDN, Services, NodeSelect), Services, MatchPeers).

candidates(Name, Services, NodeSelection) ->
    ServiceSet = ordsets:from_list(Services),
    Norm = normalize_name(Name),
    case lookup(iolist_to_binary(lists:join($., Norm)), ServiceSet, NodeSelection) of
	[] ->
	    %% no candidates, try with _default
	    DefaultAPN = normalize_name([<<"_default">>, <<"apn">>, <<"epc">>]),
	    lookup(iolist_to_binary(lists:join($., DefaultAPN)), ServiceSet, NodeSelection);
	L ->
	    L
    end.

expand_apn_plmn(IMSI) when is_binary(IMSI) ->
    {MCC, MNC, _} = itu_e212:split_imsi(IMSI),
    {MCC, MNC};
expand_apn_plmn(_) ->
    ergw_core:get_plmn_id().

expand_apn([H|_] = APN, IMSI)
  when is_binary(H) ->
    case lists:reverse(APN) of
	[<<"gprs">> | _] -> APN;
	[<<"org">>, <<"3gppnetwork">> | _] -> APN;
	_ ->
	    {MCC, MNC} = expand_apn_plmn(IMSI),
	    APN ++
		[iolist_to_binary(io_lib:format("mnc~3..0s", [MNC])),
		 iolist_to_binary(io_lib:format("mcc~3..0s", [MCC])),
		 <<"gprs">>]
    end.

split_apn([H|_] = APN)
  when is_binary(H) ->
    L = expand_apn(APN, undefined),
    lists:split(length(L) - 3, L).

apn_to_fqdn([H|_] = APN, IMSI)
  when is_binary(H) ->
    apn_to_fqdn(expand_apn(APN, IMSI)).

apn_to_fqdn([H|_] = APN)
  when is_binary(H) ->
    FQDN =
	case lists:reverse(APN) of
	    [<<"gprs">>, MCC, MNC | APN_NI] ->
		lists:reverse([<<"org">>, <<"3gppnetwork">>, MCC, MNC, <<"epc">>, <<"apn">> | APN_NI]);
	    [<<"org">>, <<"3gppnetwork">> | _] ->
		APN;
	    APN_NI ->
		normalize_name_fqdn([<<"epc">>, <<"apn">> | APN_NI])
	end,
    {fqdn, FQDN}.

%% select_by_preference/1
select_by_preference(L) ->
    %% number between 0 <= Rnd <= Max
    Total = lists:foldl(
	      fun({Pref, _}, Sum) -> Sum + Pref end, 0, L),
    Rnd = rand:uniform() * Total,
    fun F([{_, Node}], _) ->
	    Node;
	F([{Pref, Node}|_], Weight)
	  when Weight - Pref < 0 ->
	    Node;
	F([{Pref, _}|T], Weight) ->
	    F(T, Weight - Pref)
    end(L, Rnd).

%% see 3GPP TS 29.303, Annex B.2 and RFC 2782
snaptr_candidate(Candidates) ->
    PrefAddFun = fun(0, Node, L) ->
			 [{0, {0, Node}}|L];
		    (Preference, Node, L) ->
			 [{rand:uniform(), {Preference, Node}}|L]
		 end,
    {_, L} =
	lists:foldl(
	  fun({Node, {Order, Preference}, _, IP4, IP6}, {Order, L}) ->
		  E = {Node, IP4, IP6},
		  {Order, PrefAddFun(Preference, E, L)};
	     ({Node, {NOrder, Preference}, _, IP4, IP6}, {Order, _})
		when NOrder < Order ->
		  E = {Node, IP4, IP6},
		  {NOrder, PrefAddFun(Preference, E, [])};
	     (_, Acc) ->
		  Acc
	  end, {65535, []}, Candidates),
    PrefL = [N || {_,N} <- lists:sort(L)],
    N = {Name, _, _} = select_by_preference(PrefL),
    {N, lists:keydelete(Name, 1, Candidates)}.

%%%===================================================================
%%% Options Validation
%%%===================================================================

validate_options(Opts) when ?is_opts(Opts) ->
    ergw_core_config:validate_options(fun validate_options/2, Opts, []);
validate_options(Opts) ->
    erlang:error(badarg, [Opts]).

validate_options(_Name, #{type := static} = Opts) ->
    ergw_core_config:mandatory_keys([entries], Opts),
    ergw_core_config:validate_options(fun validate_static_option/2, Opts, []);
validate_options(_Name, #{type := dns} = Opts) ->
    ergw_core_config:mandatory_keys([server], Opts),
    ergw_core_config:validate_options(fun validate_dns_option/2, Opts, [{port, 53}]);
validate_options(Name, Opts) when is_list(Opts) ->
    validate_options(Name, ergw_core_config:to_map(Opts));
validate_options(Name, Opts) ->
    erlang:error(badarg, [Name, Opts]).

validate_static_option(type, Value) ->
    Value;
validate_static_option(entries, Entries) when is_list(Entries) ->
    lists:map(fun validate_static_entries/1, Entries);
validate_static_option(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

validate_static_entries(#{type := naptr} = Entry) when is_map(Entry) ->
    ergw_core_config:mandatory_keys(
      [name, order, preference, service, protocols, replacement], Entry),
    ergw_core_config:validate_options(fun validate_naptr/2, Entry, []);
validate_static_entries(#{type := host} = Entry) when is_map(Entry) ->
    ergw_core_config:mandatory_keys([name], Entry),
    ergw_core_config:validate_options(fun validate_host/2, Entry, [{ip4, []}, {ip6, []}]);
validate_static_entries(Entry) when is_list(Entry) ->
    validate_static_entries(ergw_core_config:to_map(Entry));
validate_static_entries(Entry) ->
    erlang:error(badarg, [Entry]).

validate_service('x-3gpp-amf')  -> ok;
validate_service('x-3gpp-ggsn') -> ok;
validate_service('x-3gpp-mme')  -> ok;
validate_service('x-3gpp-msc')  -> ok;
validate_service('x-3gpp-pgw')  -> ok;
validate_service('x-3gpp-sgsn') -> ok;
validate_service('x-3gpp-sgw')  -> ok;
validate_service('x-3gpp-ucmf') -> ok;
validate_service('x-3gpp-upf')  -> ok;
validate_service(Value) ->
    erlang:error(badarg, [service, Value]).

validate_protocol('x-gn') -> ok;
validate_protocol('x-gp') -> ok;
validate_protocol('x-n2') -> ok;
validate_protocol('x-n26') -> ok;
validate_protocol('x-n4') -> ok;
validate_protocol('x-n55') -> ok;
validate_protocol('x-nqprime') -> ok;
validate_protocol('x-s1-u') -> ok;
validate_protocol('x-s10') -> ok;
validate_protocol('x-s11') -> ok;
validate_protocol('x-s12') -> ok;
validate_protocol('x-s16') -> ok;
validate_protocol('x-s2a-gtp') -> ok;
validate_protocol('x-s2a-mipv4') -> ok;
validate_protocol('x-s2a-pmip') -> ok;
validate_protocol('x-s2b-gtp') -> ok;
validate_protocol('x-s2b-pmip') -> ok;
validate_protocol('x-s2c-dsmip') -> ok;
validate_protocol('x-s3') -> ok;
validate_protocol('x-s4') -> ok;
validate_protocol('x-s5-gtp') -> ok;
validate_protocol('x-s5-pmip') -> ok;
validate_protocol('x-s6a') -> ok;
validate_protocol('x-s8-gtp') -> ok;
validate_protocol('x-s8-pmip') -> ok;
validate_protocol('x-sv') -> ok;
validate_protocol('x-sxa') -> ok;
validate_protocol('x-sxb') -> ok;
validate_protocol('x-sxc') -> ok;
validate_protocol('x-urcmp') -> ok;
validate_protocol(Value) ->
    erlang:error(badarg, [protocol, Value]).

validate_naptr(type, Value) ->
    Value;
validate_naptr(name, Value) when is_binary(Value) ->
    Value;
validate_naptr(order, Value) when is_integer(Value) ->
    Value;
validate_naptr(preference, Value) when is_integer(Value) ->
    Value;
validate_naptr(service, Value) when is_atom(Value) ->
    validate_service(Value),
    Value;
validate_naptr(protocols = Opt, Value) when ?is_non_empty_opts(Value) ->
    ergw_core_config:check_unique_elements(Opt, Value),
    [validate_protocol(V) || V <- Value],
    Value;
validate_naptr(replacement, Value) when is_binary(Value) ->
    Value;
validate_naptr(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

validate_host(type, Value) ->
    Value;
validate_host(name, Value) when is_binary(Value) ->
    Value;
validate_host(ip4, Value) when is_list(Value) ->
    lists:foreach(
      fun(IP) when ?IS_IPv4(IP) -> ok;
	 (IP) -> erlang:error(badarg, [ip4, IP])
      end, Value),
    Value;
validate_host(ip6, Value) when is_list(Value) ->
    lists:foreach(
      fun(IP) when ?IS_IPv6(IP) -> ok;
	 (IP) -> erlang:error(badarg, [ip6, IP])
      end, Value),
    Value;
validate_host(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

validate_dns_option(type, Value) ->
    Value;
validate_dns_option(server, Value) when ?IS_IP(Value) ->
    Value;
validate_dns_option(port, Value) when is_integer(Value) ->
    Value;
validate_dns_option(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private

expect_answer(_, Answer, 2) ->
    Answer;
expect_answer(Ref, {A4, A6} = Answer0, Cnt) ->
    receive
	{A4, Response} when is_list(Response) ->
	    expect_answer(Ref, {[inet_dns:rr(RR, data) || RR <- Response], A6}, Cnt + 1);
	{A4, _} ->
	    expect_answer(Ref, {[], A6}, Cnt + 1);
	{A6, Response} when is_list(Response) ->
	    expect_answer(Ref, {A4, [inet_dns:rr(RR, data) || RR <- Response]}, Cnt + 1);
	{A6, _} ->
	    expect_answer(Ref, {A4, []}, Cnt + 1);
	{Ref, timeout} ->
	    Answer0
    end.

al(Answer) when is_list(Answer) ->
    Answer;
al(_) -> [].

lookup_host(Name, Selection) ->
    Ref = make_ref(),
    erlang:send_after(?TIMEOUT, self(), {Ref, timeout}),
    Query = {async_lookup_host(Name, a, Selection),
	     async_lookup_host(Name, aaaa, Selection)},
    case expect_answer(Ref, Query, 0) of
	{IP4, IP6} when is_list(IP4) andalso IP4 /= [];
			is_list(IP6) andalso IP6 /= [] ->
	    {Name, al(IP4), al(IP6)};
	_ ->
	    {error, nxdomain}
    end.

async_lookup_host(Name, Type, Selection) ->
    Owner = self(),
    spawn(
      fun() -> Owner ! {self(), (catch ergw_inet_res:resolve(Name, Selection, in, Type))} end).

lookup_naptr(Name, ServiceSet, Selection) ->
    Response = ?NAPTR(Name, Selection),
    FilteredAnswers = match(Response, ordsets:from_list(ServiceSet)),
    lists:foldl(follow(_, Selection, _), [], FilteredAnswers).

match(Msg, OrdSPSet) when is_list(Msg) ->
    lists:foldl(naptr_filter(_, OrdSPSet, _), [], Msg);
match(_, _) ->
    [].

do_lookup([], _DoFun) ->
    [];
do_lookup([Selection|Next], DoFun) ->
    case DoFun(Selection) of
	[] ->
	    do_lookup(Next, DoFun);
	{error, _} = _Other ->
	    do_lookup(Next, DoFun);
	Host ->
	    Host
    end;
do_lookup(Selection, DoFun) ->
    do_lookup([Selection], DoFun).

lookup(Name, Selection) when is_binary(Name) ->
    do_lookup(Selection, lookup_host(Name, _)).

lookup(Name, ServiceSet, Selection) when is_binary(Name) ->
    do_lookup(Selection, lookup_naptr(Name, ServiceSet, _)).

normalize_name({fqdn, FQDN}) ->
    FQDN;
normalize_name([H|_] = Name) when is_binary(H) ->
    normalize_name_fqdn(lists:reverse(Name));
normalize_name(Name) when is_binary(Name) ->
    normalize_name_fqdn(lists:reverse(binary:split(Name, <<$.>>, [global]))).

normalize_name_fqdn([<<"org">>, <<"3gppnetwork">> | _] = Name) ->
    lists:reverse(Name);
normalize_name_fqdn([<<"epc">> | _] = Name) ->
    {MCC, MNC} = ergw_core:get_plmn_id(),
    lists:reverse(
      [<<"org">>, <<"3gppnetwork">>,
       iolist_to_binary(io_lib:format("mcc~3..0s", [MCC])),
       iolist_to_binary(io_lib:format("mnc~3..0s", [MNC])) |
       Name]).

add_candidate(Pos, Tuple, Candidate) ->
    L = erlang:element(Pos, Tuple),
    erlang:setelement(Pos, Tuple, [Candidate | L]).

insert_candidate(Label, {Host, Order, Services, IP4, IP6}, Pos, Tree) ->
    {_, Proto} = lists:unzip(Services),
    Candidate = {Host, Order, Proto, IP4, IP6},
    maps:update_with(Label, add_candidate(Pos, _, Candidate),
		     add_candidate(Pos, {[], []}, Candidate), Tree).

insert_candidates([], Candidate, Pos, Tree) ->
    insert_candidate([], Candidate, Pos, Tree);
insert_candidates([_|Next] = Label, Candidate, Pos, Tree0) ->
    Tree = insert_candidate(Label, Candidate, Pos, Tree0),
    insert_candidates(Next, Candidate, Pos, Tree).

-ifdef(TEST).
insert_colo_candidates({Host, _, _, _, _} = Candidate, Pos, Tree) ->
    case binary:split(Host, <<$.>>, [global]) of
	[Top, _ | Labels]
	  when Top =:= <<"topon">>; Top =:= <<"topoff">> ->
	    insert_candidate(Labels, Candidate, Pos, Tree);
	Labels ->
	    insert_candidate(Labels, Candidate, Pos, Tree)
    end.
-endif.

insert_topo_candidates({Host, _, _, _, _} = Candidate, Pos,
		       {MatchTree0, PrefixTree0} = Tree) ->
    case binary:split(Host, <<$.>>, [global]) of
	[<<"topon">>, _ | Labels] ->
	    PrefixTree = insert_candidates(Labels, Candidate, Pos, PrefixTree0),
	    MatchTree = insert_candidate(Labels, Candidate, Pos, MatchTree0),
	    {MatchTree, PrefixTree};
	_ ->
	    Tree
    end.

have_common_services({_, _, ServicesA, _, _}, {_, _, ServicesB, _, _}) ->
    not ordsets:is_disjoint(ServicesA, ServicesB).

merge_candidates(K, {A, B}, List) ->
    Degree = length(K),
    [{Degree, {X, Y}} || X <- lists:keysort(2, A),
			 Y <- lists:keysort(2, B),
			 have_common_services(X, Y)] ++ List.

filter_tree([], _, List) ->
    lists:reverse(List);
filter_tree(_, [], List) ->
    lists:reverse(List);
filter_tree([{_, H}|T], Elements, List) ->
    case lists:member(H, Elements) of
	true ->
	    filter_tree(T, lists:delete(H, Elements), [H | List]);
	_ ->
	    filter_tree(T, Elements, List)
    end.

filter_tree(Tree) ->
    List = maps:fold(fun merge_candidates/3, [], Tree),
    {_, Pairs} = lists:unzip(List),
    filter_tree(lists:reverse(lists:keysort(1, List)), lists:usort(Pairs), []).

naptr(Name, Selection) ->
    ergw_inet_res:resolve(Name, Selection, in, naptr).

naptr_service_filter({Order, Pref, Flag, Services, _RegExp, Host}, OrdSPSet, Acc) ->
    case ordsets:is_disjoint(Services, OrdSPSet) of
	true ->
	    Acc;
	_ ->
	    [{Host, {Order, 65535 - Pref}, Flag, Services} | Acc]
    end;
naptr_service_filter(_, _, Acc) ->
    Acc.

naptr_filter(RR, OrdSPSet, Acc) ->
    case inet_dns:rr(RR, type) of
	naptr ->
	    naptr_service_filter(data(RR), OrdSPSet, Acc);
	_ ->
	    Acc
    end.

%% RFC2915: "A" means that the next lookup should be for either an A, AAAA, or A6 record.
%% We only support A for now.
follow({Host, Order, a, Services}, Selection, Res) ->
    case lookup_host(Host, Selection) of
	{_, IP4, IP6} = _R ->
	    [{Host, Order, Services, IP4, IP6} | Res];
	_ ->
	    Res
    end;
%% RFC2915: the "S" flag means that the next lookup should be for SRV records.
follow({Host, Order, s, Services}, Selection, Res) ->
    case ergw_inet_res:resolve(Host, Selection, in, srv) of
	SrvRRs when is_list(SrvRRs) ->
	    case lists:foldl(follow_srv(_, _, Selection), {[], []}, SrvRRs) of
		{IP4, IP6} when is_list(IP4) andalso IP4 /= [];
				is_list(IP6) andalso IP6 /= [] ->
		    [{Host, Order, Services, IP4, IP6} | Res];
		_ ->
		    Res
	    end;
	_ ->
	    Res
    end.

follow_srv(RR, {IP4in, IP6in} = IPs, Selection) ->
    {_Prio, _Weight, _Port, Host} = data(RR),
    case lookup_host(Host, Selection) of
	{_, IP4, IP6} ->
	    {IP4 ++ IP4in, IP6 ++ IP6in};
	_ ->
	    IPs
    end.

data(Resource) -> inet_dns:rr(Resource, data).
