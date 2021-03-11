%% Copyright 2021, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU General Public License
%% as published by the Free Software Foundation; either version
%% 2 of the License, or (at your option) any later version.

-define(match_dist_metric(Type, Name, LabelValues, Cond, Expected),
	ergw_dist_test_lib:match_dist_metric(
	  Type, Name, LabelValues, Cond, Expected, ?FILE, ?LINE, 10, Config)).
