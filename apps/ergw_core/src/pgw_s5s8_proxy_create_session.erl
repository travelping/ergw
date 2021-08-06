%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8_proxy_create_session).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([create_session/5, create_session_response/5]).

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

-define(CAUSE_OK(Cause), (Cause =:= request_accepted orelse
			  Cause =:= request_accepted_partially orelse
			  Cause =:= new_pdp_type_due_to_network_preference orelse
			  Cause =:= new_pdp_type_due_to_single_address_bearer_only)).

create_session(ReqKey, Request, _Resent, State, Data) ->
    ergw_context_statem:next(
      create_session_fun(Request, _, _),
      create_session_ok(ReqKey, Request, Data, _, _, _),
      create_session_fail(ReqKey, Request, _, _, _),
      State, Data).

create_session_ok(ReqKey, Request, DataOld, Lease,
		  State, #{proxy_context := ProxyContext,
			   right_tunnel := RightTunnel, bearer := Bearer} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    pgw_s5s8_proxy:forward_request(sgw2pgw, ReqKey, Request, RightTunnel, Lease,
				   maps:get(right, Bearer), ProxyContext, Data, DataOld),

    %% 30 second timeout to have enough room for resents
    Action = [{state_timeout, 30 * 1000, ReqKey}],
    {next_state, State#{session := connecting}, Data, Action}.

create_session_fail(ReqKey, #gtp{type = MsgType, seq_no = SeqNo} = Request,
		    #ctx_err{reply = Reply} = Error,
		    _State, #{left_tunnel := Tunnel} = Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    gtp_context:log_ctx_error(Error, []),
    Response0 = if is_list(Reply) orelse is_atom(Reply) ->
			gtp_v2_c:build_response({MsgType, Reply});
		   true ->
			gtp_v2_c:build_response(Reply)
		end,
    Response = case Tunnel of
		   #tunnel{remote = #fq_teid{teid = TEID}} ->
		       Response0#gtp{tei = TEID};
		   _ ->
		       case gtp_v2_c:find_sender_teid(Request) of
			   TEID when is_integer(TEID) ->
			       Response0#gtp{tei = TEID};
			   _ ->
			       Response0#gtp{tei = 0}
		       end
	       end,
    gtp_context:send_response(ReqKey, Response#gtp{seq_no = SeqNo}),
    {stop, normal, Data};

create_session_fail(ReqKey, Request, Error, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ct:fail(#{'ReqKey' => ReqKey, 'Request' => Request, 'Error' => Error, 'State' => State, 'Data' => Data}),
    {next_state, State#{session := shutdown}, Data}.

create_session_fun(#gtp{ie = IEs} = Request,
		   State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	     update_context_from_gtp_req(context, Request),
	     update_tunnel_from_gtp_req(left, Request),
	     bind_tunnel(left),
	     terminate_colliding_context(),
	     SessionOpts <- init_session(IEs),

	     ProxyInfo <- handle_proxy_info(SessionOpts),
	     ProxySocket <- select_gtp_proxy_sockets(ProxyInfo),

	     NodeSelect <- statem_m:get_data(maps:get(node_selection, _)),
	     %% GTP v2 services only, we don't do v1 to v2 conversion (yet)
	     Services = [{'x-3gpp-pgw', 'x-s8-gtp'}, {'x-3gpp-pgw', 'x-s5-gtp'}],
	     ProxyGGSN <-
		 statem_m:lift(ergw_proxy_lib:select_gw(ProxyInfo, v2, Services, NodeSelect, ProxySocket)),

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


create_session_response(ProxyRequest, Response, Request, State, Data) ->
    ?LOG(debug, "OK Proxy Response ~p", [Response]),
    ergw_context_statem:next(
      create_session_response_fun(Response, _, _),
      create_session_response_ok(ProxyRequest, Response, _, _, _),
      create_session_response_fail(ProxyRequest, Response, Request, _, _, _),
      State, Data).

create_session_response_ok(ProxyRequest, Response, NextState,
			   State, #{context := Context, left_tunnel := LeftTunnel,
				    bearer := #{left := LeftBearer}} = Data) ->
    _ = ?LOG(debug, "~s: -> ~p", [?FUNCTION_NAME, NextState]),

    pgw_s5s8_proxy:forward_response(ProxyRequest, Response, LeftTunnel, LeftBearer, Context),
    {next_state, State#{session := NextState}, Data}.

create_session_response_fail(ProxyRequest, Response, Request, Error, State, Data) ->
    _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
    ct:fail(#{'ProxyRequest' => ProxyRequest, 'Response' => Response,
	      'Request' => Request, 'Error' => Error, 'State' => State, 'Data' => Data}),
    {next_state, State#{session := shutdown}, Data}.

create_session_response_fun(#gtp{ie = #{?'Cause' := #v2_cause{v2_cause = Cause}}} = Response,
			    State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),

	     update_tunnel_from_gtp_req(right, Response),
	     bind_tunnel(right),
	     update_context_from_gtp_req(proxy_context, Response),

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

update_context_from_gtp_req(Type, Request) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s, ~p", [?FUNCTION_NAME, Type]),
	   Context0 <- statem_m:get_data(maps:get(Type, _)),
	   Context = pgw_s5s8:update_context_from_gtp_req(Request, Context0),
	   statem_m:modify_data(_#{Type => Context})
       ]).

update_tunnel_from_gtp_req(left, Request) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s, left", [?FUNCTION_NAME]),
	   #{left_tunnel := LeftTunnel0, bearer := #{left := LeftBearer0}} <- statem_m:get_data(),
	   {LeftTunnel, LeftBearer} <-
	       statem_m:lift(pgw_s5s8:update_tunnel_from_gtp_req(Request, LeftTunnel0, LeftBearer0)),
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
	       statem_m:lift(pgw_s5s8:update_tunnel_from_gtp_req(Request, RightTunnel0, RightBearer0)),
	   statem_m:modify_data(
	     fun(Data) ->
		     maps:update_with(bearer,
				      maps:put(right, RightBearer, _),
				      Data#{right_tunnel => RightTunnel})
	     end)
       ]).

bind_tunnel(left) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   LeftTunnel0 <- statem_m:get_data(maps:get(left_tunnel, _)),
	   LeftTunnel <- statem_m:lift(gtp_path:bind_tunnel(LeftTunnel0)),
	   statem_m:modify_data(_#{left_tunnel => LeftTunnel})
       ]);
bind_tunnel(right) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   RightTunnel0 <- statem_m:get_data(maps:get(right_tunnel, _)),
	   RightTunnel <- statem_m:lift(gtp_path:bind_tunnel(RightTunnel0)),
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

	   SessionOpts0 = pgw_s5s8:init_session(IEs, LeftTunnel, Context, AAAopts),
	   SessionOpts1 =
	       pgw_s5s8:init_session_from_gtp_req(IEs, AAAopts, LeftTunnel, LeftBearer, SessionOpts0),
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
	   ProxyContext = pgw_s5s8_proxy:init_proxy_context(Context, ProxyInfo),
	   statem_m:modify_data(_#{proxy_context => ProxyContext})
       ]).

init_proxy_tunnel(ProxySocket, ProxyGGSN) ->
    do([statem_m ||
	   _ = ?LOG(debug, "~s", [?FUNCTION_NAME]),
	   RightTunnel = pgw_s5s8_proxy:init_proxy_tunnel(ProxySocket, ProxyGGSN),
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

	   statem_m:modify_data(pgw_s5s8_proxy:delete_forward_session(Reason, _)),
	   statem_m:return(ok)
       ]).
