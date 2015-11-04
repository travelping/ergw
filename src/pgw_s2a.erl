%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s2a).

-behaviour(gtp_api).

-compile({parse_transform, do}).

-export([handle_request/2]).

-include_lib("gtplib/include/gtp_packet.hrl").

%%====================================================================
%% API
%%====================================================================

handle_request(#gtp{type = create_session_request, ie = IEs},
	       #{tei := LocalTEI, local_ip := LocalIP, handle := Handler} = State0) ->

    #v2_fully_qualified_tunnel_endpoint_identifier{instance = 0,
						   key  = RemoteCntlTEI,
						   ipv4 = RemoteCntlIP} =
	lists:keyfind(v2_fully_qualified_tunnel_endpoint_identifier, 1, IEs),

    #v2_bearer_context{group = GroupIEs} =
	lists:keyfind(v2_bearer_context, 1, IEs),
    #v2_fully_qualified_tunnel_endpoint_identifier{instance = 6,                  %% S2a TEI Instance
						   key = RemoteDataTEI,
						   ipv4 = RemoteDataIP} =
	lists:keyfind(v2_fully_qualified_tunnel_endpoint_identifier, 1, GroupIEs),

    PAA = lists:keyfind(v2_pdn_address_allocation, 1, IEs),
    {ReqMSv4, ReqMSv6} = pdn_alloc(PAA),

    {ok, MSv4, MSv6} = pdn_alloc_ip(LocalTEI, ReqMSv4, ReqMSv6, State0),
    Context = #{control_ip  => gtp_c_lib:bin2ip(RemoteCntlIP),
		control_tei => RemoteCntlTEI,
		data_ip     => gtp_c_lib:bin2ip(RemoteDataIP),
		data_tei    => RemoteDataTEI,
		ms_v4       => MSv4,
		ms_v6       => MSv6},
    State1 = State0#{context => Context},

    ok = gtp:create_pdp_context(Handler, 1, RemoteDataIP, MSv4, LocalTEI, RemoteDataTEI),

    ResponseIEs = [#v2_cause{v2_cause = request_accepted},
		   #v2_fully_qualified_tunnel_endpoint_identifier{
		      instance = 1,
		      interface_type = 36,          %% S2a PGW GTP-C
		      key = LocalTEI,
		      ipv4 = gtp_c_lib:ip2bin(LocalIP)
		     },
		   encode_paa(MSv4, MSv6),
		   %% #v2_protocol_configuration_options{config = {0,
		   %% 						[{ipcp,'CP-Configure-Ack',0,
		   %% 						  [{ms_dns1,<<8,8,8,8>>},{ms_dns2,<<0,0,0,0>>}]}]}},
		   #v2_bearer_context{group=[#v2_cause{v2_cause = request_accepted},
					     #v2_eps_bearer_id{eps_bearer_id=15,data = <<>>},
					     #v2_bearer_level_quality_of_service{pl=15,
										 pvi=0,
										 label=9,maximum_bit_rate_for_uplink=0,
										 maximum_bit_rate_for_downlink=0,
										 guaranteed_bit_rate_for_uplink=0,
										 guaranteed_bit_rate_for_downlink=0,
										 data = <<0,0,0,0>>},
					     #v2_fully_qualified_tunnel_endpoint_identifier{instance = 5,                  %% S2a TEI Instance
											    interface_type = 37,           %% S2a PGW GTP-U
											    key = LocalTEI,
											    ipv4 = gtp_c_lib:ip2bin(LocalIP)}]}
		   ],
    Response = {create_session_response, RemoteCntlTEI, ResponseIEs},
    {ok, Response, State1};

handle_request(#gtp{type = delete_session_request, tei = LocalTEI, ie = IEs},
	       #{handler := Handler, context := Context} = State0) ->
    Result =
	do([error_m ||
	       FqTEI <- lookup_ie(v2_fully_qualified_tunnel_endpoint_identifier, IEs),
	       {RemoteCntlTEI, MS, RemoteDataIP, RemoteDataTEI} <- match_context(35, Context, FqTEI),
	       pdn_release_ip(Context, State0),
	       gtp:delete_pdp_context(Handler, 1, RemoteDataIP, MS, LocalTEI, RemoteDataTEI),
	       return({RemoteCntlTEI, request_accepted, State0})
	   ]),

    case Result of
	{ok, {ReplyTEI, ReplyIEs, State}} ->
	    Reply = {delete_session_response, ReplyTEI, ReplyIEs},
	    {stop, Reply, State};

	{error, {ReplyTEI, ReplyIEs}} ->
	    Response = {delete_session_response, ReplyTEI, ReplyIEs},
	    {reply, Response, State0};

	{error, ReplyIEs} ->
	    Response = {delete_session_response, 0, ReplyIEs},
	    {reply, Response, State0}
    end;

handle_request(_Msg, State) ->
    {noreply, State}.

%%%===================================================================
%%% Helper functions
%%%===================================================================
ip2prefix({IP, Prefix}) ->
    <<Prefix:8, (gtp_c_lib:ip2bin(IP))/binary>>.

lookup_ie(Key, IEs) ->
    case lists:keyfind(Key, 1, IEs) of
	false ->
	    error_m:fail([#v2_cause{v2_cause = mandatory_ie_missing}]);
	IE ->
	    error_m:return(IE)
    end.

match_context(Type,
	      #{control_ip  := RemoteCntlIP,
		control_tei := RemoteCntlTEI,
		data_ip     := RemoteDataIP,
		data_tei    := RemoteDataTEI,
		ms_v4       := MS},
	      #v2_fully_qualified_tunnel_endpoint_identifier{instance       = 0,
							     interface_type = Type,
							     key            = RemoteCntlTEI,
							     ipv4           = RemoteCntlIP}) ->
    error_m:return({RemoteCntlTEI, MS, RemoteDataIP, RemoteDataTEI});
match_context(Type, Context, IE) ->
    lager:error("match_context: context not found, ~p, ~p, ~p", [Type, Context, lager:pr(IE, ?MODULE)]),
    error_m:fail([#v2_cause{v2_cause = context_not_found}]).

pdn_alloc(#v2_pdn_address_allocation{type = ipv4v6,
				     address = << IP6PrefixLen:8, IP6Prefix:16/binary, IP4:4/binary>>}) ->
    {gtp_c_lib:bin2ip(IP4), {gtp_c_lib:bin2ip(IP6Prefix), IP6PrefixLen}};
pdn_alloc(#v2_pdn_address_allocation{type = ipv4,
				     address = << IP4:4/binary>>}) ->
    {gtp_c_lib:bin2ip(IP4), undefined};
pdn_alloc(#v2_pdn_address_allocation{type = ipv6,
				     address = << IP6PrefixLen:8, IP6Prefix:16/binary>>}) ->
    {undefined, {gtp_c_lib:bin2ip(IP6Prefix), IP6PrefixLen}}.

encode_paa(IPv4, undefined) ->
    encode_paa(ipv4, gtp_c_lib:ip2bin(IPv4), <<>>);
encode_paa(undefined, IPv6) ->
    encode_paa(ipv6, <<>>, ip2prefix(IPv6));
encode_paa(IPv4, IPv6) ->
    encode_paa(ipv4v6, gtp_c_lib:ip2bin(IPv4), ip2prefix(IPv6)).

encode_paa(Type, IPv4, IPv6) ->
    #v2_pdn_address_allocation{type = Type, address = <<IPv6/binary, IPv4/binary>>}.

pdn_alloc_ip(TEI, IPv4, IPv6, #{handler := Handler}) ->
    gtp:allocate_pdp_ip(Handler, TEI, IPv4, IPv6).

pdn_release_ip(#{ms_v4 := MSv4, ms_v6 := MSv6}, #{handler := Handler}) ->
    gtp:release_pdp_ip(Handler, MSv4, MSv6).

