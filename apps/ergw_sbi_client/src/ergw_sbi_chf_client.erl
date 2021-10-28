%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

%% Nchf client, based on:
%% * 3GPP TS 32.290, Rel. 17.3.0
%% * 3GPP TS 32.291, Rel. 17.0.0

-module(ergw_sbi_chf_client).

-export([report_usage/2,
	 offline_only_charging_create/2,
	 offline_only_charging_update/3,
	 offline_only_charging_release/3]).

-ignore_xref([?MODULE]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_3gpp.hrl").

%%% ============================================================================
%%% API functions
%%% ============================================================================

report_usage(Report, State0) ->
    State1 = close_service_data_containers(Report, State0),
    State2 = traffic_data_containers(Report, State1),
    _State = process_secondary_rat_usage_data_reports(Report, State2).

offline_only_charging_create(Session, Opts) ->
    {ok, State0} = init_state(Opts),
    {Request0, State} = init_request(Opts, State0),
    Request = from_session(Session, Request0),
    send_chf_req([], Request, Opts, State).

offline_only_charging_update(Session, Opts, State0) ->
    {Request0, State} = init_request(Opts, State0),
    Request = from_session(Session, Request0),
    send_chf_req([<<"update">>], Request, Opts, State).

offline_only_charging_release(Session, Opts, State0) ->
    {Request0, State} = init_request(Opts, State0),
    Request = from_session(Session, Request0),
    send_chf_req([<<"release">>], Request, Opts, State).

%%% ============================================================================
%%% State Logic
%%% ============================================================================

init_state(#{chf :=
		 #{timeout := Timeout,
		   uri :=
		       #{host := _, port := _, path := ApiRoot} = Resource}
	    } = _Opts) ->

    %% TBD: there are multiple formats of the URI given in the specs
    Path = uri([ApiRoot, <<"nchf-offlineonlycharging">>, <<"v1">>, <<"offlinechargingdata">>]),
    State =
	#{resource => Resource#{path := Path},
	  timeout => Timeout,
	  invocation_seq_no => 0,

	  used_unit_seq_no => 0,
	  used_unit_cont => #{},
	  qfi_seq_no => 0,
	  qfi_cont => [],
	  sec_rat_reports => []
	 },
    {ok, State};
init_state(Opts) ->
    case application:get_env(ergw_sbi_client, chf, #{}) of
	#{endpoint := Endpoint} = Config ->
	    case parse_uri(Endpoint) of
		#{} = URI ->
		    CHF = Config#{uri => URI},
		    init_state(Opts#{chf => maps:merge(CHF, maps:get(chf, Opts, #{}))});
		Error ->
		    Error
	    end;
	_ ->
	    {error, not_configured}
    end.

close_service_data_containers(#{service_data := SDC}, State) ->
    lists:foldl(fun close_service_data_container/2, State, SDC);
close_service_data_containers(_, State) ->
    State.

close_service_data_container(#{'Rating-Group' := [RG]} = Report0,
			     #{used_unit_seq_no := SeqNo, used_unit_cont := Cont} = State) ->
    Report = Report0#{'Local-Sequence-Number' => SeqNo},
    State#{used_unit_seq_no := SeqNo + 1,
	   used_unit_cont := maps:update_with(RG, fun(X) -> [Report|X] end, [Report], Cont)}.

traffic_data_containers(#{traffic_data := TD}, State)
  when is_list(TD) ->
    lists:foldl(fun traffic_data_container/2, State, TD);
traffic_data_containers(_, State) ->
    State.

traffic_data_container(TD0, #{qfi_seq_no := SeqNo, qfi_cont := Cont} = State) ->
    TD = TD0#{'Local-Sequence-Number' => SeqNo},
    State#{qfi_seq_no := SeqNo + 1, qfi_cont := [TD|Cont]}.

%% TBD: copied from Rf:

process_secondary_rat_usage_data_reports(#{'RAN-Secondary-RAT-Usage-Report' := Reports},
					 #{sec_rat_reports := SecRatRs} = State) ->
    State#{sec_rat_reports := SecRatRs ++ Reports};
process_secondary_rat_usage_data_reports(_R, State) ->
    State.

%%% ============================================================================
%%% Request Logic
%%% ============================================================================

send_chf_req(Action, Request, _Opts, #{resource := Resource, timeout := Timeout} = State) ->
    #{host := Host, port := Port, path := Path, scheme := _} = Resource,
    ActionPath = uri([Path|Action]),

    Headers = #{<<"content-type">> => <<"application/json">>},

    Body = jsx:encode(Request),
    ct:pal("Body:~n~s~n", [jsx:encode(Request, [{indent, 2}])]),
    ReqOpts = #{start_pool_if_missing => true,
		conn_opts => #{protocols => [http2]},
		http2_opts => #{keepalive => infinity},
		scope => ?MODULE},

    {ok, StreamRef} = post(Host, Port, ActionPath, Headers, Body, ReqOpts),

    get_response(#{state => State,
		   timeout => Timeout,
		   stream_ref => StreamRef,
		   acc => <<>>}).

post(Host, Port, Path, Headers0, Body, ReqOpts) ->
    StartPoolIfMissing = maps:get(start_pool_if_missing, ReqOpts, false),
    Transport = gun:default_transport(Port),
    Authority = gun_http:host_header(Transport, Host, Port),
    Headers = Headers0#{<<"host">> => Authority},

    case gun_pool:post(Path, Headers, Body, ReqOpts) of
	{async, StreamRef} ->
	    {ok, StreamRef};
	{error, pool_not_found, _} when StartPoolIfMissing =:= true->
	    {ok, ManagerPid} = gun_pool:start_pool(Host, Port, ReqOpts),
	    ok = gun_pool:await_up(ManagerPid),
	    post(Host, Port, Path, Headers0, Body, ReqOpts#{start_pool_if_missing => false});
	Other ->
	    Other
    end.

get_response(#{stream_ref := StreamRef, timeout := Timeout, acc := Acc} = Opts) ->
    %% @TODO: fix correct 'Timeout' calculation issue and add time of request finished
    case gun_pool:await(StreamRef, Timeout) of
	{response, fin, Status, Headers} ->
	    handle_response(Opts#{status => Status, headers => Headers}, Acc);
	{response, nofin, Status, Headers} ->
	    get_response(Opts#{status => Status, headers => Headers});
	{data, nofin, Data} ->
	    get_response(Opts#{acc => <<Acc/binary, Data/binary>>});
	{data, fin, Data} ->
	    handle_response(Opts, <<Acc/binary, Data/binary>>);
	{error, timeout} = Response ->
	    Response;
	{error, _Reason} = Response->
	    Response
    end.

%%% ============================================================================
%%% Internal Functions
%%% ============================================================================

-define(SECONDS_PER_DAY, 86400).
-define(DAYS_FROM_0_TO_1970, 719528).
-define(SECONDS_FROM_0_TO_1970, (?DAYS_FROM_0_TO_1970*?SECONDS_PER_DAY)).

-define(SCI, 'pDUSessionChargingInformation').
-define(SI, 'pduSessionInformation').
-define(SCI_SI, ?SCI, ?SI).
-define(SNFI, 'servingNetworkFunctionInformation').
-define(SCI_SI_SNFI, ?SCI, ?SI, ?SNFI).

uri(URI) ->
    iolist_to_binary([lists:join($/, URI)]).

put_kv([K], V, M) ->
    M#{K => V};
put_kv([H|T], V, M) ->
    maps:put(H, put_kv(T, V, maps:get(H, M, #{})), M).

-if(0).
from_ip({_, _, _, _} = IP) ->
    #{'ipv4Addr' => iolist_to_binary(inet:ntoa(IP))};
from_ip({_, _, _, _,_, _, _, _} = IP) ->
    #{'ipv6Addr' => iolist_to_binary(inet:ntoa(IP))}.
-endif.

%% rat_type() -> 'EUTRA_U';
%% rat_type() -> 'NR_U';
%% rat_type() -> 'TRUSTED_N3GA';
%% rat_type() -> 'TRUSTED_WLAN';
%% rat_type() -> 'WIRELINE';
%% rat_type() -> 'WIRELINE_BBF';
%% rat_type() -> 'WIRELINE_CABLE';
rat_type(K,  1, R) -> put_kv(K, 'UTRA', R);
rat_type(K,  2, R) -> put_kv(K, 'GERA', R);
rat_type(K,  3, R) -> put_kv(K, 'WLAN', R);
rat_type(K,  6, R) -> put_kv(K, 'EUTRA', R);
rat_type(K,  7, R) -> put_kv(K, 'VIRTUAL', R);
rat_type(K,  8, R) -> put_kv(K, 'NBIOT', R);
rat_type(K,  9, R) -> put_kv(K, 'LTE-M', R);
rat_type(K, 10, R) -> put_kv(K, 'NR', R);
rat_type(_,  _, R) -> R.

strdatetime(DateTime) ->
    Secs = calendar:datetime_to_gregorian_seconds(DateTime),
     iolist_to_binary(calendar:system_time_to_rfc3339(Secs - ?SECONDS_FROM_0_TO_1970)).

strtime(Time) ->
    strtime(Time, millisecond).

strtime(Time, Unit) ->
    SysTime = Time + erlang:time_offset(),
    iolist_to_binary(
      calendar:system_time_to_rfc3339(
	erlang:convert_time_unit(SysTime, native, Unit), [{unit, Unit}])).

from_plmnid({MCC, MNC}) ->
    #{'mcc' => MCC, 'mnc' => MNC}.

from_uli('CGI', #cgi{plmn_id = PlmnId, lac = LAC, ci = CI}, Req) ->
    Id = #{'plmnId' => from_plmnid(PlmnId),
	   'lac' => LAC,
	   'cellId' => CI},
    put_kv([?SCI, 'userLocationinfo', 'cgi'], Id, Req);
from_uli('SAI', #sai{plmn_id = PlmnId, lac = LAC, sac = SAC}, Req) ->
    Id = #{'plmnId' => from_plmnid(PlmnId),
	   'lac' => LAC,
	   'sac' => SAC},
    put_kv([?SCI, 'userLocationinfo', 'sai'], Id, Req);
from_uli('RAI', #rai{plmn_id = PlmnId, lac = LAC, rac = RAC}, Req) ->
    Id = #{'plmnId' => from_plmnid(PlmnId),
	   'lac' => LAC,
	   'rac' => RAC},
    put_kv([?SCI, 'userLocationinfo', 'rai'], Id, Req);
from_uli('LAI', #lai{plmn_id = PlmnId, lac = LAC}, Req) ->
    Id = #{'plmnId' => from_plmnid(PlmnId),
	   'lac' => LAC},
    put_kv([?SCI, 'userLocationinfo', 'lai'], Id, Req);
from_uli(_, _, Req) ->
    Req.

%% Trigger:
%%  - triggerType
%%  - triggerCategory
%%  - timeLimit
%%  - volumeLimit64
%%  - eventLimit
%%  - maxNumberOfccc

trigger(Category, Type) ->
    #{'triggerCategory' => Category, 'triggerType' => Type}.

from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_CGI_SAI_CHANGE') ->
    trigger('IMMEDIATE_REPORT', 'CGI_SAI_CHANGE');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_ECGI_CHANGE') ->
    trigger('IMMEDIATE_REPORT', 'ECGI_CHANGE');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_NORMAL_RELEASE') ->
    trigger('IMMEDIATE_REPORT', 'FINAL');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_QOS_CHANGE') ->
    trigger('IMMEDIATE_REPORT', 'QOS_CHANGE');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_RAT_CHANGE') ->
    trigger('IMMEDIATE_REPORT', 'RAT_CHANGE');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_SERVICE_IDLED_OUT') ->
    trigger('IMMEDIATE_REPORT', 'MANAGEMENT_INTERVENTION');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_SERVING_NODE_CHANGE') ->
    trigger('IMMEDIATE_REPORT', 'SERVING_NODE_CHANGE');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_SERVING_NODE_PLMN_CHANGE') ->
    trigger('IMMEDIATE_REPORT', 'PLMN_CHANGE');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TAI_CHANGE') ->
    trigger('IMMEDIATE_REPORT', 'TAI_CHANGE');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TARIFF_TIME_CHANGE') ->
    trigger('IMMEDIATE_REPORT', 'TARIFF_TIME_CHANGE');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_TIME_LIMIT') ->
    trigger('IMMEDIATE_REPORT', 'TIME_LIMIT');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_UE_TIMEZONE_CHANGE') ->
    trigger('IMMEDIATE_REPORT', 'UE_TIMEZONE_CHANGE');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_USER_LOCATION_CHANGE') ->
    trigger('IMMEDIATE_REPORT', 'USER_LOCATION_CHANGE');
from_change_condition(?'DIAMETER_3GPP_CHARGING-CHANGE-CONDITION_VOLUME_LIMIT') ->
    trigger('IMMEDIATE_REPORT', 'VOLUME_LIMIT').

%%% ============================================================================

init_request(#{now := Now}, #{invocation_seq_no := SeqNo} = State0) ->
    Request0 =
	#{'nfConsumerIdentification' =>
	      #{'nodeFunctionality' => 'PGW_C_SMF'},
	  'invocationSequenceNumber' => SeqNo + 1,
	  'invocationTimeStamp' => strtime(Now),
	  ?SCI =>
	      #{?SI =>
		    #{?SNFI =>
			  %% TBD: same as Rf 'Serving-Node-Type', fake it for now
			  #{'nodeFunctionality' => 'SGW'}
		      }
	       }
	 },
    {Request1, State1} = add_multiple_unit_usage(Request0, State0),
    {Request2, State2} = add_multiple_qfi(Request1, State1),
    {Request, State} = add_ran_sec_rat_type(Request2, State2),
    {Request, State#{invocation_seq_no := SeqNo + 1}}.

from_session(Session, Request) ->
    maps:fold(fun from_session/3, Request, Session).

add_multiple_unit_usage(Req0, #{used_unit_cont := Cont} = State)
  when map_size(Cont) /= 0 ->
    Req = Req0#{'multipleUnitUsage' => maps:fold(fun from_used_unit_map/3, [], Cont)},
    {Req, State#{used_unit_cont := #{}}};
add_multiple_unit_usage(Req, State) ->
    {Req, State}.

%% for a detailed mapping of API fields to CDR fields see:
%% * 3GPP TS 29.251, Rel. 17.0, clause 7.2

%% MultipleUnitUsage:
%%  - ratingGroup
%%  - requestedUnit
%%  - usedUnitContainer -> UsedUnitContainer[]:
%%    - serviceId:
%%    - quotaManagementIndicator:
%%    - triggers:
%%    - triggerTimestamp:
%%    - time:
%%    - totalVolume:
%%    - uplinkVolume:
%%    - downlinkVolume:
%%    - serviceSpecificUnits:
%%    - eventTimeStamps:
%%    - localSequenceNumber
%%    - pDUContainerInformation -> PDUContainerInformation:
%%      - timeofFirstUsage
%%      - timeofLastUsage
%%      - qoSInformation
%%      - qoSCharacteristics
%%      - afChargingIdentifier
%%      - afChargingIdString
%%      - userLocationInformation
%%      - uetimeZone
%%      - rATType
%%      - servingNodeID
%%      - presenceReportingAreaInformation
%%      - 3gppPSDataOffStatus
%%      - sponsorIdentity
%%      - applicationserviceProviderIdentity
%%      - chargingRuleBaseName
%%      - mAPDUSteeringFunctionality
%%      - mAPDUSteeringMode
%%    - nSPAContainerInformation:
%%  - uPFID
%%  - multihomedPDUAddress

%% ratingGroup
from_used_unit_map(RG, UsedUnits, Reqs) ->
    Req = #{'ratingGroup' => RG,
	    'usedUnitContainer' =>
		lists:map(
		  fun(Used) ->
			  maps:fold(fun from_used_unit_cont/3, #{}, Used)
		  end, UsedUnits)},
    [Req|Reqs].

%% triggers:
from_used_unit_cont('Change-Condition', V, Req) when is_list(V) ->
    Req#{'triggers' => lists:map(fun from_change_condition/1, V)};
from_used_unit_cont('Change-Condition', V, Req) when is_integer(V) ->
    Req#{'triggers' => [from_change_condition(V)]};

%% triggerTimestamp:
from_used_unit_cont('Change-Time', [V], Req) ->
    Req#{'triggerTimestamp' => strdatetime(V)};

%% time
from_used_unit_cont('Time-Usage', [V], Req) ->
    Req#{'time' => V};

%% uplinkVolume
from_used_unit_cont('Accounting-Input-Octets', [V], Req) ->
    Req#{'uplinkVolume' => V};

%% downlinkVolume
from_used_unit_cont('Accounting-Output-Octets', [V], Req) ->
    Req#{'downlinkVolume' => V};

%% localSequenceNumber
from_used_unit_cont('Local-Sequence-Number', V, Req) ->
    Req#{'localSequenceNumber' => V};

%% pDUContainerInformation/timeofFirstUsage
from_used_unit_cont('Time-First-Usage', [V], Req) ->
    put_kv(['pDUContainerInformation', 'timeofFirstUsage'], strdatetime(V), Req);

%% pDUContainerInformation/timeofLastUsage
from_used_unit_cont('Time-Last-Usage', [V], Req) ->
    put_kv(['pDUContainerInformation', 'timeofLastUsage'], strdatetime(V), Req);

%% pDUContainerInformation/qoSInformation
%% from_used_unit_cont('QoS-Information', V, Req) ->
%%     put_kv(['pDUContainerInformation', 'qoSInformation'], V, Req);

%% %% pDUContainerInformation/userLocationInformation
%% from_used_unit_cont('3GPP-User-Location-Info', V, Req) ->
%%     put_kv(['pDUContainerInformation', 'userLocationInformation'], V, Req);

%% pDUContainerInformation/rATType
from_used_unit_cont('3GPP-RAT-Type', [V], Req) ->
    rat_type(['pDUContainerInformation', 'rATType'], V, Req);

%% pDUContainerInformation/chargingRuleBaseName
from_used_unit_cont('Charging-Rule-Base-Name', [V], Req) ->
    put_kv(['pDUContainerInformation', 'chargingRuleBaseName'], V, Req);

from_used_unit_cont(_K, _V, Req) ->
    Req.

%% roamingQBCInformation
%%  - multipleQFIcontainer
%%  - uPFID
%%  - roamingChargingProfile

add_multiple_qfi(Req0, #{qfi_cont := Cont} = State)
  when length(Cont) /= 0 ->
    Req =
	Req0#{'roamingQBCInformation' =>
		  #{'multipleQFIcontainer' => lists:map(fun from_qfi_cont/1, Cont)}
	     },
    {Req, State#{qfi_cont := #{}}};
add_multiple_qfi(Req, State) ->
    {Req, State}.

%% see 3GPP TS 32.255, Appendix B.2.2 for EPC mapping of QFI

%% MultipleQFIcontainer:
%%  - triggers
%%  - triggerTimestamp
%%  - time
%%  - totalVolume
%%  - uplinkVolume
%%  - downlinkVolume
%%  - localSequenceNumber
%%  - qFIContainerInformation -> QFIContainerInformation
%%     - qFI
%%     - reportTime
%%     - timeofFirstUsage
%%     - timeofLastUsage
%%     - qoSInformation
%%     - qoSCharacteristics
%%     - userLocationInformation
%%     - uetimeZone
%%     - presenceReportingAreaInformation
%%     - rATType
%%     - servingNetworkFunctionID
%%     - 3gppPSDataOffStatus
%%     - 3gppChargingId
%%     - diagnostics
%%     - enhancedDiagnostics
%%     - rANSecondaryRATType
%%     - qosFlowsUsageReports

from_qfi_cont(QFI) ->
    maps:fold(fun from_qfi_cont/3, #{}, QFI).

%% triggers:
from_qfi_cont('Change-Condition', V, Req) ->
    Req#{'triggers' => lists:map(fun from_change_condition/1, V)};
%% triggerTimestamp:
from_qfi_cont('Change-Time', [V], Req) ->
    Req#{'triggerTimestamp' => strdatetime(V)};

%% uplinkVolume
from_qfi_cont('Accounting-Input-Octets', [V], Req) ->
    Req#{'uplinkVolume' => V};

%% downlinkVolume
from_qfi_cont('Accounting-Output-Octets', [V], Req) ->
    Req#{'downlinkVolume' => V};

%% localSequenceNumber
from_qfi_cont('Local-Sequence-Number', V, Req) ->
    Req#{'localSequenceNumber' => V};

%% qFIContainerInformation/rATType
from_qfi_cont('3GPP-RAT-Type', [V], Req) ->
    rat_type(['qFIContainerInformation', 'rATType'], V, Req);

%% qFIContainerInformation/3gppChargingId
from_qfi_cont('3GPP-Charging-Id', [V], Req) ->
    put_kv(['pDUContainerInformation', '3gppChargingId'], V, Req);

from_qfi_cont(_K, _V, Req) ->
    Req.


%% RANSecondaryRATUsageReport
%%  - rANSecondaryRATType
%%  - qosFlowsUsageReports

add_ran_sec_rat_type(Req0, #{sec_rat_reports := Reports} = State)
  when length(Reports) /= 0 ->
    RanSecRatUsageReport =
	#{'rANSecondaryRATType' => 'NR',
	  'qosFlowsUsageReports' =>
	      lists:foldl(fun from_ran_sec_rat_report/2, [], Reports)},
    Req = put_kv([?SCI, 'rANSecondaryRATUsageReport'], RanSecRatUsageReport, Req0),
    {Req, State#{sec_rat_reports := []}};
add_ran_sec_rat_type(Req, State) ->
    {Req, State}.

from_ran_sec_rat_report(#{'Secondary-RAT-Type' := [<<0>>]} = Report, Reports) ->
    R = maps:fold(fun from_ran_sec_rat_report/3, #{}, Report),
    [R|Reports];
from_ran_sec_rat_report(_Report, Reports) ->
    Reports.

%% {'3GPP-Charging-Id' => [1409268758],
%%  'Accounting-Input-Octets' => "\v",
%%  'Accounting-Output-Octets' => "\n",
%%  'RAN-End-Timestamp' => [{{2036,2,8},{11,31,3}}],
%%  'RAN-Start-Timestamp' => [{{2036,2,8},{10,35,30}}],
%%  'Secondary-RAT-Type' => [<<0>>]}

%% QosFlowsUsageReport:
%%  - qFI
%%  - startTimestamp
%%  - endTimestamp
%%  - downlinkVolume
%%  - uplinkVolume

%% startTimestamp
from_ran_sec_rat_report( 'RAN-Start-Timestamp', [V], Req) ->
    Req#{'startTimestamp' => strdatetime(V)};

%% endTimestamp
from_ran_sec_rat_report( 'RAN-End-Timestamp', [V], Req) ->
    Req#{'endTimestamp' => strdatetime(V)};

%% downlinkVolume
from_ran_sec_rat_report('Accounting-Output-Octets', [V], Req) ->
    Req#{'downlinkVolume' => V};

%% uplinkVolume
from_ran_sec_rat_report('Accounting-Input-Octets', [V], Req) ->
    Req#{'uplinkVolume' => V};

from_ran_sec_rat_report(_K, _V, Req) ->
    Req.

%% from_session('APN', [H|_] = V, Req) when is_binary(H) ->
%%     Req#{'accessPointName' => iolist_to_binary(lists:join($., V))};

%% ChargingDataRequest
%%  - subscriberIdentifier
%%  - nfConsumerIdentification
%%  - invocationTimeStamp
%%  - invocationSequenceNumber
%%  - serviceSpecificationInformation
%%  - multipleUnitUsage
%%  - triggers
%%  TS 32.255 4G Data Connectivity added fields:
%%  - pDUSessionChargingInformation
%%  - roamingQBCInformation

%% subscriberIdentifier
from_session('3GPP-IMSI', V, Req) ->
    Req#{'subscriberIdentifier' => <<"imsi-", V/binary>>};

%% nfConsumerIdentification -> NFIdentification
%%  - nFName
%%  - nFIPv4Address
%%  - nFIPv6Address
%%  - nFPLMNID
%%  - nodeFunctionality
%%  - nFFqdn

from_session('Node-Id', V, Req) ->
    put_kv(['nfConsumerIdentification', 'nFName'], V, Req);
from_session('3GPP-GGSN-MCC-MNC', V, Req) ->
    put_kv(['nfConsumerIdentification', 'nFPLMNID'], from_plmnid(V), Req);
from_session('3GPP-GGSN-Address', V, Req) ->
    put_kv(['nfConsumerIdentification', 'nFIPv4Address'],
	   iolist_to_binary(inet:ntoa(V)), Req);
from_session('3GPP-GGSN-IPv6-Address', V, Req) ->
    put_kv(['nfConsumerIdentification', 'nFIPv6Address'],
	   iolist_to_binary(inet:ntoa(V)), Req);

%% pDUSessionChargingInformation -> PDUSessionChargingInformation
%%  - chargingId
%%  - userInformation
%%  - userLocationinfo
%%  - mAPDUNon3GPPUserLocationInfo
%%  - userLocationTime
%%  - presenceReportingAreaInformation
%%  - uetimeZone
%%  - pduSessionInformation
%%  - unitCountInactivityTimer
%%  - rANSecondaryRATUsageReport

%% chargingId
from_session('3GPP-Charging-Id', V, Req) ->
    put_kv([?SCI, 'chargingId'], V, Req);

%% userInformation
from_session('3GPP-MSISDN', V, Req) ->
    put_kv([?SCI, 'userInformation' , 'servedGPSI'], <<"msisdn-", V/binary>>, Req);
from_session('3GPP-IMEISV' , V, Req) ->
    put_kv([?SCI, 'userInformation' , 'servedPEI'], <<"imeisv-", V/binary>>, Req);

%% userLocationinfo
from_session(Key, V, Req)
  when Key =:= 'User-Location-Info';
       Key =:= '3GPP-User-Location-Info' ->
    maps:fold(fun from_uli/3, Req, V);

%% pduSessionInformation -> PDUSessionInformation
%%  - networkSlicingInfo
%%  - pduSessionID
%%  - pduType
%%  - sscMode
%%  - hPlmnId
%%  - servingNetworkFunctionID
%%  - ratType
%%  - mAPDUNon3GPPRATType
%%  - dnnId
%%  - chargingCharacteristics
%%  - chargingCharacteristicsSelectionMode
%%  - startTime
%%  - stopTime
%%  - 3gppPSDataOffStatus
%%  - sessionStopIndicator
%%  - pduAddress
%%  - diagnostics
%%  - authorizedQoSInformation
%%  - subscribedQoSInformation
%%  - authorizedSessionAMBR
%%  - subscribedSessionAMBR
%%  - servingCNPlmnId
%%  - mAPDUSessionInformation
%%  - enhancedDiagnostics

%% pduSessionID
from_session('3GPP-NSAPI', V, Req) ->
    put_kv([?SCI_SI, 'pduSessionID'], V, Req);

%% pduType
from_session('3GPP-PDP-Type', V, Req) ->
    Type = string:uppercase(atom_to_binary(V)),
    put_kv([?SCI_SI, 'pduType'], Type, Req);

%% hPlmnId
from_session('3GPP-IMSI-MCC-MNC', V, Req) ->
    put_kv([?SCI_SI, 'hPlmnId'], from_plmnid(V), Req);

%% servingNetworkFunctionID -> ServingNetworkFunctionID
%%  - servingNetworkFunctionInformation -> NFIdentification
%%    - nFName
%%    - nFIPv4Address
%%    - nFIPv6Address
%%    - nFPLMNID
%%    - nodeFunctionality
%%    - nFFqdn
%%  - aMFId

from_session('3GPP-SGSN-MCC-MNC', V, Req) ->
    put_kv([?SCI_SI_SNFI, 'nFPLMNID'], from_plmnid(V), Req);
from_session('3GPP-SGSN-Address', V, Req) ->
    put_kv([?SCI_SI_SNFI, 'nFIPv4Address'], iolist_to_binary(inet:ntoa(V)), Req);
from_session('3GPP-SGSN-IPv6-Address', V, Req) ->
    put_kv([?SCI_SI_SNFI, 'nFIPv6Address'], iolist_to_binary(inet:ntoa(V)), Req);

%% ratType
from_session('3GPP-RAT-Type', V, Req) ->
    rat_type([?SCI_SI, 'ratType'], V, Req);

%% dnnId
from_session('APN', V, Req) ->
    put_kv([?SCI_SI, 'dnnId'], V, Req);

%% chargingCharacteristics
from_session('3GPP-Charging-Characteristics' = Key, V, Req) ->
    %% TBD: depends on ergw_aaa
    put_kv([?SCI_SI, 'chargingCharacteristics'],
	   ergw_aaa_3gpp_dict:encode(Key, V), Req);

%% startTime
from_session('Accounting-Start', V, Req) ->
    put_kv([?SCI_SI, 'startTime'], strtime(V, second), Req);

%% stopTime
from_session('Accounting-Stop', V, Req) ->
    put_kv([?SCI_SI, 'stopTime'], strtime(V, second), Req);

%% pduAddress -> PDUAddress
%%  - pduIPv4Address
%%  - pduIPv6AddresswithPrefix
%%  - pduAddressprefixlength
%%  - iPv4dynamicAddressFlag
%%  - iPv6dynamicPrefixFlag
%%  - addIpv6AddrPrefixes

%% pduIPv4Address
from_session('Framed-IP-Address', V, Req) ->
    put_kv([?SCI_SI, 'pduAddress', 'pduIPv4Address'],
	   iolist_to_binary(inet:ntoa(V)), Req);

%% pduIPv6AddresswithPrefix
from_session('Framed-IPv6-Prefix', {IP, PrefixLen}, Req0) ->
    Req = put_kv([?SCI_SI, 'pduAddress', 'pduIPv6AddresswithPrefix'],
		 iolist_to_binary(inet:ntoa(IP)), Req0),
    put_kv([?SCI_SI, 'pduAddress', 'pduAddressprefixlength'], PrefixLen, Req);

%% iPv4dynamicAddressFlag
from_session('Requested-IP-Address', {0,0,0,0}, Req) ->
    put_kv([?SCI_SI, 'pduAddress', 'iPv4dynamicAddressFlag'], true, Req);

%% iPv6dynamicPrefixFlag
from_session('Requested-IPv6-Prefix', {{0,0,0,0,0,0,0,0},_}, Req) ->
    put_kv([?SCI_SI, 'pduAddress', 'iPv6dynamicPrefixFlag'], true, Req);

%% TBD:
%%   authorizedQoSInformation
%%   authorizedSessionAMBR

from_session(_, _, Req) ->
    Req.

handle_response(#{status := 201, headers := Headers, state := State0} = Opts, Body) ->
    case lists:keyfind(<<"location">>, 1, Headers) of
	{<<"location">>, Location} ->
	    case parse_uri(Location) of
		#{host := _, port := _, path := _, scheme := _} = URI ->
		    State = State0#{resource := URI},
		    handle_response_body(Opts#{state := State}, Body);
		BadURI when is_map(BadURI) ->
		    {error, invalid_resource_location};
		{error, _} = Error ->
		    Error
	    end
    end;
handle_response(#{status := 200} = Opts, Body) ->
    handle_response_body(Opts, Body);
handle_response(_, _) ->
    {error, invalid_response}.

handle_response_body(#{headers := Headers, state := State}, Body) ->
    case decode_body(Headers, Body) of
	#{<<"invocationSequenceNumber">> := _} ->
	    {ok, State};
	Response when is_map(Response) ->
	    {error, invalid_payload};
	{error, _} = Error ->
	    Error
    end.

decode_body(Headers, Body) ->
    case lists:keyfind(<<"content-type">>, 1, Headers) of
	{<<"content-type">>, ContentType} ->
	    case cow_http_hd:parse_content_type(ContentType) of
		{<<"application">>, <<"json">>, _Param} ->
		    jsx:decode(Body, [{labels, binary}, return_maps]);
		_ ->
		    {error, invalid_content_type}
	    end;
	_ ->
	    {error, no_content_type}
    end.

parse_uri(URI) when is_list(URI) ->
    case uri_string:parse(URI) of
	#{host := _, port := _, path := _, scheme := _} = ParsedUri ->
	    ParsedUri;
	#{scheme := "http"} = ParsedUri ->
	    ParsedUri#{port => 80};
	#{scheme := "https"} = ParsedUri ->
	    ParsedUri#{port => 443};
	Error ->
	    Error
    end;
parse_uri(URI) when is_binary(URI) ->
    parse_uri(binary_to_list(URI));
parse_uri(_) ->
    {error, parse}.
