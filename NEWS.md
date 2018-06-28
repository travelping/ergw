erGW - 3GPP GGSN and PDN-GW in Erlang
=====================================

Version 1.18.1 - 28 Jun 2018
----------------------------

* Add missing jsx dependency to .app file

Version 1.18.0 - 01 Jun 2018
----------------------------

* Rework DNS resolver to traverse records manually
* Add redirector mode for GTP socket

Version 1.17.0 - 24 May 2018
----------------------------

* Make the fallback GGSN/PGW IP setting into a list of candidates
* Add DNS helper module to resolve names with NAPTR record [#67](https://github.com/travelping/ergw/pull/67)
* Upgrade `gen_socket` to work on Erlang-R20+ [#68](https://github.com/travelping/ergw/pull/68)
* Fix metrics suffix for counters [#65](https://github.com/travelping/ergw/pull/65)
* Use exometer_core, cowboy and jobs dependencies from hex.pm [#58](https://github.com/travelping/ergw/pull/58)
* Fix fmt_ies/1 during pretty print of gtp message [#61](https://github.com/travelping/ergw/pull/61)
* Fix error log about invalid response in gtp_socket [#60](https://github.com/travelping/ergw/pull/60)

Version 1.16.0 - 03 Oct 2017
----------------------------

* change Modify Bearer Request SGW change detection for RAU/TAU/HO
* change session collision detection to take only IMSI or IMEI, not both
* implement destination port handling for GTPv2-C triggered request

Version 1.15.0 - 29 Aug 2017
----------------------------

* GGSN outgoing load balancing in proxy mode
* fix context path counters
* make sure colliding session are terminated before the
  new session is registered (avoiding a race)
* handle access point names as DNS labels (make them
  case insensitive)
* decouple sequence numbers in proxy mode again (fixes bug
  introduced in last release)

Version 1.14.0 - 04 Aug 2017
----------------------------

* properly clean DP context on shutdown
* catch duplicate context registration
* remove colliding tunnels when a new context is created
  (mandated by 3GPP procedures)
* implement 3GPP TS 23.401, Sect. 5.4.2.2, HSS Initiated Subscribed QoS Modification

Version 1.13.1 - 12 Jul 2017
----------------------------

* fix handling of freebind and netdev socket options

Version 1.13.0 - 11 Jul 2017
----------------------------

* add rate limiting for incoming requests, the default is 100 req/s
* upgrade gtplib, fix PCO's with vendor extensions
* fix handling of IP's in metrics names
* Serve Prometheus metrics on `/metrics`
* populate missing version field on request
* fix resend behaviour in proxy mode
* support Erlang 20.0
* optimise GTP message encoding

Version 1.12.0 - 21 Jun 2017
----------------------------

* add more metrics and export them through HTTP API
* enhance the config validation
* change the handler configuration to be inline with the documentation
* enhance the proxy DS API
* add HTTP status API

Version 1.11.0 - 27 Apr 2017
----------------------------

* GTP context no longer crashes when error replies do not contain mandatory IEs
* unify translation logic in proxy mode
* more unit test

Version 1.10.0 - 18 Apr 2017
----------------------------

* fix path restart when multiple context are active
* better directional filtering of Request/Responses in proxy mode
* added some more test for proxy functions

Version 1.9.0 - 05 Apr 2017
---------------------------

* extensive unit tests for GGSN, PGW and proxy modes
* fix QoS IE encoding for extended bit rates
* fix path restart behavior
* implement GTPv2 messages:
   * Change Notification Request
   * Delete Bearer Request
   * Modify Bearer Command
* implement GTPv1 messages:
   * MS Info Change Notification Request
   * SGSN initiated Update PDP Context Request
   * GGSN initiated Delete PDP Context Request
* drop S2a support (will be readded later)

Version 1.8.0 - 24 Mar 2017
---------------------------

* support more message types in GTPv2 proxy
* fix TEID translation GTPv2 proxy
* fix retransmit timer handling for the proxy case
* added basic test suite for PGW
* (experimental) support for IPv6 as transport for GTP (not as payload)

Version 1.7.0 - 24 Feb 2017
---------------------------

* more fixes for the GTPv2 proxy, not yet working
* fix retransmission cache timeout bug
* add rcvbuf option to sockets
* use full sequence number range for GTPv2

Version 1.6.0 - 17 Jan 2017
---------------------------

* send end marker on S5/S8 GTP-U tunnels during hand over
* properly handle GTP version changes during handover
* validate TEID in requests

Version 1.5.0 - 08 Dec 2016
---------------------------

* socket are restarted after a crash now
* handle GTP v1 and v2 on the same path
* use seperate TEID for GTP-C and GTP-U
* add configuration for gateways home MCC and MNC
* GTP-U error indication is now handled properly
* SGW and SGSN handover procedures are working now

Version 1.4.0 - 25 Nov 2016
---------------------------

* rework the configuration model, see CONFIG.md for details
* preliminary API for exporting runtime state information
  (unstable, subject to change)
* complete S5/S8 interface
* initiate Accounting sessin after authentication

Version 1.3.0 - 03 Nov 2016
---------------------------

* extend error message on send failures
* use TEI from updated context for PDP Update Response
* rework IP pool handling (configuration format changed!)

Version 1.2.0 - 02 Nov 2016
---------------------------

* JSON data source for proxy mappings
* handle GTP-C decoder failures
* support session default settings
* AAA support for S5/S8

Version 1.1.0 - 21 Oct 2016
---------------------------

* fix IP pool handling
* replace records in API handler with maps
* replace IP allocator with constant time variant
* update to gtplib 1.1.0+ API

Version 1.0.0 - 07 Oct 2016
---------------------------

* Initial release
