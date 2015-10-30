%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_v2_c).

-compile({parse_transform, do}).

-export([handle_request/4]).

-include_lib("gtplib/include/gtp_packet.hrl").

%%====================================================================
%% API
%%====================================================================

handle_request(create_session_request, _, IEs,
	       #{local_ip := LocalIP, ip := IP, handler := Handler} = State0) ->
    #v2_fully_qualified_tunnel_endpoint_identifier{key = RemoteCntlTEI} =
	lists:keyfind(v2_fully_qualified_tunnel_endpoint_identifier, 1, IEs),

    #v2_bearer_context{group = GroupIEs} =
	lists:keyfind(v2_bearer_context, 1, IEs),
    #v2_fully_qualified_tunnel_endpoint_identifier{instance = 6,                  %% S2a TEI Instance
						   key = RemoteDataTEI} =
	lists:keyfind(v2_fully_qualified_tunnel_endpoint_identifier, 1, GroupIEs),

    PAA = lists:keyfind(v2_pdn_address_allocation, 1, IEs),
    {ReqMSv4, ReqMSv6} = pdn_alloc(PAA),

    {ok, LocalTEI} = gtp_c_lib:alloc_tei(),
    {ok, MSv4, MSv6} = pdn_alloc_ip(LocalTEI, ReqMSv4, ReqMSv6, State0),
    Context = #{remote_tei_control => RemoteCntlTEI,
		remote_tei_data    => RemoteDataTEI,
		ms_v4              => MSv4,
		ms_v6              => MSv6},
    State1 = gtp_c_lib:enter_tei(LocalTEI, Context, State0),

    ok = gtp:create_pdp_context(Handler, 1, IP, MSv4, LocalTEI, RemoteDataTEI),

    RecoveryIE = handle_sgsn(IEs, State1),
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
		   | RecoveryIE],
    Response = {create_session_response, RemoteCntlTEI, ResponseIEs},
    {reply, Response, State1};

handle_request(delete_session_request, TEI, IEs,
	       #{ip := IP, handler := Handler} = State0) ->
    Result =
	do([error_m ||
	       Context <- gtp_c_lib:lookup_tei(TEI, State0),
	       FqTEI <- lookup_ie(v2_fully_qualified_tunnel_endpoint_identifier, IEs),
	       {MS, RemoteDataTEI} <- match_context(35, gtp_c_lib:ip2bin(IP), Context, FqTEI),
	       pdn_release_ip(Context, State0),
	       gtp:delete_pdp_context(Handler, 1, IP, MS, TEI, RemoteDataTEI),
	       State1 <- gtp_c_lib:remove_tei(TEI, State0),
	       return({TEI, request_accepted, State1})
	   ]),

    case Result of
	{ok, {ReplyTEI, ReplyIEs, State}} ->
	    Response = {delete_session_response, ReplyTEI, map_reply_ies(ReplyIEs)},
	    {reply, Response, State};

	{error, {ReplyTEI, ReplyIEs}} ->
	    Response = {delete_session_response, ReplyTEI, map_reply_ies(ReplyIEs)},
	    {reply, Response, State0};

	{error, ReplyIEs} ->
	    Response = {delete_session_response, 0, map_reply_ies(ReplyIEs)},
	    {reply, Response, State0}
    end;

handle_request(_Type, _TEI, _IEs, State) ->
    {noreply, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

ip2prefix({IP, Prefix}) ->
    <<Prefix:8, (gtp_c_lib:ip2bin(IP))/binary>>.

handle_sgsn(IEs, _State) ->
    case lists:keyfind(recovery, 1, IEs) of
        #recovery{restart_counter = _RCnt} ->
            %% TODO: register SGSN with restart_counter and handle SGSN restart
            [];
        _ ->
            []
    end.

lookup_ie(Key, IEs) ->
    case lists:keyfind(Key, 1, IEs) of
	false ->
	    error_m:fail([#v2_cause{v2_cause = mandatory_ie_missing}]);
	IE ->
	    error_m:return(IE)
    end.

match_context(Type, IP,
	      #{remote_tei_control := RemoteCntlTEI,
		remote_tei_data    := RemoteDataTEI,
		ms_v4              := MS},
	      #v2_fully_qualified_tunnel_endpoint_identifier{instance       = 0,
							     interface_type = Type,
							     key            = RemoteCntlTEI,
							     ipv4           = IP}) ->
    error_m:return({MS, RemoteDataTEI});
match_context(Type, IP, Context, IE) ->
    lager:error("match_context: context not found, ~p, ~p, ~p, ~p", [Type, IP, Context, lager:pr(IE, ?MODULE)]),
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
