-module(ergw_sbi_client_SUITE).

-export([
    all/0,
    groups/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    upf_selection_ok/0,
    upf_selection_ok/1,
    upf_selection_error/0,
    upf_selection_error/1
]).

-define(TEST_CONFIG, #{
    upf_selection_api => #{
	timeout => 1000,
	default => "fallback",
	endpoint => "https://ptsv2.com/t/qx48x-1624877407/post"
    }
}).

-define(SELECT_UPF, #{
    accessPointName => "string",
    supi => "string",
    vPlmn => #{
	plmnId => #{
	    mcc => "string",
	    mnc => "string"
	},
	cpAddress => #{
	    ipv4Addr => "198.51.100.1",
	    ipv6Addr => "2001:db8:85a3::8a2e:370:7334",
	    ipv6Prefix => "2001:db8:abcd:12::0/64"
	},
	upAddress => #{
	    ipv4Addr => "198.51.100.1",
	    ipv6Addr => "2001:db8:85a3::8a2e:370:7334",
	    ipv6Prefix => "2001:db8:abcd:12::0/64"
	}
    },
    protocolType => "GTPv1",
    gpsi => "string",
    pei => "string",
    userLocationInfo => #{
	cgi => #{
	    plmnId => #{
		mcc => "string",
		mnc => "string"
	    },
	    lac => "string",
	    cellId => "string"
	},
	sai => #{
	    plmnId => #{
		mcc => "string",
		mnc => "string"
	    },
	    lac => "string",
	    sac => "string"
	},
	lai => #{
	    plmnId => #{
		mcc => "string",
		mnc => "string"
	    },
	    lac => "string"
	},
	rai => #{
	    plmnId => #{
		mcc => "string",
		mnc => "string"
	    },
	    lac => "string",
	    rac => "string"
	},
	ageOfLocationInformation => 0,
	ueLocationTimestamp => "2021-06-30T15:01:36.097Z",
	geographicalInformation => "string",
	geodeticInformation => "string"
    },
    qualityOfService => "string"
}).

all() ->
    [
	{group, successed},
	{group, failed}
    ].

groups() ->
    [
	{successed, [sequence], [
	    upf_selection_ok
	]},
	{failed, [sequence], [
	    upf_selection_error
	]}
    ].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(ergw_sbi_client),
    _ = ergw_sbi_client_config:validate_options(fun ergw_sbi_client_config:validate_option/2, ?TEST_CONFIG),
    Config.

end_per_suite(Config) ->
    Config.

%% http://ptsv2.com/t/qx48x-1624877407

upf_selection_ok() ->
    [{doc, "Check upf_selection_api"}].
upf_selection_ok(_Config) ->
    case ergw_sbi_client:upf_selection(?SELECT_UPF) of
	{ok, Response} ->
	    ct:comment("erGW SBI UPF selection API request success result"),
	    ct:pal("Response: ~p", [Response]);
	Any ->
	    ct:fail(Any)
    end.

upf_selection_error() ->
    [{doc, "Check request error behavior"}].
upf_selection_error(_Config) ->
    #{upf_selection_api := UPF} = ?TEST_CONFIG,
    _ = ergw_sbi_client:setup(?TEST_CONFIG#{upf_selection_api => UPF#{endpoint => "https://none-existing.com"}}),
    case ergw_sbi_client:upf_selection(#{}) of
	{error, timeout} = Error ->
	    ct:comment("erGW SBI request error result"),
	    ct:pal("Response: ~p", [Error]);
	Any ->
	    ct:fail(Any)
    end.
