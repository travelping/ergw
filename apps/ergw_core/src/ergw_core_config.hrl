%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-define(is_opts(X), (is_list(X) orelse is_map(X))).
-define(is_non_empty_opts(X), ((is_list(X) andalso length(X) /= 0) orelse
			       (is_map(X) andalso map_size(X) /= 0))).

-define(IS_IP(X), (is_tuple(X) andalso (tuple_size(X) == 4 orelse tuple_size(X) == 8))).
-define(IS_IPv4(X), (is_tuple(X) andalso tuple_size(X) == 4)).
-define(IS_IPv6(X), (is_tuple(X) andalso tuple_size(X) == 8)).

-define(IS_binIPv4(X), (is_binary(X) andalso size(X) ==  4)).
-define(IS_binIPv6(X), (is_binary(X) andalso size(X) == 16)).
