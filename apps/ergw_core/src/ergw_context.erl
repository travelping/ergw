%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_context).

%% API
-export([init_state/0, sx_report/1, port_message/2, port_message/3, port_message/4]).
-export([validate_options/2]).
-ifdef(TEST).
-export([test_cmd/3]).
-endif.

-if(?OTP_RELEASE =< 23).
-ignore_xref([behaviour_info/1]).
-endif.

%%-type ctx_ref() :: {Handler :: atom(), Server :: pid()}.
-type seid() :: 0..16#ffffffffffffffff.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include_lib("opentelemetry_api/include/otel_tracer.hrl").
-include("ergw_core_config.hrl").
-include("include/ergw.hrl").

%%%=========================================================================
%%%  API
%%%=========================================================================

-callback sx_report(Server :: pid(), PFCP :: #pfcp{}) ->
    {ok, SEID :: seid()} |
    {ok, SEID :: seid(), Cause :: atom()} |
    {ok, SEID :: seid(), ResponseIEs :: map()}.

-callback port_message(Request :: #request{}, Msg :: #gtp{}) -> ok.

-callback port_message(Server :: pid(), Request :: #request{},
		       Msg :: #gtp{}, Resent :: boolean()) -> ok.

%%% -----------------------------------------------------------------

%% init_state/0
init_state() ->
    #{session => init, async => #{}}.

sx_report(#pfcp{type = session_report_request, seid = SEID} = Report) ->
    apply2context(#seid_key{seid = SEID}, sx_report, [Report]).

%% port_message/2
port_message(Request, Msg) ->
    SpanCtx = ?current_span_ctx,
    proc_lib:spawn(fun() ->
			   ?set_current_span(SpanCtx),
			   port_message_h(Request, Msg)
		   end),
    ok.

%% port_message/3
port_message(Id, #request{socket = Socket} = Request, Msg) ->
    Key = gtp_context:context_key(Socket, Id),
    case gtp_context_reg:select(Key) of
	[{Handler, Server}] when is_atom(Handler), is_pid(Server) ->
	    Handler:port_message(Server, Request, Msg, false);
	_Other ->
	    ?LOG(debug, "no context found for key ~0p", [Key]),
	    throw({error, not_found})
    end.

%% port_message/4
port_message(Key, Request, Msg, Resent) ->
    gtp_path:activity(Request, Msg),
    apply2context(Key, port_message, [Request, Msg, Resent]).

-ifdef(TEST).

%% test_cmd/3
test_cmd(_Type, Key, is_alive = Cmd) ->
    apply2context(Key, ctx_test_cmd, [Cmd]) =:= true;
test_cmd(_Type, Key, Cmd) ->
    apply2context(Key, ctx_test_cmd, [Cmd]).

-endif.

%%%===================================================================
%%% Options Validation
%%%===================================================================

validate_options(_Name, #{handler := Handler} = Values)
  when is_atom(Handler) ->
    case code:ensure_loaded(Handler) of
	{module, _} ->
	    ok;
	_ ->
	    erlang:error(badarg, [handler, Values])
    end,
    Handler:validate_options(Values);
validate_options(Name, Values) when is_list(Values) ->
    validate_options(Name, ergw_core_config:to_map(Values));
validate_options(Name, Values) ->
    erlang:error(badarg, [Name, Values]).

%%%=========================================================================
%%%  internal functions
%%%=========================================================================

apply2context(Key, F, A) ->
    case gtp_context_reg:lookup(Key) of
	{Handler, Server} when is_atom(Handler), is_pid(Server) ->
	    apply(Handler, F, [Server | A]);
	_Other ->
	    ?LOG(debug, "no context registered with key ~0p", [Key]),
	    {error, not_found}
    end.

%% TODO - MAYBE
%%  it might be benificial to first perform the lookup and then enqueue
%%
port_message_h(Request, #gtp{} = Msg) ->
    Queue = load_class(Msg),
    case ?with_span(<<"queue">>, #{}, fun(_) -> jobs:ask(Queue) end) of
	{ok, Opaque} ->
	    try
		port_message_run(Request, Msg)
	    catch
		throw:{error, Error} ->
		    ?LOG(error, "handler failed with: ~p", [Error]),
		    gtp_context:generic_error(Request, Msg, Error)
	    after
		jobs:done(Opaque)
	    end;
	{error, Reason} ->
	    gtp_context:generic_error(Request, Msg, Reason)
    end.

port_message_run(Request, #gtp{type = g_pdu} = Msg) ->
    port_message_p(Request, Msg);
port_message_run(#request{key = ReqKey} = Request, Msg0) ->
    Msg = gtp_packet:decode_ies(Msg0),
    case port_message(ReqKey, Request, Msg, true) of
	{error, not_found} ->
	    port_message_p(Request, Msg);
	Result ->
	    Result
    end.

port_message_p(#request{} = Request, #gtp{tei = 0} = Msg) ->
    gtp_context:port_message(Request, Msg);
port_message_p(#request{socket = Socket} = Request, #gtp{tei = TEI} = Msg) ->
    case port_message(gtp_context:socket_teid_key(Socket, TEI), Request, Msg, false) of
	{error, _} = Error ->
	    throw(Error);
	Result ->
	    Result
    end.

load_class(#gtp{version = v1} = Msg) ->
    gtp_v1_c:load_class(Msg);
load_class(#gtp{version = v2} = Msg) ->
    gtp_v2_c:load_class(Msg).
