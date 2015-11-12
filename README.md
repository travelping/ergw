erGW - 3GPP GGSN/P-GW in Erlang
===============================
[![Build Status](https://travis-ci.org/travelping/ergw.svg?branch=master)](https://travis-ci.org/travelping/ergw)

This is a 3GPP GGSN and PGW implemented in Erlang.

2015-10-30 - this is code very much WiP !!!!

Implmenented messages:

 * GTPv1 Create/Update/Delete PDP Context Request on Gn
 * GTPv2 Create/Delete Session Request on S2a

MISSING FEATURES
----------------

* no APN selection
* QoS parameters are hard-coded
* SGSN handover (IP and TEI change) no supported

BUILDING
--------

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
