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

-define(SERVER, ?MODULE).
-define(App, ergw_core).

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

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

validate_options(Values) ->
    ergw_core_config:validate_options(fun validate_option/2, Values, []).

validate_imsi(From, To) when is_binary(From), is_binary(To) ->
    To;
validate_imsi(From, {IMSI, MSISDN} = To)
  when is_binary(From), is_binary(IMSI), is_binary(MSISDN) ->
    To;
validate_imsi(From, To) ->
    erlang:error(badarg, [From, To]).

validate_apn([From|_], [To|_] = APN) when is_binary(From), is_binary(To) ->
    APN;
validate_apn(From, To) ->
    erlang:error(badarg, [From, To]).

validate_option(imsi, Opts) when ?non_empty_opts(Opts) ->
    ergw_core_config:validate_options(fun validate_imsi/2, Opts, []);
validate_option(apn, Opts) when ?non_empty_opts(Opts) ->
    ergw_core_config:validate_options(fun validate_apn/2, Opts, []);
validate_option(Opt, Value) ->
    erlang:error(badarg, [Opt, Value]).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    {ok, Opts} = ergw_core_config:get([proxy_map], []),
    State = validate_options(Opts),
    {ok, State}.

handle_call({setopts, Opts}, _From, _) ->
    State = validate_options(Opts),
    {reply, ok, State};

handle_call({map, #{imsi := IMSI, apn := APN} = PI0}, _From, State) ->
    PI1 =
	case maps:get(imsi, State, undefined) of
	    #{IMSI := MappedIMSI} when is_binary(MappedIMSI) ->
		PI0#{imsi => MappedIMSI};
	    #{IMSI := {MappedIMSI, MappedMSISDN}} ->
		PI0#{imsi => MappedIMSI, msisdn => MappedMSISDN};
	    _ ->
		PI0
	end,
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