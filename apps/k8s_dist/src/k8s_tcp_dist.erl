%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(k8s_tcp_dist).

-export([listen/1, accept/1, accept_connection/5,
	 setup/5, close/1, select/1, address/0]).

-ignore_xref([?MODULE]).

%% short cut select/1. The original version uses inet:getaddr/2,
%% but that doesn't work on k8s clusters out of the box.
select(_) ->
    true.

address() ->
    inet_tcp_dist:address().

listen(Name) ->
    inet_tcp_dist:listen(Name).

accept(Listen) ->
    inet_tcp_dist:accept(Listen).

accept_connection(AcceptPid, Socket, MyNode, Allowed, SetupTime) ->
    inet_tcp_dist:accept_connection(AcceptPid, Socket, MyNode, Allowed, SetupTime).

setup(Node, Type, MyNode, LongOrShortNames,SetupTime) ->
    inet_tcp_dist:setup(Node, Type, MyNode, LongOrShortNames, SetupTime).

close(Socket) ->
    inet_tcp_dist:close(Socket).
