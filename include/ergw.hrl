%% Copyright 2015, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-define(GTP0_PORT,	3386).
-define(GTP1c_PORT,	2123).
-define(GTP1u_PORT,	2152).
-define(GTP2c_PORT,	2123).

-record(gtp_port, {pid             :: pid(),
		   restart_counter :: integer(),
		   ip              :: inet:ip_address()
		  }).
