%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_v1_c).

-behaviour(gtp_protocol).

%% API
-export([gtp_msg_types/0, gtp_msg_type/1,
	 get_handler/2,
	 build_response/1,
	 build_echo_request/1,
	 validate_teid/2,
	 type/0, port/0,
	 get_msg_keys/1]).

%% support functions
-export([restart_counter/1, build_recovery/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-define('Recovery',					{recovery, 0}).
-define('Access Point Name',				{access_point_name, 0}).
-define('IMSI',						{international_mobile_subscriber_identity, 0}).
-define('IMEI',						{imei, 0}).

%%====================================================================
%% API
%%====================================================================

restart_counter(#recovery{restart_counter = RestartCounter}) ->
    RestartCounter;
restart_counter(_) ->
    undefined.

build_recovery(#gtp_port{} = GtpPort, NewPeer, IEs) when NewPeer == true ->
    add_recovery(GtpPort, IEs);
build_recovery(#context{
		  remote_restart_counter = RemoteRestartCounter,
		  control_port = GtpPort}, NewPeer, IEs)
  when NewPeer == true orelse
       RemoteRestartCounter == undefined ->
    add_recovery(GtpPort, IEs);
build_recovery(_, _, IEs) ->
    IEs.

type() -> 'gtp-c'.
port() -> ?GTP1c_PORT.

build_echo_request(_GtpPort) ->
    #gtp{version = v1, type = echo_request, tei = 0, ie = []}.

build_response({Type, TEI, IEs}) ->
    #gtp{version = v1, type = gtp_msg_response(Type), tei = TEI, ie = map_reply_ies(IEs)};
build_response({Type, IEs}) ->
    #gtp{version = v1, type = gtp_msg_response(Type), tei = 0, ie = map_reply_ies(IEs)}.

gtp_msg_types() ->
    [echo_request,					echo_response,
     version_not_supported,
     node_alive_request,				node_alive_response,
     redirection_request,				redirection_response,
     create_pdp_context_request,			create_pdp_context_response,
     update_pdp_context_request,			update_pdp_context_response,
     delete_pdp_context_request,			delete_pdp_context_response,
     initiate_pdp_context_activation_request,		initiate_pdp_context_activation_response,
     error_indication,
     pdu_notification_request,				pdu_notification_response,
     pdu_notification_reject_request,			pdu_notification_reject_response,
     supported_extension_headers_notification,
     send_routeing_information_for_gprs_request,	send_routeing_information_for_gprs_response,
     failure_report_request,				failure_report_response,
     note_ms_gprs_present_request,			note_ms_gprs_present_response,
     identification_request,				identification_response,
     sgsn_context_request,				sgsn_context_response,
     sgsn_context_acknowledge,
     forward_relocation_request,			forward_relocation_response,
     forward_relocation_complete,
     relocation_cancel_request,				relocation_cancel_response,
     forward_srns_context,
     forward_relocation_complete_acknowledge,
     forward_srns_context_acknowledge,
     ran_information_relay,
     mbms_notification_request,				mbms_notification_response,
     mbms_notification_reject_request,			mbms_notification_reject_response,
     create_mbms_context_request,			create_mbms_context_response,
     update_mbms_context_request,			update_mbms_context_response,
     delete_mbms_context_request,			delete_mbms_context_response,
     mbms_registration_request,				mbms_registration_response,
     mbms_de_registration_request,			mbms_de_registration_response,
     mbms_session_start_request,			mbms_session_start_response,
     mbms_session_stop_request,				mbms_session_stop_response,
     mbms_session_update_request,			mbms_session_update_response,
     ms_info_change_notification_request,		ms_info_change_notification_response,
     data_record_transfer_request,			data_record_transfer_response].

gtp_msg_type(echo_request)					-> request;
gtp_msg_type(echo_response)					-> response;
gtp_msg_type(version_not_supported)				-> other;
gtp_msg_type(node_alive_request)				-> request;
gtp_msg_type(node_alive_response)				-> response;
gtp_msg_type(redirection_request)				-> request;
gtp_msg_type(redirection_response)				-> response;
gtp_msg_type(create_pdp_context_request)			-> request;
gtp_msg_type(create_pdp_context_response)			-> response;
gtp_msg_type(update_pdp_context_request)			-> request;
gtp_msg_type(update_pdp_context_response)			-> response;
gtp_msg_type(delete_pdp_context_request)			-> request;
gtp_msg_type(delete_pdp_context_response)			-> response;
gtp_msg_type(initiate_pdp_context_activation_request)		-> request;
gtp_msg_type(initiate_pdp_context_activation_response)		-> response;
gtp_msg_type(error_indication)					-> other;
gtp_msg_type(pdu_notification_request)				-> request;
gtp_msg_type(pdu_notification_response)				-> response;
gtp_msg_type(pdu_notification_reject_request)			-> request;
gtp_msg_type(pdu_notification_reject_response)			-> response;
gtp_msg_type(supported_extension_headers_notification)		-> other;
gtp_msg_type(send_routeing_information_for_gprs_request)	-> request;
gtp_msg_type(send_routeing_information_for_gprs_response)	-> response;
gtp_msg_type(failure_report_request)				-> request;
gtp_msg_type(failure_report_response)				-> response;
gtp_msg_type(note_ms_gprs_present_request)			-> request;
gtp_msg_type(note_ms_gprs_present_response)			-> response;
gtp_msg_type(identification_request)				-> request;
gtp_msg_type(identification_response)				-> response;
gtp_msg_type(sgsn_context_request)				-> request;
gtp_msg_type(sgsn_context_response)				-> response;
gtp_msg_type(sgsn_context_acknowledge)				-> other;
gtp_msg_type(forward_relocation_request)			-> request;
gtp_msg_type(forward_relocation_response)			-> response;
gtp_msg_type(forward_relocation_complete)			-> other;
gtp_msg_type(relocation_cancel_request)				-> request;
gtp_msg_type(relocation_cancel_response)			-> response;
gtp_msg_type(forward_srns_context)				-> other;
gtp_msg_type(forward_relocation_complete_acknowledge)		-> other;
gtp_msg_type(forward_srns_context_acknowledge)			-> other;
gtp_msg_type(ran_information_relay)				-> other;
gtp_msg_type(mbms_notification_request)				-> request;
gtp_msg_type(mbms_notification_response)			-> response;
gtp_msg_type(mbms_notification_reject_request)			-> request;
gtp_msg_type(mbms_notification_reject_response)			-> response;
gtp_msg_type(create_mbms_context_request)			-> request;
gtp_msg_type(create_mbms_context_response)			-> response;
gtp_msg_type(update_mbms_context_request)			-> request;
gtp_msg_type(update_mbms_context_response)			-> response;
gtp_msg_type(delete_mbms_context_request)			-> request;
gtp_msg_type(delete_mbms_context_response)			-> response;
gtp_msg_type(mbms_registration_request)				-> request;
gtp_msg_type(mbms_registration_response)			-> response;
gtp_msg_type(mbms_de_registration_request)			-> request;
gtp_msg_type(mbms_de_registration_response)			-> response;
gtp_msg_type(mbms_session_start_request)			-> request;
gtp_msg_type(mbms_session_start_response)			-> response;
gtp_msg_type(mbms_session_stop_request)				-> request;
gtp_msg_type(mbms_session_stop_response)			-> response;
gtp_msg_type(mbms_session_update_request)			-> request;
gtp_msg_type(mbms_session_update_response)			-> response;
gtp_msg_type(ms_info_change_notification_request)		-> request;
gtp_msg_type(ms_info_change_notification_response)		-> response;
gtp_msg_type(data_record_transfer_request)			-> request;
gtp_msg_type(data_record_transfer_response)			-> response;
gtp_msg_type(_)							-> other.

gtp_msg_response(echo_request)					-> echo_response;
gtp_msg_response(node_alive_request)				-> node_alive_response;
gtp_msg_response(redirection_request)				-> redirection_response;
gtp_msg_response(create_pdp_context_request)			-> create_pdp_context_response;
gtp_msg_response(update_pdp_context_request)			-> update_pdp_context_response;
gtp_msg_response(delete_pdp_context_request)			-> delete_pdp_context_response;
gtp_msg_response(initiate_pdp_context_activation_request)	-> initiate_pdp_context_activation_response;
gtp_msg_response(pdu_notification_request)			-> pdu_notification_response;
gtp_msg_response(pdu_notification_reject_request)		-> pdu_notification_reject_response;
gtp_msg_response(send_routeing_information_for_gprs_request)	-> send_routeing_information_for_gprs_response;
gtp_msg_response(failure_report_request)			-> failure_report_response;
gtp_msg_response(note_ms_gprs_present_request)			-> note_ms_gprs_present_response;
gtp_msg_response(identification_request)			-> identification_response;
gtp_msg_response(sgsn_context_request)				-> sgsn_context_response;
gtp_msg_response(forward_relocation_request)			-> forward_relocation_response;
gtp_msg_response(relocation_cancel_request)			-> relocation_cancel_response;
gtp_msg_response(mbms_notification_request)			-> mbms_notification_response;
gtp_msg_response(mbms_notification_reject_request)		-> mbms_notification_reject_response;
gtp_msg_response(create_mbms_context_request)			-> create_mbms_context_response;
gtp_msg_response(update_mbms_context_request)			-> update_mbms_context_response;
gtp_msg_response(delete_mbms_context_request)			-> delete_mbms_context_response;
gtp_msg_response(mbms_registration_request)			-> mbms_registration_response;
gtp_msg_response(mbms_de_registration_request)			-> mbms_de_registration_response;
gtp_msg_response(mbms_session_start_request)			-> mbms_session_start_response;
gtp_msg_response(mbms_session_stop_request)			-> mbms_session_stop_response;
gtp_msg_response(mbms_session_update_request)			-> mbms_session_update_response;
gtp_msg_response(ms_info_change_notification_request)		-> ms_info_change_notification_response;
gtp_msg_response(data_record_transfer_request)			-> data_record_transfer_response;
gtp_msg_response(Response)					-> Response.

get_handler(#gtp_port{name = PortName}, _Msg) ->
    ergw:handler(PortName, gn);
get_handler(_Port, _Msg) ->
    {error, {mandatory_ie_missing, ?'Access Point Name'}}.

validate_teid(MsgType, 0)
 when MsgType =:= create_pdp_context_request;
      MsgType =:= create_mbms_context_request;
      MsgType =:= identification_request;
      MsgType =:= sgsn_context_request;
      MsgType =:= echo_request;
      MsgType =:= forward_relocation_request;
      MsgType =:= pdu_notification_request;
      MsgType =:= mbms_notification_request;
      MsgType =:= relocation_cancel_request;
      MsgType =:= mbms_registration_request;
      MsgType =:= mbms_session_start_request;
      MsgType =:= ms_info_change_notification_request ->
    ok;
validate_teid(MsgType, 0) ->
    case gtp_msg_type(MsgType) of
	request ->
	    {error, not_found};
	_ ->
	    ok
    end;
validate_teid(_MsgType, _TEID) ->
    ok.

get_msg_keys(#gtp{version = v1, ie = IEs}) ->
    K0 = case maps:get(?'IMEI', IEs, undefined) of
	     #imei{imei = IMEI} ->
		 [{imei, IMEI}];
	     _ ->
		 []
	 end,
    case maps:get(?'IMSI', IEs, undefined) of
	#international_mobile_subscriber_identity{imsi = IMSI} ->
	    [{imsi, IMSI} | K0];
	_ ->
	    K0
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

add_recovery(#gtp_port{restart_counter = RCnt}, IEs) when is_list(IEs) ->
    [#recovery{restart_counter = RCnt} | IEs];
add_recovery(#gtp_port{restart_counter = RCnt}, IEs) when is_map(IEs) ->
    IEs#{'Recovery' => #recovery{restart_counter = RCnt}}.

map_reply_ies(IEs) when is_list(IEs) ->
    [map_reply_ie(IE) || IE <- IEs];
map_reply_ies(IEs) when is_map(IEs) ->
    maps:map(fun(_K, IE) -> map_reply_ie(IE) end, IEs);
map_reply_ies(IE) ->
    [map_reply_ie(IE)].

map_reply_ie(request_accepted) ->
    #cause{value = request_accepted};
map_reply_ie(not_found) ->
    #cause{value = non_existent};
map_reply_ie({mandatory_ie_missing, _}) ->
    #cause{value = mandatory_ie_missing};
map_reply_ie(IE)
  when is_tuple(IE) ->
    IE.
