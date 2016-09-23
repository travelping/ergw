erGW - 3GPP GGSN/P-GW in Erlang
===============================
[![Build Status](https://travis-ci.org/travelping/ergw.svg?branch=master)](https://travis-ci.org/travelping/ergw)

This is a 3GPP GGSN and PGW implemented in Erlang.

2015-10-30 - this is code very much WiP !!!!

IMPLEMENTED FEATURES
--------------------

Messages:

 * GTPv1 Create/Update/Delete PDP Context Request on Gn
 * GTPv2 Create/Delete Session Request on S2a
 * GTPv2 Create/Delete Session Request on S5/S8

From the above the following procedures as defined by 3GPP T 23.060 should work:

 * PDP Context Activation/Deactivation Procedure
 * PDP Context Activation/Deactivation Procedure using S4

MISSING FEATURES
----------------

The following procedures are assumed/known to be *NOT* working:

 * Secondary PDP Context Activation Procedure
 * Secondary PDP Context Activation Procedure using S4
 * most (if not all) TS 23.060, Sect. 9.2.3 Modification Procedures
 * all  TS 23.060, Sect. 6.13 Intersystem Change Procedures (handover 2G/3G/LTE)

Other shortcomings:

 * QoS parameters are hard-coded
 * SGSN handover (IP and TEI change) no supported

BUILDING
--------

*The minimum supported Erlang version is 19.0.*

Using tetrapak:

    # tetrapak build check

Using rebar:

    # rebar get-deps
    # rebar compile

RUNNING
-------

Very experimental:

- edit the APN parameted in gtp:test/0
- run with:

```
# tetrapak shell
Erlang/OTP 18 [erts-7.0.3] [source] [64-bit] [smp:8:8] [async-threads:10] [kernel-poll:false]

Eshell V7.0.3  (abort with ^G)
1> start().
2> gtp:test().
```

- connect with SGSN or S-GW
