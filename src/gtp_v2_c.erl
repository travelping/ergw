%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_v2_c).

-behaviour(gtp_protocol).

%% API
-export([gtp_msg_type/1, build_response/1]).

-include_lib("gtplib/include/gtp_packet.hrl").

%%====================================================================
%% API
%%====================================================================
handle_sgsn(IEs, _State) ->
    case lists:keyfind(recovery, 1, IEs) of
        #recovery{restart_counter = _RCnt} ->
            %% TODO: register SGSN with restart_counter and handle SGSN restart
            [];
        _ ->
            []
    end.

build_response({Type, TEI, IEs}) ->
    #gtp{version = v2, type = Type, tei = TEI, ie = map_reply_ies(IEs)};
build_response({Type, IEs}) ->
    #gtp{version = v2, type = Type, tei = 0, ie = map_reply_ies(IEs)}.

gtp_msg_type(echo_request)					-> request;
gtp_msg_type(echo_response)					-> response;
gtp_msg_type(version_not_supported)				-> other;
gtp_msg_type(create_session_request)				-> request;
gtp_msg_type(create_session_response)				-> response;
gtp_msg_type(delete_session_request)				-> request;
gtp_msg_type(delete_session_response)				-> response;
gtp_msg_type(modify_bearer_request)				-> request;
gtp_msg_type(modify_bearer_response)				-> response;
gtp_msg_type(change_notification_request)			-> request;
gtp_msg_type(change_notification_response)			-> response;
gtp_msg_type(modify_bearer_command)				-> other;
gtp_msg_type(modify_bearer_failure_indication)			-> other;
gtp_msg_type(delete_bearer_command)				-> other;
gtp_msg_type(delete_bearer_failure_indication)			-> other;
gtp_msg_type(bearer_resource_command)				-> other;
gtp_msg_type(bearer_resource_failure_indication)		-> other;
gtp_msg_type(downlink_data_notification_failure_indication)	-> other;
gtp_msg_type(trace_session_activation)				-> other;
gtp_msg_type(trace_session_deactivation)			-> other;
gtp_msg_type(stop_paging_indication)				-> other;
gtp_msg_type(create_bearer_request)				-> request;
gtp_msg_type(create_bearer_response)				-> response;
gtp_msg_type(update_bearer_request)				-> request;
gtp_msg_type(update_bearer_response)				-> response;
gtp_msg_type(delete_bearer_request)				-> request;
gtp_msg_type(delete_bearer_response)				-> response;
gtp_msg_type(delete_pdn_connection_set_request)			-> request;
gtp_msg_type(delete_pdn_connection_set_response)		-> response;
gtp_msg_type(pgw_downlink_triggering_notification)		-> other;
gtp_msg_type(pgw_downlink_triggering_acknowledge)		-> other;
gtp_msg_type(identification_request)				-> request;
gtp_msg_type(identification_response)				-> response;
gtp_msg_type(context_request)					-> request;
gtp_msg_type(context_response)					-> response;
gtp_msg_type(context_acknowledge)				-> other;
gtp_msg_type(forward_relocation_request)			-> request;
gtp_msg_type(forward_relocation_response)			-> response;
gtp_msg_type(forward_relocation_complete_notification)		-> other;
gtp_msg_type(forward_relocation_complete_acknowledge)		-> other;
gtp_msg_type(forward_access_context_notification)		-> other;
gtp_msg_type(forward_access_context_acknowledge)		-> other;
gtp_msg_type(relocation_cancel_request)				-> request;
gtp_msg_type(relocation_cancel_response)			-> response;
gtp_msg_type(configuration_transfer_tunnel)			-> other;
gtp_msg_type(detach_notification)				-> other;
gtp_msg_type(detach_acknowledge)				-> other;
gtp_msg_type(cs_paging_indication)				-> other;
gtp_msg_type(ran_information_relay)				-> other;
gtp_msg_type(alert_mme_notification)				-> other;
gtp_msg_type(alert_mme_acknowledge)				-> other;
gtp_msg_type(ue_activity_notification)				-> other;
gtp_msg_type(ue_activity_acknowledge)				-> other;
gtp_msg_type(isr_status_indication)				-> other;
gtp_msg_type(create_forwarding_tunnel_request)			-> request;
gtp_msg_type(create_forwarding_tunnel_response)			-> response;
gtp_msg_type(suspend_notification)				-> other;
gtp_msg_type(suspend_acknowledge)				-> other;
gtp_msg_type(resume_notification)				-> other;
gtp_msg_type(resume_acknowledge)				-> other;
gtp_msg_type(create_indirect_data_forwarding_tunnel_request)	-> request;
gtp_msg_type(create_indirect_data_forwarding_tunnel_response)	-> response;
gtp_msg_type(delete_indirect_data_forwarding_tunnel_request)	-> request;
gtp_msg_type(delete_indirect_data_forwarding_tunnel_response)	-> response;
gtp_msg_type(release_access_bearers_request)			-> request;
gtp_msg_type(release_access_bearers_response)			-> response;
gtp_msg_type(downlink_data_notification)			-> other;
gtp_msg_type(downlink_data_notification_acknowledge)		-> other;
gtp_msg_type(pgw_restart_notification)				-> other;
gtp_msg_type(pgw_restart_notification_acknowledge)		-> other;
gtp_msg_type(update_pdn_connection_set_request)			-> request;
gtp_msg_type(update_pdn_connection_set_response)		-> response;
gtp_msg_type(mbms_session_start_response)			-> response;
gtp_msg_type(mbms_session_update_request)			-> request;
gtp_msg_type(mbms_session_update_response)			-> response;
gtp_msg_type(mbms_session_stop_request)				-> request;
gtp_msg_type(mbms_session_stop_response)			-> response;
gtp_msg_type(_)							-> other.

%%%===================================================================
%%% Internal functions
%%%===================================================================

map_reply_ies(IEs) when is_list(IEs) ->
    [map_reply_ie(IE) || IE <- IEs];
map_reply_ies(IE) ->
    [map_reply_ie(IE)].

map_reply_ie(request_accepted) ->
    #v2_cause{v2_cause = request_accepted};
map_reply_ie(not_found) ->
    #v2_cause{v2_cause = context_not_found};
map_reply_ie(IE)
  when is_tuple(IE) ->
    IE.

