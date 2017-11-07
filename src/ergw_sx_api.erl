%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-module(ergw_sx_api).

-include("include/ergw.hrl").

-callback validate_options(list() | map()) ->
    Return :: list() | map().

-callback start_link(Args :: term()) ->
    Return :: {ok, Pid :: pid()} |
	      ignore |
	      {error, Error :: term()}.

-callback send(GtpPort :: #gtp_port{},
	       IP :: inet:ip_address(),
	       Port :: inet:port_number(),
	       Data :: binary()) ->
    Return :: term().

-callback get_id(GtpPort :: #gtp_port{}) ->
    Return :: term().

-callback call(Context :: #context{},
	       Request :: atom(),
	       IEs :: map()) ->
    Return :: term().
