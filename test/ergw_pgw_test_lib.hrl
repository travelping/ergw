%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-ifndef(ERGW_PGW_NO_IMPORTS).

-import('ergw_pgw_test_lib', [make_echo_request/1,
			      create_session/1, create_session/2,
			      make_create_session_request/1,
			      validate_create_session_response/2,
			      delete_session/2,
			      make_delete_session_request/1,
			      validate_delete_session_response/2]).

-endif.

-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).
