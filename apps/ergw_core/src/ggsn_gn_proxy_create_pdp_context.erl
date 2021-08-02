%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn_proxy_create_pdp_context).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([create_pdp_context/5]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-include("ggsn_gn.hrl").

%%====================================================================
%% Impl.
%%====================================================================

create_pdp_context(ReqKey, Request, _Resent, State, Data) ->
    gtp_context:next(
      create_pdp_context_fun(Request, _, _),
      create_pdp_context_ok(ReqKey, Request, _, _, _),
      create_pdp_context_fail(ReqKey, Request, _, _, _),
      State, Data).

create_pdp_context_ok(ReqKey, Request, Lease,
		  State, #{proxy_context := ProxyContext,
			   right_tunnel := RightTunnel, bearer := Bearer} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ggsn_gn_proxy:forward_request(sgsn2ggsn, ReqKey, Request, RightTunnel, Lease,
				  maps:get(right, Bearer), ProxyContext, Data),

    %% 30 second timeout to have enough room for resents
    Action = [{state_timeout, 30 * 1000, ReqKey}],
    {next_state, State#{session := connecting}, Data, Action}.

create_pdp_context_fail(ReqKey, #gtp{type = MsgType, seq_no = SeqNo} = Request,
		    #ctx_err{reply = Reply} = Error,
		    _State, #{left_tunnel := Tunnel} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    gtp_context:log_ctx_error(Error, []),
    Response0 = if is_list(Reply) orelse is_atom(Reply) ->
			gtp_v1_c:build_response({MsgType, Reply});
		   true ->
			gtp_v1_c:build_response(Reply)
		end,
    Response = case Tunnel of
		   #tunnel{remote = #fq_teid{teid = TEID}} ->
		       Response0#gtp{tei = TEID};
		   _ ->
		       case gtp_v1_c:find_sender_teid(Request) of
			   TEID when is_integer(TEID) ->
			       Response0#gtp{tei = TEID};
			   _ ->
			       Response0#gtp{tei = 0}
		       end
	       end,
    gtp_context:send_response(ReqKey, Response#gtp{seq_no = SeqNo}),
    {stop, normal, Data}.

create_pdp_context_fun(#gtp{ie = IEs} = Request,
		   State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	     update_context_from_gtp_req(Request),
	     update_tunnel_from_gtp_req(Request),
	     bind_tunnel(left),
	     terminate_colliding_context(),
	     SessionOpts <- init_session(IEs),

	     ProxyInfo <- handle_proxy_info(SessionOpts),
	     ProxySocket <- select_gtp_proxy_sockets(ProxyInfo),

	     NodeSelect <- statem_m:get_data(maps:get(node_selection, _)),
	     %% GTP v1 services only, we don't do v1 to v2 conversion (yet)
	     Services = [{'x-3gpp-ggsn', 'x-gn'}, {'x-3gpp-ggsn', 'x-gp'},
			 {'x-3gpp-pgw', 'x-gn'}, {'x-3gpp-pgw', 'x-gp'}],
	     ProxyGGSN <-
		 statem_m:lift(ergw_proxy_lib:select_gw(ProxyInfo, v1, Services, NodeSelect, ProxySocket)),

	     Candidates <- select_sx_proxy_candidate(ProxyGGSN, ProxyInfo),
	     SxConnectId = ergw_sx_node:request_connect(Candidates, NodeSelect, 1000),

	     aaa_start(SessionOpts),

	     init_proxy_context(ProxyInfo),
	     init_proxy_tunnel(ProxySocket, ProxyGGSN),
	     Lease <- aquire_lease(right),

	     %% TBD: make non-blocking
	     return(ergw_sx_node:wait_connect(SxConnectId)),

	     NodeCaps <- select_upf(Candidates),
	     assign_local_data_teid(left, NodeCaps),
	     assign_local_data_teid(right, NodeCaps),

	     PCC = ergw_proxy_lib:proxy_pcc(),
	     pfcp_create_session(PCC),

	     ergw_gtp_gsn_lib:remote_context_register_new(),
	     return(Lease)
	 ]), State, Data).

update_context_from_gtp_req(Request) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   Context0 <- statem_m:get_data(maps:get(context, _)),
	   Context = ggsn_gn:update_context_from_gtp_req(Request, Context0),
	   statem_m:modify_data(_#{context => Context})
       ]).

update_tunnel_from_gtp_req(Request) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{left_tunnel := LeftTunnel0, bearer := #{left := LeftBearer0}} <- statem_m:get_data(),
	   {LeftTunnel, LeftBearer} <-
	       statem_m:lift(ggsn_gn:update_tunnel_from_gtp_req(Request, LeftTunnel0, LeftBearer0)),
	   statem_m:modify_data(
	     fun(Data) ->
		     maps:update_with(bearer,
				      maps:put(left, LeftBearer, _),
				      Data#{left_tunnel => LeftTunnel})
	     end)
       ]).

bind_tunnel(left) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   LeftTunnel0 <- statem_m:get_data(maps:get(left_tunnel, _)),
	   LeftTunnel <- statem_m:lift(gtp_path:bind_tunnel(LeftTunnel0)),
	   statem_m:modify_data(_#{left_tunnel => LeftTunnel})
       ]).

aquire_lease(right) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   RightTunnel0 <- statem_m:get_data(maps:get(right_tunnel, _)),
	   {Lease, RightTunnel} <- statem_m:lift(gtp_path:aquire_lease(RightTunnel0)),
	   statem_m:modify_data(_#{right_tunnel => RightTunnel}),
	   statem_m:return(Lease)
       ]).

terminate_colliding_context() ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{left_tunnel := LeftTunnel, context := Context} <- statem_m:get_data(),
	   statem_m:return(gtp_context:terminate_colliding_context(LeftTunnel, Context))
       ]).

init_session(IEs) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{left_tunnel := LeftTunnel, bearer := #{left := LeftBearer},
	     context := Context, aaa_opts := AAAopts} <- statem_m:get_data(),

	   SessionOpts0 = ggsn_gn:init_session(IEs, LeftTunnel, Context, AAAopts),
	   SessionOpts1 =
	       ggsn_gn:init_session_from_gtp_req(IEs, AAAopts, LeftTunnel, LeftBearer, SessionOpts0),
	   %% SessionOpts = init_session_qos(ReqQoSProfile, SessionOpts1),

	   statem_m:modify_data(_#{session_opts => SessionOpts1}),
	   statem_m:return(SessionOpts1)
       ]).

handle_proxy_info(SessionOpts) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{context := Context, proxy_ds := ProxyDS, left_tunnel := LeftTunnel,
	     bearer := #{left := LeftBearer}} <- statem_m:get_data(),
	   PI = ergw_proxy_lib:proxy_info(SessionOpts, LeftTunnel, LeftBearer, Context),
	   case gtp_proxy_ds:map(ProxyDS, PI) of
	       ProxyInfo when is_map(ProxyInfo) ->
		   ?LOG(debug, "OK Proxy Map: ~p", [ProxyInfo]),
		   statem_m:return(ProxyInfo);

	       {error, Cause} ->
		   ?LOG(warning, "Failed Proxy Map: ~p", [Cause]),
		   statem_m:fail(?CTX_ERR(?FATAL, Cause))
	   end
       ]).

select_gtp_proxy_sockets(ProxyInfo) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   Data <- statem_m:get_data(),
	   statem_m:return(ergw_proxy_lib:select_gtp_proxy_sockets(ProxyInfo, Data))
       ]).

select_sx_proxy_candidate(ProxyGGSN, ProxyInfo) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   Data <- statem_m:get_data(),
	   statem_m:return(
	     ergw_proxy_lib:select_sx_proxy_candidate(ProxyGGSN, ProxyInfo, Data))
       ]).

aaa_start(SessionOpts) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   Session <- statem_m:get_data(maps:get('Session', _)),
	   statem_m:lift(
	     ergw_aaa_session:invoke(Session, SessionOpts, start, #{async =>true}))
       ]).

init_proxy_context(ProxyInfo) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   Context <- statem_m:get_data(maps:get(context, _)),
	   ProxyContext = ggsn_gn_proxy:init_proxy_context(Context, ProxyInfo),
	   statem_m:modify_data(_#{proxy_context => ProxyContext})
       ]).

init_proxy_tunnel(ProxySocket, ProxyGGSN) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   RightTunnel = ggsn_gn_proxy:init_proxy_tunnel(ProxySocket, ProxyGGSN),
	   statem_m:modify_data(_#{right_tunnel => RightTunnel})
       ]).

select_upf(Candidates) ->
     do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	    {PCtx, NodeCaps} <- statem_m:lift(ergw_pfcp_context:select_upf(Candidates)),
	    statem_m:modify_data(_#{pfcp => PCtx}),
	    statem_m:return(NodeCaps)
	]).

assign_local_data_teid(left = Key, NodeCaps) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{pfcp := PCtx, left_tunnel := LeftTunnel,
	     bearer := Bearer0} <- statem_m:get_data(),
	   Bearer <-
	       statem_m:lift(
		 ergw_gsn_lib:assign_local_data_teid(Key, PCtx, NodeCaps, LeftTunnel, Bearer0)),
	   statem_m:modify_data(_#{bearer => Bearer})
       ]);
assign_local_data_teid(right = Key, NodeCaps) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   #{pfcp := PCtx, right_tunnel := RightTunnel,
	     bearer := Bearer0} <- statem_m:get_data(),
	   Bearer <-
	       statem_m:lift(
		 ergw_gsn_lib:assign_local_data_teid(Key, PCtx, NodeCaps, RightTunnel, Bearer0)),
	   statem_m:modify_data(_#{bearer => Bearer})
       ]).

pfcp_create_session(PCC) ->
     do([statem_m ||
	    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	    #{context := Context, bearer := Bearer, pfcp := PCtx0} <- statem_m:get_data(),

	    {ReqId, PCtx} <-
		statem_m:return(
		  ergw_pfcp_context:send_session_establishment_request(
		    gtp_context, PCC, PCtx0, Bearer, Context)),
	    statem_m:modify_data(_#{pfcp => PCtx}),

	    Response <- statem_m:wait(ReqId),
	    ergw_gtp_gsn_lib:pfcp_create_session_response(Response),

	    statem_m:return()
	]).
