%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_context).

%% API
-export([init_state/0, init_state/1,
	 port_message/2, port_message/3, port_message/4,
	 sx_report/1, pfcp_timer/3, pfcp_down/2,
	 create_context_record/3,
	 put_context_record/3,
	 get_context_record/1,
	 delete_context_record/1]).
-export([validate_options/2]).
-ifdef(TEST).
-export([test_cmd/3]).
-endif.

-ignore_xref([pfcp_timer/3]).

-if(?OTP_RELEASE =< 23).
-ignore_xref([behaviour_info/1]).
-endif.

%%-type ctx_ref() :: {Handler :: atom(), Server :: pid()}.
-type seid() :: 0..16#ffffffffffffffff.

-include_lib("kernel/include/logger.hrl").
-include_lib("gtplib/include/gtp_packet.hrl").
-include_lib("pfcplib/include/pfcp_packet.hrl").
-include("ergw_core_config.hrl").
-include("include/ergw.hrl").

%%%=========================================================================
%%%  API
%%%=========================================================================

-callback ctx_sx_report(Server :: pid(), PFCP :: #pfcp{}) ->
    {ok, SEID :: seid()} |
    {ok, SEID :: seid(), Cause :: atom()} |
    {ok, SEID :: seid(), ResponseIEs :: map()}.

-callback port_message(Request :: #request{}, Msg :: #gtp{}) -> ok.

-callback ctx_port_message(RecordId :: binary(), Request :: #request{},
			   Msg :: #gtp{}, Resent :: boolean()) -> ok.

-callback ctx_pfcp_timer(RecordIdOrPid :: term(), Time :: integer(), Evs :: list()) ->
    Response :: term().

-callback ctx_pfcp_down(RecordIdOrPid :: term(), SxNode :: pid()) ->
    Response :: term().

%%% -----------------------------------------------------------------

%% init_state/0
init_state() ->
    init_state(init).

%% init_state/1
init_state(SState) ->
    #{session => SState, async => #{}, fsm => init}.

sx_report(#pfcp{type = session_report_request, seid = SEID} = Report) ->
    with_context([#seid_key{seid = SEID}], ctx_sx_report, [Report]).

%% port_message/2
port_message(Request, Msg) ->
    proc_lib:spawn(fun() -> port_message_h(Request, Msg) end),
    ok.

%% port_message/3
port_message(Id, #request{socket = Socket} = Request, Msg) ->
    Key = gtp_context:context_key(Socket, Id),
    with_context([Key], ctx_port_message, [Request, Msg, false]).

%% port_message/4
port_message(Key, Request, Msg, Resent) ->
    with_context([Key], ctx_port_message, [Request, Msg, Resent]).

pfcp_timer(Id, Time, Evs) ->
    with_context([Id], ctx_pfcp_timer, [Time, Evs]).

pfcp_down(Id, SxNode) ->
    with_context([Id], ctx_pfcp_down, [SxNode]).

%%%===================================================================
%%% Nudsf support
%%%===================================================================

create_context_record(State, Meta, #{record_id := RecordId} = Data) ->
    Serialized = serialize_block(#{state => State, data => Data}),
    ergw_nudsf:create(RecordId, Meta, #{<<"context">> => Serialized}).

put_context_record(State, Meta, #{record_id := RecordId} = Data) ->
    Serialized = serialize_block(#{state => State, data => Data}),
    ergw_nudsf:put(record, RecordId, Meta, #{<<"context">> => Serialized}).

get_context_record(RecordId) ->
    case ergw_nudsf:get(block, RecordId, <<"context">>) of
	{ok, BlockBin} ->
	    case  deserialize_block(BlockBin) of
		#{state := State, data := Data} ->
		    {ok, State, Data};
		_ ->
		    {error, not_found}
	    end;
	_ ->
	    {error, not_found}
    end.

delete_context_record(#{record_id := RecordId}) ->
    ergw_nudsf:delete(record, RecordId);
delete_context_record(_Data) ->
    {error, not_found}.

serialize_block(Data) ->
    term_to_binary(Data, [{minor_version, 2}, compressed]).

deserialize_block(Data) ->
    binary_to_term(Data, [safe]).

-ifdef(TEST).

%% test_cmd/3
test_cmd(_Type, Key, is_alive = Cmd) ->
    with_context([Key], ctx_test_cmd, [Cmd]) =:= true;
test_cmd(_Type, Key, Cmd) ->
    with_context([Key], ctx_test_cmd, [Cmd]).

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

select_context([]) ->
    not_found;
select_context([H|T]) ->
    case gtp_context_reg:select(H) of
	[{Handler, Pid} = R|_] when is_atom(Handler), is_pid(Pid) ->
	    R;
	_ ->
	    select_context(T)
    end.

with_handler_context(M, F, Pid, A) ->
    ?LOG(debug, "~s: ~p:~p", [?FUNCTION_NAME, M, F]),
    case apply(M, F, [Pid] ++ A) of
	{reply, Reply} ->
	    Reply;
	timeout ->
	    {error, timeout};
	{error, {_Reason, _}} ->
	    {error, not_found};
	{'EXIT', normal} ->
	    {error, not_found};
	Other ->
	    Other
    end.

with_external_context(RecordId, F, A) ->
    case ergw_context_statem:call(RecordId, handler) of
	{ok, {Handler, Pid}} ->
	    with_handler_context(Handler, F, Pid, A);
	Other ->
	    Other
    end.

with_local_context(Keys, F, A) ->
    ?LOG(debug, "~s #: ~p~nAll: ~p~n", [?FUNCTION_NAME, Keys, gtp_context_reg:all()]),
    case select_context(Keys) of
	{Handler, Pid} ->
	    with_handler_context(Handler, F, Pid, A);
	_ ->
	    ?LOG(debug, "unable to find context in cache ~p", [Keys]),
	    {error, not_found}
    end.

with_context([RecordId] = Keys, F, A) when is_binary(RecordId) ->
    case with_local_context(Keys, F, A) of
	{error, not_found} ->
	    with_external_context(RecordId, F, A);
	Other ->
	    Other
    end;
with_context(Keys, F, A) ->
    case with_local_context(Keys, F, A) of
	{error, not_found} ->
	    ?LOG(debug, "unable to find context in cache ~p", [Keys]),
	    case gtp_context_reg:search(Keys) of
		[RecordId] ->
		    with_external_context(RecordId, F, A);
		OtherSrch ->
		    ?LOG(debug, "unable to find context ~p -> ~p", [Keys, OtherSrch]),
		    {error, not_found}
	    end;
	Other ->
	    Other
    end.

%% TODO - MAYBE
%%  it might be benificial to first perform the lookup and then enqueue
%%
port_message_h(Request, #gtp{} = Msg) ->
    Queue = load_class(Msg),
    case jobs:ask(Queue) of
	{ok, Opaque} ->
	    try port_message_run(Request, Msg) of
		{error, PortError} ->
		    ?LOG(error, "handler failed with: ~p", [PortError]),
		    gtp_context:generic_error(Request, Msg, PortError);
		_ ->
		    ok
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
    %% check if this request is already pending
    Msg = gtp_packet:decode_ies(Msg0),
    gtp_path:activity(Request, Msg),
    case gtp_context_reg:lookup(ReqKey) of
	undefined ->
	    ?LOG(debug, "NO DUPLICATE REQEST"),
	    port_message_p(Request, Msg);
	{Handler, Pid} when is_atom(Handler), is_pid(Pid) ->
	    with_handler_context(Handler, ctx_port_message, Pid, [Request, Msg, true]);
	_Other ->
	    %% TBD.....
	    ?LOG(warning, "DUPLICATE REQUEST: ~p", [_Other]),
	    ok
    end.

port_message_p(#request{} = Request, #gtp{tei = 0} = Msg) ->
    gtp_context:port_message(Request, Msg);
port_message_p(#request{socket = Socket} = Request, #gtp{tei = TEI} = Msg) ->
    Key = gtp_context:socket_teid_key(Socket, TEI),
    with_context([Key], ctx_port_message, [Request, Msg, false]).

load_class(#gtp{version = v1} = Msg) ->
    gtp_v1_c:load_class(Msg);
load_class(#gtp{version = v2} = Msg) ->
    gtp_v2_c:load_class(Msg).

%%====================================================================
%% context queries
%%====================================================================

-if(0).

filter([Key]) ->
    filter(Key);
filter(Keys) when is_list(Keys) ->
    #{'cond' => 'OR', 'units' => lists:map(fun filter/1, Keys)};
filter(#socket_teid_key{name = Name, type = Type, teid = TEID}) ->
    #{'cond' => 'AND',
      units =>
	  [
	   #{tag => type, value => Type},
	   #{tag => socket, value => Name},
	   #{tag => local_control_tei, value => TEID}
	  ]};
filter(#context_key{socket = Name, id = Key}) ->
    #{'cond' => 'AND',
      units =>
	  [
	   #{tag => socket, value => Name},
	   #{tag => context_id, value => Key}
	  ]};
filter(#seid_key{seid = SEID}) ->
    #{tag => seid, value => SEID}.

-endif.
