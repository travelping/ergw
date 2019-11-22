%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(vrf).

%%-compile({parse_transform, cut}).

%% API
-export([validate_options/1, validate_option/2,
	 validate_name/1, normalize_name/1]).

-include_lib("kernel/include/logger.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% Options Validation
%%%===================================================================

validate_options(Options) ->
    ?LOG(debug, "VRF Options: ~p", [Options]),
    ergw_config:validate_options(fun validate_option/2, Options, [], map).

validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

validate_name(Name) ->
    try
	normalize_name(Name)
    catch
	_:_ ->
	    throw({error, {options, {vrf, Name}}})
    end.

normalize_name(Name)
  when is_atom(Name) ->
    List = binary:split(atom_to_binary(Name, latin1), [<<".">>], [global, trim_all]),
    normalize_name(List);
normalize_name([Label | _] = Name)
  when is_binary(Label) ->
    << <<(size(L)):8, L/binary>> || L <- Name >>;
normalize_name(Name)
  when is_list(Name) ->
    List = binary:split(list_to_binary(Name), [<<".">>], [global, trim_all]),
    normalize_name(List);
normalize_name(Name)
  when is_binary(Name) ->
    Name.

%% printable_name(Name) when is_binary(Name) ->
%%     L = [ Part || <<Len:8, Part:Len/bytes>> <= Name ],
%%     unicode:characters_to_binary(lists:join($., L));
%% printable_name(Name) ->
%%     unicode:characters_to_binary(io_lib:format("~p", [Name])).
