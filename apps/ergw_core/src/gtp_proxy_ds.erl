%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_proxy_ds).

-behaviour(gen_server).

%% API
-export([start_link/0, map/1, map/2, validate_options/1, setopts/1]).

-ifdef(TEST).
-export([start/0]).
-endif.

-ignore_xref([start_link/0, map/1, map/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include_lib("kernel/include/logger.hrl").
-include("ergw_core_config.hrl").

-define(SERVER, ?MODULE).

-define(ResponseKeys, [imsi, msisdn, apn, context, gwSelectionAPN, upfSelectionAPN]).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-ifdef(TEST).
start() ->
    gen_server:start({local, ?SERVER}, ?MODULE, [], []).
-endif.

setopts(Opts0) ->
    Opts = validate_options(Opts0),
    gen_server:call(?SERVER, {setopts, Opts}).

map(ProxyInfo) ->
    gen_server:call(?SERVER, {map, ProxyInfo}).

map(Handler, ProxyInfo) ->
    try apply(Handler, map, [ProxyInfo]) of
	Response when is_map(Response) ->
	    normalize_response(Response);
	Other ->
	    Other
    catch
	Error:Cause ->
	    ?LOG(warning, "Failed Proxy Map: ~p", [{Error, Cause}]),
	    {error, system_failure}
    end.

%%%===================================================================
%%% Options Validation
%%%===================================================================

validate_options(Values) ->
    ergw_core_config:validate_options(fun validate_option/2, Values, []).

validate_imsi(From, #{imsi := IMSI, msisdn := MSISDN} = To)
  when is_binary(From), is_binary(IMSI), is_binary(MSISDN) ->
    To;
validate_imsi(From, #{imsi := IMSI} = To)
  when is_binary(From), is_binary(IMSI), not is_map_key(msisdn, To) ->
    To;
validate_imsi(From, To) when is_list(To) ->
    validate_imsi(From, ergw_core_config:to_map(To));
validate_imsi(From, To) ->
    erlang:error(badarg, [From, To]).

validate_apn([From|_], [To|_] = APN) when is_binary(From), is_binary(To) ->
    APN;
validate_apn(From, To) ->
    erlang:error(badarg, [From, To]).

validate_option(imsi, Opts) when ?is_non_empty_opts(Opts) ->
    ergw_core_config:validate_options(fun validate_imsi/2, Opts, []);
validate_option(apn, Opts) when ?is_non_empty_opts(Opts) ->
    ergw_core_config:validate_options(fun validate_apn/2, Opts, []);
validate_option(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, #{}}.

handle_call({setopts, Opts}, _From, _) ->
    State = validate_options(Opts),
    {reply, ok, State};

handle_call({map, #{imsi := IMSI, apn := APN} = PI0}, _From, State) ->
    PI1 = maps:merge(PI0, maps:get(IMSI, maps:get(imsi, State, #{}), #{})),
    PI =
	case ergw_apn:get(APN, maps:get(apn, State, undefined)) of
	    {ok, DstAPN} -> PI1#{apn => DstAPN};
	    {error, _}   -> PI1
	end,
    {reply, normalize_response(PI), State};

handle_call({map, PI}, _From, State) ->
    {reply, {error, {badarg, PI}}, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

normalize_response(#{apn := APN} = Response0) ->
    Response = maps:with(?ResponseKeys, Response0),
    maps:merge(#{gwSelectionAPN => APN, upfSelectionAPN => APN}, Response);
normalize_response(_) ->
    {error, system_failure}.
