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

-export([validate_options/2, expand_apn/2, split_apn/1,
	 apn_to_fqdn/2, apn_to_fqdn/1,
	 topology_match/2,
	 candidates/3, snaptr_candidate/1, topology_select/4,
	 lookup/2]).

-include_lib("kernel/include/logger.hrl").

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

%% -type service()           :: string().
%% -type protocol()          :: string().
%% -type service_parameter() :: {service(), protocol()}.
%% -type preference()        :: {integer(), integer()}.

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
    case lookup(lists:flatten(lists:join($., Norm)), ServiceSet, NodeSelection) of
	[] ->
	    %% no candidates, try with _default
	    DefaultAPN = normalize_name(["_default", "apn", "epc"]),
	    lookup(lists:flatten(lists:join($., DefaultAPN)), ServiceSet, NodeSelection);
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
    apn_to_fqdn([binary_to_list(X) || X <- APN]);
apn_to_fqdn(APN)
  when is_list(APN) ->
    FQDN =
	case lists:reverse(APN) of
	    ["gprs", MCC, MNC | APN_NI] ->
		lists:reverse(["org", "3gppnetwork", MCC, MNC, "epc", "apn" | APN_NI]);
	    ["org", "3gppnetwork" | _] ->
		APN;
	    APN_NI ->
		normalize_name_fqdn(["epc", "apn" | APN_NI])
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

-define(IS_IP(X), (is_tuple(X) andalso (tuple_size(X) == 4 orelse tuple_size(X) == 8))).

validate_ip_list(L) ->
    lists:foreach(
      fun(IP) when ?IS_IP(IP) -> ok;
	 (IP) -> throw({error, {options, {ip, IP}}})
      end, L).

validate_static_option({Label, {Order, Prio} = Degree, [{_,_}|_] = Services, Host})
  when is_list(Label),
       is_integer(Order),
       is_integer(Prio),
       is_list(Host) ->
    {Label, Degree, ordsets:from_list(Services), Host};
validate_static_option({Host, IP4, IP6} = Opt)
  when is_list(Host),
       is_list(IP4),
       is_list(IP6),
       (length(IP4) /= 0 orelse length(IP6) /= 0) ->
    validate_ip_list(IP4),
    validate_ip_list(IP6),
    Opt;
validate_static_option(Opt) ->
    throw({error, {options, {static, Opt}}}).

validate_options(static, Opts)
  when is_list(Opts), length(Opts) > 0 ->
    lists:map(fun validate_static_option/1, Opts);
validate_options(dns, undefined) ->
    undefined;
validate_options(dns, IP) when ?IS_IP(IP) ->
    {IP, 53};
validate_options(dns, {IP, Port} = Server)
  when ?IS_IP(IP) andalso is_integer(Port) ->
    Server;
validate_options(Type, Opts) ->
    throw({error, {options, {Type, Opts}}}).

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
do_lookup(Selection, DoFun) when is_atom(Selection) ->
    do_lookup([Selection], DoFun).

lookup(Name, Selection) ->
    do_lookup(Selection, lookup_host(Name, _)).

lookup(Name, ServiceSet, Selection) ->
    do_lookup(Selection, lookup_naptr(Name, ServiceSet, _)).

normalize_name({fqdn, FQDN}) ->
    FQDN;
normalize_name([H|_] = Name) when is_list(H) ->
    normalize_name_fqdn(lists:reverse(Name));
normalize_name(Name) when is_list(Name) ->
    normalize_name_fqdn(lists:reverse(string:tokens(Name, ".")));
normalize_name(Name) when is_binary(Name) ->
    normalize_name(binary_to_list(Name)).

normalize_name_fqdn(["org", "3gppnetwork" | _] = Name) ->
    lists:reverse(Name);
normalize_name_fqdn(["epc" | _] = Name) ->
    {MCC, MNC} = ergw_core:get_plmn_id(),
    lists:reverse(
      ["org", "3gppnetwork",
       lists:flatten(io_lib:format("mcc~3..0s", [MCC])),
       lists:flatten(io_lib:format("mnc~3..0s", [MNC])) |
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
    case string:tokens(Host, ".") of
	[Top, _ | Labels]
	  when Top =:= "topon"; Top =:= "topoff" ->
	    insert_candidate(Labels, Candidate, Pos, Tree);
	Labels ->
	    insert_candidate(Labels, Candidate, Pos, Tree)
    end.
-endif.

insert_topo_candidates({Host, _, _, _, _} = Candidate, Pos,
		       {MatchTree0, PrefixTree0} = Tree) ->
    case string:tokens(Host, ".") of
	["topon", _ | Labels] ->
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
    [Service | Protocols] = string:tokens(Services, ":"),
    RRSPSet = ordsets:from_list([{Service, P} || P <- Protocols]),
    case ordsets:is_disjoint(RRSPSet, OrdSPSet) of
	true ->
	    Acc;
	_ ->
	    [{Host, {Order, 65535 - Pref}, Flag, RRSPSet} | Acc]
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
follow({Host, Order, "a", Services}, Selection, Res) ->
    Key = string:to_lower(Host),
    case lookup_host(Key, Selection) of
	{_, IP4, IP6} ->
	    [{Host, Order, Services, IP4, IP6} | Res];
	_ ->
	    Res
    end;
%% RFC2915: the "S" flag means that the next lookup should be for SRV records.
follow({Host, Order, "s", Services}, Selection, Res) ->
    Key = string:to_lower(Host),
    case ergw_inet_res:resolve(Key, Selection, in, srv) of
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
    Key = string:to_lower(Host),
    case lookup_host(Key, Selection) of
	{_, IP4, IP6} ->
	    {IP4 ++ IP4in, IP6 ++ IP6in};
	_ ->
	    IPs
    end.

data(Resource) -> inet_dns:rr(Resource, data).
