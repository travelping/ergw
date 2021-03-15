%% Copyright 2020 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_socket).

-export([start_link/3, validate_options/1]).

-ignore_xref([start_link/3]).

%%====================================================================
%% API
%%====================================================================

start_link('gtp-c', Name, Opts) ->
    ergw_gtp_c_socket:start_link(Name, Opts);
start_link('gtp-u', Name, Opts) ->
    ergw_gtp_u_socket:start_link(Name, Opts);
start_link('pfcp', Name, Opts) ->
    ergw_sx_socket:start_link(Name, Opts).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

validate_options(Values) when ?non_empty_opts(Values) ->
    ergw_core_config:validate_options(fun validate_option/2, Values, []);
validate_options(Values) ->
    throw({error, {options, {sockets, Values}}}).

validate_option(_Name, #{type := Type} = Values)
  when Type =:= 'gtp-c';
       Type =:= 'gtp-u' ->
    ergw_gtp_socket:validate_options(Values);
validate_option(_Name, #{type := pfcp} = Values) ->
    ergw_sx_socket:validate_options(Values);
validate_option(Name, Values) when is_list(Values) ->
    validate_option(Name, ergw_core_config:to_map(Values));
validate_option(Opt, Values) ->
    throw({error, {options, {Opt, Values}}}).
