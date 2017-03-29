%% Copyright 2017, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-ifndef(ERGW_GGSN_NO_IMPORTS).

-import('ergw_ggsn_test_lib', [make_echo_request/1,
			       create_pdp_context/1, create_pdp_context/2,
			       make_create_pdp_context_request/1,
			       validate_create_pdp_context_response/2,
			       delete_pdp_context/2,
			       make_delete_pdp_context_request/1,
			       validate_delete_pdp_context_response/2]).

-endif.
