-record(proxy_info, {
	  context      :: binary(),
	  apn          :: [binary()],
	  ggsn         :: inet:ip_address(),
	  imsi         :: binary(),
	  msisdn       :: binary(),
	  restrictions :: [{'v1', boolean()} |
			   {'v2', boolean()}]
	 }).
