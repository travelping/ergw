-module(gtp_context).

-compile({parse_transform, do}).

-export([lookup/1, new/6, handle_message/4, start_link/6]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("gtplib/include/gtp_packet.hrl").

%%====================================================================
%% API
%%====================================================================

lookup(TEI) ->
    gtp_context_reg:lookup(TEI).

new(Type, IP, Port, Handler, LocalIP,
    #gtp{version = Version, ie = IEs} = Msg) ->
    Protocol = get_protocol(Type, Version),
    do([error_m ||
	   Interface <- get_interface_type(Version, IEs),
	   Context <- gtp_context_sup:new(Type, Handler, LocalIP, Protocol, Interface, []),
	   handle_message(Context, IP, Port, Msg)
       ]).

handle_message(Context, IP, Port, Msg) ->
    gen_server:cast(Context, {handle_message, IP, Port, Msg}).

start_link(Type, Handler, LocalIP, Protocol, Interface, Opts) ->
    gen_server:start_link(?MODULE, [Type, Handler, LocalIP, Protocol, Interface], Opts).

%%====================================================================
%% gen_server API
%%====================================================================

init([Type, Handler, LocalIP, Protocol, Interface]) ->
    {ok, TEI} = gtp_c_lib:alloc_tei(),

    State = #{
      type      => Type,
      handler   => Handler,
      protocol  => Protocol,
      interface => Interface,
      tei       => TEI,
      local_ip  => LocalIP},
    {ok, State}.

handle_call(Request, _From, State) ->
    lager:warning("handle_call: ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast({handle_message, IP, Port, #gtp{type = Type} = Msg}, State) ->
    lager:debug("~w: handle gtp: ~w, ~p",
		[?MODULE, Port, gtp_c_lib:fmt_gtp(Msg)]),
    case gtp_msg_type(Type, State) of
	response -> handle_response(Msg, State);
	_        -> handle_request(IP, Port, Msg, State)
    end;

handle_cast(Msg, State) ->
    lager:error("~w: handle_cast: ~p", [?MODULE, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(Info, State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Message Handling functions
%%%===================================================================

handle_request(IP, Port, #gtp{version = Version, seq_no = SeqNo} = Msg, State0) ->
    lager:debug("GTP~s ~s:~w: ~p",
		[Version, inet:ntoa(IP), Port, gtp_c_lib:fmt_gtp(Msg)]),

    try interface_handle_request(Msg, State0) of
	{reply, Reply, State1} ->
	    Response = build_response(Reply, State1),
	    send_message(IP, Port, Response#gtp{seq_no = SeqNo}, State1),
	    {noreply, State1};

	{stop, Reply, State1} ->
	    Response = build_response(Reply, State1),
	    send_message(IP, Port, Response#gtp{seq_no = SeqNo}, State1),
	    {stop, normal, State1};

	{error, Reply} ->
	    Response = build_response(Reply, State0),
	    send_message(IP, Port, Response#gtp{seq_no = SeqNo}, State0),
	    {noreply, State0};

	{noreply, State1} ->
	    {noreply, State1};

	Other ->
	    lager:error("handle_request failed with: ~p", [Other]),
	    {noreply, State0}
    catch
	Class:Error ->
	    Stack  = erlang:get_stacktrace(),
	    lager:error("GTP~p failed with: ~p:~p (~p)", [Version, Class, Error, Stack]),
	    {noreply, State0}
    end.

handle_response(Msg, #{path := Path} = State) ->
    gtp_path:handle_response(Path, Msg),
    {noreply, State}.

send_message(IP, Port, Msg, #{type := Type, handler := Handler} = State) ->
    %% TODO: handle encode errors
    try
        Data = gtp_packet:encode(Msg),
	lager:debug("gtp_path send ~s to ~w:~w: ~p, ~p", [Type, IP, Port, Msg, Data]),
	gtp:send(Handler, Type, IP, Port, Data)
    catch
	Class:Error ->
	    lager:error("gtp_path send failed with ~p:~p", [Class, Error])
    end,
    State.

%%%===================================================================
%%% Internal functions
%%%===================================================================

get_protocol('gtp-u', v1) ->
    gtp_v1_u;
get_protocol('gtp-c', v1) ->
    gtp_v1_c;
get_protocol('gtp-c', v2) ->
    gtp_v2_c.

get_interface_type(v1, _) ->
    {ok, ggsn_gn};
get_interface_type(v2, _IEs) ->
    {ok, pgw_s2a};
get_interface_type(v2, _IEs) ->
    {ok, pgw_s5s8}.

apply_mod(Key, F, A, State) ->
    M = maps:get(Key, State),
    apply(M, F, A).

gtp_msg_type(Type, State) ->
    apply_mod(protocol, gtp_msg_type, [Type], State).

interface_handle_request(Msg, State) ->
    apply_mod(interface, handle_request, [Msg, State], State).

build_response(Reply, State) ->
    apply_mod(protocol, build_response, [Reply], State).
