%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(pgw_s5s8_create_session).

-compile([{parse_transform, do},
	  {parse_transform, cut}]).

-export([create_session/5]).

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("diameter/include/diameter_gen_base_rfc6733.hrl").
-include_lib("ergw_aaa/include/diameter_3gpp_ts29_212.hrl").
-include_lib("ergw_aaa/include/ergw_aaa_session.hrl").
-include("include/ergw.hrl").

-include("gtp_context.hrl").
-include("pgw_s5s8.hrl").

%%====================================================================
%% Impl.
%%====================================================================


create_session(ReqKey, Request, _Resent, State, Data) ->
    gtp_context:next(
      create_session_fun(Request, _, _),
      create_session_ok(ReqKey, Request, _, _, _),
      create_session_fail(ReqKey, Request, _, _, _),
      State, Data).

create_session_ok(ReqKey,
		 #gtp{ie = #{?'Bearer Contexts to be created' :=
				 #v2_bearer_context{group = #{?'EPS Bearer ID' := EBI}}
			    } = IEs} = Request,
		 {Cause, SessionOpts},
		 _State, #{context := Context, left_tunnel := LeftTunnel,
			   bearer := Bearer} = Data) ->
    ct:pal("Cause: ~p~nOpts: ~p~nIEs: ~p~nEBI: ~p~nTunnel: ~p~nBearer: ~p~nContext: ~p~n",
	   [Cause, SessionOpts, IEs, EBI, LeftTunnel, Bearer, Context]),
    ResponseIEs = pgw_s5s8:create_session_response(Cause, SessionOpts, IEs, EBI, LeftTunnel, Bearer, Context),
    Response = pgw_s5s8:response(create_session_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = pgw_s5s8:context_idle_action([], Context),
    {next_state, connected, Data, Actions}.

create_session_fail(ReqKey, #gtp{type = MsgType, seq_no = SeqNo} = Request,
		    #ctx_err{reply = Reply} = Error,
		    _State, #{left_tunnel := Tunnel} = Data) ->
    ct:pal("Error: ~p", [Error]),
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
		       case gtp_context:find_sender_teid(Request) of
			   TEID when is_integer(TEID) ->
			       Response0#gtp{tei = TEID};
			   _ ->
			       Response0#gtp{tei = 0}
		       end
	       end,
    gtp_context:send_response(ReqKey, Response#gtp{seq_no = SeqNo}),
    {stop, normal, Data};

create_session_fail(ReqKey, Request, Error, State, Data) ->
    ct:fail("ReqKey: ~p~nRequest: ~p~nError: ~p~nState: ~p~nData: ~p~n",
	    [ReqKey, Request, Error, State, Data]),
    {next_state, shutdown, Data}.

create_session_fun(#gtp{ie = #{?'Access Point Name' := #v2_access_point_name{apn = APN}} = IEs} = Request,
		   State,
		   #{context := Context0, node_selection := NodeSelect,
		     left_tunnel := LeftTunnel, bearer := #{left := LeftBearer}} = Data) ->
    PeerUpNode =
	case IEs of
	    #{?'SGW-U node name' := #v2_fully_qualified_domain_name{fqdn = SGWuFQDN}} ->
		SGWuFQDN;
	    _ -> []
	end,
    Services = [{'x-3gpp-upf', 'x-sxb'}],

    %% async call, want to wait for the result later...
    {ok, UpSelInfo} =
	ergw_gtp_gsn_lib:connect_upf_candidates(APN, Services, NodeSelect, PeerUpNode),

    Context = pgw_s5s8:update_context_from_gtp_req(Request, Context0),

    DataNext = Data#{context => Context},
    gtp_context:next(
      pgw_s5s8:update_tunnel_from_gtp_req(Request, LeftTunnel, LeftBearer),
      update_tunnel_from_gtp_req_ok(Request, _, UpSelInfo, _, _),
      fun gtp_context:fail/3,
     State, DataNext).

update_tunnel_from_gtp_req_ok(
  #gtp{ie = #{?'Access Point Name' := #v2_access_point_name{apn = APN}} = IEs} = Request,
  {LeftTunnel0, LeftBearer}, UpSelInfo,
  State,
  #{context := Context, aaa_opts := AAAopts} = Data) ->

    LeftTunnel = gtp_path:bind(Request, LeftTunnel0),

    gtp_context:terminate_colliding_context(LeftTunnel, Context),

    SessionOpts0 = pgw_s5s8:init_session(IEs, LeftTunnel, Context, AAAopts),
    SessionOpts1 = pgw_s5s8:init_session_from_gtp_req(IEs, AAAopts, LeftTunnel, SessionOpts0),
    %% SessionOpts = init_session_qos(ReqQoSProfile, SessionOpts1),

    PAA = maps:get(?'PDN Address Allocation', IEs, undefined),
    DAF = proplists:get_bool('DAF', gtp_v2_c:get_indication_flags(IEs)),

    DataNext = Data#{left_tunnel => LeftTunnel},
    ergw_gtp_gsn_lib:create_session_n(
      APN, pgw_s5s8:pdn_alloc(PAA), DAF, UpSelInfo, SessionOpts1, LeftBearer, State, DataNext).
