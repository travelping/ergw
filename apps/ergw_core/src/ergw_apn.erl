%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_apn).

-compile({no_auto_import,[get/1]}).

-export([add/2, get/1, get/2,
	 validate_options/1,
	 validate_apn_name/1]).

-include("ergw_core_config.hrl").
-include("include/ergw.hrl").

%%====================================================================
%% API
%%====================================================================

add(Name0, Opts0) ->
    {Name, Opts} = ergw_apn:validate_options({Name0, Opts0}),
    {ok, APNs} = ergw_core_config:get([apns], #{}),
    ergw_core_config:put(apns, maps:put(Name, Opts, APNs)).

get(APN) ->
    {ok, APNs} = ergw_core_config:get([apns], #{}),
    get(APN, APNs).

get([H|_] = APN0, APNs) when is_binary(H) ->
    APN = gtp_c_lib:normalize_labels(APN0),
    {NI, OI} = ergw_node_selection:split_apn(APN),
    FqAPN = NI ++ OI,
    case APNs of
	#{FqAPN := A} -> {ok, A};
	#{NI :=    A} -> {ok, A};
	#{'_' :=   A} -> {ok, A};
	_ -> {error, ?CTX_ERR(?FATAL, missing_or_unknown_apn)}
    end;
get(_, _) ->
    {error, ?CTX_ERR(?FATAL, missing_or_unknown_apn)}.

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(ApnDefaults, [{ip_pools, []},
		      {bearer_type, 'IPv4v6'},
		      {prefered_bearer_type, 'IPv6'},
		      {ipv6_ue_interface_id, default},
		      {inactivity_timeout, 48 * 3600 * 1000}         %% 48hrs timer in msecs
		     ]).

validate_options({APN0, Value}) when ?is_opts(Value) ->
    APN =
	if APN0 =:= '_' -> APN0;
	   true         -> validate_apn_name(APN0)
	end,
    Opts = ergw_core_config:validate_options(fun validate_apn_option/1, Value, ?ApnDefaults),
    ergw_core_config:mandatory_keys([vrfs], Opts),
    {APN, Opts};
validate_options({Opt, Value}) ->
    erlang:error(badarg, [Opt, Value]).

validate_apn_name(APN) when is_list(APN) ->
    try
	gtp_c_lib:normalize_labels(APN)
    catch
	error:badarg ->
	    erlang:error(badarg, [apn, APN])
    end;
validate_apn_name(APN) ->
    erlang:error(badarg, [apn, APN]).

validate_apn_option({vrf, Name}) ->
    {vrfs, [vrf:validate_name(Name)]};
validate_apn_option({vrfs = Opt, VRFs})
  when length(VRFs) /= 0 ->
    V = [vrf:validate_name(Name) || Name <- VRFs],
    ergw_core_config:check_unique_elements(Opt, V),
    {Opt, V};
validate_apn_option({ip_pools = Opt, Pools})
  when is_list(Pools) ->
    V = [ergw_ip_pool:validate_name(Opt, Name) || Name <- Pools],
    ergw_core_config:check_unique_elements(Opt, V),
    {Opt, V};
validate_apn_option({nat_port_blocks = Opt, [<<"*">>]}) ->
    {Opt, ['_']};
validate_apn_option({nat_port_blocks = Opt, ['_']} = V) ->
    {Opt, V};
validate_apn_option({nat_port_blocks, Blocks} = Opt)
  when is_list(Blocks), length(Blocks) /= 0 ->
    lists:foreach(
      fun(<<"*">>) -> erlang:error(badarg, [Opt]);
	 (B) when is_binary(B) -> ok;
	 (_) -> erlang:error(badarg, [Opt])
      end, Blocks),
    Opt;
validate_apn_option({bearer_type = Opt, Type})
  when Type =:= 'IPv4'; Type =:= 'IPv6'; Type =:= 'IPv4v6' ->
    {Opt, Type};
validate_apn_option({prefered_bearer_type = Opt, Type})
  when Type =:= 'IPv4'; Type =:= 'IPv6' ->
    {Opt, Type};
validate_apn_option({ipv6_ue_interface_id = Opt, Type})
  when Type =:= default;
       Type =:= random ->
    {Opt, Type};
validate_apn_option({ipv6_ue_interface_id, {0,0,0,0,E,F,G,H}} = Opt)
  when E >= 0, E < 65536, F >= 0, F < 65536,
       G >= 0, G < 65536, H >= 0, H < 65536,
       (E + F + G + H) =/= 0 ->
    Opt;
validate_apn_option({Opt, Value})
  when Opt == 'MS-Primary-DNS-Server';   Opt == 'MS-Secondary-DNS-Server';
       Opt == 'MS-Primary-NBNS-Server';  Opt == 'MS-Secondary-NBNS-Server';
       Opt == 'DNS-Server-IPv6-Address'; Opt == '3GPP-IPv6-DNS-Servers' ->
    {Opt, ergw_core_config:validate_ip_cfg_opt(Opt, Value)};
validate_apn_option({Opt = inactivity_timeout, Timer})
  when (is_integer(Timer) andalso Timer > 0)
       orelse Timer =:= infinity->
    {Opt, Timer};
validate_apn_option({Opt, Value}) ->
    erlang:error(badarg, [Opt, Value]).
