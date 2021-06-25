erGW - 3GPP GGSN and PDN-GW in Erlang
=====================================

Version 3.0.0 - 25 June 2021
-------------------------------

**Features** :rocket:
* [#408](https://github.com/travelping/ergw/pull/408) Update alpine to 3.14 for Dockerfile
* [#405](https://github.com/travelping/ergw/pull/405) New IP assignment, random init, fifo reuse of IP
* [#404](https://github.com/travelping/ergw/pull/404) Add PSDBU part or the EPFAR feature
* [#393](https://github.com/travelping/ergw/pull/393) Add NAT to the TDF function
* [#357](https://github.com/travelping/ergw/pull/357) Add PFPC User ID to Session Establishment Request
* [#365](https://github.com/travelping/ergw/pull/365) Add UP Feature checking

**Bugfixes** :bug:
* [#402](https://github.com/travelping/ergw/pull/402) Bump gtp and pfcp lib to normalize FQDNs on ingres
* [#391](https://github.com/travelping/ergw/pull/391) Handle timeout in PFCP send
* [#356](https://github.com/travelping/ergw/pull/356) Fix PFCP control during HSS Initiated Subscribed QoS Modification

**Improvements** :bulb:
* [#354](https://github.com/travelping/ergw/pull/354) Refactor application split and with it also config handling

Version 2.8.14 - 3 June 2021
-------------------------------
**Bugfixes** :bug:
* [#401](https://github.com/travelping/ergw/pull/401) Lowercase `APN` expansion

Version 2.8.13 - 1 June 2021
-------------------------------
**Bugfixes** :bug:
* [#395](https://github.com/travelping/ergw/pull/395) Lowercase `APN` before further processing it

Version 2.8.12 - 31 May 2021
-------------------------------
**Improvements** :bulb:
* [#380](https://github.com/travelping/ergw/pull/380) Start use image `quay.io/travelping/alpine-erlang:23.3.4`(the image is included fix for kernel)
* [#373](https://github.com/travelping/ergw/pull/373) Start use `master` of `prometheus`(included all speedup fixes)

**Bugfixes** :bug:
* [#376](https://github.com/travelping/ergw/pull/376) Change `normal` termination reason

**Dependencies** :gear:
* [#389](https://github.com/travelping/ergw/pull/389) Update [ergw_aaa](https://github.com/travelping/ergw_aaa) tag to [3.6.14](https://github.com/travelping/ergw_aaa/releases/tag/3.6.14)

Version 2.8.11 - 23 April 2021
-------------------------------
**Improvements** :bulb:
* [#369](https://github.com/travelping/ergw/pull/369) Start use fork of `prometheus` with speedup fix

Version 2.8.10 - 7 April 2021
-------------------------------
**Bugfixes** :bug:
* [cfdf116](https://github.com/travelping/ergw/commit/cfdf1162fbdc3d955f26b85bf6f2ce23c4a4f942) DNS lookup responses with no answer records are not cached
> As a temporary fix, the simple DNS cache is used on this patch release.

Version 2.8.9 - 25 March 2021
-------------------------------
**Improvements** :bulb:
* [#343](https://github.com/travelping/ergw/pull/343) Update `alpine` to `3.13` for `Dockerfile`
> (C) musl-1.2.1.tar.gz (sig) - August 4, 2020
  This release features the new "mallocng" malloc implementation, replacing musl's original
  dlmalloc-like allocator that suffered from fundamental design problems. Its major user-facing
  new properties are the ability to return freed memory on a much finer granularity and
  avoidance of many catastrophic fragmentation patterns.
  In addition it provides strong hardening against memory usage errors by the caller,
  including detection of overflows, double-free, and use-after-free,
  and does not admit corruption of allocator state via these errors.

**Dependencies** :gear:
* [#345](https://github.com/travelping/ergw/pull/345) Update [ergw_aaa](https://github.com/travelping/ergw_aaa) tag to [3.6.10](https://github.com/travelping/ergw_aaa/releases/tag/3.6.10)
* [#337](https://github.com/travelping/ergw/pull/337) Update [pfcplib](https://github.com/travelping/pfcplib) tag to [2.0.0](https://github.com/travelping/pfcplib/releases/tag/2.0.0)
* [#351](https://github.com/travelping/ergw/pull/351) Update [gtplib](https://github.com/travelping/gtplib) tag to [2.0.1](https://github.com/travelping/gtplib/releases/tag/2.0.1)

Version 2.8.8 - 9 March 2021
-------------------------------

**Bugfixes** :bug:
* [#332](https://github.com/travelping/ergw/pull/332) Build is broked for OTP `22.3` in ergw `2.8.7`
* [#335](https://github.com/travelping/ergw/pull/335) fix statem data corruption `in S5/S8` proxy

**Features** :rocket:
* [#331](https://github.com/travelping/ergw/pull/331) implement a "real" DNS response cache
* [#333](https://github.com/travelping/ergw/pull/333) Remove prefix `v` from image tag
* [#341](https://github.com/travelping/ergw/pull/341) Udpate OTP image to `23.2.7`
* [#334](https://github.com/travelping/ergw/pull/334) add `UP VTIME` feature support

Version 2.8.7 - 26 February 2021
-------------------------------

**Bugfixes** :bug:
* [#326](https://github.com/travelping/ergw/pull/326) Return proper sender `TEID` when rejecting new sessions
* [#327](https://github.com/travelping/ergw/pull/327) Use `Bearer QoS` from session in `Create Session Response`
* [#325](https://github.com/travelping/ergw/pull/325) Switch to `rand:uniform/1` for `SEID` generation

Version 2.8.6 - 4 February 2021
-------------------------------

**Documentations** :books:
* [#318](https://github.com/travelping/ergw/pull/318) Add `path_management` to `README`

**Dependencies** :gear:
* [#319](https://github.com/travelping/ergw/pull/319) Update [ergw_aaa](https://github.com/travelping/ergw_aaa) tag to [3.6.9](https://github.com/travelping/ergw_aaa/releases/tag/3.6.9)

**Improvements** :bulb:
* [#310](https://github.com/travelping/ergw/pull/310) Shuffle the config loading to make it available earlier

**Refactorings** :fire:
* [#313](https://github.com/travelping/ergw/pull/313) Remove `/metrics` from `Swagger` definitions

**Features** :rocket:
* [#315](https://github.com/travelping/ergw/pull/315) Implement configurable `GTP` path `ICMP` error behaviour
* [#306](https://github.com/travelping/ergw/pull/306) Implement configurable `GTP` `RTT` metrics interval

Version 2.8.5 - 29 January 2021
-------------------------------

**Dependencies** :gear:
* [#308](https://github.com/travelping/ergw/pull/308) Update [ergw_aaa](https://github.com/travelping/ergw_aaa) tag to [3.6.8](https://github.com/travelping/ergw_aaa/releases/tag/3.6.8)

**Features** :rocket:
* [#304](https://github.com/travelping/ergw/pull/304) Multiarch build support on `Travis` and `GitLab-CI`

**Bugfixes** :bug:
* [#298](https://github.com/travelping/ergw/pull/298) Remove non use option and fix `dev-sx.config`

Version 2.8.4 - 26 January 2021
-------------------------------

**Bugfixes** :bug:
* [#296](https://github.com/travelping/ergw/pull/296) Fix reliably delete `PFCP` session

Version 2.8.3 - 22 January 2021
-------------------------------

**Documentations** :books:
* [#285](https://github.com/travelping/ergw/pull/285) Add missing decription of `PFCP` metrics

**Dependencies** :gear:
* [#292](https://github.com/travelping/ergw/pull/292) Update [ergw_aaa](https://github.com/travelping/ergw_aaa) tag to [3.6.7](https://github.com/travelping/ergw_aaa/releases/tag/3.6.7)
* [#291](https://github.com/travelping/ergw/pull/291) Update [prometheus_diameter_collector](https://github.com/travelping/prometheus_diameter_collector) tag to [1.2.0](https://github.com/travelping/prometheus_diameter_collector/releases/tag/1.2.0)

**Improvements** :bulb:
* [#293](https://github.com/travelping/ergw/pull/293) `PFCP` reduce log output

**Refactorings** :fire:
* [#289](https://github.com/travelping/ergw/pull/289) Remove dotfiles
* [#290](https://github.com/travelping/ergw/pull/290) Remove diagrams

**Features** :rocket:
* [#278](https://github.com/travelping/ergw/pull/278) Add global `node_id` config setting and use it in `PFCP`
* [#279](https://github.com/travelping/ergw/pull/279) Replace context key tuples with records
* [#283](https://github.com/travelping/ergw/pull/283) Configurable retry timings for `SMF` / `UPF` heartbeats
* [#286](https://github.com/travelping/ergw/pull/286) Added `PFCP` `Sx` association metric
* [#294](https://github.com/travelping/ergw/pull/294) Change socket config `split_sockets` to `send_port`

**Bugfixes** :bug:
* [#282](https://github.com/travelping/ergw/pull/282) Fix online charging `URR` link

Version 2.8.2 - 10 December 2020
-------------------------------

* CT: change the nested groups in the GTP suites - [PR #276](https://github.com/travelping/ergw/pull/276)
* A collection of small CT fixes - [PR #274](https://github.com/travelping/ergw/pull/274)
* Use random `udp` source port for `GTP-C` requests - [PR #273](https://github.com/travelping/ergw/pull/273)
* Fix reading from socket error queue - [PR #272](https://github.com/travelping/ergw/pull/272)
* Updated [ergw_aaa](https://github.com/travelping/ergw_aaa) tag to [3.6.4](https://github.com/travelping/ergw_aaa/releases/tag/3.6.4) - [PR #271](https://github.com/travelping/ergw/pull/271)
* Improve session termination reason handling - [PR #271](https://github.com/travelping/ergw/pull/271)
* Add miss test case of proxy_lib_SUITE - [PR #270](https://github.com/travelping/ergw/pull/270)

Version 2.8.1 - 25 November 2020
-------------------------------

* Bump OTP to `23.1.2.0` and `22.3.4.12`
* Fix issue [#245](https://github.com/travelping/ergw/issues/245): provided correct config example of `sockets` section
* Remove `sx_socket` option because `sx` socket is now handled in the sockets section of `ergw`
* Fix proxy `gw` selection when a `gw` is `down`
* Fix issue [#133](https://github.com/travelping/ergw/issues/133) for correct display of IPv4 and IPv6

Version 2.8.0 - 16 November 2020
-------------------------------

* Refactor handler contexts
* Implement UP based TEID assignment
* Remove reliance on User Plane IP Resource Information IE
* Update [ergw_aaa](https://github.com/travelping/ergw_aaa) tag to [3.6.2](https://github.com/travelping/ergw_aaa/releases/tag/3.6.2)
* Fix Common Tests
* Handle timeouts create `session`/`pdp_context` requests 
* Extend delete contexts REST API for delete all contexts: `/api/v1/contexts`

Version 2.7.2 - 5 November 2020
-------------------------------

* Update [prometheus_diameter_collector](https://github.com/travelping/prometheus_diameter_collector) tag to [1.0.1](https://github.com/travelping/prometheus_diameter_collector/releases/tag/1.0.1) for handle discarded answers in the diameter stats
* Added [SemVer](https://semver.org/) for `erGw` for skip step of change `rebar.config` each time when version of project will update.

Version 2.7.1 - 28 October 2020
-------------------------------

* Update [ergw_aaa](https://github.com/travelping/ergw_aaa) tag to [3.6.1](https://github.com/travelping/ergw_aaa/releases/tag/3.6.1)

Version 2.7.0 - 26 October 2020
-------------------------------

* Added termination cause mapping
* Fixed broken `ergw-c-node.config`
* Update [ergw_aaa](https://github.com/travelping/ergw_aaa) tag to [3.6.0](https://github.com/travelping/ergw_aaa/releases/tag/3.6.0)

Version 2.6.1 - 08 October 2020
-------------------------------

* fix resource leak in TEI mngr
* fix path maintenace, attempts to contact a peer where resetting that peer
  state to UP

Version 2.6.0 - 02 October 2020
-------------------------------

* feature: provide implementation for `DELETE /api/v1/contexts/:count` for
  GTP-Proxy setups ("drain")
* feature: configurable TEID prefix to use
* feature: async IP assignment for IPv4 and IPv6
* feature: simple cache for Node Selection results based upon DNS queries

* fix handling DNS responses without IP in Sx node selection
  (would shutdown of *ergw*)
* fix Change Reporting Indication/Action (Offline Charging)
* fix encoding of IE 'Indication'
* improve GTP Path Maintenance procedures.
  NOTE: In GTP proxy use of *ergw* the path maintenance now stops forwarding
        traffic to a non-responsive target PGW after it detects, based on GTP echo
        probes, that it is not reachable. The PGW path is blocked for a configurable
        duration (default 1 hour) for forwarding. The configuration of the duration
        is done with the `down_timeout` parameter of the `path_management` section
        in the node config (see: `config/ergw-c-node.config` for example)


* unify socket definition. 
  NOTE: this requires changes to the configuration
  of *ergw*: `sx_socket` is removed from the *ergw* configuration, `sx` socket
  is now handled in the `sockets` section of *ergw*. See
  config/ergw-c-node.config for an example.

* switch to Erlang/OTP 23.1
* increase test coverage

Version 2.5.0 - 04 August 2020
----------------------------
* implement path monitoring profiles for outgoing (active) paths
* bump ergw_aaa dependency to 3.5.0 to support  
  [state stats](https://github.com/travelping/ergw_aaa/blob/3.5.0/doc/aaa_session_metrics.md) and
  diameter [avp filters](https://github.com/travelping/ergw_aaa/blob/3.5.0/doc/diameter_avp_filter.md)
* bump [prometheus_diameter_collector](https://github.com/travelping/prometheus_diameter_collector)
  to report internal plain error counters in the same manner as the diameter
  result codes.
* upgrade to OTP-23.0.3

Version 2.4.3 - 26 May 2020
---------------------------
* fix handling `context` attribute of ProxyMap response
* fix `netdev` configuration option
* switch to Erlang/OTP 23.0 as base runtime

Version 2.4.2 - 11 May 2020
---------------------------

* bump ergw_aaa for request tracking changes, fixes accounting of
  outstanding requests
* fix GTP path failure detection

Version 2.4.1 - 30 Apr 2020
---------------------------

* test enhancements
* handle UPF removal/failure in proxy case
* make offline URR generation dependent on global setting
* use seperate socket in PFCP server of send and recv

Version 2.4.0 - 17 Apr 2020
---------------------------

* Offline Charging (Rf):
  * include Traffic-Data-Volumes
  * add Time of First/Last packet
* support different rating groups for online and offline charging
  in the same PCC rule (split charging)
* implemented RFC/3GPP compliant selection of NAPTR records by preference
* added late A/AAAA resolution of NAPTR/SRV pointers
* update gtplib to fix a few corner cases in GTP encoding
* fix GTPv1 cause code encoding
* switch from gen_socket to Erlang native socket.erl for GTP-C and PFCP
* upgrade eradius (through ergw_aaa) for async, retries and timeout option
* proxy mode config fixes
* experimental support for Erlang/OTP 23.0

Version 2.3.0 - 24 Feb 2020
---------------------------

* RADIUS is fixed and under CI
* UP Inactviity Timer feature add, use for session idle timeout
* Support 5G (and WiFi offload) Secondary RAT Usage Data Reporting
* rework dual address bearer support to actually conform to the specs
* implemented 5G Nsbf_Management API
* reselect UPF node based on outcome of authentication
* added PFCP metrics
* better support permanent Sx nodes (config change)
* multi UPF support
* switch from lager to Erlang logger

Version 2.2.0 - 26 Nov 2019
---------------------------

* new load control framework in ergw_aaa
* corrected OCS free behavior
* NASREQ Authentication and Accounting
* docker images moved to quay.io
* TDF
* (very) improved Gx PCC handling
* Gx RAR support
* replace exometer with prometheus.io exporter

Version 2.1.0 - 12 Aug 2019
---------------------------

* Support Erlang OTP 21.3 through 22.0
* stabilize CUPS support
* beta quality DIAMETER Gx, Gy and Rf support
* many bug fixes (see git log)

Version 2.0.0 - 02 Aug 2018
----------------------------

* Rewrite user plane interface to use control and user plane separation
  of EPC nodes (CUPS) architecture, compatible [UPF implementation](https://github.com/travelping/vpp/tree/feature/upf)
* Drop tetrapak build support
* Support Erlang OTP 20.1 through 21.0
* Implement NAPTR based node selection
* IPv6 control and user plane support
* Beta quality features:
   * S11 / SAE-GW

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
