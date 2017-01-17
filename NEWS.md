erGW - 3GPP GGSN and PDN-GW in Erlang
=====================================

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
