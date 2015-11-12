%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_v1_c).

-behaviour(gtp_protocol).

%% API
-export([gtp_msg_type/1,
	 build_response/1,
	 build_echo_request/0,
	 type/0, port/0]).

%% support functions
-export([handle_sgsn/3, build_recovery/2]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

%%====================================================================
%% API
%%====================================================================
handle_sgsn(IEs, Context, State) ->
    RecoveryCount =
	case lists:keyfind(recovery, 1, IEs) of
	    #recovery{restart_counter = RCnt} ->
		RCnt;
        _ ->
		undefined
    end,
    gtp_context:handle_recovery(RecoveryCount, Context, State).

build_recovery(#gtp_port{restart_counter = RCnt}, true) ->
    [#recovery{restart_counter = RCnt}];
build_recovery(_, _) ->
    [].

type() -> 'gtp-c'.
port() -> ?GTP1c_PORT.

build_echo_request() ->
    #gtp{version = v1, type = echo_request, tei = 0, ie = []}.

build_response({Type, TEI, IEs}) ->
    #gtp{version = v1, type = gtp_msg_response(Type), tei = TEI, ie = map_reply_ies(IEs)};
build_response({Type, IEs}) ->
    #gtp{version = v1, type = gtp_msg_response(Type), tei = 0, ie = map_reply_ies(IEs)}.

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

%%%===================================================================
%%% Internal functions
%%%===================================================================

map_reply_ies(IEs) when is_list(IEs) ->
    [map_reply_ie(IE) || IE <- IEs];
map_reply_ies(IE) ->
    [map_reply_ie(IE)].

map_reply_ie(request_accepted) ->
    #cause{value = request_accepted};
map_reply_ie(not_found) ->
    #cause{value = unknown_pdp_address_or_pdp_type};
map_reply_ie({mandatory_ie_missing, _}) ->
    #cause{value = mandatory_ie_missing};
map_reply_ie(IE)
  when is_tuple(IE) ->
    IE.
