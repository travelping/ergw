%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-ifndef(ERGW_PGW_NO_IMPORTS).

-import('ergw_pgw_test_lib', [make_request/3, make_response/3, validate_response/4,
			      create_session/1, create_session/2, create_session/3,
			      delete_session/2, delete_session/3,
			      modify_bearer/3,
			      modify_bearer_command/3,
			      change_notification/3,
			      suspend_notification/3,
			      resume_notification/3]).

-endif.

-define('S5/S8-U SGW',  4).
-define('S5/S8-U PGW',  5).
-define('S5/S8-C SGW',  6).
-define('S5/S8-C PGW',  7).
-define('S11-C MME',    10).
-define('S11/S4-C SGW', 11).
