%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ggsn_gn_proxy_create_pdp_context).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([create_pdp_context/5, create_pdp_context_response/5]).

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

-define(CAUSE_OK(Cause), (Cause =:= request_accepted orelse
			  Cause =:= new_pdp_type_due_to_network_preference orelse
			  Cause =:= new_pdp_type_due_to_single_address_bearer_only)).

create_pdp_context(ReqKey, Request, _Resent, State, Data) ->
    ergw_context_statem:next(
      create_pdp_context_fun(Request, _, _),
      create_pdp_context_ok(ReqKey, Request, _, _, _),
      create_pdp_context_fail(ReqKey, Request, _, _, _),
      State#{fsm := busy}, Data).

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
	     ergw_gtp_gsn_lib:update_context_from_gtp_req(ggsn_gn, context, Request),
	     ergw_gtp_gsn_lib:update_tunnel_from_gtp_req(ggsn_gn, v1, left, Request),
	     ergw_gtp_gsn_lib:bind_tunnel(left),
	     ergw_gtp_gsn_lib:terminate_colliding_context(),
	     SessionOpts <- ergw_gtp_gsn_lib:init_session(ggsn_gn, IEs),

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
	     ergw_gtp_gsn_lib:assign_local_data_teid(left, NodeCaps),
	     ergw_gtp_gsn_lib:assign_local_data_teid(right, NodeCaps),

	     PCC = ergw_proxy_lib:proxy_pcc(),
	     ergw_gtp_gsn_lib:pfcp_create_session(PCC),

	     ergw_gtp_gsn_lib:remote_context_register_new(),
	     return(Lease)
	 ]), State, Data).

create_pdp_context_response(ProxyRequest, Response, Request, #{fsm := busy} = State, Data) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),
    ergw_context_statem:next(
      create_pdp_context_response_fun(Response, _, _),
      create_pdp_context_response_ok(ProxyRequest, Response, _, _, _),
      create_pdp_context_response_fail(ProxyRequest, Response, Request, _, _, _),
      State, Data).

create_pdp_context_response_ok(ProxyRequest, Response, NextState,
			   State, #{context := Context, left_tunnel := LeftTunnel,
				    bearer := #{left := LeftBearer}} = Data) ->
    _ = ?LOG(debug, "~s: -> ~p", [?FUNCTION_NAME, NextState]),

    ggsn_gn_proxy:forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    case NextState of
	connected ->
	    {next_state, State#{session := NextState, fsm := idle}, Data};
	shutdown ->
	    {next_state, State#{session := NextState, fsm := busy}, Data}
    end.

create_pdp_context_response_fail(ProxyRequest, Response, Request, Error, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

    %% this can not happen
    ?LOG(warning, #{'ProxyRequest' => ProxyRequest, 'Response' => Response,
		    'Request' => Request, 'Error' => Error, 'State' => State, 'Data' => Data}),
    {next_state, State#{session := shutdown}, Data}.

create_pdp_context_response_fun(#gtp{ie = #{?'Cause' := #cause{value = Cause}}} = Response,
			    State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	     ergw_gtp_gsn_lib:update_tunnel_from_gtp_req(ggsn_gn, v1, right, Response),
	     ergw_gtp_gsn_lib:bind_tunnel(right),
	     ergw_gtp_gsn_lib:update_context_from_gtp_req(ggsn_gn, proxy_context, Response),

	     proxy_context_register(),

	     case ?CAUSE_OK(Cause) of
		 true ->
		     do([statem_m ||
			    _ = ?LOG(debug, "~s: ok with ~p", [?FUNCTION_NAME, Cause]),

			    PCC = ergw_proxy_lib:proxy_pcc(),
			    pfcp_modify_bearers(PCC),
			    statem_m:return(connected)
			]);
		 _ ->
		     do([statem_m ||
			    _ = ?LOG(debug, "~s: fail with ~p", [?FUNCTION_NAME, Cause]),

			    delete_forward_session(normal),
			    statem_m:return(shutdown)
			])
	     end
	 ]), State, Data).

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

pfcp_modify_bearers(PCC) ->
     do([statem_m ||
	    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	    #{pfcp := PCtx0, bearer := Bearer} <- statem_m:get_data(),
	    {PCtx, ReqId} <-
		statem_m:return(
		  ergw_pfcp_context:send_session_modification_request(
		    PCC, [], #{}, Bearer, PCtx0)),
	    statem_m:modify_data(_#{pfcp => PCtx}),
	    Response <- statem_m:wait(ReqId),

	    PCtx1 <- statem_m:get_data(maps:get(pfcp, _)),
	    {_, _, SessionInfo} <-
		statem_m:lift(ergw_pfcp_context:receive_session_modification_response(PCtx1, Response)),
	    statem_m:modify_data(_#{session_info => SessionInfo}),

	    statem_m:return(SessionInfo)
	]).

%% TBD: make non-blocking
delete_forward_session(Reason) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	   statem_m:modify_data(ggsn_gn_proxy:delete_forward_session(Reason, _)),
	   statem_m:return(ok)
       ]).
