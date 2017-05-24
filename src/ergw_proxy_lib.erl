%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_proxy_lib).

-export([validate_option/2]).

%%%===================================================================
%%% API
%%%===================================================================

validate_option(proxy_data_source, Value) ->
    case code:ensure_loaded(Value) of
	{module, _} ->
	    ok;
	_ ->
	    throw({error, {options, {proxy_data_source, Value}}})
    end,
    Value;
validate_option(Opt, Value)
  when Opt == proxy_sockets;
       Opt == proxy_data_paths ->
    validate_context_option(Opt, Value);
validate_option(contexts, Values) when is_list(Values) ->
    lists:map(fun validate_context/1, Values);
validate_option(Opt, Value) ->
    gtp_context:validate_option(Opt, Value).

%%%===================================================================
%%% Options Validation
%%%===================================================================

validate_context_option(proxy_sockets, Value) when is_list(Value), Value /= [] ->
    Value;
validate_context_option(proxy_data_paths, Value) when is_list(Value), Value /= [] ->
    Value;
validate_context_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_context({Name, Opts0})
  when is_binary(Name), is_list(Opts0) ->
    Defaults = [{proxy_sockets,    []},
		{proxy_data_paths, []}],
    Opts = maps:from_list(ergw_config:validate_options(
			    fun validate_context_option/2, Opts0, Defaults)),
    {Name, Opts};
validate_context({Name, Opts0})
  when is_binary(Name), is_map(Opts0) ->
    Defaults = #{proxy_sockets    => [],
		 proxy_data_paths => []},
    Opts1 = maps:merge(Defaults, Opts0),
    Opts = maps:from_list(ergw_config:validate_options(
			    fun validate_context_option/2, maps:to_list(Opts1))),
    {Name, Opts};
validate_context(Value) ->
    throw({error, {options, {contexts, Value}}}).
