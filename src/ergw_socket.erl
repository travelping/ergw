%% Copyright 2020 Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_socket).

-compile({parse_transform, cut}).

-export([start_link/3, validate_options/1, config_meta/0]).

-ignore_xref([start_link/3]).

%%====================================================================
%% API
%%====================================================================

start_link(Name, 'gtp-c', Opts) ->
    ergw_gtp_c_socket:start_link(Name, Opts);
start_link(Name, 'gtp-u', Opts) ->
    ergw_gtp_u_socket:start_link(Name, Opts);
start_link(Name, 'pfcp', Opts) ->
    ergw_sx_socket:start_link(Name, Opts).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(is_opts(X), (is_list(X) orelse is_map(X))).

validate_options(Values) when is_list(Values), length(Values) >= 1 ->
    ergw_config_legacy:check_unique_keys(sockets, Values),
    ergw_config_legacy:validate_options(fun validate_option/1, Values, [], map);
validate_options(Values) ->
    throw({error, {options, {sockets, Values}}}).

validate_option({Name, Values} = Opt) when is_atom(Name), ?is_opts(Values) ->
    ValuesOut =
	case ergw_config_legacy:get_opt(type, Values, undefined) of
	    'gtp-c' ->
		ergw_gtp_socket:validate_options(Name, Values);
	    'gtp-u' ->
		ergw_gtp_socket:validate_options(Name, Values);
	    'pfcp' ->
		ergw_sx_socket:validate_options(Name, Values);
	    _ ->
		throw({error, {options, Opt}})
	end,
    {ergw_config:to_binary(Name), ValuesOut};
validate_option(Opt) ->
    throw({error, {options, Opt}}).

config_meta() ->
    {{klist, {name, binary}, {delegate, fun delegate_type/1}}, #{}}.

delegate_type(Map) when is_map(Map) ->
    case ergw_config:to_atom(ergw_config:get_key(type, Map)) of
	'gtp-c' ->
	    ergw_gtp_socket:config_meta();
	'gtp-u' ->
	    ergw_gtp_socket:config_meta();
	'pfcp' ->
	    ergw_sx_socket:config_meta()
    end;
delegate_type(schema) ->
    Handlers = [ergw_gtp_socket,  ergw_sx_socket],
    lists:map(fun(Handler) -> Handler:config_meta() end, Handlers).
