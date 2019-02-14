%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_context).

-compile({no_auto_import, [apply/3]}).

%% API
-export([apply/3, sx_report/1, port_message/2, port_message/3, port_message/4]).

%%-type ctx_ref() :: {Handler :: atom(), Server :: pid()}.
-type seid() :: 0..16#ffffffffffffffff.

-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
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

sx_report(#pfcp{type = session_report_request, seid = SEID} = Report) ->
    apply({seid, SEID}, sx_report, [Report]).

port_message(Request, Msg) ->
    proc_lib:spawn(fun() -> port_message_h(Request, Msg) end),
    ok.

port_message(Keys, #request{gtp_port = GtpPort} = Request, Msg)
  when is_list(Keys) ->
    Contexts = gtp_context_reg:match_keys(GtpPort, Keys),
    port_message_ctx(Contexts, Request, Msg).

port_message(Key, Request, Msg, Resent) ->
    apply(Key, port_message, [Request, Msg, Resent]).

%%%=========================================================================
%%%  internal functions
%%%=========================================================================

apply(Key, F, A) ->
    case gtp_context_reg:lookup(Key) of
	{Handler, Server} when is_atom(Handler), is_pid(Server) ->
	    erlang:apply(Handler, F, [Server | A]);
	_Other ->
	    {error, not_found}
    end.

port_request_key(#request{key = ReqKey, gtp_port = GtpPort}) ->
    gtp_context:port_key(GtpPort, ReqKey).

%% TODO - MAYBE
%%  it might be benificial to first perform the lookup and then enqueue
%%
port_message_h(Request, #gtp{} = Msg) ->
    Queue = load_class(Msg),
    case jobs:ask(Queue) of
	{ok, Opaque} ->
	    try
		port_message_run(Request, Msg)
	    catch
		throw:{error, Error} ->
		    lager:error("handler failed with: ~p", [Error]),
		    gtp_context:generic_error(Request, Msg, Error)
	    after
		jobs:done(Opaque)
	    end;
	{error, Reason} ->
	    gtp_context:generic_error(Request, Msg, Reason)
    end.

port_message_run(Request, #gtp{type = g_pdu} = Msg) ->
    port_message_p(Request, Msg);
port_message_run(Request, Msg0) ->
    Msg = gtp_packet:decode_ies(Msg0),
    case port_message(port_request_key(Request), Request, Msg, true) of
	{error, not_found} ->
	    port_message_p(Request, Msg);
	Result ->
	    Result
    end.

port_message_p(#request{} = Request, #gtp{tei = 0} = Msg) ->
    gtp_context:port_message(Request, Msg);
port_message_p(#request{gtp_port = GtpPort} = Request, #gtp{tei = TEI} = Msg) ->
    case port_message(gtp_context:port_teid_key(GtpPort, TEI), Request, Msg, false) of
	{error, _} = Error ->
	    throw(Error);
	Result ->
	    Result
    end.

port_message_ctx([{Handler, Server} | _], Request, Msg)
  when is_atom(Handler), is_pid(Server) ->
    Handler:port_message(Server, Request, Msg, false);
port_message_ctx(_, _Request, _Msg) ->
    throw({error, not_found}).

load_class(#gtp{version = v1} = Msg) ->
    gtp_v1_c:load_class(Msg);
load_class(#gtp{version = v2} = Msg) ->
    gtp_v2_c:load_class(Msg).
