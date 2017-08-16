%% Copyright 2016, Travelping GmbH <info@travelping.com>

%% This program is free software; you can redistribute it and/or
%% modify it under the terms of the GNU Lesser General Public License
%% as published by the Free Software Foundation; either version
%% 3 of the License, or (at your option) any later version.

-record(qos, {delay_class,
	      reliability_class,
	      peak_throughput,
	      precedence_class,
	      mean_throughput,
	      traffic_class,
	      delivery_order,
	      delivery_of_erroneorous_sdu,
	      max_sdu_size,
	      max_bit_rate_uplink,
	      max_bit_rate_downlink,
	      residual_ber,
	      sdu_error_ratio,
	      transfer_delay,
	      traffic_handling_priority,
	      guaranteed_bit_rate_uplink,
	      guaranteed_bit_rate_downlink,
	      signaling_indication,
	      source_statistics_descriptor
	    }).
