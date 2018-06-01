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

-define(VENDOR_ID_3GPP, 10415).

%%
%% DIAMETER 3GPP Experimental-Result-Code
%%
-define(DIAMETER_PCC_BEARER_EVENT, 4141).
-define(DIAMETER_BEARER_EVENT, 4142).
-define(DIAMETER_AN_GW_FAILED, 4143).
-define(DIAMETER_PENDING_TRANSACTION, 4144).
-define(DIAMETER_USER_UNKNOWN, 5030).
-define(DIAMETER_ERROR_INITIAL_PARAMETERS, 5140).
-define(DIAMETER_ERROR_TRIGGER_EVENT, 5141).
-define(DIAMETER_PCC_RULE_EVENT, 5142).
-define(DIAMETER_ERROR_BEARER_NOT_AUTHORIZED, 5143).
-define(DIAMETER_ERROR_TRAFFIC_MAPPING_INFO_REJECTED, 5144).
-define(DIAMETER_QOS_RULE_EVENT, 5145).
-define(DIAMETER_ERROR_CONFLICTING_REQUEST, 5147).
-define(DIAMETER_ADC_RULE_EVENT, 5148).
-define(DIAMETER_ERROR_NBIFOM_NOT_AUTHORIZED, 5149).
-define(DIAMETER_ERROR_LATE_OVERLAPPING_REQUEST, 5453).
-define(DIAMETER_ERROR_TIMED_OUT_REQUEST, 5454).
