%% Copyright 2020 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_socket).

-export([start_link/2, validate_options/1]).

-ignore_xref([start_link/2]).

%%====================================================================
%% API
%%====================================================================

start_link('gtp-c', Opts) ->
    ergw_gtp_c_socket:start_link(Opts);
start_link('gtp-u', Opts) ->
    ergw_gtp_u_socket:start_link(Opts);
start_link('pfcp', Opts) ->
    ergw_sx_socket:start_link(Opts).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(is_opts(X), (is_list(X) orelse is_map(X))).

validate_options(Values) when is_list(Values), length(Values) >= 1 ->
    ergw_core_config:check_unique_keys(sockets, Values),
    ergw_core_config:validate_options(fun validate_option/2, Values, [], list);
validate_options(Values) ->
    throw({error, {options, {sockets, Values}}}).

validate_option(Name, #{type := Type} = Values)
  when Type =:= 'gtp-c';
       Type =:= 'gtp-u' ->
    ergw_gtp_socket:validate_options(Name, Values);
validate_option(Name, #{type := pfcp} = Values) ->
    ergw_sx_socket:validate_options(Name, Values);
validate_option(Name, Values) when is_list(Values) ->
    validate_option(Name, ergw_core_config:to_map(Values));
validate_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).
