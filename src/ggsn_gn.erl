%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn).

-behaviour(gtp_api).

-export([handle_request/2]).

-include_lib("gtplib/include/gtp_packet.hrl").

%%====================================================================
%% API
%%====================================================================

handle_request(#gtp{type = create_pdp_context_request, ie = IEs},
	       #{tei := LocalTEI, local_ip := LocalIP, handler := Handler} = State0) ->
    [RemoteCntlIP_IE,RemoteDataIP_IE | _] = collect_ies(gsn_address, IEs),
    RemoteCntlIP = gtp_c_lib:bin2ip(RemoteCntlIP_IE#gsn_address.address),
    RemoteDataIP = gtp_c_lib:bin2ip(RemoteDataIP_IE#gsn_address.address),

    #tunnel_endpoint_identifier_data_i{tei = RemoteDataTEI} =
	lists:keyfind(tunnel_endpoint_identifier_data_i, 1, IEs),
    #tunnel_endpoint_identifier_control_plane{tei = RemoteCntlTEI} =
	lists:keyfind(tunnel_endpoint_identifier_control_plane, 1, IEs),

    EUA = lists:keyfind(end_user_address, 1, IEs),
    {ReqMSv4, ReqMSv6} = pdp_alloc(EUA),

    {ok, MSv4, MSv6} = pdp_alloc_ip(LocalTEI, ReqMSv4, ReqMSv6, State0),
    Context = #{control_ip  => RemoteCntlIP,
		control_tei => RemoteCntlTEI,
		data_ip     => RemoteDataIP,
		data_tei    => RemoteDataTEI,
		ms_v4       => MSv4,
		ms_v6       => MSv6},
    State1 = State0#{context => Context},

    ok = gtp:create_pdp_context(Handler, 1, RemoteDataIP, MSv4, LocalTEI, RemoteDataTEI),

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
					       data = <<11,146,31>>}],
    Reply = {create_pdp_context_response, RemoteCntlTEI, ResponseIEs},
    {reply, Reply, State1};

handle_request(#gtp{type = delete_pdp_context_request, tei = LocalTEI, ie = _IEs},
	       #{handler := Handler, context := Context} = State) ->
    #{control_tei := RemoteCntlTEI,
      data_ip     := RemoteDataIP,
      data_tei    := RemoteDataTEI,
      ms_v4       := MSv4} = Context,

    ok = gtp:delete_pdp_context(Handler, 1, RemoteDataIP, MSv4, LocalTEI, RemoteDataTEI),
    pdp_release_ip(Context, State),
    Reply = {delete_pdp_context_response, RemoteCntlTEI, request_accepted},
    {stop, Reply, State};

handle_request(_Msg, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

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

pdp_release_ip(#{ms_v4 := MSv4, ms_v6 := MSv6}, #{handler := Handler}) ->
    gtp:release_pdp_ip(Handler, MSv4, MSv6).

collect_ies(Type, IEs) ->
    lists:filter(fun(X) -> element(1, X) == Type end, IEs).
