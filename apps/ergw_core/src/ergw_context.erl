%% Copyright 2019, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_context).

%% API
-export([init_state/0, init_state/1,
	 port_message/2, port_message/3, port_message/4,
	 sx_report/1, pfcp_timer/3,
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

%%% -----------------------------------------------------------------

%% init_state/0
init_state() ->
    init_state(init).

%% init_state/1
init_state(SState) ->
    #{session => SState, fsm => init}.

%% TBD: use some kind of register?
handler(sx) -> ergw_sx_node;
handler(gtp) -> gtp_context;
handler(tdf) -> tdf.

sx_report(#pfcp{type = session_report_request, seid = SEID} = Report) ->
    apply2context(sx, [#seid_key{seid = SEID}], ctx_sx_report, [Report]).

%% port_message/2
port_message(Request, Msg) ->
    proc_lib:spawn(fun() -> port_message_h(Request, Msg) end),
    ok.

-if(OLD).
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
-endif.

%% port_message/3
port_message(Id, #request{socket = Socket} = Request, Msg) ->
    Key = gtp_context:context_key(Socket, Id),
    apply2context(gtp, [Key], ctx_port_message, [Request, Msg, false]).

%% port_message/4
port_message(Key, Request, Msg, Resent) ->
    apply2context(gtp, [Key], ctx_port_message, [Request, Msg, Resent]).

pfcp_timer(Id, Time, Evs) ->
    apply2context(gtp, [Id], ctx_pfcp_timer, [Time, Evs]).

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
test_cmd(Type, Key, is_alive = Cmd) ->
    apply2context(Type, [Key], ctx_test_cmd, [Cmd]) =:= true;
test_cmd(Type, Key, Cmd) ->
    apply2context(Type, [Key], ctx_test_cmd, [Cmd]).

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

-if(OLD).
apply2context(Key, F, A) ->
    case gtp_context_reg:lookup(Key) of
	{Handler, Server} when is_atom(Handler), is_pid(Server) ->
	    apply(Handler, F, [Server | A]);
	_Other ->
	    ?LOG(debug, "no context registered with key ~0p", [Key]),
	    {error, not_found}
    end.
-endif.

select_context([]) ->
    not_found;
select_context([H|T]) ->
    case gtp_context_reg:select(H) of
	[{Handler, Pid} = R|_] when is_atom(Handler), is_pid(Pid) ->
	    R;
	_ ->
	    select_context(T)
    end.

apply2handler(M, F, A) ->
    case apply(M, F, A) of
	{reply, Reply} ->
	    Reply;
	timeout ->
	    {error, timeout};
	{error, {_Reason, _}} ->
	    {error, not_found};
	Other ->
	    Other
    end.

apply2local(_Type, Keys, F, A) ->
    case select_context(Keys) of
	{Handler, Pid} ->
	    apply2handler(Handler, F, [Pid] ++ A);
	_ ->
	    ?LOG(debug, "unable to find context in cache ~p", [Keys]),
	    {error, not_found}
    end.

apply2context(Type, Keys, F, A) ->
    case apply2local(Type, Keys, F, A) of
	{error, not_found} ->
	    ?LOG(debug, "unable to find context in cache ~p", [Keys]),
	    Filter = filter(Keys),
	    case ergw_nudsf:search(Filter) of
		{1, [RecordId]} ->
		    apply2handler(handler(Type), F, [RecordId] ++ A);
		OtherNudsf ->
		    ?LOG(debug, "unable to find context ~p -> ~p", [Filter, OtherNudsf]),
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
	    apply2handler(Handler, ctx_port_message, [Pid, Request, Msg, true]);
	_Other ->
	    %% TBD.....
	    ct:pal("DUPLICATE REQUEST: ~p", [_Other]),
	    ok
    end.

port_message_p(#request{} = Request, #gtp{tei = 0} = Msg) ->
    gtp_context:port_message(Request, Msg);
port_message_p(#request{socket = Socket} = Request, #gtp{tei = TEI} = Msg) ->
    Key = gtp_context:socket_teid_key(Socket, TEI),
    apply2context(gtp, [Key], ctx_port_message, [Request, Msg, false]).

load_class(#gtp{version = v1} = Msg) ->
    gtp_v1_c:load_class(Msg);
load_class(#gtp{version = v2} = Msg) ->
    gtp_v2_c:load_class(Msg).

%%====================================================================
%% context queries
%%====================================================================

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
