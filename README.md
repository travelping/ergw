# erGW - 3GPP GGSN and PDN-GW in Erlang
[![Build Status][travis badge]][travis]
[![Coverage Status][coveralls badge]][coveralls]
[![Erlang Versions][erlang version badge]][travis]

This is a 3GPP GGSN and PDN-GW implemented in Erlang. It strives to eventually support all the functionality as defined by [3GPP TS 23.002](http://www.3gpp.org/dynareport/23002.htm) Section 4.1.3.1 for the GGSN and Section 4.1.4.2.2 for the PDN-GW.

# CONTENTS
* [IMPLEMENTED FEATURES](#implemented-features)
* [EXPERIMENTAL FEATURES](#experimental-features)
* [USER PLANE](#user-plane)
* [DIAMETER and RADIUS over Gi/SGi](#diameter-and-radius-over-gisgi)
* [POLICY CONTROL](#policy-control)
* [ONLINE/OFFLINE CHARING](#onlineoffline-charing)
* [MISSING FEATURES](#missing-features)
* [ERLANG Version Support](#erlang-version-support)
* [DOCKER IMAGES](#docker-images)
   * [BUILDING DOCKER IMAGE](#building-docker-image)
* [BUILDING & RUNNING](#building--running)
   * [REQUIRED](#required)
   * [CONFIGURATION](#configuration)
   * [COMPILE & RUN](#compile--run)

# IMPLEMENTED FEATURES
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

# EXPERIMENTAL FEATURES
Experimental features may change or be removed at any moment. Configuration settings
for them are not guaranteed to work across versions. Check [CONFIG.md](CONFIG.md) and
[NEWS.md](NEWS.md) on version upgrades.

 * rate limiting, defaults to 100 requests/second
 * metrics, see [METRICS.md](METRICS.md)

# USER PLANE
*erGW* uses the 3GPP control and user plane separation (CUPS) of EPC nodes
architecture as layed out in [3GPP TS 23.214](http://www.3gpp.org/dynareport/23244.htm)
and [3GPP TS 29.244](http://www.3gpp.org/dynareport/29244.htm).

# DIAMETER and RADIUS over Gi/SGi
The SAE-GW, PGW and GGSN interfaces supports DIAMETER and RADIUS over the Gi/SGi interface
as specified by 3GPP TS 29.061 Section 16.
This support is experimental in this version and not all aspects are functional. For RADIUS
only the Authentication and Authorization is full working, Accounting is experimental and
not fully supported. For DIAMETER NASREQ only the Accounting is working.

See [RADIUS.md](RADIUS.md) for a list of supported Attrbiutes.

Many thanks to [On Waves](https://www.on-waves.com/) for sponsoring the RADIUS Authentication implementation.

Example of configuration **RADIUS**:
```erlang
%% ...
{ergw_aaa, [
    {handlers, [
        {ergw_aaa_static, [
            {'Node-Id',        <<"CHANGE-ME">>},            %% <- CHANGE
            {'NAS-Identifier', <<"CHANGE-ME">>},            %% <- CHANGE
            {'NAS-IP-Address', {127,0,0,3}},                %% <- CHANGE
            {'Acct-Interim-Interval',   1800},              %% <- CHANGE
            {'Framed-Protocol',         'PPP'},
            {'Service-Type',            'Framed-User'}
        ]},
        {ergw_aaa_radius, [
            {server,
                {{127,0,0,4}, 1813, <<"CHANGE-ME-SECRET">>} %% <- CHANGE IP and SECRET
            },
            {termination_cause_mapping, [
                {normal, 1},
                {administrative, 6},
                {link_broken, 2},
                {upf_failure, 9},
                {remote_failure, 9},
                {cp_inactivity_timeout, 4},
                {up_inactivity_timeout, 4},
                {asr, 6},
                {error, 9},
                {peer_restart, 7}
            ]}
        ]}
    ]},
    {services, [
        {'Default', [
            {handler, 'ergw_aaa_static'}
        ]},
        {'RADIUS-Acct', [
            {handler, 'ergw_aaa_radius'}
        ]}
    ]},
    {apps, [
        {default, [
            {session, ['Default']},
            {procedures, [
                {authenticate, []},
                {authorize, []},
                {start, ['RADIUS-Acct']},
                {interim, ['RADIUS-Acct']},
                {stop, ['RADIUS-Acct']}
            ]}
        ]}
    ]}
]},
%% ...
```
Example of configuration **epc-ocs** `function` of **DIAMETER**:
```erlang
%% ...
{ergw_aaa, [
%% ...
    {functions, [
        {'epc-ocs', [
            {handler, ergw_aaa_diameter},
            {'Origin-Host', <<"CHANGE-ME">>},                           %% <- CHANGE: Origin-Host needs to be resolvable 
                                                                        %% to local IP (either through /etc/hosts or DNS)
            {'Origin-Realm', <<"CHANGE-ME">>},                          %% <- CHANGE
            {transports, [
                [
                    {connect_to, <<"aaa://CHANGE-ME;transport=tcp">>},  %% <- CHANGE
                    {recbuf,131072},                                    %% <- CHANGE
                    {sndbuf,131072}                                     %% <- CHANGE
                ]
            ]}
        ]}
    ]},
%% ...
]},
%% ...
```
Example of configuration **ergw-pgw-epc-rf** `function` of **DIAMETER**:
```erlang
%% ...
{ergw_aaa, [
    %% ...
    {functions, [
        {'ergw-pgw-epc-rf', [
            {handler, ergw_aaa_diameter},
            {'Origin-Host', <<"CHANGE-ME">>},                           %% <- CHANGE
            {'Origin-Realm', <<"CHANGE-ME">>},                          %% <- CHANGE
            {transports, [
                [
                    {connect_to, <<"aaa://CHANGE-ME;transport=tcp">>},  %% <- CHANGE
                    {recbuf,131072},                                    %% <- CHANGE
                    {reuseaddr,false},                                  %% <- CHANGE
                    {sndbuf,131072}                                     %% <- CHANGE
                ]
            ]}
        ]},
    ]},
    {handlers, [
        %% ...
        {ergw_aaa_rf, [
            {function, 'ergw-pgw-epc-rf'},
            {'Destination-Realm', <<"CHANGE-ME">>}                      %% <- CHANGE
        ]},
        {termination_cause_mapping, [
            {normal, 1},           
            {administrative, 4}, 
            {link_broken, 5},      
            {upf_failure, 5},      
            {remote_failure, 1},   
            {cp_inactivity_timeout, 4},
            {up_inactivity_timeout, 4},
            {asr, 6},
            {error, 9},
            {peer_restart, 1} 
        ]}
        %% ...
    ]},
    {services, [
        %% ...
        {'Rf', [{handler, 'ergw_aaa_rf'}]},
        %% ...
    ]},
    {apps, [
        {default, [
            %% ...
            {procedures, [
                %% ...
                { {rf, 'Initial'}, ['Rf']},
                { {rf, 'Update'}, ['Rf']},
                { {rf, 'Terminate'}, ['Rf']},
                %% ...
            ]}
        ]}
        %% ...
    ]}
]},
%% ...
```

# POLICY CONTROL
DIAMETER is Gx is supported as experimental feature. Only Credit-Control-Request/Answer
(CCR/CCA) and Abort-Session-Request/Answer (ASR/ASA) procedures are supported.
Re-Auth-Request/Re-Auth-Answer (RAR/RAA) procedures are not supported.

# ONLINE/OFFLINE CHARING
Online charging through Gy is in beta quality with the following known caveats:

 * When multiple rating groups are in use, CCR Update requests will contain unit
   reservation requests for all rating groups, however they should only contain the entries
   for the rating groups where new quotas, threshold and validity's are needed.

Offline charging through Rf is supported in beta quality in this version and works only in
"independent online and offline charging" mode (tight interworking of online and offline
charging is not supported).

Like on Gx only CCR/CCR and ASR/ASA procredures are supported.

# MISSING FEATURES
The following procedures are assumed/known to be *NOT* working:

 * Secondary PDP Context Activation Procedure
 * Secondary PDP Context Activation Procedure using S4

Other shortcomings:

 * QoS parameters are hard-coded

# ERLANG Version Support
All minor version of the current major release and the highest minor version of
the previous major release will be supported.
Due to a bug in OTP 22.x, the `netdev` configuration option of *erGW* is broken
([see](https://github.com/erlang/otp/pull/2600)). If you need this feature, you
must use OTP 23.x.

When in doubt check the `otp_release` section in [.travis.yml](.travis.yml) for tested
versions.

# DOCKER IMAGES
Docker images are build by travis-ci and pushed to [hub.docker.com](https://hub.docker.com/r/ergw/ergw-c-node/tags),
and by gitlab.com and pushed to [quay.io](https://quay.io/repository/travelping/ergw-c-node?tab=tags).

## BUILDING DOCKER IMAGE
**erGW** Docker image can be get from [quay.io](https://quay.io/repository/travelping/ergw-c-node?tab=tags). For create a new image based on `ergw-c-node` from `quay.io` need run second command:

```sh
$ docker run -t -i --rm quay.io/travelping/ergw-c-node:2.4.2 -- /bin/sh
/ # cd opt
/opt # ls
ergw-c-node
```

# BUILDING & RUNNING
## REQUIRED
* The minimum supported Erlang version is **22.3.4** (*Erlang 23.0.3 is the recommended version.*).
* [Rebar3](https://www.rebar3.org/)
An *erGW* installation needs a user plane provider to handle the GTP-U path. This
instance can be installed on the same or different host.

A suitable user plane node based on [VPP](https://wiki.fd.io/view/VPP) can be found at [VPP-UFP](https://github.com/travelping/vpp/).

## CONFIGURATION
**erGW** can be started with [rebar3](https://s3.amazonaws.com/rebar3/rebar3) command line tools, and build with run can looks like:

```sh
$ git clone https://github.com/travelping/ergw.git
$ cd ergw
$ wget https://s3.amazonaws.com/rebar3/rebar3
$ chmod u+x ./rebar3
$ touch ergw.config
```

Then fill just created **ergw.config** file with content like described below providing a suitable configuration, e.g.:

```erlang
%-*-Erlang-*-
[{setup, [{data_dir, "/var/lib/ergw"},
          {log_dir,  "/var/log/ergw-c-node"}
         ]},

 {kernel,
  [{logger,
    [{handler, default, logger_std_h,
      #{level => info,
        config =>
            #{sync_mode_qlen => 10000,
              drop_mode_qlen => 10000,
              flush_qlen     => 10000}
       }
     }
    ]}
  ]},

 {ergw, [{'$setup_vars',
          [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
         {plmn_id, {<<"001">>, <<"01">>}},

         {http_api,
          [{port, 8080},
           {ip, {0,0,0,0}}
          ]},

         {sockets,
          [{cp, [{type, 'gtp-u'},
             {vrf, cp},
             {ip,  {127,0,0,1}},
             freebind,
             {reuseaddr, true}
            ]},
           {irx, [{type, 'gtp-c'},
                  {vrf, epc},
                  {ip,  {127,0,0,1}},
                  {reuseaddr, true}
                 ]},
           {sx, [{node, 'ergw'},
                 {name, 'ergw'},
                 {type, 'pfcp'},
                 {socket, cp},
                 {ip,  {172,21,16,2}}
           ]}
          ]},

         {vrfs,
          [{sgi, [{pools,  [{{10, 106, 0, 1}, {10, 106, 255, 254}, 32},
                            {{16#8001, 0, 0, 0, 0, 0, 0, 0},
                             {16#8001, 0, 0, 16#FFFF, 0, 0, 0, 0}, 64}
                           ]},
                  {'MS-Primary-DNS-Server', {8,8,8,8}},
                  {'MS-Secondary-DNS-Server', {8,8,4,4}},
                  {'MS-Primary-NBNS-Server', {127,0,0,1}},
                  {'MS-Secondary-NBNS-Server', {127,0,0,1}}
                 ]}
          ]},

         {handlers,
          [{'h1', [{handler, pgw_s5s8},
                   {protocol, gn},
                   {sockets, [irx]},
                   {node_selection, [default]}
                  ]},
           {'h2', [{handler, pgw_s5s8},
                   {protocol, s5s8},
                   {sockets, [irx]},
                   {node_selection, [default]}
                  ]}
          ]},

         {apns,
          [{[<<"tpip">>, <<"net">>], [{vrf, sgi}]},
           {[<<"APN1">>], [{vrf, sgi}]}
          ]},

         {teid, {3, 6}}, % {teid, {Prefix, Length}}

         {node_selection,
          [{default,
            {static,
             [
              %% APN NAPTR alternative
              {"_default.apn.$ORIGIN", {300,64536},
               [{"x-3gpp-upf","x-sxb"}],
               "topon.sx.prox01.$ORIGIN"},

              %% A/AAAA record alternatives
              {"topon.sx.prox01.$ORIGIN", [{127,0,0,1}], []}
             ]
            }
           }
          ]
         },

         {nodes,
          [{default,
            [{vrfs,
              [{cp, [{features, ['CP-Function']}]},
               {epc, [{features, ['Access']}]},
               {sgi, [{features, ['SGi-LAN']}]}]
             }]
           }]
         }
        ]},

 {ergw_aaa,
  [{handlers,
    [{ergw_aaa_static,
        [{'NAS-Identifier',          <<"NAS-Identifier">>},
         {'Acct-Interim-Interval',   600},
         {'Framed-Protocol',         'PPP'},
         {'Service-Type',            'Framed-User'},
         {'Node-Id',                 <<"PGW-001">>},
         {'Charging-Rule-Base-Name', <<"cr-01">>},
         {rules, #{'Default' =>
                       #{'Rating-Group' => [3000],
                         'Flow-Information' =>
                             [#{'Flow-Description' => [<<"permit out ip from any to assigned">>],
                                'Flow-Direction'   => [1]    %% DownLink
                               },
                              #{'Flow-Description' => [<<"permit out ip from any to assigned">>],
                                'Flow-Direction'   => [2]    %% UpLink
                               }],
                         'Metering-Method'  => [1],
                         'Precedence' => [100]
                        }
                  }
         }
        ]}
    ]},

   {services,
    [{'Default', [{handler, 'ergw_aaa_static'}]}
    ]},

   {apps,
    [{default,
      [{session, ['Default']},
       {procedures, [{authenticate, []},
                     {authorize, []},
                     {start, []},
                     {interim, []},
                     {stop, []}
                    ]}
      ]}
    ]}
  ]},

 {jobs, [{samplers,
          [{cpu_feedback, jobs_sampler_cpu, []}
          ]},
         {queues,
          [{path_restart,
            [{regulators, [{counter, [{limit, 100}]}]},
             {modifiers,  [{cpu_feedback, 10}]} %% 10 = % increment by which to modify the limit
            ]},
           {create,
            [{max_time, 5000}, %% max 5 seconds
             {regulators, [{rate, [{limit, 100}]}]},
             {modifiers,  [{cpu_feedback, 10}]} %% 10 = % increment by which to modify the limit
            ]},
           {delete,
            [{regulators, [{counter, [{limit, 100}]}]},
             {modifiers,  [{cpu_feedback, 10}]} %% 10 = % increment by which to modify the limit
            ]},
           {other,
            [{max_time, 10000}, %% max 10 seconds
             {regulators, [{rate, [{limit, 1000}]}]},
             {modifiers,  [{cpu_feedback, 10}]} %% 10 = % increment by which to modify the limit
            ]}
          ]}
        ]}
].
```
## COMPILE & RUN
```sh
$ ./rebar3 compile
$ sudo ./rebar3 shell --setcookie secret --sname ergw --config ergw.config --apps ergw
===> Verifying dependencies...
CONFIG: enabling persistent_term support
===> Analyzing applications...
===> Compiling ergw
Erlang/OTP 23 [erts-11.0.3] [source] [64-bit] [smp:8:8] [ds:8:8:10] [async-threads:1] [hipe]

Eshell V11.0.3  (abort with ^G)
(ergw@localhost)1> application:info().
```

The configuration is documented in [CONFIG.md](CONFIG.md)

<!-- Badges -->
[travis]: https://travis-ci.com/travelping/ergw
[travis badge]: https://img.shields.io/travis/com/travelping/ergw/master.svg?style=flat-square
[coveralls]: https://coveralls.io/github/travelping/ergw
[coveralls badge]: https://img.shields.io/coveralls/travelping/ergw/master.svg?style=flat-square
[erlang version badge]: https://img.shields.io/badge/erlang-R22.3.4%20to%2023.1-blue.svg?style=flat-square
