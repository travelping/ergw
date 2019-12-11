%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_proxy_ds).

-behaviour(gen_server).

%% API
-export([start_link/0, map/1, lb/1, validate_options/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("gtp_proxy_ds.hrl").

-define(SERVER, ?MODULE).
-define(App, ergw).

%%%===================================================================
%%% API
%%%===================================================================

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

map(ProxyInfo) ->
    gen_server:call(?SERVER, {map, ProxyInfo}).

lb(ProxyInfo) ->
    LBType = application:get_env(?App, proxy_lb_type, first),
    lb(ProxyInfo, LBType).

%%%===================================================================
%%% Options Validation
%%%===================================================================

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			    (is_map(X) andalso map_size(X) /= 0))).

validate_options(Values) ->
    ergw_config:validate_options(fun validate_option/2, Values, [], map).

validate_imsi(From, To) when is_binary(From), is_binary(To) ->
    To;
validate_imsi(From, {IMSI, MSISDN} = To)
  when is_binary(From), is_binary(IMSI), is_binary(MSISDN) ->
    To;
validate_imsi(From, To) ->
    throw({error, {options, {From, To}}}).

validate_apn([From|_], [To|_] = APN) when is_binary(From), is_binary(To) ->
    APN;
validate_apn(From, To) ->
    throw({error, {options, {From, To}}}).

validate_option(imsi, Opts) when ?non_empty_opts(Opts) ->
    ergw_config:check_unique_keys(imsi, Opts),
    ergw_config:validate_options(fun validate_imsi/2, Opts, [], map);
validate_option(apn, Opts) when ?non_empty_opts(Opts) ->
    ergw_config:check_unique_keys(apn, Opts),
    ergw_config:validate_options(fun validate_apn/2, Opts, [], map);
validate_option(Opt, Value) ->
    throw({error, {options, {Opt, Value}}}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    State = validate_options(application:get_env(?App, proxy_map, #{})),
    {ok, State}.

handle_call({map, #proxy_info{ggsns = GGSNs0, imsi = IMSI, src_apn = APN} = ProxyInfo0},
	    _From, #{apn := APNMap, imsi := IMSIMap} = State) ->
    ProxyInfo1 =
	case IMSIMap of
	    #{IMSI := MappedIMSI} when is_binary(MappedIMSI) ->
		ProxyInfo0#proxy_info{imsi = MappedIMSI};
	    #{IMSI := {MappedIMSI, MappedMSISDN}} ->
		ProxyInfo0#proxy_info{imsi = MappedIMSI, msisdn = MappedMSISDN};
	    _ ->
		ProxyInfo0
	end,
    ProxyInfo =
	case ergw_gsn_lib:apn(APN, APNMap) of
	    {ok, DstAPN} ->
		ProxyInfo1#proxy_info{
		  ggsns = [GGSN#proxy_ggsn{dst_apn = DstAPN} || GGSN <- GGSNs0]};
	    _ ->
		ProxyInfo1
	end,
    {reply, {ok, ProxyInfo}, State}.

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

lb(#proxy_info{ggsns = [GGSN | _]}, first) -> GGSN;
lb(#proxy_info{ggsns = [GGSN]}, random) -> GGSN;
lb(#proxy_info{ggsns = GGSNs}, random) when is_list(GGSNs) ->
    Index = rand:uniform(length(GGSNs)),
    lists:nth(Index, GGSNs);
lb(#proxy_info{ggsns = [GGSN | _]}, _) -> GGSN.
