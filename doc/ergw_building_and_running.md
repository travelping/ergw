
## Building and Running  

### Prerequisites

* Erlang OTP **23.2.7** is the recommended version.
* [Rebar3](https://www.rebar3.org/)
An *erGW* installation needs a user plane provider to handle the GTP-U path. This
instance can be installed on the same or different host.

A suitable user plane node based on [VPP](https://wiki.fd.io/view/VPP) can be found at [VPP-UFP](https://github.com/travelping/vpp/).

### Configuration

erGW can be started with [rebar3](https://s3.amazonaws.com/rebar3/rebar3) command line tools, and build with run looks like:

```sh
$ git clone https://github.com/travelping/ergw.git
$ cd ergw
$ wget https://s3.amazonaws.com/rebar3/rebar3
$ chmod u+x ./rebar3
$ touch ergw.config
```

Then fill the just created ergw.config file with content like described below providing a suitable configuration, e.g.:

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

         {node_id, <<"pgw.$ORIGIN">>},
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
           {sx, [{type, 'pfcp'},
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

         {teid, {3, 6}}, % {teid, {Prefix, Length}} - optional, default: {0, 0}

         {metrics, [
             {gtp_path_rtt_millisecond_intervals, [10, 100]} % optional, default: [10, 30, 50, 75, 100, 1000, 2000]
         ]},

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
             },
             {heartbeat, [
               {interval, 5000},
               {timeout, 500},
               {retry, 5}
             ]},
             {request,
               [{timeout, 30000},
               {retry, 5}]}]
           }]
         },

         {path_management, [
           {t3, 10000},
           {n3,  5},
           {echo, 60000},
           {idle_timeout, 1800000},
           {idle_echo,     600000},
           {down_timeout, 3600000},
           {down_echo,     600000},
           {icmp_error_handling, immediate} % optional, can be 'ignore' | 'immediate', by default: immediate
         ]}
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

### Compiling and Running

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

The configuration is documented in [CONFIG.md](CONFIG.md).

### Running Unit Test

The Unit test can be run local with:

```sh
$ rebar ct
```

In order to run the IPv6 a number of locap IPv6 addresses have to be added to the host.
See [.github/workflows/main.yml](.github/workflows/main.yml) or [.gitlab-ci.yml](.gitlab-ci.yml)

The DNS resolver tests can be run with a local DNS server. The docker image used with
the CI test can also be used for this purpose.

Run it with:

```sh
docker run -d --rm \
        --name=bind9 \
        --publish 127.0.10.1:53:53/udp \
        --publish 127.0.10.1:53:53/tcp \
        --publish 127.0.10.1:953:953/tcp \
        quay.io/travelping/ergw-dns-test-server:latest
```

and

```sh
export CI_DNS_SERVER=127.0.10.1
```

before running the unit tests.

<!-- Badges -->
[gh]: https://github.com/travelping/ergw/actions/workflows/main.yml
[gh badge]: https://img.shields.io/github/workflow/status/travelping/ergw/CI?style=flat-square
[coveralls]: https://coveralls.io/github/travelping/ergw
[coveralls badge]: https://img.shields.io/coveralls/travelping/ergw/master.svg?style=flat-square
[erlang version badge]: https://img.shields.io/badge/erlang-R22.3.4%20to%2023.1-blue.svg?style=flat-square
