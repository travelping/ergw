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

-module(ergw_dns).

-export([naptr/1, srv/1, a/1]).

-export([lookup/1, lookup/2]).

%%====================================================================
%% API
%%====================================================================

%% @private
naptr(Name) ->
    inet_res:lookup(Name, in, naptr, get_ns_opts()).

%% @private
srv(Name) ->
    inet_res:lookup(Name, in, srv, get_ns_opts()).

%% @private
a(Name) ->
    inet_res:lookup(Name, in, a, get_ns_opts()).

-spec lookup(Name :: string() | inet:ip_address()) -> 
    list(inet:ip_address()).
lookup(Name) ->
    match(?MODULE:naptr(Name)).

-spec lookup(Name :: string() | inet:ip_address(), Version :: v1 | v2) ->
    list(inet:ip_address()).
lookup(Name, Version) ->
    Response = ?MODULE:naptr(Name),
    match(Response, Version).

%%%===================================================================
%%% Internal functions
%%%===================================================================
match(Results) ->
    FilteredResources = [Result
                         || Result <- Results,
                            version(Result, v1)]
                     ++ [Result
                         || Result <- Results,
                            version(Result, v2)],
    Resources = [follow(Resource)
                 || Resource <- lists:usort(FilteredResources)],
    lists:usort(lists:flatten(Resources)).

match(Results, Version) ->
    FilteredResources = [follow(Result)
                         || Result <- Results,
                            version(Result, Version)],
    lists:usort(lists:flatten(FilteredResources)).

%% RFC2915: "A" means that the next lookup should be for either an A, AAAA, or A6 record.
%% We only support A for now.
follow({_Order, _Pref, "a", _Server, _Regexp, Replacement}) ->
    ?MODULE:a(Replacement);

%% RFC2915: the "S" flag means that the next lookup should be for SRV records.
follow({_Order, _Pref, "s", _Server, _Regexp, Replacement}) ->
    [follow(Answer) || Answer <- ?MODULE:srv(Replacement)];

%% This happens for SRV resource
follow({_Prio, _Weight, _Port, Target}) ->
    ?MODULE:a(Target);

follow(_) -> [].

get_ns_opts() ->
    %% 3GPP DNS answers are almost always large, use TCP by default....
	case setup:get_env(ergw, nameservers) of
	    undefined ->
    		[{usevc, true}];
	    {ok, Nameservers} ->
    		[{usevc, true}, {nameservers, Nameservers}]
	end.

% x-gn and x-gp for GTPv1,
% x-s5-gtp and x-s8-gtp for GTPv2
version(RR, v1) -> version(RR, ["x-gn", "x-gp"]);
version(RR, v2) -> version(RR, ["x-s5-gtp", "x-s8-gtp"]);
version({_, _, _, Services0, _, _}, Offer) when is_list(Offer) ->
    %% XXX: Services (3GPP TS 23.003 Section 19.4.3) are ignored
    [_Service | Protocols] = string:tokens(Services0, ":"),
    lists:any(fun(Protocol) -> lists:member(Protocol, Protocols) end, Offer);
version(_, _) -> false.
