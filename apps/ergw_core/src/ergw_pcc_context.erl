%% Copyright 2020, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_pcc_context).

-compile({parse_transform, cut}).

-export([pcc_ctx_to_credit_request/1]).
-export([
	 session_events_to_pcc_ctx/2,
	 gx_events_to_pcc_ctx/4,
	 gy_events_to_pcc_ctx/3,
	 gy_credit_request/2,
	 gy_credit_request/3
	]).
-export([pcc_ctx_has_rules/1]).

-include_lib("kernel/include/logger.hrl").
-include("include/ergw.hrl").

%%%===================================================================
%%% PCC context helper
%%%===================================================================

pcc_ctx_has_rules(#pcc_ctx{rules = Rules}) ->
    maps:size(Rules) /= 0.

get_rating_group(Key, M) when is_map(M) ->
    hd(maps:get(Key, M, maps:get('Rating-Group', M, [undefined]))).

%%%===================================================================
%%% Gy/Gx events to PCC context translation functions
%%%===================================================================

-record(pcc_upd, {errors = [], rules = #{}}).

session_events_to_pcc_ctx(Evs, PCC) ->
    lists:foldl(fun session_events_to_pcc_ctx_2/2, PCC, Evs).

session_events_to_pcc_ctx_2({set, {Service, {Type, Level, Interval, Opts}}},
			    #pcc_ctx{monitors = Monitors} = PCC) ->
    Definition = {Type, Interval, Opts},
    PCC#pcc_ctx{monitors =
		    maps:update_with(Level, maps:put(Service, Definition, _),
				     #{Service => Definition}, Monitors)};
session_events_to_pcc_ctx_2(Ev, PCC) ->
    ?LOG(warning, "unhandled Session Event ~p", [Ev]),
    PCC.

%% convert Gx like Install/Remove interactions in PCC rule states

%% gx_events_to_pcc_ctx/4
gx_events_to_pcc_ctx(Evs, Filter, RuleBase,
		     #pcc_ctx{rules = Rules0, credits = GrantedCredits} = PCC) ->
    #pcc_upd{errors = Errors, rules = Rules} =
	lists:foldl(update_pcc_rules(_, Filter, RuleBase, _), #pcc_upd{rules = Rules0}, Evs),
    Credits = maps:fold(pcc_rules_to_credits(_, _, GrantedCredits, _), #{}, Rules),
    {PCC#pcc_ctx{rules = Rules, credits = Credits}, Errors}.

update_pcc_rules({pcc, install, Ev}, Filter, RuleBase, Update)
  when Filter == install; Filter == '_' ->
    lists:foldl(install_pcc_rules(_, RuleBase, _), Update, Ev);
update_pcc_rules({pcc, remove, Ev}, Filter, _RuleBase, Update)
  when Filter == remove; Filter == '_' ->
    lists:foldl(fun remove_pcc_rules/2, Update, Ev);
update_pcc_rules(_, _, _, Update) ->
    Update.

pcc_rules_to_credits(_K, #{'Online' := [1]} = Definition, Granted, Acc) ->
    RatingGroup = get_rating_group('Online-Rating-Group', Definition),
    RG = maps:get(RatingGroup, Granted, empty),
    maps:update_with(RatingGroup, fun(V) -> V end, RG, Acc);
pcc_rules_to_credits(_K, _V, _Granted, Acc) ->
    Acc.

split_pcc_rule(Rule) ->
    maps:fold(fun(K, V, {Action, Opts})
		    when K =:= 'Charging-Rule-Name';
			 K =:= 'Charging-Rule-Base-Name';
			 K =:= 'Charging-Rule-Definition' ->
		      {Action#{K => V}, Opts};
		 (K, V, {Action, Opts}) ->
		      {Action, Opts#{K => V}}
	      end, {#{}, #{}}, Rule).

pcc_upd_error(Error, #pcc_upd{errors = Errs} = Updates) ->
    Updates #pcc_upd{errors = [Error|Errs]}.

update_pcc_rule(Name, Rule, Opts, #pcc_upd{rules = Rules0} = Update) ->
    UpdRule = maps:merge(Opts, Rule),
    Rules = maps:update_with(Name, maps:merge(_, UpdRule), UpdRule, Rules0),
    Update#pcc_upd{rules = Rules}.

install_preconf_rule(Name, IsRuleBase, Opts, RuleBase, Update) ->
    case RuleBase of
	#{Name := Rules} when IsRuleBase andalso is_list(Rules) ->
	    UpdOpts = Opts#{'Charging-Rule-Base-Name' => Name},
	    lists:foldl(install_preconf_rule(_, false, UpdOpts, RuleBase, _), Update, Rules);
	#{Name := Rule} when (not IsRuleBase) andalso is_map(Rule) ->
	    update_pcc_rule(Name, Rule, Opts, Update);
	_ when IsRuleBase ->
	    pcc_upd_error({not_found, {rulebase, Name}}, Update);
	_ ->
	    pcc_upd_error({not_found, {rule, Name}}, Update)
    end.

install_pcc_rules(Install, RuleBase, Update) ->
    {Rules, Opts} = split_pcc_rule(Install),
    maps:fold(install_pcc_rule(_, _, Opts, RuleBase, _), Update, Rules).

install_pcc_rule('Charging-Rule-Name', V, Opts, RuleBase, Update) ->
    lists:foldl(install_preconf_rule(_, false, Opts, RuleBase, _), Update, V);
install_pcc_rule('Charging-Rule-Base-Name', V, Opts, RuleBase, Update) ->
    lists:foldl(install_preconf_rule(_, true, Opts, RuleBase, _), Update, V);
install_pcc_rule('Charging-Rule-Definition', V, Opts, _RuleBase, Update) ->
    lists:foldl(fun(#{'Charging-Rule-Name' := Name} = Rule, Upd) ->
			update_pcc_rule(Name, Rule, Opts, Upd)
		end, Update, V).

remove_pcc_rules(Install, Update) ->
    {Rules, Opts} = split_pcc_rule(Install),
    maps:fold(remove_pcc_rules(_, _, Opts, _), Update, Rules).

remove_pcc_rule(Name, true, _Opts, #pcc_upd{rules = Rules0} = Update) ->
    Rules =
	maps:filter(fun(_K, #{'Charging-Rule-Base-Name' := BaseName}) ->
			    BaseName /= Name;
		       (_K, _V) -> true
		    end, Rules0),
    Update#pcc_upd{rules = Rules};
remove_pcc_rule(Name, false, _Opts, #pcc_upd{rules = Rules} = Update) ->
    case Rules of
	#{Name := _} ->
	    Update#pcc_upd{rules = maps:remove(Name, Rules)};
	_ ->
	    pcc_upd_error({not_found, {rule, Name}}, Update)
    end.
remove_pcc_rules('Charging-Rule-Name', V, Opts, Update) ->
    lists:foldl(remove_pcc_rule(_, false, Opts, _), Update, V);
remove_pcc_rules('Charging-Rule-Base-Name', V, Opts, Update) ->
    lists:foldl(remove_pcc_rule(_, true, Opts, _), Update, V).

credits_to_pcc_rules(K, #{'Online' := [1]} = V, Pools, {Rules, Removed}) ->
    RatingGroup = get_rating_group('Online-Rating-Group', V),
    case is_map_key(RatingGroup, Pools) of
	true ->
	    {maps:put(K, V, Rules), Removed};
	false ->
	    {Rules, [{no_credits, K} | Removed]}
    end;
credits_to_pcc_rules(K, V, _, {Rules, Removed}) ->
    {maps:put(K, V, Rules), Removed}.

%% gy_events_to_pcc_ctx/3
gy_events_to_pcc_ctx(Now, Evs, #pcc_ctx{rules = Rules0, credits = Credits0} = PCC) ->
    Upd = proplists:get_value(update_credits, Evs, []),
    Credits = lists:foldl(ergw_gsn_lib:gy_events_to_credits(Now, _, _), Credits0, Upd),
    {Rules, Removed} = maps:fold(credits_to_pcc_rules(_, _, Credits, _), {#{}, []}, Rules0),
    {PCC#pcc_ctx{rules = Rules, credits = Credits}, Removed}.

%%%===================================================================
%%% PCC context to Gy events translation functions
%%%===================================================================

%% 3GPP TS 23.203, Sect. 6.1.2 Reporting:
%%
%% NOTE 1: Reporting usage information to the online charging function
%%         is distinct from credit management. Hence multiple PCC/ADC
%%         rules may share the same charging key for which one credit
%%         is assigned whereas reporting may be at higher granularity
%%         if serviced identifier level reporting is used.
%%
%% also see RFC 4006, https://tools.ietf.org/html/rfc4006#section-5.1.2
%%
pcc_rules_to_credit_request(_K, #{'Online' := [1]} = Definition, Acc) ->
    case get_rating_group('Online-Rating-Group', Definition) of
	RatingGroup when is_integer(RatingGroup) ->
	    RG = empty,
	    maps:update_with(RatingGroup, fun(V) -> V end, RG, Acc);
	_ ->
	    ?LOG(warning, "Online Charging requested, but no Rating Group: ~p", [Definition]),
	    Acc
    end;
pcc_rules_to_credit_request(_K, _V, Acc) ->
    Acc.

%% pcc_ctx_to_credit_request/1
pcc_ctx_to_credit_request(#pcc_ctx{rules = Rules}) ->
    ?LOG(debug, "Rules: ~p", [Rules]),
    CreditReq = maps:fold(fun pcc_rules_to_credit_request/3, #{}, Rules),
    ?LOG(debug, "CreditReq: ~p", [CreditReq]),
    CreditReq.

%% gy_credit_request/2
gy_credit_request(Ev, #pcc_ctx{credits = CreditsNeeded}) ->
    ergw_gsn_lib:make_gy_credit_request(Ev, #{}, CreditsNeeded).

%% gy_credit_request/3
gy_credit_request(Ev, #pcc_ctx{credits = CreditsOld},
		  #pcc_ctx{credits = CreditsNeeded}) ->
    Add = maps:without(maps:keys(CreditsOld), CreditsNeeded),
    ergw_gsn_lib:make_gy_credit_request(Ev, Add, CreditsNeeded).
