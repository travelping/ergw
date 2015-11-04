%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(gtp_path).

-behaviour(gen_server).

%% API
-export([start_link/6, get/2,
	 handle_response/2,
	 send_request/4]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

-include_lib("gtplib/include/gtp_packet.hrl").

%%%===================================================================
%%% API
%%%===================================================================

start_link(Type, IP, Handler, LocalIP, Args, Opts) ->
    gen_server:start_link(?MODULE, {Type, IP, Handler, LocalIP, Args}, Opts).

get(Type, IP) ->
    gtp_path_reg:lookup({Type, IP}).

%%%===================================================================
%%% Protocol Module API
%%%===================================================================

send_request(Port, #gtp{} = Msg, Fun,
	     #{t3 := T3, n3 := N3, seq_no := SeqNo} = State)
  when is_function(Fun, 2) ->
    send_message_timeout(SeqNo, T3, N3, Port,
			 Msg#gtp{seq_no = SeqNo}, Fun, State#{seq_no := SeqNo + 1}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================
init({Type, IP, Handler, LocalIP, Args}) ->
    gtp_path_reg:register({Type, IP}),

    State = #{type     => Type,
	      ip       => IP,
	      handler  => Handler,
	      local_ip => LocalIP,
	      t3       => proplists:get_value(t3, Args, 10 * 1000), %% 10sec
	      n3       => proplists:get_value(n3, Args, 5),
	      seq_no   => 0,
	      pending  => gb_trees:empty(),
	      tunnel_endpoints => gb_trees:empty()},

    lager:debug("State: ~p", [State]),
    {ok, State}.

handle_call(Request, _From, State) ->
    lager:warning("handle_call: ~p", [lager:pr(Request, ?MODULE)]),
    {reply, ok, State}.

handle_cast(Msg, State) ->
    lager:debug("~w: handle_cast: ~p", [?MODULE, lager:pr(Msg, ?MODULE)]),
    {noreply, State}.

handle_info(Info = {timeout, TRef, {send, SeqNo}}, #{pending := Pending0} = State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    case gb_trees:lookup(SeqNo, Pending0) of
	{value, {_T3, _N3 = 0,_Port, Msg, _Fun, TRef}} ->
	    %% TODO: handle path failure....
	    lager:error("gtp_path: message resent expired", [Msg]),
	    Pending1 = gb_trees:delete(SeqNo, Pending0),
	    {noreply, State#{pending => Pending1}};

	{value, {T3, N3, Port, Msg, Fun, TRef}} ->
	    %% resent....
	    Pending1 = gb_trees:delete(SeqNo, Pending0),
	    NewState = send_message_timeout(SeqNo, T3, N3 - 1, Port, Msg, Fun, State#{pending => Pending1}),
	    {noreply, NewState}
    end;
handle_info(Info, State) ->
    lager:debug("handle_info: ~p", [lager:pr(Info, ?MODULE)]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

%% TODO: handle error responses
handle_response(Msg = #gtp{seq_no = SeqNo},
		#{pending := Pending0} = State) ->
    case gb_trees:lookup(SeqNo, Pending0) of
	none -> %% duplicate, drop silently
	    State;
	{value, {_T3, _N3, _Port, _ReqMsg, Fun, TRef}} ->
	    cancel_timer(TRef),
	    Pending1 = gb_trees:delete(SeqNo, Pending0),
	    Fun(Msg, State#{pending := Pending1})
    end.

final_send_message(Handler, Type, IP, Port, Msg) ->
    %% TODO: handle encode errors
    try
        Data = gtp_packet:encode(Msg),
	lager:debug("gtp_path send ~s to ~w:~w: ~p, ~p", [Type, IP, Port, Msg, Data]),
	gtp:send(Handler, Type, IP, Port, Data)
    catch
	Class:Error ->
	    lager:error("gtp_path send failed with ~p:~p", [Class, Error])
    end.

final_send_message(Port, Msg, #{type := Type, ip := IP, handler := Handler} = State) ->
    final_send_message(Handler, Type, IP, Port, Msg),
    State.

send_message_timeout(SeqNo, T3, N3, Port, Msg, Fun, #{pending := Pending0} = State) ->
    TRef = erlang:start_timer(T3, self(), {send, SeqNo}),
    Pending1 = gb_trees:insert(SeqNo, {T3, N3, Port, Msg, Fun, TRef}, Pending0),
    final_send_message(Port, Msg, State#{pending := Pending1}).

cancel_timer(Ref) ->
    case erlang:cancel_timer(Ref) of
        false ->
            receive {timeout, Ref, _} -> 0
            after 0 -> false
            end;
        RemainingTime ->
            RemainingTime
    end.

