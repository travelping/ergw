%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8_proxy_modify_bearer).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([modify_bearer/5, modify_bearer_response/5]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-include("pgw_s5s8.hrl").

%%====================================================================
%% Impl.
%%====================================================================

modify_bearer(ReqKey, Request, _Resent, State, Data) ->
    gtp_context:next(
      modify_bearer_fun(Request, _, _),
      modify_bearer_ok(ReqKey, Request, Data, _, _, _),
      modify_bearer_fail(ReqKey, Request, _, _, _),
      State, Data).

modify_bearer_ok(ReqKey, Request, DataOld, Lease,
		 State, #{proxy_context := ProxyContext, right_tunnel := RightTunnel,
			  bearer := #{right := RightBearer}} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    pgw_s5s8_proxy:forward_request(
      sgw2pgw, ReqKey, Request, RightTunnel, Lease, RightBearer, ProxyContext, Data, DataOld),
    {next_state, State, Data}.

modify_bearer_fail(ReqKey, Request, Error, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ct:fail(#{'ReqKey' => ReqKey, 'Request' => Request, 'Error' => Error, 'State' => State, 'Data' => Data}),
    {stop, normal, Data}.

modify_bearer_fun(Request, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	     update_tunnel_from_gtp_req(left, Request),
	     update_tunnel_endpoint(left, Data),
	     handle_peer_change(Data),
	     update_tunnel_endpoint(right, Data),
	     Lease <- aquire_lease(right),
	     statem_m:return(Lease)
	 ]), State, Data).

modify_bearer_response(ProxyRequest, Response, Request, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ?LOG(debug, "OK Proxy Response ~p", [Response]),
    gtp_context:next(
      modify_bearer_response_fun(ProxyRequest, Response, _, _),
      modify_bearer_response_ok(ProxyRequest, Response, _, _, _),
      modify_bearer_response_fail(ProxyRequest, Response, Request, _, _, _),
      State, Data).

modify_bearer_response_ok(ProxyRequest, Response, _,
			   State, #{context := Context, left_tunnel := LeftTunnel,
				    bearer := #{left := LeftBearer}} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

    pgw_s5s8_proxy:forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    {next_state, State, Data}.

modify_bearer_response_fail(ProxyRequest, Response, Request, Error, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

    ct:fail(#{'ProxyRequest' => ProxyRequest, 'Response' => Response,
	      'Request' => Request, 'Error' => Error, 'State' => State, 'Data' => Data}),
    {next_state, State#{session := shutdown}, Data}.

modify_bearer_response_fun(#proxy_request{right_tunnel = RightTunnelPrev},
			   Response, State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	     update_tunnel_from_gtp_req(right, Response),
	     update_tunnel_endpoint(right, Data),
	     update_context_from_gtp_req(proxy_context, Response),

	     proxy_context_register(),

	     PCC = ergw_proxy_lib:proxy_pcc(),
	     pfcp_modify_bearers(PCC, RightTunnelPrev),
	     statem_m:return()
	 ]), State, Data).

update_context_from_gtp_req(Type, Request) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s, ~p", [?FUNCTION_NAME, Type]),
	   Context0 <- statem_m:get_data(maps:get(Type, _)),
	   Context = pgw_s5s8:update_context_from_gtp_req(Request, Context0),
	   statem_m:modify_data(_#{Type => Context})
       ]).

%% TBD: almost identical to create_session
update_tunnel_from_gtp_req(left, Request) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s, left", [?FUNCTION_NAME]),
	   #{left_tunnel := LeftTunnel0, bearer := #{left := LeftBearer0}} <- statem_m:get_data(),
	   {LeftTunnel, LeftBearer} <-
	       statem_m:lift(pgw_s5s8:update_tunnel_from_gtp_req(
			       Request, LeftTunnel0#tunnel{version = v2}, LeftBearer0)),
	   statem_m:modify_data(
	     fun(Data) ->
		     maps:update_with(bearer,
				      maps:put(left, LeftBearer, _),
				      Data#{left_tunnel => LeftTunnel})
	     end)
       ]);
update_tunnel_from_gtp_req(right, Request) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s, right", [?FUNCTION_NAME]),
	   #{right_tunnel := RightTunnel0, bearer := #{right := RightBearer0}} <- statem_m:get_data(),
	   {RightTunnel, RightBearer} <-
	       statem_m:lift(pgw_s5s8:update_tunnel_from_gtp_req(
			       Request, RightTunnel0#tunnel{version = v2}, RightBearer0)),
	   statem_m:modify_data(
	     fun(Data) ->
		     maps:update_with(bearer,
				      maps:put(right, RightBearer, _),
				      Data#{right_tunnel => RightTunnel})
	     end)
       ]).

update_tunnel_endpoint(left, #{left_tunnel := LeftTunnelOld}) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s, left", [?FUNCTION_NAME]),
	   LeftTunnel0 <- statem_m:get_data(maps:get(left_tunnel, _)),
	   LeftTunnel <- statem_m:return(ergw_gtp_gsn_lib:update_tunnel_endpoint(
					   LeftTunnelOld, LeftTunnel0)),
	   statem_m:modify_data(_#{left_tunnel => LeftTunnel})
       ]);
update_tunnel_endpoint(right, #{right_tunnel := RightTunnelOld}) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s/~p, right", [?FUNCTION_NAME, ?FUNCTION_ARITY]),
	   RightTunnel0 <- statem_m:get_data(maps:get(right_tunnel, _)),
	   RightTunnel <- statem_m:return(ergw_gtp_gsn_lib:update_tunnel_endpoint(
					    RightTunnelOld, RightTunnel0)),
	   statem_m:modify_data(_#{right_tunnel => RightTunnel})
       ]).

aquire_lease(right) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   RightTunnel0 <- statem_m:get_data(maps:get(right_tunnel, _)),
	   {Lease, RightTunnel} <- statem_m:lift(gtp_path:aquire_lease(RightTunnel0)),
	   statem_m:modify_data(_#{right_tunnel => RightTunnel}),
	   statem_m:return(Lease)
       ]).

proxy_context_register() ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{proxy_context := ProxyContext,
	     right_tunnel := RightTunnel, bearer := Bearer} <- statem_m:get_data(),
	   statem_m:return(
	     gtp_context:remote_context_register(RightTunnel, Bearer, ProxyContext))
       ]).

handle_peer_change(#{left_tunnel := LeftTunnelOld, right_tunnel := RightTunnelOld}) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	   LeftTunnel <- statem_m:get_data(maps:get(left_tunnel, _)),
	   RightTunnel <-
	       statem_m:return(
		 ergw_gtp_gsn_lib:handle_peer_change(
		   LeftTunnel, LeftTunnelOld, RightTunnelOld#tunnel{version = v2})),
	   statem_m:modify_data(_#{right_tunnel => RightTunnel})
       ]).

%% TBD: unify with ergw_gtp_gsn_lib:apply_bearer_change/2
pfcp_modify_bearers(PCC, RightTunnelPrev) ->
     do([statem_m ||
	    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	    #{pfcp := PCtx0, right_tunnel := RightTunnel, bearer := Bearer}
		<- statem_m:get_data(),

	    SendEM = RightTunnelPrev#tunnel.version == RightTunnel#tunnel.version,
	    ModifyOpts =
	       if SendEM -> #{send_end_marker => true};
		  true   -> #{}
	       end,

	    {PCtx, ReqId} <-
		statem_m:return(
		  ergw_pfcp_context:send_session_modification_request(
		    PCC, [], ModifyOpts, Bearer, PCtx0)),
	    statem_m:modify_data(_#{pfcp => PCtx}),
	    Response <- statem_m:wait(ReqId),

	    PCtx1 <- statem_m:get_data(maps:get(pfcp, _)),
	    {_, _, SessionInfo} <-
		statem_m:lift(ergw_pfcp_context:receive_session_modification_response(PCtx1, Response)),
	    statem_m:modify_data(_#{session_info => SessionInfo}),

	    statem_m:return(SessionInfo)
	]).
