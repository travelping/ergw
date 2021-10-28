%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_core_sbi_lib).

-export([init_per_group/1, end_per_group/1]).

init_per_group(Config0) ->
    [{ok, _} = application:ensure_all_started(App) ||
	App <- [ranch, ergw_sbi_client]],

    ProtoOpts =
	#{env =>
	      #{dispatch =>
		    cowboy_router:compile(
		      [{'_',
			[{"/nf-selection", ergw_core_sbi_h, []},
			 {"/chf/nchf-offlineonlycharging/v1/offlinechargingdata/[:id/[:action]]", ergw_core_sbi_chf_h, []}
			]}
		      ])
	       }},
    {ok, _O} = cowboy:start_clear(?MODULE, [], ProtoOpts),
    Port = ranch:get_port(?MODULE),
    ct:pal("CowBoy: ~p, Port: ~p", [_O, Port]),

    SbiCfg =
	#{upf_selection =>
	      #{timeout => 1000,
		default => "fallback",
		endpoint =>
		    uri_string:recompose(
		      #{host => "localhost", path => "/nf-selection", port => Port, scheme => "http"})
	       },
	  chf =>
	      #{timeout => 1000,
		endpoint =>
		    uri_string:recompose(
		      #{host => "localhost", path => "/chf", port => Port, scheme => "http"})
	       }
	 },

    AppCfg0 = proplists:get_value(app_cfg, Config0),
    AppCfg = lists:keystore(ergw_sbi_client, 1, AppCfg0, {ergw_sbi_client, maps:to_list(SbiCfg)}),
    Config = lists:keystore(app_cfg, 1, Config0, {app_cfg, AppCfg}),
    [{sbi_config, SbiCfg}|Config].

end_per_group(_) ->
    (catch cowboy:stop_listener(?MODULE)).
