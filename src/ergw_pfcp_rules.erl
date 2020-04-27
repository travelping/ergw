%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_pfcp_rules).

-compile({parse_transform, cut}).

-export([add/2, add/4, update_with/5]).

-include_lib("kernel/include/logger.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% Manage PFCP rules in context
%%%===================================================================

add(Type, Key, Rule, #pfcp_ctx{sx_rules = Rules} = PCtx) ->
    PCtx#pfcp_ctx{
      sx_rules = Rules#{{Type, Key} => pfcp_packet:ies_to_map(Rule)}}.

add([], PCtx) ->
    PCtx;
add([{Type, Key, Rule}|T], PCtx)
  when is_atom(Rule) ->
    add(T, add(Type, Key, Rule, PCtx));
add([{Type, Key, Rule0}|T], PCtx) ->
    Rule = pfcp_packet:ies_to_map(Rule0),
    add(T, add(Type, Key, Rule, PCtx)).

update_with(Type, Key, Fun, Init, #pfcp_ctx{sx_rules = Rules} = PCtx) ->
    PCtx#pfcp_ctx{
      sx_rules =
	  maps:update_with({Type, Key}, Fun, pfcp_packet:ies_to_map(Init), Rules)}.
