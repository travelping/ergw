%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_path).

-behaviour(gen_server).

%% API
-export([start_link/6, get/4,
	 handle_message/3,
	 send_request/4, send_message/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("gtplib/include/gtp_packet.hrl").

%%%===================================================================
%%% API
%%%===================================================================

start_link(Type, IP, Handler, LocalIP, Args, Opts) ->
    gen_server:start_link(?MODULE, {Type, IP, Handler, LocalIP, Args}, Opts).

get(Type, IP, Handler, LocalIP) ->
    Key = {Type, IP},
    case gtp_path_reg:lookup(Key) of
        Path when is_pid(Path) ->
            Path;

        R ->
            lager:debug("gtp_path_reg:lookup(~w) got ~p", [Key, R]),
            {ok, Path} = gtp_path_sup:new_path(Type, IP, Handler, LocalIP, []),
            lager:info("NEW process for ~w at ~p", [Key, Path]),
            Path
    end.

handle_message(Path, Port, Msg) ->
    gen_server:cast(Path, {Port, Msg}).

%%%===================================================================
%%% Protocol Module API
%%%===================================================================

send_request(Port, #gtp{version = v1} = Msg, Fun,
	     #{t3 := T3, n3 := N3, seq_no := SeqNo} = State)
  when is_function(Fun, 2) ->
    send_message_timeout(SeqNo, T3, N3, Port,
			 Msg#gtp{seq_no = SeqNo}, Fun, State#{seq_no := SeqNo + 1});

send_request(Port, #gtp{version = v2} = Msg, Fun,
	     #{t3 := T3, n3 := N3, seq_no := SeqNo} = State)
  when is_function(Fun, 2) ->
    send_message_timeout(SeqNo, T3, N3, Port,
			 Msg#gtp{seq_no = SeqNo}, Fun, State#{seq_no := SeqNo + 1}).

send_message(Port, #gtp{} = Msg, State) ->
    final_send_message(Port, Msg, State).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init({Type, IP, Handler, LocalIP, Args}) ->
    gtp_path_reg:register({Type, IP}),

    State = #{type     => Type,
	      ip       => IP,
	      handler  => Handler,
	      local_ip => LocalIP,
	      t3       => proplists:get_value(t3, Args, 10 * 1000), %% 10sec
	      n3       => proplists:get_value(n3, Args, 5),
	      seq_no   => 0,
	      pending  => gb_trees:empty(),
	      tunnel_endpoints => gb_trees:empty()},

    lager:debug("State: ~p", [State]),
    {ok, State}.

handle_call(Request, _From, State) ->
    lager:warning("handle_call: ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({Port,
	     #gtp{version = v1, type = echo_request, tei = TEI, seq_no = SeqNo, ie = IEs}},
	    State) ->
    %% TODO: handle restart counter
    ResponseIEs = [],
    Response = #gtp{version = v1, type = echo_response, tei = TEI, seq_no = SeqNo, ie = ResponseIEs},
    send_message(Port, Response, State),
    {noreply, State};

handle_cast({Port,
	     #gtp{version = v2, type = echo_request, tei = TEI, seq_no = SeqNo, ie = IEs}},
	    State) ->
    %% TODO: handle restart counter
    ResponseIEs = [],
    Response = #gtp{version = v2, type = echo_response, tei = TEI, seq_no = SeqNo, ie = ResponseIEs},
    send_message(Port, Response, State),
    {noreply, State};

handle_cast({Port, #gtp{version = v1, type = Type} = Msg},
	    State0) ->
    State =
	case gtp_v1_msg_type(Type) of
	    response -> handle_response(Msg, State0);
	    _        -> handle_request(Port, Msg, State0)
	end,
    {noreply, State};

handle_cast({Port, #gtp{version = v2, type = Type} = Msg}, State0) ->
    lager:debug("~w: handle gtp_v2: ~w, ~p",
		[?MODULE, Port, fmt_gtp(Msg)]),
    State =
	case gtp_v2_msg_type(Type) of
	    response -> handle_response(Msg, State0);
	    _        -> handle_request(Port, Msg, State0)
	end,
    {noreply, State};

handle_cast(Msg, State) ->
    lager:debug("~w: handle_cast: ~p", [?MODULE, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(Info = {timeout, TRef, {send, SeqNo}}, #{pending := Pending0} = State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    case gb_trees:lookup(SeqNo, Pending0) of
	{value, {_T3, _N3 = 0,_Port, Msg, _Fun, TRef}} ->
	    %% TODO: handle path failure....
	    lager:error("gtp_path: message resent expired", [Msg]),
	    Pending1 = gb_trees:delete(SeqNo, Pending0),
	    {noreply, State#{pending => Pending1}};

	{value, {T3, N3, Port, Msg, Fun, TRef}} ->
	    %% resent....
	    Pending1 = gb_trees:delete(SeqNo, Pending0),
	    NewState = send_message_timeout(SeqNo, T3, N3 - 1, Port, Msg, Fun, State#{pending => Pending1}),
	    {noreply, NewState}
    end;
handle_info(Info, State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

fmt_ies(IEs) ->
    lists:map(fun(#v2_bearer_context{group = Group}) ->
		      lager:pr(#v2_bearer_context{group = fmt_ies(Group)}, ?MODULE);
		 (X) ->
		      lager:pr(X, ?MODULE)
	      end, IEs).

fmt_gtp(#gtp{version = v1, ie = IEs} = Msg) ->
    lager:pr(Msg#gtp{ie = fmt_ies(IEs)}, ?MODULE);
fmt_gtp(#gtp{version = v2, ie = IEs} = Msg) ->
    lager:pr(Msg#gtp{ie = fmt_ies(IEs)}, ?MODULE).

gtp_v1_msg_type(echo_request)					-> request;
gtp_v1_msg_type(echo_response)					-> response;
gtp_v1_msg_type(version_not_supported)				-> other;
gtp_v1_msg_type(node_alive_request)				-> request;
gtp_v1_msg_type(node_alive_response)				-> response;
gtp_v1_msg_type(redirection_request)				-> request;
gtp_v1_msg_type(redirection_response)				-> response;
gtp_v1_msg_type(create_pdp_context_request)			-> request;
gtp_v1_msg_type(create_pdp_context_response)			-> response;
gtp_v1_msg_type(update_pdp_context_request)			-> request;
gtp_v1_msg_type(update_pdp_context_response)			-> response;
gtp_v1_msg_type(delete_pdp_context_request)			-> request;
gtp_v1_msg_type(delete_pdp_context_response)			-> response;
gtp_v1_msg_type(initiate_pdp_context_activation_request)	-> request;
gtp_v1_msg_type(initiate_pdp_context_activation_response)	-> response;
gtp_v1_msg_type(error_indication)				-> other;
gtp_v1_msg_type(pdu_notification_request)			-> request;
gtp_v1_msg_type(pdu_notification_response)			-> response;
gtp_v1_msg_type(pdu_notification_reject_request)		-> request;
gtp_v1_msg_type(pdu_notification_reject_response)		-> response;
gtp_v1_msg_type(supported_extension_headers_notification)	-> other;
gtp_v1_msg_type(send_routeing_information_for_gprs_request)	-> request;
gtp_v1_msg_type(send_routeing_information_for_gprs_response)	-> response;
gtp_v1_msg_type(failure_report_request)				-> request;
gtp_v1_msg_type(failure_report_response)			-> response;
gtp_v1_msg_type(note_ms_gprs_present_request)			-> request;
gtp_v1_msg_type(note_ms_gprs_present_response)			-> response;
gtp_v1_msg_type(identification_request)				-> request;
gtp_v1_msg_type(identification_response)			-> response;
gtp_v1_msg_type(sgsn_context_request)				-> request;
gtp_v1_msg_type(sgsn_context_response)				-> response;
gtp_v1_msg_type(sgsn_context_acknowledge)			-> other;
gtp_v1_msg_type(forward_relocation_request)			-> request;
gtp_v1_msg_type(forward_relocation_response)			-> response;
gtp_v1_msg_type(forward_relocation_complete)			-> other;
gtp_v1_msg_type(relocation_cancel_request)			-> request;
gtp_v1_msg_type(relocation_cancel_response)			-> response;
gtp_v1_msg_type(forward_srns_context)				-> other;
gtp_v1_msg_type(forward_relocation_complete_acknowledge)	-> other;
gtp_v1_msg_type(forward_srns_context_acknowledge)		-> other;
gtp_v1_msg_type(ran_information_relay)				-> other;
gtp_v1_msg_type(mbms_notification_request)			-> request;
gtp_v1_msg_type(mbms_notification_response)			-> response;
gtp_v1_msg_type(mbms_notification_reject_request)		-> request;
gtp_v1_msg_type(mbms_notification_reject_response)		-> response;
gtp_v1_msg_type(create_mbms_context_request)			-> request;
gtp_v1_msg_type(create_mbms_context_response)			-> response;
gtp_v1_msg_type(update_mbms_context_request)			-> request;
gtp_v1_msg_type(update_mbms_context_response)			-> response;
gtp_v1_msg_type(delete_mbms_context_request)			-> request;
gtp_v1_msg_type(delete_mbms_context_response)			-> response;
gtp_v1_msg_type(mbms_registration_request)			-> request;
gtp_v1_msg_type(mbms_registration_response)			-> response;
gtp_v1_msg_type(mbms_de_registration_request)			-> request;
gtp_v1_msg_type(mbms_de_registration_response)			-> response;
gtp_v1_msg_type(mbms_session_start_request)			-> request;
gtp_v1_msg_type(mbms_session_start_response)			-> response;
gtp_v1_msg_type(mbms_session_stop_request)			-> request;
gtp_v1_msg_type(mbms_session_stop_response)			-> response;
gtp_v1_msg_type(mbms_session_update_request)			-> request;
gtp_v1_msg_type(mbms_session_update_response)			-> response;
gtp_v1_msg_type(ms_info_change_notification_request)		-> request;
gtp_v1_msg_type(ms_info_change_notification_response)		-> response;
gtp_v1_msg_type(data_record_transfer_request)			-> request;
gtp_v1_msg_type(data_record_transfer_response)			-> response;
gtp_v1_msg_type(_)						-> other.

gtp_v2_msg_type(echo_request)					-> request;
gtp_v2_msg_type(echo_response)					-> response;
gtp_v2_msg_type(version_not_supported)				-> other;
gtp_v2_msg_type(create_session_request)				-> request;
gtp_v2_msg_type(create_session_response)			-> response;
gtp_v2_msg_type(delete_session_request)				-> request;
gtp_v2_msg_type(delete_session_response)			-> response;
gtp_v2_msg_type(modify_bearer_request)				-> request;
gtp_v2_msg_type(modify_bearer_response)				-> response;
gtp_v2_msg_type(change_notification_request)			-> request;
gtp_v2_msg_type(change_notification_response)			-> response;
gtp_v2_msg_type(modify_bearer_command)				-> other;
gtp_v2_msg_type(modify_bearer_failure_indication)		-> other;
gtp_v2_msg_type(delete_bearer_command)				-> other;
gtp_v2_msg_type(delete_bearer_failure_indication)		-> other;
gtp_v2_msg_type(bearer_resource_command)			-> other;
gtp_v2_msg_type(bearer_resource_failure_indication)		-> other;
gtp_v2_msg_type(downlink_data_notification_failure_indication)	-> other;
gtp_v2_msg_type(trace_session_activation)			-> other;
gtp_v2_msg_type(trace_session_deactivation)			-> other;
gtp_v2_msg_type(stop_paging_indication)				-> other;
gtp_v2_msg_type(create_bearer_request)				-> request;
gtp_v2_msg_type(create_bearer_response)				-> response;
gtp_v2_msg_type(update_bearer_request)				-> request;
gtp_v2_msg_type(update_bearer_response)				-> response;
gtp_v2_msg_type(delete_bearer_request)				-> request;
gtp_v2_msg_type(delete_bearer_response)				-> response;
gtp_v2_msg_type(delete_pdn_connection_set_request)		-> request;
gtp_v2_msg_type(delete_pdn_connection_set_response)		-> response;
gtp_v2_msg_type(pgw_downlink_triggering_notification)		-> other;
gtp_v2_msg_type(pgw_downlink_triggering_acknowledge)		-> other;
gtp_v2_msg_type(identification_request)				-> request;
gtp_v2_msg_type(identification_response)			-> response;
gtp_v2_msg_type(context_request)				-> request;
gtp_v2_msg_type(context_response)				-> response;
gtp_v2_msg_type(context_acknowledge)				-> other;
gtp_v2_msg_type(forward_relocation_request)			-> request;
gtp_v2_msg_type(forward_relocation_response)			-> response;
gtp_v2_msg_type(forward_relocation_complete_notification)	-> other;
gtp_v2_msg_type(forward_relocation_complete_acknowledge)	-> other;
gtp_v2_msg_type(forward_access_context_notification)		-> other;
gtp_v2_msg_type(forward_access_context_acknowledge)		-> other;
gtp_v2_msg_type(relocation_cancel_request)			-> request;
gtp_v2_msg_type(relocation_cancel_response)			-> response;
gtp_v2_msg_type(configuration_transfer_tunnel)			-> other;
gtp_v2_msg_type(detach_notification)				-> other;
gtp_v2_msg_type(detach_acknowledge)				-> other;
gtp_v2_msg_type(cs_paging_indication)				-> other;
gtp_v2_msg_type(ran_information_relay)				-> other;
gtp_v2_msg_type(alert_mme_notification)				-> other;
gtp_v2_msg_type(alert_mme_acknowledge)				-> other;
gtp_v2_msg_type(ue_activity_notification)			-> other;
gtp_v2_msg_type(ue_activity_acknowledge)			-> other;
gtp_v2_msg_type(isr_status_indication)				-> other;
gtp_v2_msg_type(create_forwarding_tunnel_request)		-> request;
gtp_v2_msg_type(create_forwarding_tunnel_response)		-> response;
gtp_v2_msg_type(suspend_notification)				-> other;
gtp_v2_msg_type(suspend_acknowledge)				-> other;
gtp_v2_msg_type(resume_notification)				-> other;
gtp_v2_msg_type(resume_acknowledge)				-> other;
gtp_v2_msg_type(create_indirect_data_forwarding_tunnel_request)	-> request;
gtp_v2_msg_type(create_indirect_data_forwarding_tunnel_response)-> response;
gtp_v2_msg_type(delete_indirect_data_forwarding_tunnel_request)	-> request;
gtp_v2_msg_type(delete_indirect_data_forwarding_tunnel_response)-> response;
gtp_v2_msg_type(release_access_bearers_request)			-> request;
gtp_v2_msg_type(release_access_bearers_response)		-> response;
gtp_v2_msg_type(downlink_data_notification)			-> other;
gtp_v2_msg_type(downlink_data_notification_acknowledge)		-> other;
gtp_v2_msg_type(pgw_restart_notification)			-> other;
gtp_v2_msg_type(pgw_restart_notification_acknowledge)		-> other;
gtp_v2_msg_type(update_pdn_connection_set_request)		-> request;
gtp_v2_msg_type(update_pdn_connection_set_response)		-> response;
gtp_v2_msg_type(mbms_session_start_response)			-> response;
gtp_v2_msg_type(mbms_session_update_request)			-> request;
gtp_v2_msg_type(mbms_session_update_response)			-> response;
gtp_v2_msg_type(mbms_session_stop_request)			-> request;
gtp_v2_msg_type(mbms_session_stop_response)			-> response;
gtp_v2_msg_type(_)						-> other.

handle_request(Port, Msg = #gtp{version = v1}, #{type := 'gtp-u'} = State) ->
    handle_request(gtp_v1_u, Port, Msg, State);
handle_request(Port, Msg = #gtp{version = v1}, #{type := 'gtp-c'} = State) ->
    handle_request(gtp_v1_c, Port, Msg, State);
handle_request(Port, Msg = #gtp{version = v2}, #{type := 'gtp-c'} = State) ->
    handle_request(gtp_v2_c, Port, Msg, State);
handle_request(_Port, Msg, #{type := Type} = State) ->
    lager:error("unsupported protocol version ~p:~p", [element(1, Msg), Type]),
    State.

handle_request(M, Port, Msg = #gtp{version = v1, type = Type, tei = TEI, seq_no = SeqNo, ie = IEs},
	       #{ip := IP} = State0) ->
    lager:debug("GTPv1 ~s(~s:~w): ~p",
		[gtp_packet:msg_description(Type), inet:ntoa(IP), Port, fmt_gtp(Msg)]),

    try M:handle_request(Type, TEI, IEs, State0) of
	{reply, {RType, RTEI, RIEs}, State1} ->
	    Response = #gtp{version = v1, type = RType, tei = RTEI, seq_no = SeqNo, ie = RIEs},
	    lager:debug("gtp_v1 response: ~p", [fmt_gtp(Response)]),
	    send_message(Port, Response, State1);

	{noreply, State1} ->
	    State1;

	Other ->
	    lager:error("~s failed with: ~p", [M, Other]),
	    State0
    catch
	Class:Error ->
	    Stack  = erlang:get_stacktrace(),
	    lager:error("~s failed with: ~p:~p (~p)", [M, Class, Error, Stack]),
	    State0
    end;

handle_request(M, Port, Msg = #gtp{version = v2, type = Type, tei = TEI, seq_no = SeqNo, ie = IEs},
	       #{ip := IP} = State0) ->
    lager:debug("GTPv2 ~s(~s:~w): ~p",
		[gtp_packet:msg_description_v2(Type), inet:ntoa(IP), Port, fmt_gtp(Msg)]),

    try M:handle_request(Type, TEI, IEs, State0) of
	{reply, {RType, RTEI, RIEs}, State1} ->
	    Response = #gtp{version = v2, type = RType, tei = RTEI, seq_no = SeqNo, ie = RIEs},
	    lager:debug("gtp_v2 response: ~p", [fmt_gtp(Response)]),
	    send_message(Port, Response, State1);

	{noreply, State1} ->
	    State1;

	Other ->
	    lager:error("~s failed with: ~p", [M, Other]),
	    State0
    catch
	Class:Error ->
	    Stack  = erlang:get_stacktrace(),
	    lager:error("~s failed with: ~p:~p (~p)", [M, Class, Error, Stack]),
	    State0
    end.

handle_response(Msg = #gtp{version = v1, seq_no = SeqNo},
		#{pending := Pending0} = State) ->
    case gb_trees:lookup(SeqNo, Pending0) of
	none -> %% duplicate, drop silently
	    State;
	{value, {_T3, _N3, _Port, _ReqMsg, Fun, TRef}} ->
	    cancel_timer(TRef),
	    Pending1 = gb_trees:delete(SeqNo, Pending0),
	    Fun(Msg, State#{pending := Pending1})
    end;
handle_response(Msg = #gtp{version = v2, seq_no = SeqNo},
		#{pending := Pending0} = State) ->
    case gb_trees:lookup(SeqNo, Pending0) of
	none -> %% duplicate, drop silently
	    State;
	{value, {_T3, _N3, _Port, _ReqMsg, Fun, TRef}} ->
	    cancel_timer(TRef),
	    Pending1 = gb_trees:delete(SeqNo, Pending0),
	    Fun(Msg, State#{pending := Pending1})
    end.

final_send_message(Port, Msg, #{type := Type, ip := IP, handler := Handler} = State) ->
    %% TODO: handle encode errors
    try
        Data = gtp_packet:encode(Msg),
	lager:debug("gtp_path send ~s to ~w:~w: ~p, ~p", [Type, IP, Port, Msg, Data]),
	gtp:send(Handler, Type, IP, Port, Data)
    catch
	Class:Error ->
	    lager:error("gtp_path send failed with ~p:~p", [Class, Error])
    end,
    State.

send_message_timeout(SeqNo, T3, N3, Port, Msg, Fun, #{pending := Pending0} = State) ->
    TRef = erlang:start_timer(T3, self(), {send, SeqNo}),
    Pending1 = gb_trees:insert(SeqNo, {T3, N3, Port, Msg, Fun, TRef}, Pending0),
    final_send_message(Port, Msg, State#{pending := Pending1}).

cancel_timer(Ref) ->
    case erlang:cancel_timer(Ref) of
        false ->
            receive {timeout, Ref, _} -> 0
            after 0 -> false
            end;
        RemainingTime ->
            RemainingTime
    end.
