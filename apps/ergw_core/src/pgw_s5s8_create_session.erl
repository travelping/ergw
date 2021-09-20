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
-include_lib("opentelemetry_api/include/otel_tracer.hrl").
-include("include/ergw.hrl").

-include("pgw_s5s8.hrl").

%%====================================================================
%% Impl.
%%====================================================================

%% otel_context_attrs(#{context :=
%% 			 #context{imsi = IMSI, imei = IMEI, msisdn = MSISDN, apn = APN}}) ->
%%     Attr = [{'gtp.imsi', IMSI}, {'gtp.imei', IMEI}, {'gtp.msisdn', MSISDN}, {'gtp.apn', APN}],
%%     ct:pal("Attr: ~p~n", [Attr]),
%%     lists:filter(fun({_, V}) -> V /= undefined end, Attr);
%% otel_context_attrs(_) ->
%%     [].

otel_request_attrs(#gtp{ie =
			    #{?IMSI :=
				  #v2_international_mobile_subscriber_identity{imsi = IMSI}}
		       }) ->
    [{'gtp.imsi', IMSI}];
otel_request_attrs(_) ->
    [].

create_session(ReqKey, Request, _Resent, State, Data) ->
    SOpts = #{remote_parent_not_sampled => {ergw_otel_gtp_sampler, #{}},
	      local_parent_not_sampled => {ergw_otel_gtp_sampler, #{}},
	      root => {ergw_otel_gtp_sampler, #{}}},
    Sampler = otel_sampler:new({parent_based, SOpts}),
    Attrs = otel_request_attrs(Request),
    SpanCtx = ?start_span(?FUNCTION_OTEL_EVENT, #{sampler => Sampler, attributes => Attrs}),
    ergw_context_statem:next(
      SpanCtx,
      create_session_fun(Request, _, _),
      create_session_ok(ReqKey, Request, _, _, _),
      create_session_fail(ReqKey, Request, _, _, _),
      State, Data).

create_session_ok(ReqKey,
		 #gtp{ie = #{?'Bearer Contexts to be created' :=
				 #v2_bearer_context{group = #{?'EPS Bearer ID' := EBI}}
			    } = IEs} = Request,
		 {Cause, SessionOpts},
		 State, #{context := Context, left_tunnel := LeftTunnel,
			   bearer := Bearer} = Data) ->
    ?add_event(?FUNCTION_OTEL_EVENT,
	       [{cause, Cause},
		{sessionOpts, SessionOpts},
		{ies, IEs},
		{ebi, EBI},
		{leftTunnel, LeftTunnel},
		{bearer, Bearer},
		{context, Context}]),

    ResponseIEs = pgw_s5s8:create_session_response(Cause, SessionOpts, IEs, EBI, LeftTunnel, Bearer, Context),
    Response = pgw_s5s8:response(create_session_response, LeftTunnel, ResponseIEs, Request),
    gtp_context:send_response(ReqKey, Request, Response),

    Actions = pgw_s5s8:context_idle_action([], Context),
    {next_state, State#{session := connected}, Data, Actions}.

create_session_fail(ReqKey, #gtp{type = MsgType, seq_no = SeqNo} = Request,
		    #ctx_err{reply = Reply} = Error,
		    _State, #{left_tunnel := Tunnel} = Data) ->
    ?add_event(?FUNCTION_OTEL_EVENT, [{error, Error}]),

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
    ?add_event(?FUNCTION_OTEL_EVENT, [{error, Error}]),

    ct:fail(#{'ReqKey' => ReqKey, 'Request' => Request, 'Error' => Error, 'State' => State, 'Data' => Data}),
    {next_state, State#{session := shutdown}, Data}.

create_session_fun(#gtp{ie = #{?'Access Point Name' := #v2_access_point_name{apn = APN}} = IEs} = Request,
		   State, Data) ->
    statem_m:run(
      do([statem_m ||
	     _ = ?add_event(?FUNCTION_OTEL_EVENT, []),

	     NodeSelect <- statem_m:get_data(maps:get(node_selection, _)),
	     PeerUpNode =
		 case IEs of
		     #{?'SGW-U node name' := #v2_fully_qualified_domain_name{fqdn = SGWuFQDN}} ->
			 SGWuFQDN;
		     _ -> []
		 end,
	     Services = [{'x-3gpp-upf', 'x-sxb'}],

	     %% async call, want to wait for the result later...
	     UpSelInfo <-
		 statem_m:lift(ergw_gtp_gsn_lib:connect_upf_candidates(APN, Services, NodeSelect, PeerUpNode)),
	     ergw_gtp_gsn_lib:update_context_from_gtp_req(pgw_s5s8, context, Request),
	     ergw_gtp_gsn_lib:update_tunnel_from_gtp_req(pgw_s5s8, v2, left, Request),
	     ergw_gtp_gsn_lib:bind_tunnel(left),
	     ergw_gtp_gsn_lib:terminate_colliding_context(),
	     SessionOpts <- ergw_gtp_gsn_lib:init_session(pgw_s5s8, IEs),

	     PAA = maps:get(?'PDN Address Allocation', IEs, undefined),
	     DAF = proplists:get_bool('DAF', gtp_v2_c:get_indication_flags(IEs)),

	     ergw_gtp_gsn_lib:create_session_m(
	       APN, pgw_s5s8:pdn_alloc(PAA), DAF, UpSelInfo, SessionOpts)
	 ]), State, Data).
