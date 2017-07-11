erGW - 3GPP GGSN and PDN-GW in Erlang
=====================================
[![Build Status][travis badge]][travis]
[![Coverage Status][coveralls badge]][coveralls]
[![Erlang Versions][erlang version badge]][travis]

This is a 3GPP GGSN and PDN-GW implemented in Erlang. It strives to eventually support all the functionality as defined by [3GPP TS 23.002](https://portal.3gpp.org/desktopmodules/Specifications/SpecificationDetails.aspx?specificationId=728) Section 4.1.3.1 for the GGSN and Section 4.1.4.2.2 for the PDN-GW.

IMPLEMENTED FEATURES
--------------------

Messages:

 * GTPv1 Create/Update/Delete PDP Context Request on Gn
 * GTPv2 Create/Delete Session Request on S5/S8

From the above the following procedures as defined by 3GPP T 23.060 should work:

 * PDP Context Activation/Modification/Deactivation Procedure
 * PDP Context Activation/Modification/Deactivation Procedure using S4
 * Intersystem Change Procedures (handover 2G/3G/LTE)
 * 3GPP TS 23.401 Annex D, Interoperation with Gn/Gp SGSNs procedures
   (see [CONFIG.md](CONFIG.md))

EXPERIMENTAL FEATURES
---------------------

Experimental features may change or be removed at any moment. Configuration settings
for them are not guaranteed to work across versions. Check [CONFIG.md](CONFIG.md) and
[NEWS.md](NEWS.md) on version upgrades.

 * rate limiting, defaults to 100 requests/second
 * metrics, see [METRICS.md](METRICS.md)

RADIUS over Gi/SGi
------------------

The GGSN Gn interface supports RADIUS over the Gi interface as specified by 3GPP TS 29.061 Section 16.
At the moment, only the Authentication and Authorization is supported, Accounting is not supported.

See [RADIUS.md](RADIUS.md) for a list of supported Attrbiutes.

Many thanks to [On Waves](https://www.on-waves.com/) for sponsoring the RADIUS Authentication implementation.

MISSING FEATURES
----------------

The following procedures are assumed/known to be *NOT* working:

 * Secondary PDP Context Activation Procedure
 * Secondary PDP Context Activation Procedure using S4

Other shortcomings:

 * QoS parameters are hard-coded

BUILDING
--------

*The minimum supported Erlang version is 19.0.*

Using tetrapak:

    # tetrapak build check

Using rebar:

    # rebar3 compile

RUNNING
-------

A erGW installation needs a data path provider to handle the GTP-U path. This instance can be installed on the same host or a different host.

* for a data path suitable for GGSN/PGW see: [GTP-u-KMod](https://github.com/travelping/gtp_u_kmod)
* for a data path suitable for GTPhub see: [GTP-u-EDP](https://github.com/travelping/gtp_u_edp)

erGW can be started with the normal Erlang command line tools, e.g.:

```
erl -setcookie secret -sname ergw -config ergw.config
Erlang/OTP 19 [erts-8.0.3] [source] [64-bit] [async-threads:10] [kernel-poll:false]

Eshell V8.0.3  (abort with ^G)
(ergw@localhost)1> application:ensure_all_started(ergw).
```

This requires a suitable ergw.config, e.g.:

    [{setup, [{data_dir, "/var/lib/ergw"},
              {log_dir,  "/var/log/gtp-c-node"}                             %% NOTE: lager is not using this
             ]},
    
     {ergw, [{sockets,
              [{irx, [{type, 'gtp-c'},
                      {ip,  {192,0,2,16}},
                      {netdev, "grx"},
                      freebind
                     ]},
               {grx, [{type, 'gtp-u'},
                      {node, 'gtp-u-node@localhost'},
                      {name, 'grx'}]}
              ]},
    
             {vrfs,
              [{upstream, [{pools,  [{{10, 180, 0, 1}, {10, 180, 255, 254}, 32},
                                     {{16#8001, 0, 0, 0, 0, 0, 0, 0}, {16#8001, 0, 0, 16#FFFF, 0, 0, 0, 0}, 64}
                                    ]},
                           {'MS-Primary-DNS-Server', {8,8,8,8}},
                           {'MS-Secondary-DNS-Server', {8,8,4,4}},
                           {'MS-Primary-NBNS-Server', {127,0,0,1}},
                           {'MS-Secondary-NBNS-Server', {127,0,0,1}}
                          ]}
              ]},
    
             {handlers,
              [{gn, [{handler, pgw_s5s8},
                     {sockets, [irx]},
                     {data_paths, [grx]},
                     {aaa, [{'Username',
                             [{default, ['IMSI', <<"@">>, 'APN']}]}]}
                    ]},
               {s5s8, [{handler, pgw_s5s8},
                       {sockets, [irx]},
                       {data_paths, [grx]}
                      ]}
              ]},
    
             {apns,
              [{[<<"example">>, <<"net">>], [{vrf, upstream}]}
              ]}
            ]},
    
     {ergw_aaa, [
                 %% {ergw_aaa_provider, {ergw_aaa_mock, [{shared_secret, <<"MySecret">>}]}}
                 {ergw_aaa_provider,
                  {ergw_aaa_radius,
                   [{nas_identifier,<<"nas01.example.com">>},
                    {radius_auth_server,{{192,0,2,32},1812,<<"secret">>}},
                    {radius_acct_server,{{192,0,2,32},1813,<<"secret">>}}
                   ]}
                 }
                ]},
    
     {lager, [
              {log_root, "/var/log/gtp-c-node"},
              {colored, true},
              {handlers, [
                          {lager_console_backend, debug},
                          {lager_file_backend, [{file, "error.log"}, {level, error}]},
                          {lager_file_backend, [{file, "console.log"}, {level, debug}]}
                         ]}
             ]}
    ].

The configuration is documented in [CONFIG.md](CONFIG.md)

This process can be simplified by using [enit](https://github.com/travelping/enit). A sample config that only requires minimal adjustment for IP's, hostnames and interfaces can be found in priv/enit/ggsn.
Install those files to / (root) and start with ```enit startfg ergw```.

<!-- Badges -->
[travis]: https://travis-ci.org/travelping/ergw
[travis badge]: https://img.shields.io/travis/travelping/ergw/master.svg?style=flat-square
[coveralls]: https://coveralls.io/github/travelping/ergw
[coveralls badge]: https://img.shields.io/coveralls/travelping/ergw/master.svg?style=flat-square
[erlang version badge]: https://img.shields.io/badge/erlang-R19.1%20to%2020.0-blue.svg?style=flat-square
