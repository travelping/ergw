%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-ifndef(ERGW_GGSN_NO_IMPORTS).

-import('smc_ggsn_test_lib', [make_request/3, make_response/3, validate_response/4,
			       create_pdp_context/1, create_pdp_context/2,
			       update_pdp_context/2,
			       ms_info_change_notification/2,
			       delete_pdp_context/1, delete_pdp_context/2]).

-endif.
