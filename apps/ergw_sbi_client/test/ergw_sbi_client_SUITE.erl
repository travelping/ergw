-module(ergw_sbi_client_SUITE).

-compile([export_all, nowarn_export_all]).

-include_lib("gtplib/include/gtp_packet.hrl").

-define(match(Guard, Expr),
	((fun () ->
		  case (Expr) of
		      Guard -> ok;
		      V -> ct:pal("MISMATCH(~s:~b, ~s)~nExpected: ~p~nActual:   ~p~n",
				   [?FILE, ?LINE, ??Expr, ??Guard, V]),
			    error(badmatch)
		  end
	  end)())).

all() ->
    [from_session,
     upf_selection
    ].

init_per_suite(Config) ->
    [{ok, _} = application:ensure_all_started(App) ||
	App <- [ranch, gun, ergw_sbi_client]],

    ProtoOpts =
	#{env =>
	      #{dispatch =>
		    cowboy_router:compile(
		      [{'_', [{"/ok", sbi_h, []}]}])
	       }},
    {ok, _} = cowboy:start_clear(?MODULE, [], ProtoOpts),
    Port = ranch:get_port(?MODULE),

    TestCfg =
	#{upf_selection =>
	      #{timeout => 1000,
		default => "fallback",
		endpoint =>
		    uri_string:recompose(
		      #{host => "localhost", path => "/ok", port => Port, scheme => "http"})
	       }
	 },
    _ = ergw_sbi_client_config:validate_options(fun ergw_sbi_client_config:validate_option/2, TestCfg),
    ok = ergw_sbi_client:setup(TestCfg),
    Config.

end_per_suite(_) ->
    ok = cowboy:stop_listener(?MODULE),
    ok.

%%--------------------------------------------------------------------
session() ->
    %% copied from ergw_core/pgw_SUITE
    #{'Username' => <<"111111111111111/3520990017614823/440000000000/ATOM/TEXT/12345@example.net">>,
      'Framed-Protocol' => 'GPRS-PDP-Context',
      'Multi-Session-Id' => 15958412130338583375391261628607396908,
      'TAI' => <<3,2,22,214,217>>,
      '3GPP-SGSN-Address' => {127,127,127,127},
      'ECGI' => <<3,2,22,8,71,9,92>>,
      '3GPP-RAT-Type' => 1,
      'Framed-IPv6-Pool' => <<"pool-A">>,
      '3GPP-Charging-Id' => 1981737279,
      '3GPP-Selection-Mode' => 0,
      '3GPP-IMSI' => <<"111111111111111">>,
      '3GPP-MSISDN' => <<"440000000000">>,
      'Password' => <<"ergw">>,
      '3GPP-GGSN-Address' => {127,0,0,1},
      'Session-Start' => -576460456578330165,
      'Calling-Station-Id' => <<"440000000000">>,
      'Service-Type' => 'Framed-User',
      '3GPP-GGSN-MCC-MNC' => <<"00101">>,
      '3GPP-IMEISV' => <<"3520990017614823">>,
      'Charging-Rule-Base-Name' => <<"m2m0001">>,
      '3GPP-MS-TimeZone' => {10,0},
      'Session-Id' => 15958412130338583375391261628607396909,
      'Framed-Pool' => <<"pool-A">>,
      'Diameter-Session-Id' => <<"zeus;201423479;105063168;207890578476">>,
      'User-Location-Info' =>
	  #{'ext-macro-eNB' =>
		#ext_macro_enb{plmn_id = {<<"001">>, <<"001">>},
			       id = rand:uniform(16#1fffff)},
	    'TAI' =>
		#tai{plmn_id = {<<"001">>, <<"001">>},
		     tac = rand:uniform(16#ffff)}},
      'Called-Station-Id' => <<"example.net">>,
      'Node-Id' => <<"PGW-001">>,
      'QoS-Information' =>
	  #{'APN-Aggregate-Max-Bitrate-DL' => 1704125000,
	    'APN-Aggregate-Max-Bitrate-UL' => 48128000,
	    'Allocation-Retention-Priority' =>
		#{'Pre-emption-Capability' => 1,
		  'Pre-emption-Vulnerability' => 0,
		  'Priority-Level' => 10},
	    'Guaranteed-Bitrate-DL' => 0,
	    'Guaranteed-Bitrate-UL' => 0,
	    'Max-Requested-Bandwidth-DL' => 0,
	    'Max-Requested-Bandwidth-UL' => 0,
	    'QoS-Class-Identifier' => 8},
      'NAS-Identifier' => <<"NAS-Identifier">>,
      '3GPP-NSAPI' => 5,
      '3GPP-PDP-Type' => 'IPv4',
      '3GPP-SGSN-MCC-MNC' => <<"001001">>,
      '3GPP-IMSI-MCC-MNC' => <<"11111">>,

      %% TBD:
      'APN' => [<<"example">>, <<"net">>],
      '3GPP-SGSN-UP-Address' => {127,127,127,127},
      'GTP-Version' => v2
     }.

%%--------------------------------------------------------------------
from_session() ->
    [{doc, "Check mapping from session to request"}].
from_session(_Config) ->
    Req = ergw_sbi_client:from_session(session()),
    ct:pal("Req: ~p~n", [Req]),

    ?match(
       #{'QoS-Information' :=
	     #{'APN-Aggregate-Max-Bitrate-DL' := 1704125000,
	       'APN-Aggregate-Max-Bitrate-UL' := 48128000,
	       'Allocation-Retention-Priority' :=
		   #{'Pre-emption-Capability' := 1,
		     'Pre-emption-Vulnerability' := 0,'Priority-Level' := 10},
	       'Guaranteed-Bitrate-DL' := 0,'Guaranteed-Bitrate-UL' := 0,
	       'Max-Requested-Bandwidth-DL' := 0,
	       'Max-Requested-Bandwidth-UL' := 0,'QoS-Class-Identifier' := 8},
	 <<"accessPointName">> := <<"example.net">>,
	 <<"gpsi">> := <<"msisdn-440000000000">>,
	 <<"pei">> := <<"imeisv-3520990017614823">>,
	 <<"protocolType">> := <<"GTPv2">>,
	 <<"supi">> := <<"imsi-111111111111111">>,
	 <<"vPlmn">> :=
	     #{<<"cpAddress">> := #{<<"ipv4Addr">> := <<"127.127.127.127">>},
	       <<"plmnId">> := #{<<"mcc">> := <<"001">>, <<"mnc">> := <<"001">>},
	       <<"upAddress">> := #{<<"ipv4Addr">> := <<"127.127.127.127">>}}}, Req),
    ok.

%%--------------------------------------------------------------------
upf_selection() ->
    [{doc, "Check upf_selection_api"}].
upf_selection(_Config) ->
    Session = session(),

    ?match({ok, {_,_,_,_}},
	   ergw_sbi_client:upf_selection(Session#{'3GPP-MSISDN' => <<"440000000000">>})),
    ?match({ok, {_,_,_,_,_,_,_,_}},
	   ergw_sbi_client:upf_selection(Session#{'3GPP-MSISDN' => <<"440000000001">>})),
    ?match({ok, F} when is_binary(F),
	   ergw_sbi_client:upf_selection(Session#{'3GPP-MSISDN' => <<"440000000002">>})),
    ?match({error, _},
	   ergw_sbi_client:upf_selection(Session#{'3GPP-MSISDN' => <<"440000000009">>})),
    ok.
