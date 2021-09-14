# erGW - 3GPP GGSN and PDN-GW in Erlang
[![Build Status][gh badge]][gh]
[![Coverage Status][coveralls badge]][coveralls]
[![Erlang Versions][erlang version badge]][gh]  


## Introduction

The erGW is a 3GPP GGSN and PDN-GW implemented in Erlang. It strives to eventually support all the functionality as defined by [3GPP TS 23.002](http://www.3gpp.org/dynareport/23002.htm) Section 4.1.3.1 for the GGSN and Section 4.1.4.2.2 for the PDN-GW.

### Implemented Features  

Messages:

 * GTPv1 Create/Update/Delete PDP Context Request on Gn
 * GTPv2 Create/Delete Session Request on S5/S8

From the above the following procedures as defined by 3GPP T 23.060 should work:

 * PDP Context Activation/Modification/Deactivation Procedure
 * PDP Context Activation/Modification/Deactivation Procedure using S4
 * Intersystem Change Procedures (handover 2G/3G/LTE)
 * 3GPP TS 23.401:
   * Sect. 5.4.2.2, HSS Initiated Subscribed QoS Modification (without PCRF)
   * Annex D, Interoperation with Gn/Gp SGSNs procedures (see [CONFIG.md](CONFIG.md))

## User Plane
The erGW uses the 3GPP control and user plane separation (CUPS) of EPC nodes
architecture as layed out in [3GPP TS 23.214](http://www.3gpp.org/dynareport/23244.htm)
and [3GPP TS 29.244](http://www.3gpp.org/dynareport/29244.htm).

## Interfaces

The SAE-GW, PGW and GGSN interfaces supports DIAMETER and RADIUS over the Gi/SGi interface
as specified by 3GPP TS 29.061 Section 16.
This support is experimental in this version and not all aspects are functional. For RADIUS
only the Authentication and Authorization is full working, Accounting is experimental and
not fully supported. For DIAMETER NASREQ only the Accounting is working.

See [RADIUS.md](RADIUS.md) for a list of supported Attributes.

Many thanks to [On Waves](https://www.on-waves.com/) for sponsoring the RADIUS Authentication implementation.

### Policy Control
DIAMETER is Gx is supported as experimental feature. Only Credit-Control-Request/Answer
(CCR/CCA) and Abort-Session-Request/Answer (ASR/ASA) procedures are supported.
Re-Auth-Request/Re-Auth-Answer (RAR/RAA) procedures are not supported.

### Online/Offline Charging
Online charging through Gy is in beta quality with the following known caveats:

 * When multiple rating groups are in use, CCR Update requests will contain unit
   reservation requests for all rating groups, however they should only contain the entries
   for the rating groups where new quotas, threshold and validity's are needed.

Offline charging through Rf is supported in beta quality in this version and works only in
"independent online and offline charging" mode (tight interworking of online and offline
charging is not supported).

Like on Gx only CCR/CCR and ASR/ASA procredures are supported.

## ERLANG Version Support
All minor version of the current major release and the highest minor version of
the previous major release will be supported.
Due to a bug in OTP 22.x, the `netdev` configuration option of erGW is broken
([see](https://github.com/erlang/otp/pull/2600)). If you need this feature, you
must use OTP 23.x.

When in doubt check the `otp_release` section in [.github/workflows/main.yml](.github/workflows/main.yml) for tested
versions.


## Documentation

* [Complete Features](https://github.com/travelping/ergw/blob/mmlieb/docs/doc/ergw_features.md)
* [Complete Interfaces with Examples](https://github.com/travelping/ergw/blob/mmlieb/docs/doc/ergw_interfaces.md)
* [Docker Images](https://github.com/travelping/ergw/blob/mmlieb/docs/doc/ergw_builing_docker_image.md)
* [Building and Running](https://github.com/travelping/ergw/blob/mmlieb/docs/doc/ergw_building_and_running.md)
