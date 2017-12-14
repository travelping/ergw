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

-export([naptr/1, lookup/1, lookup/2]).

%%====================================================================
%% API
%%====================================================================

%% @private
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

-spec lookup(Name :: string() | inet:ip_address()) -> 
    list(inet:ip_address()).
lookup(Name) -> 
    Response = ?MODULE:naptr(Name),
    lists:usort(match(Response, v1) ++ match(Response, v2)).

-spec lookup(Name :: string() | inet:ip_address(), Version :: v1 | v2) -> 
    list(inet:ip_address()).
lookup(Name, Version) ->
    Response = ?MODULE:naptr(Name),
    match(Response, Version).

%%%===================================================================
%%% Internal functions
%%%===================================================================

match({ok, Msg}, Version) ->
    FilteredAnswers = [data(Answer)
		       || Answer <- inet_dns:msg(Msg, anlist),
				    inet_dns:rr(Answer, type) =:= naptr,
				    version(Answer, Version)],
    FilteredResources = [follow(Answer, inet_dns:msg(Msg, arlist))
			 || Answer <- FilteredAnswers],
    lists:flatten(FilteredResources);
match(_, _) -> [].

%% RFC2915: "A" means that the next lookup should be for either an A, AAAA, or A6 record. 
%% We only support A for now.
follow({_Order, _Pref, "a", _Server, _Regexp, Replacement}, Resources) -> 
    [data(Resource)
     || Resource <- Resources,
		    type(Resource) =:= a,
		    string_equal(domain(Resource), Replacement)];

%% RFC2915: the "S" flag means that the next lookup should be for SRV records.
follow({_Order, _Pref, "s", _Server, _Regexp, Replacement}, Resources) -> 
    [follow(data(Resource), Resources)
     || Resource <- Resources,
		    type(Resource) =:= srv,
		    string_equal(domain(Resource), Replacement)];

%% This happens for SRV resource
follow({_Prio, _Weight, _Port, Target}, Resources) ->
    [data(Resource)
     || Resource <- Resources,
		    type(Resource) =:= a,
		    string_equal(domain(Resource), Target)];

follow(_, _) -> [].

domain(Resource) -> inet_dns:rr(Resource, domain).
data(Resource) -> inet_dns:rr(Resource, data).
type(Resource) -> inet_dns:rr(Resource, type).

string_equal(Str1, Str2) -> string:to_lower(Str1) == string:to_lower(Str2).

% x-gn and x-gp for GTPv1,
% x-s5-gtp and x-s8-gtp for GTPv2
version(RR, v1) -> version(RR, ["x-gn", "x-gp"]);
version(RR, v2) -> version(RR, ["x-s5-gtp", "x-s8-gtp"]);
version(RR, Offer) when is_list(Offer) ->
    {_, _, _, Services0, _, _} = data(RR),
    %% XXX: Services (3GPP TS 23.003 Section 19.4.3) are ignored
    [_Service | Protocols] = string:tokens(Services0, ":"),
    lists:any(fun(Protocol) -> lists:member(Protocol, Protocols) end, Offer);
version(_, _) -> false.
