%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_c_lib).

-export([build_req_record/3]).
-export([ip2bin/1, bin2ip/1]).
-export([alloc_tei/0]).
-export([fmt_gtp/1]).

-include_lib("gtplib/include/gtp_packet.hrl").

%%====================================================================
%% Request validation helper
%%====================================================================

build_req_record(RecTag, Spec, IEs) ->
    {Fields, {Add, Missing}} = lists:mapfoldl(fun req_merge/2, {IEs, []}, Spec),
    Record = list_to_tuple([RecTag | Fields] ++ [Add]),
    {Record, Missing}.

req_merge({IdWant, Opt}, {IEs, Missing}) ->
    case req_find(IdWant, IEs) of
	undefined when Opt == mandatory ->
	    {undefined, {IEs, [IdWant|Missing]}};
	undefined ->
	    {undefined, {IEs, Missing}};
	Value ->
	    {Value, {lists:delete(Value, IEs), Missing}}
    end.

req_find(_, []) ->
    undefined;
req_find({Type, Instance}, [IE|_])
  when element(1, IE) == Type andalso
       element(2, IE) == Instance ->
    IE;
req_find(IdWant, [_|Next]) ->
    req_find(IdWant, Next).

%%====================================================================
%% IP helpers
%%====================================================================

ip2bin(IP) when is_binary(IP) ->
    IP;
ip2bin({A, B, C, D}) ->
    <<A, B, C, D>>;
ip2bin({A, B, C, D, E, F, G, H}) ->
    <<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>.

bin2ip(<<A, B, C, D>>) ->
    {A, B, C, D};
bin2ip(<<A:16, B:16, C:16, D:16, E:16, F:16, G:16, H:16>>) ->
    {A, B, C, D, E, F, G, H}.

%%====================================================================
%% TEI registry
%%====================================================================

-define(MAX_TRIES, 32).

alloc_tei() ->
    alloc_tei(?MAX_TRIES).

alloc_tei(0) ->
    {error, no_tei};
alloc_tei(Cnt) ->
    TEI = erlang:unique_integer([positive]) rem 4294967296,    %% 32bit maxint + 1
    case gtp_context_reg:register(TEI) of
	ok ->
	    {ok, TEI};
	_Other ->
	    alloc_tei(Cnt - 1)
    end.

%%%===================================================================
%%% Helper functions
%%%===================================================================

fmt_ies(IEs) ->
    lists:map(fun(#v2_bearer_context{group = Group}) ->
		      lager:pr(#v2_bearer_context{group = fmt_ies(Group)}, ?MODULE);
		 (X) ->
		      lager:pr(X, ?MODULE)
	      end, IEs).

fmt_gtp(#gtp{ie = IEs} = Msg) ->
    lager:pr(Msg#gtp{ie = fmt_ies(IEs)}, ?MODULE).
