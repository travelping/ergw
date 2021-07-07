%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_core_sbi_lib).

-export([init_per_suite/1, end_per_suite/1]).

init_per_suite(Config) ->
    [{ok, _} = application:ensure_all_started(App) ||
	App <- [ranch, ergw_sbi_client]],

    ProtoOpts =
	#{env =>
	      #{dispatch =>
		    cowboy_router:compile(
		      [{'_', [{"/nf-selection", ergw_core_sbi_h, []}]}])
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
	       }
	 },
    [{sbi_config, SbiCfg}|Config].


end_per_suite(_) ->
    (catch cowboy:stop_listener(?MODULE)).
