%% Copyright 2018, Travelping GmbH <info@travelping.com>

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

-export([lookup/2, colocation_match/2, topology_match/2]).

-ifdef(TEST).
-export([naptr/1]).
-define(NAPTR, ?MODULE:naptr).
-else.
-define(NAPTR, naptr).
-endif.

-compile({parse_transform, cut}).

%%====================================================================
%% API
%%====================================================================

-type service()           :: string().
-type protocol()          :: string().
-type service_parameter() :: {service(), protocol()}.
-type preference()        :: {integer(), integer()}.

-spec lookup(Name :: string(), QueryServices :: [service_parameter()]) ->
		    [{Host :: string(), Preference :: preference(),
		      Services :: [service_parameter()],
		      IPv4 :: [inet:ip4_address()],
		      IPv6 :: [inet:ip4_address()]}].
lookup(Name, ServiceSet) ->
    Response = ?NAPTR(Name),
    match(Response, ordsets:from_list(ServiceSet)).

colocation_match(CandidatesA, CandidatesB) ->
    Tree0 = #{},
    Tree1 = lists:foldl(insert_colo_candidates(_, 1, _), Tree0, CandidatesA),
    Tree = lists:foldl(insert_colo_candidates(_, 2, _), Tree1, CandidatesB),
    filter_tree(Tree).

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

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @private

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

insert_colo_candidates({Host, _, _, _, _} = Candidate, Pos, Tree) ->
    case string:tokens(Host, ".") of
	[Top, _ | Labels]
	  when Top =:= "topon"; Top =:= "topoff" ->
	    insert_candidate(Labels, Candidate, Pos, Tree);
	Labels ->
	    insert_candidate(Labels, Candidate, Pos, Tree)
    end.

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

naptr(Name) ->
    NsOpts =
	case setup:get_env(ergw, nameservers) of
	    undefined ->
		[];
	    {ok, Nameservers} ->
		[{nameservers, Nameservers}]
	end,
    %% 3GPP DNS answers are almost always large, use TCP by default....
    inet_res:resolve(Name, in, naptr, [{usevc, true} | NsOpts]).

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

match({ok, Msg}, OrdSPSet) ->
    FilteredAnswers =
	lists:foldl(naptr_filter(_, OrdSPSet, _), [], inet_dns:msg(Msg, anlist)),
    ArMap = arlist_to_map(Msg),
    [follow(RR, ArMap) || RR <- FilteredAnswers];
match(_, _) -> [].

arlist_to_map(RR, Map) ->
    Type = type(RR),
    Domain = string:to_lower(domain(RR)),
    Data = data(RR),
    maps:update_with(
      Type, maps:update_with(Domain, [Data|_], [Data], _), #{Domain => [Data]}, Map).

arlist_to_map(Msg) ->
    lists:foldl(fun arlist_to_map/2, #{}, inet_dns:msg(Msg, arlist)).

resolve_rr(Type, Key, ArMap) ->
    Hosts = maps:get(Type, ArMap, #{}),
    maps:get(Key, Hosts, []).

%% RFC2915: "A" means that the next lookup should be for either an A, AAAA, or A6 record.
%% We only support A for now.
follow({Host, Order, "a", Services}, ArMap) ->
    Key = string:to_lower(Host),
    IP4 = resolve_rr(a, Key, ArMap),
    IP6 = resolve_rr(aaaa, Key, ArMap),
    {Host, Order, Services, IP4, IP6};

%% RFC2915: the "S" flag means that the next lookup should be for SRV records.
follow({Host, Order, "s", Services}, ArMap) ->
    Key = string:to_lower(Host),
    SrvRRs = resolve_rr(srv, Key, ArMap),
    {IP4, IP6} = lists:foldl(follow_srv(_, ArMap, _), {[], []}, SrvRRs),
    {Host, Order, Services, IP4, IP6}.

follow_srv({_Prio, _Weight, _Port, Host}, ArMap, {IP4in, IP6in}) ->
    Key = string:to_lower(Host),
    IP4 = resolve_rr(a, Key, ArMap),
    IP6 = resolve_rr(aaaa, Key, ArMap),
    {IP4 ++ IP4in, IP6 ++ IP6in}.

domain(Resource) -> inet_dns:rr(Resource, domain).
data(Resource) -> inet_dns:rr(Resource, data).
type(Resource) -> inet_dns:rr(Resource, type).
