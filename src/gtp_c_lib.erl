%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_c_lib).

-export([ip2bin/1, bin2ip/1]).
-export([alloc_tei/0, enter_tei/3, lookup_tei/2, remove_tei/2]).

-include_lib("gtplib/include/gtp_packet.hrl").

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
    case gtp_path_reg:register_tei(TEI) of
	ok ->
	    {ok, TEI};
	_Other ->
	    alloc_tei(Cnt - 1)
    end.

enter_tei(TEI, TEInfo, #{tunnel_endpoints := TEReg0} = State) ->
    TEReg1 = gb_trees:enter(TEI, TEInfo, TEReg0),
    State#{tunnel_endpoints := TEReg1}.

lookup_tei(TEI, #{tunnel_endpoints := TEReg} = _State) ->
    case gb_trees:lookup(TEI, TEReg) of
	{value, Value} ->
	    {ok, Value};
	_ ->
	    {error, not_found}
    end;
lookup_tei(_TEI, _State) ->
    {error, not_found}.

remove_tei(TEI, #{tunnel_endpoints := TEReg0} = State) ->
    TEReg1 = gb_trees:delete_any(TEI, TEReg0),
    gtp_path_reg:unregister_tei(TEI),
    {ok, State#{tunnel_endpoints := TEReg1}};
remove_tei(_TEI, State) ->
    {ok, State}.
