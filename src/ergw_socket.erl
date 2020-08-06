%% Copyright 2020 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_socket).

-export([start_link/2, validate_options/1]).

%%====================================================================
%% API
%%====================================================================

start_link('gtp-c', Opts) ->
    ergw_gtp_c_socket:start_link(Opts);
start_link('gtp-u', Opts) ->
    ergw_gtp_u_socket:start_link(Opts);
start_link('pfcp', Opts) ->
    ergw_sx_socket:start_link(Opts);
start_link('dhcp', Opts) ->
    ergw_dhcp_socket:start_link(Opts).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(is_opts(X), (is_list(X) orelse is_map(X))).

validate_options(Values) when is_list(Values), length(Values) >= 1 ->
    ergw_config:check_unique_keys(sockets, Values),
    ergw_config:validate_options(fun validate_option/2, Values, [], list);
validate_options(Values) ->
    throw({error, {options, {sockets, Values}}}).

validate_option(Name, Values)
  when is_atom(Name), ?is_opts(Values) ->
    case ergw_config:get_opt(type, Values, undefined) of
	'gtp-c' ->
	    ergw_gtp_socket:validate_options(Name, Values);
	'gtp-u' ->
	    ergw_gtp_socket:validate_options(Name, Values);
	'pfcp' ->
	    ergw_sx_socket:validate_options(Name, Values);
	'dhcp' ->
	    ergw_dhcp_socket:validate_options(Name, Values);
	_ ->
	    throw({error, {options, {Name, Values}}})
    end;
validate_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).
