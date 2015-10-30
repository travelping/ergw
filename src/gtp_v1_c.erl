%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_v1_c).

-compile({parse_transform, do}).

-export([handle_request/4]).

-include_lib("gtplib/include/gtp_packet.hrl").

%%====================================================================
%% API
%%====================================================================

handle_request(create_pdp_context_request, _, IEs,
	       #{local_ip := LocalIP, handler := Handler} = State0) ->
    [SGSNCntlIP_IE,SGSNDataIP_IE | _] = collect_ies(gsn_address, IEs),
    SGSNCntlIP = gtp_c_lib:bin2ip(SGSNCntlIP_IE#gsn_address.address),
    SGSNDataIP = gtp_c_lib:bin2ip(SGSNDataIP_IE#gsn_address.address),

    #tunnel_endpoint_identifier_data_i{tei = SGSNDataTEI} =
	lists:keyfind(tunnel_endpoint_identifier_data_i, 1, IEs),
    #tunnel_endpoint_identifier_control_plane{tei = SGSNCntlTEI} =
	lists:keyfind(tunnel_endpoint_identifier_control_plane, 1, IEs),

    EUA = lists:keyfind(end_user_address, 1, IEs),
    {ReqMSv4, ReqMSv6} = pdp_alloc(EUA),

    {ok, LocalTEI} = gtp_c_lib:alloc_tei(),
    {ok, MSv4, MSv6} = pdp_alloc_ip(LocalTEI, ReqMSv4, ReqMSv6, State0),
    Context = #{sgsn_control_ip  => SGSNCntlIP,
		sgsn_control_tei => SGSNCntlTEI,
		sgsn_data_ip     => SGSNDataIP,
		sgsn_data_tei    => SGSNDataTEI,
		ms_v4            => MSv4,
		ms_v6            => MSv6},
    State1 = gtp_c_lib:enter_tei(LocalTEI, Context, State0),

    ok = gtp:create_pdp_context(Handler, 1, SGSNDataIP, MSv4, LocalTEI, SGSNDataTEI),

    RecoveryIE = handle_sgsn(IEs, State1),
    ResponseIEs = [#cause{value = request_accepted},
		   #reordering_required{required = no},
		   #tunnel_endpoint_identifier_data_i{tei = LocalTEI},
		   #tunnel_endpoint_identifier_control_plane{tei = LocalTEI},
		   #charging_id{id = <<0,0,0,1>>},
		   encode_eua(MSv4, MSv6),
		   #protocol_configuration_options{config = {0,
							     [{ipcp,'CP-Configure-Ack',0,
                                                               [{ms_dns1,<<8,8,8,8>>},{ms_dns2,<<0,0,0,0>>}]}]}},
		   #gsn_address{address = gtp_c_lib:ip2bin(LocalIP)},   %% for Control Plane
		   #gsn_address{address = gtp_c_lib:ip2bin(LocalIP)},   %% for User Traffic
		   #quality_of_service_profile{priority = 0,
					       data = <<11,146,31>>}
		   | RecoveryIE],
    Response = {create_pdp_context_response, SGSNCntlTEI, ResponseIEs},
    {reply, Response, State1};

handle_request(delete_pdp_context_request, TEI, _IEs,
	       #{handler := Handler} = State0) ->
    Result =
	do([error_m ||
	       #{sgsn_data_ip  := SGSNDataIP,
		 sgsn_data_tei := SGSNDataTEI,
		 ms_v4         := MSv4}
		   <- gtp_c_lib:lookup_tei(TEI, State0),
	       gtp:delete_pdp_context(Handler, 1, SGSNDataIP, MSv4, TEI, SGSNDataTEI),
	       State1 <- gtp_c_lib:remove_tei(TEI, State0),
	       return({TEI, request_accepted, State1})
	   ]),

    case Result of
	{ok, {ReplyTEI, ReplyIEs, State}} ->
	    Response = {delete_pdp_context_response, ReplyTEI, map_reply_ies(ReplyIEs)},
	    {reply, Response, State};

	{error, {ReplyTEI, ReplyIEs}} ->
	    Response = {delete_pdp_context_response, ReplyTEI, map_reply_ies(ReplyIEs)},
	    {reply, Response, State0};

	{error, ReplyIEs} ->
	    Response = {delete_pdp_context_response, 0, map_reply_ies(ReplyIEs)},
	    {reply, Response, State0}
    end;

handle_request(_Type, _TEI, _IEs, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

handle_sgsn(IEs, _State) ->
    case lists:keyfind(recovery, 1, IEs) of
        #recovery{restart_counter = _RCnt} ->
            %% TODO: register SGSN with restart_counter and handle SGSN restart
            [];
        _ ->
            []
    end.

pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#21,
			    pdp_address = Address}) ->
    IP4 = case Address of
	      << >> ->
		  {0,0,0,0};
	      <<_:4/bytes>> ->
		  gtp_c_lib:bin2ip(Address)
	  end,
    {IP4, undefined};

pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#57,
			    pdp_address = Address}) ->
    IP6 = case Address of
	      << >> ->
		  {{0,0,0,0,0,0,0,0},0};
	      <<_:16/bytes>> ->
		  {gtp_c_lib:bin2ip(Address),128}
	  end,
    {undefined, IP6};
pdp_alloc(#end_user_address{pdp_type_organization = 1,
			    pdp_type_number = 16#8D,
			    pdp_address = Address}) ->
    case Address of
	<< IP4:4/bytes, IP6:16/bytes >> ->
	    {gtp_c_lib:bin2ip(IP4), {gtp_c_lib:bin2ip(IP6), 128}};
	<< IP6:16/bytes >> ->
	    {{0,0,0,0}, {gtp_c_lib:bin2ip(IP6), 128}};
	<< IP4:4/bytes >> ->
	    {gtp_c_lib:bin2ip(IP4), {{0,0,0,0,0,0,0,0},0}};
 	<<  >> ->
	    {{0,0,0,0}, {{0,0,0,0,0,0,0,0},0}}
   end;

pdp_alloc(_) ->
    {undefined, undefined}.

encode_eua(IPv4, undefined) ->
    encode_eua(1, 16#21, gtp_c_lib:ip2bin(IPv4), <<>>);
encode_eua(undefined, {IPv6,_}) ->
    encode_eua(1, 16#57, <<>>, gtp_c_lib:ip2bin(IPv6));
encode_eua(IPv4, {IPv6,_}) ->
    encode_eua(1, 16#8D, gtp_c_lib:ip2bin(IPv4), gtp_c_lib:ip2bin(IPv6)).

encode_eua(Org, Number, IPv4, IPv6) ->
    #end_user_address{pdp_type_organization = Org,
		      pdp_type_number = Number,
		      pdp_address = <<IPv4/binary, IPv6/binary >>}.

pdp_alloc_ip(TEI, IPv4, IPv6, #{handler := Handler}) ->
    gtp:allocate_pdp_ip(Handler, TEI, IPv4, IPv6).

map_reply_ies(IEs) when is_list(IEs) ->
    [map_reply_ie(IE) || IE <- IEs];
map_reply_ies(IE) ->
    [map_reply_ie(IE)].

map_reply_ie(request_accepted) ->
    #cause{value = request_accepted};
map_reply_ie(not_found) ->
    #cause{value = unknown_pdp_address_or_pdp_type};
map_reply_ie(IE)
  when is_tuple(IE) ->
    IE.

collect_ies(Type, IEs) ->
    lists:filter(fun(X) -> element(1, X) == Type end, IEs).
