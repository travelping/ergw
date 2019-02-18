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

-export([validate_options/2, apn_to_fqdn/1,
	 lookup_dns/3, colocation_match/2, topology_match/2,
	 candidates/3, lookup/2, lookup/3]).

-ifdef(TEST).
-export([naptr/2]).
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

-spec lookup_dns(Name :: string(),
		 QueryServices :: [service_parameter()],
		 NameServers :: undefined | {inet:ip_address(), inet:port_number()}) ->
			[{Host :: string(), Preference :: preference(),
			  Services :: [service_parameter()],
			  IPv4 :: [inet:ip4_address()],
			  IPv6 :: [inet:ip4_address()]}].
lookup_dns(Name, ServiceSet, NameServers) ->
    Response = ?NAPTR(Name, NameServers),
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

candidates(Name, Services, NodeSelection) ->
    ServiceSet = ordsets:from_list(Services),
    Norm = normalize_name(Name),
    case get_candidates(lists:flatten(lists:join($., Norm)), ServiceSet, NodeSelection) of
	[] ->
	    %% no candidates, try with _default
	    DefaultAPN = normalize_name(["_default", "apn", "epc"]),
	    get_candidates(lists:flatten(lists:join($., DefaultAPN)),
			   ServiceSet, NodeSelection);
	L ->
	    L
    end.

apn_to_fqdn({fqdn, _} = FQDN) ->
    FQDN;
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

lookup_host(Name, dns, NameServers) ->
    NsOpts =
	case NameServers of
	    {_,_}  ->
		[{nameservers, [NameServers]}];
	    _ ->
		[]
	end,
    %% 3GPP DNS answers are almost always large, use TCP by default....
    case inet_res:resolve(Name, in, any, [{usevc, true} | NsOpts]) of
	{ok, Msg} ->
	    lists:foldl(
	      fun(RR, R) ->
		      case {inet_dns:rr(RR, class), inet_dns:rr(RR, type)} of
			  {in, a} ->
			      setelement(2, R, [inet_dns:rr(RR, data) | element(2, R)]);
			  {in, aaaa} ->
			      setelement(3, R, [inet_dns:rr(RR, data) | element(3, R)]);
			  Other ->
			      R
		      end
	      end, {Name, [], []}, inet_dns:msg(Msg, anlist));
	{error, _} = Error ->
	    lager:debug("DNS Error: ~p", [Error]),
	    Error
    end;
lookup_host(Name, static, RR) ->
    lager:info("Host ~p, RR ~p", [Name, RR]),
    case lists:keyfind(Name, 1, RR) of
	{_, _, _} = R ->
	    R;
	_ ->
	    {error, not_found}
    end.

lookup_naptr(Name, ServiceSet, dns, NameServers) ->
    lookup_dns(Name, ServiceSet, NameServers);
lookup_naptr(Name, ServiceSet, static, RR) ->
    L1 = [X || X <- RR, string:equal(element(1, X), Name, true),
			not ordsets:is_disjoint(element(3, X), ServiceSet)],
    lists:foldl(lookup_naptr_static(_, RR, _), [], L1).

lookup_naptr_static({_, Order, Services, Host}, RR, Acc) ->
    case lists:keyfind(Host, 1, RR) of
	{_, IP4, IP6} ->
	    [{Host, Order, Services, IP4, IP6} | Acc];
	_ ->
	    Acc
    end;
lookup_naptr_static(_, _, Acc) ->
    Acc.

do_lookup(Selection, DoFun) ->
    lager:info("Selection ~p in ~p", [Selection, application:get_env(ergw, node_selection, #{})]),
    case application:get_env(ergw, node_selection, #{}) of
	#{Selection := {Type, Opts}} ->
	    lager:info("Type ~p, Opts ~p", [Type, Opts]),
	    DoFun(Type, Opts);
	_ ->
	    []
    end.

lookup(Name, Selection) ->
    do_lookup(Selection, lookup_host(Name, _, _)).

lookup(Name, ServiceSet, Selection) ->
    do_lookup(Selection, lookup_naptr(Name, ServiceSet, _, _)).

get_candidates(_Name, _ServiceSet, []) ->
    [];
get_candidates(Name, ServiceSet, [NodeSelection | NextSelection]) ->
    case lookup(Name, ServiceSet, NodeSelection) of
	[] ->
	    get_candidates(Name, ServiceSet, NextSelection);
	L ->
	    L
    end.

normalize_name({fqdn, FQDN}) ->
    FQDN;
normalize_name([H|_] = Name) when is_list(H) ->
    normalize_name_fqdn(lists:reverse(Name));
normalize_name(Name) when is_list(Name) ->
    normalize_name_fqdn(lists:reverse(string:tokens(Name, "."))).

normalize_name_fqdn(["org", "3gppnetwork" | _] = Name) ->
    lists:reverse(Name);
normalize_name_fqdn(["epc" | _] = Name) ->
    {MCC, MNC} = ergw:get_plmn_id(),
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

naptr(Name, NameServers) ->
    NsOpts =
	case NameServers of
	    {_,_}  ->
		[{nameservers, [NameServers]}];
	    _ ->
		[]
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
