%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_proxy_ds).

-behaviour(gen_server).

%% API
-export([start_link/0, map/1, lb/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-include("gtp_proxy_ds.hrl").

-define(SERVER, ?MODULE).
-define(App, ergw).

-record(state, {imsi, apn}).

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
%%% gen_server callbacks
%%%===================================================================

init([]) ->
    State = load_config(),
    {ok, State}.

handle_call({map, #proxy_info{ggsns = GGSNs0, imsi = IMSI, src_apn = APN} = ProxyInfo0},
	    _From, #state{apn = APNMap, imsi = IMSIMap} = State) ->
    GGSNs = [GGSN#proxy_ggsn{dst_apn = proplists:get_value(APN, APNMap, APN)}
             || GGSN <- GGSNs0],
    ProxyInfo =
        case proplists:get_value(IMSI, IMSIMap, IMSI) of
            {MappedIMSI, MappedMSISDN} ->
            ProxyInfo0#proxy_info{
              ggsns = GGSNs,
              imsi = MappedIMSI,
              msisdn = MappedMSISDN};
             MappedIMSI ->
            ProxyInfo0#proxy_info{
              ggsns = GGSNs,
              imsi = MappedIMSI}
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

load_config() ->
    ProxyMap = application:get_env(?App, proxy_map, []),
    #state{
       imsi = proplists:get_value(imsi, ProxyMap, []),
       apn  = proplists:get_value(apn,  ProxyMap, [])
      }.
