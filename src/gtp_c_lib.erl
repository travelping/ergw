%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_c_lib).

-compile({parse_transform, cut}).

-export([fmt_gtp/1]).
-export([normalize_labels/1]).

-include_lib("gtplib/include/gtp_packet.hrl").

%% make sure DNS and APN labels are lower case and contain only
%% permited characters (labels have to start with letters and
%% not end with hyphens, but we don't check that)
normalize_labels('_') ->
    '_';
normalize_labels(Labels) when is_list(Labels) ->
    lists:map(fun normalize_labels/1, Labels);
normalize_labels(Label) when is_binary(Label) ->
    << << (dns_char(C)):8 >> || <<C:8>> <= Label >>.

dns_char($-) ->
    $-;
dns_char(C) when C >= $0 andalso C =< $9 ->
    C;
dns_char(C) when C >= $A andalso C =< $Z ->
    C + 32;
dns_char(C) when C >= $a andalso C =< $z ->
    C;
dns_char(C) ->
    error(badarg, [C]).


%%%===================================================================
%%% Helper functions
%%%===================================================================

fmt_ie(#v2_bearer_context{group = Group}) ->
    lager:pr(#v2_bearer_context{group = fmt_ies(Group)}, ?MODULE);
fmt_ie(V) when is_list(V) ->
    lists:map(fun fmt_ie/1, V);
fmt_ie(V) ->
    lager:pr(V, ?MODULE).

fmt_ies(IEs) when is_map(IEs) ->
    maps:map(fun(_K, V) -> fmt_ie(V) end, IEs);
fmt_ies(IEs) when is_list(IEs) ->
    lists:map(fun fmt_ie/1, IEs);
fmt_ies(IEs) -> IEs.

fmt_gtp(#gtp{ie = IEs} = Msg) ->
    lager:pr(Msg#gtp{ie = fmt_ies(IEs)}, ?MODULE).
