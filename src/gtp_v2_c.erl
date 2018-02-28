%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_v2_c).

-behaviour(gtp_protocol).

%% API
-export([gtp_msg_types/0, gtp_msg_type/1,
	 get_handler/2,
	 build_response/1,
	 build_echo_request/1,
	 validate_teid/2,
	 type/0, port/0,
	 get_msg_keys/1, update_context_id/2,
	 get_cause/1,
	 load_class/1]).

%% support functions
-export([build_recovery/3]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

-define('Cause',					{v2_cause, 0}).
-define('Recovery',					{v2_recovery, 0}).
-define('Access Point Name',				{v2_access_point_name, 0}).
-define('Sender F-TEID for Control Plane',		{v2_fully_qualified_tunnel_endpoint_identifier, 0}).
-define('IMSI',						{v2_international_mobile_subscriber_identity, 0}).
-define('ME Identity',					{v2_mobile_equipment_identity, 0}).
-define('Bearer Contexts',                  		{v2_bearer_context, 0}).
-define('EPS Bearer ID',				{v2_eps_bearer_id, 0}).
-define('Indication Flags',				{v2_indication, 0}).

%%====================================================================
%% API
%%====================================================================

build_recovery(GtpPort = #gtp_port{}, NewPeer, IEs) when NewPeer == true ->
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
port() -> ?GTP2c_PORT.

build_echo_request(GtpPort) ->
    IEs = add_recovery(GtpPort, []),
    #gtp{version = v2, type = echo_request, tei = undefined, ie = IEs}.

build_response({Type, TEI, IEs}) ->
    #gtp{version = v2, type = gtp_msg_response(Type), tei = TEI, ie = map_reply_ies(IEs)};
build_response({Type, IEs}) ->
    #gtp{version = v2, type = gtp_msg_response(Type), tei = undefined, ie = map_reply_ies(IEs)}.

gtp_msg_types() ->
    [echo_request,					echo_response,
     version_not_supported,
     create_session_request,				create_session_response,
     delete_session_request,				delete_session_response,
     modify_bearer_request,				modify_bearer_response,
     change_notification_request,			change_notification_response,
     modify_bearer_command,				modify_bearer_failure_indication,
     delete_bearer_command,				delete_bearer_failure_indication,
     bearer_resource_command,				bearer_resource_failure_indication,
     downlink_data_notification_failure_indication,
     trace_session_activation,				trace_session_deactivation,
     stop_paging_indication,
     create_bearer_request,				create_bearer_response,
     update_bearer_request,				update_bearer_response,
     delete_bearer_request,				delete_bearer_response,
     delete_pdn_connection_set_request,			delete_pdn_connection_set_response,
     pgw_downlink_triggering_notification,		pgw_downlink_triggering_acknowledge,
     identification_request,				identification_response,
     context_request,					context_response,
     context_acknowledge,
     forward_relocation_request,			forward_relocation_response,
     forward_relocation_complete_notification,		forward_relocation_complete_acknowledge,
     forward_access_context_notification,		forward_access_context_acknowledge,
     relocation_cancel_request,				relocation_cancel_response,
     configuration_transfer_tunnel,
     detach_notification,				detach_acknowledge,
     cs_paging_indication,
     ran_information_relay,
     alert_mme_notification,				alert_mme_acknowledge,
     ue_activity_notification,				ue_activity_acknowledge,
     isr_status_indication,
     create_forwarding_tunnel_request,			create_forwarding_tunnel_response,
     suspend_notification,				suspend_acknowledge,
     resume_notification,				resume_acknowledge,
     create_indirect_data_forwarding_tunnel_request,	create_indirect_data_forwarding_tunnel_response,
     delete_indirect_data_forwarding_tunnel_request,	delete_indirect_data_forwarding_tunnel_response,
     release_access_bearers_request,			release_access_bearers_response,
     downlink_data_notification,			downlink_data_notification_acknowledge,
     pgw_restart_notification,				pgw_restart_notification_acknowledge,
     update_pdn_connection_set_request,			update_pdn_connection_set_response,
     mbms_session_start_request,			mbms_session_start_response,
     mbms_session_update_request,			mbms_session_update_response,
     mbms_session_stop_request,				mbms_session_stop_response].

gtp_msg_type(echo_request)					-> request;
gtp_msg_type(echo_response)					-> response;
gtp_msg_type(version_not_supported)				-> response;
gtp_msg_type(create_session_request)				-> request;
gtp_msg_type(create_session_response)				-> response;
gtp_msg_type(delete_session_request)				-> request;
gtp_msg_type(delete_session_response)				-> response;
gtp_msg_type(modify_bearer_request)				-> request;
gtp_msg_type(modify_bearer_response)				-> response;
gtp_msg_type(change_notification_request)			-> request;
gtp_msg_type(change_notification_response)			-> response;
gtp_msg_type(modify_bearer_command)				-> request;
gtp_msg_type(modify_bearer_failure_indication)			-> response;
gtp_msg_type(delete_bearer_command)				-> request;
gtp_msg_type(delete_bearer_failure_indication)			-> response;
gtp_msg_type(bearer_resource_command)				-> request;
gtp_msg_type(bearer_resource_failure_indication)		-> response;
gtp_msg_type(downlink_data_notification_failure_indication)	-> request;
gtp_msg_type(trace_session_activation)				-> request;
gtp_msg_type(trace_session_deactivation)			-> request;
gtp_msg_type(stop_paging_indication)				-> request;
gtp_msg_type(create_bearer_request)				-> request;
gtp_msg_type(create_bearer_response)				-> response;
gtp_msg_type(update_bearer_request)				-> request;
gtp_msg_type(update_bearer_response)				-> response;
gtp_msg_type(delete_bearer_request)				-> request;
gtp_msg_type(delete_bearer_response)				-> response;
gtp_msg_type(delete_pdn_connection_set_request)			-> request;
gtp_msg_type(delete_pdn_connection_set_response)		-> response;
gtp_msg_type(pgw_downlink_triggering_notification)		-> request;
gtp_msg_type(pgw_downlink_triggering_acknowledge)		-> response;
gtp_msg_type(identification_request)				-> request;
gtp_msg_type(identification_response)				-> response;
gtp_msg_type(context_request)					-> request;
gtp_msg_type(context_response)					-> response;
gtp_msg_type(context_acknowledge)				-> response;
gtp_msg_type(forward_relocation_request)			-> request;
gtp_msg_type(forward_relocation_response)			-> response;
gtp_msg_type(forward_relocation_complete_notification)		-> request;
gtp_msg_type(forward_relocation_complete_acknowledge)		-> response;
gtp_msg_type(forward_access_context_notification)		-> request;
gtp_msg_type(forward_access_context_acknowledge)		-> response;
gtp_msg_type(relocation_cancel_request)				-> request;
gtp_msg_type(relocation_cancel_response)			-> response;
gtp_msg_type(configuration_transfer_tunnel)			-> request;
gtp_msg_type(detach_notification)				-> request;
gtp_msg_type(detach_acknowledge)				-> response;
gtp_msg_type(cs_paging_indication)				-> request;
gtp_msg_type(ran_information_relay)				-> request;
gtp_msg_type(alert_mme_notification)				-> request;
gtp_msg_type(alert_mme_acknowledge)				-> response;
gtp_msg_type(ue_activity_notification)				-> request;
gtp_msg_type(ue_activity_acknowledge)				-> response;
gtp_msg_type(isr_status_indication)				-> request;
gtp_msg_type(create_forwarding_tunnel_request)			-> request;
gtp_msg_type(create_forwarding_tunnel_response)			-> response;
gtp_msg_type(suspend_notification)				-> request;
gtp_msg_type(suspend_acknowledge)				-> response;
gtp_msg_type(resume_notification)				-> request;
gtp_msg_type(resume_acknowledge)				-> response;
gtp_msg_type(create_indirect_data_forwarding_tunnel_request)	-> request;
gtp_msg_type(create_indirect_data_forwarding_tunnel_response)	-> response;
gtp_msg_type(delete_indirect_data_forwarding_tunnel_request)	-> request;
gtp_msg_type(delete_indirect_data_forwarding_tunnel_response)	-> response;
gtp_msg_type(release_access_bearers_request)			-> request;
gtp_msg_type(release_access_bearers_response)			-> response;
gtp_msg_type(downlink_data_notification)			-> request;
gtp_msg_type(downlink_data_notification_acknowledge)		-> response;
gtp_msg_type(pgw_restart_notification)				-> request;
gtp_msg_type(pgw_restart_notification_acknowledge)		-> response;
gtp_msg_type(update_pdn_connection_set_request)			-> request;
gtp_msg_type(update_pdn_connection_set_response)		-> response;
gtp_msg_type(mbms_session_start_request)			-> request;
gtp_msg_type(mbms_session_start_response)			-> response;
gtp_msg_type(mbms_session_update_request)			-> request;
gtp_msg_type(mbms_session_update_response)			-> response;
gtp_msg_type(mbms_session_stop_request)				-> request;
gtp_msg_type(mbms_session_stop_response)			-> response;
gtp_msg_type(_)							-> other.

gtp_msg_response(echo_request)						-> echo_response;
gtp_msg_response(create_session_request)				-> create_session_response;
gtp_msg_response(delete_session_request)				-> delete_session_response;
gtp_msg_response(modify_bearer_request)					-> modify_bearer_response;
gtp_msg_response(change_notification_request)				-> change_notification_response;
gtp_msg_response(modify_bearer_command)					-> modify_bearer_failure_indication;
gtp_msg_response(delete_bearer_command)					-> delete_bearer_failure_indication;
gtp_msg_response(bearer_resource_command)				-> bearer_resource_failure_indication;
gtp_msg_response(create_bearer_request)					-> create_bearer_response;
gtp_msg_response(update_bearer_request)					-> update_bearer_response;
gtp_msg_response(delete_bearer_request)					-> delete_bearer_response;
gtp_msg_response(delete_pdn_connection_set_request)			-> delete_pdn_connection_set_response;
gtp_msg_response(identification_request)				-> identification_response;
gtp_msg_response(context_request)					-> context_response;
gtp_msg_response(forward_relocation_request)				-> forward_relocation_response;
gtp_msg_response(relocation_cancel_request)				-> relocation_cancel_response;
gtp_msg_response(create_forwarding_tunnel_request)			-> create_forwarding_tunnel_response;
gtp_msg_response(create_indirect_data_forwarding_tunnel_request)	-> create_indirect_data_forwarding_tunnel_response;
gtp_msg_response(delete_indirect_data_forwarding_tunnel_request)	-> delete_indirect_data_forwarding_tunnel_response;
gtp_msg_response(release_access_bearers_request)			-> release_access_bearers_response;
gtp_msg_response(update_pdn_connection_set_request)			-> update_pdn_connection_set_response;
gtp_msg_response(mbms_session_start_request)				-> mbms_session_start_response;
gtp_msg_response(mbms_session_update_request)				-> mbms_session_update_response;
gtp_msg_response(mbms_session_stop_request)				-> mbms_session_stop_response;
gtp_msg_response(Response)						-> Response.

get_handler(#gtp_port{name = PortName},
	    #gtp{ie = #{?'Sender F-TEID for Control Plane' :=
			    #v2_fully_qualified_tunnel_endpoint_identifier{interface_type = IfType}}}) ->
    case map_v2_iftype(IfType) of
	{ok, Protocol} ->
	    ergw:handler(PortName, Protocol);
	_ ->
	    %% TODO: correct error message
	    {error, not_found}
    end;
get_handler(_Port, _Msg) ->
    {error, {mandatory_ie_missing, ?'Sender F-TEID for Control Plane'}}.

validate_teid(MsgType, 0)
 when MsgType =:= create_session_request;
      MsgType =:= create_indirect_data_forwarding_tunnel_request;
      MsgType =:= identification_request;
      MsgType =:= forward_relocation_request;
      MsgType =:= context_request;
      MsgType =:= relocation_cancel_request;
      MsgType =:= delete_pdn_connection_set_request;
      MsgType =:= mbms_session_start_request ->
    ok;
validate_teid(MsgType, 0) ->
    case gtp_msg_type(MsgType) of
	request ->
	    throw({error, not_found});
	_ ->
	    ok
    end;
validate_teid(_MsgType, _TEID) ->
    ok.

get_indication_flags(#{?'Indication Flags' := #v2_indication{flags = Flags}}) ->
    Flags;
get_indication_flags(_) ->
    [].

get_context_ebi(#{?'EPS Bearer ID' := #v2_eps_bearer_id{eps_bearer_id = LBI}}) ->
    LBI;
get_context_ebi(#{?'Bearer Contexts' :=
		      #v2_bearer_context{
			 group = #{
			   ?'EPS Bearer ID' := #v2_eps_bearer_id{eps_bearer_id = EBI}}}}) ->
    EBI;
get_context_ebi(_) ->
    '_'.

get_context_id(IEs) ->
    EBI = get_context_ebi(IEs),
    UIMSI = proplists:get_bool('UIMSI', get_indication_flags(IEs)),
    case {UIMSI, IEs} of
	{true, #{?'ME Identity' := #v2_mobile_equipment_identity{mei = IMEI}}} ->
	    {imei, IMEI, EBI};
	{false, #{?'IMSI' := #v2_international_mobile_subscriber_identity{imsi = IMSI}}} ->
	    {imsi, IMSI, EBI};
	_ ->
	    undefined
    end.

get_msg_keys(#gtp{version = v2, ie = IEs}) ->
    case get_context_id(IEs) of
	undefined ->
	    [];
	Id ->
	    [Id]
    end.

update_context_id(#gtp{version = v2, ie = IEs}, Context) ->
    case get_context_id(IEs) of
	{_, _, EBI} = Id when is_integer(EBI) ->
	    Context#context{context_id = Id};
	_Other ->
	    Context
    end.

get_cause(#{?Cause := #v2_cause{v2_cause = Cause}}) ->
    Cause;
get_cause(_) ->
    undefined.

load_class(#gtp{type = Type})
  when Type =:= create_session_request;
       Type =:= create_bearer_request ->
    create;
load_class(#gtp{type = Type})
  when Type =:= delete_session_request;
       Type =:= delete_bearer_command;
       Type =:= delete_bearer_request ->
    delete;
load_class(_) ->
    other.

%%%===================================================================
%%% Internal functions
%%%===================================================================

add_recovery(#gtp_port{restart_counter = RCnt}, IEs) when is_list(IEs) ->
    [#v2_recovery{restart_counter = RCnt} | IEs];
add_recovery(#gtp_port{restart_counter = RCnt}, IEs) when is_map(IEs) ->
    IEs#{'Recovery' => #v2_recovery{restart_counter = RCnt}}.

map_reply_ies(IEs) when is_list(IEs) ->
    [map_reply_ie(IE) || IE <- IEs];
map_reply_ies(IEs) when is_map(IEs) ->
    maps:map(fun(_K, IE) -> map_reply_ie(IE) end, IEs);
map_reply_ies(IE) ->
    [map_reply_ie(IE)].

map_reply_ie(request_accepted) ->
    #v2_cause{v2_cause = request_accepted};
map_reply_ie(not_found) ->
    #v2_cause{v2_cause = context_not_found};
map_reply_ie({mandatory_ie_missing, {_IE, _Instance}}) ->
    #v2_cause{v2_cause = mandatory_ie_missing};
map_reply_ie(system_failure) ->
    #v2_cause{v2_cause = system_failure};
map_reply_ie(missing_or_unknown_apn) ->
    #v2_cause{v2_cause = missing_or_unknown_apn};
map_reply_ie(no_resources_available) ->
    #v2_cause{v2_cause = no_resources_available};
map_reply_ie(rejected) ->
    #v2_cause{v2_cause = no_resources_available};
map_reply_ie(IE)
  when is_tuple(IE) ->
    IE.

map_v2_iftype(6)  -> {ok, s5s8};
map_v2_iftype(10) -> {ok, s11};
map_v2_iftype(_)  -> {error, unsupported}.
