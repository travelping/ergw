%% Copyright 2018, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_gtp_stateless).

-export([handle_message/2]).

-include_lib("gtplib/include/gtp_packet.hrl").
-include("include/ergw.hrl").

%%====================================================================
%% API
%%====================================================================

handle_message(Request, Msg) ->
    proc_lib:spawn(fun() -> q_handle_message(Request, Msg) end),
    ok.

try_handle_message(#request{gtp_port = GtpPort} = Request, Msg) ->
    case get_handler_if(GtpPort, Msg) of
	{ok, Interface, _} ->
	    case ergw:get_accept_new() of
		true -> ok;
		_ ->
		    throw({error, no_resources_available})
	    end,
	    Context = Interface:get_context(GtpPort),
	    Interface:handle_message(Context, Request, Msg);

	{error, _} = Error ->
	    throw(Error)
    end.

q_handle_message(Request, Msg0) ->
    Queue = load_class(Msg0),
    try
	jobs:run(
	  Queue,
	  fun() ->
		  Msg = gtp_packet:decode_ies(Msg0),
		  try_handle_message(Request, Msg)
	  end)
    catch
	throw:{error, Error} ->
	    lager:error("handler failed with: ~p", [Error]),
	    generic_error(Request, Msg0, Error);
	error:Error = rejected ->
	    lager:debug("handler failed with: ~p", [Error]),
	    generic_error(Request, Msg0, Error)
    end.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_handler_if(GtpPort, #gtp{version = v1} = Msg) ->
    gtp_v1_c:get_handler(GtpPort, Msg);
get_handler_if(GtpPort, #gtp{version = v2} = Msg) ->
    gtp_v2_c:get_handler(GtpPort, Msg).

load_class(#gtp{version = v1} = Msg) ->
    gtp_v1_c:load_class(Msg);
load_class(#gtp{version = v2} = Msg) ->
    gtp_v2_c:load_class(Msg).

generic_error(#request{gtp_port = GtpPort} = Request,
	      #gtp{version = Version, type = MsgType, seq_no = SeqNo}, Error) ->
    Handler = gtp_path:get_handler(GtpPort, Version),
    Reply = Handler:build_response({MsgType, 0, Error}),
    ergw_gtp_c_socket:send_response(Request, Reply#gtp{seq_no = SeqNo}, SeqNo /= 0).
