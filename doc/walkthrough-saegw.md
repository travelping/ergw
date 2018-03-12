Walk-Through SEA-GW (combined S-GW/PGW)
=======================================

This walk-through creates a combined S-GW/PGW (sometimes also called
a SAE-GW) which support the S11, S1-U and SGi 3GPP reference points.

Requirements
------------

* working MME and eNode-B
* Linux bare metal system with at least 3 network interfaces
* 2 IPv4 addresses for EPC (Enhanced Packet Core) connection
* 1 IPv4 address for SGi interface
* 1 IPv4 network range for SGi LAN

***Warning:***
You can also run this setup on a virtual machine or in containers. If you do so,
make sure that you understand how your hypervisor or container infrastructure
interacts with VPP.

In  particular, the VPP created interface will have MAC addresses that differ from
the MAC of the interfaces they attach too.

Many hypervisors and container providers have filters in place that prevent the
spoofing of MAC and/or IP addresses that will interact badly with that.
You might have to disable those filters or use MAC addresses on the VPP interfaces
that match that of the virtual interfaces. Check the VPP documentation on how to
configure the interfaces with dedicated MACs.

Setup
-----

                                 +----------------------------------------+
                                 |                                        |
                              +--+--+       +-----------------+           |
                              |     |       |                 |           |
    S11 GTP-C IP to MME       | irx +-------+    erGW - CP    +           |
            172.20.16.1       |     |       |                 |           |
                              +--+--+       +-------+---------+       +---+-----------+
                                 |                  |                 |               |
                                 |              Sxb |              +--+ SGi-LAN (sgi) |
                                 |                  |              |  | 10.0.0.1/24   |
                              +--+--+       +-------+---------+    |  +---+-----------+
                              |     |       |                 |    |      |
    S1-U GTP-U IP to eNode-B  | grx +-------+    VPP - UP     +----+      |
            172.20.17.1       |     |       |                 |           |
                              +--+--+       +-----------------+           |
                                 |                                        |
                                 |                                        |
                                 +----------------------------------------+

The interfaces and VRFs are named according to their function (irx, grx, sgi).
For communication on the Sx reference point between CP and UP the 192.168.1.0/24
network is used. The UP is using 192.168.1.1 and the CP is using 192.168.1.2.

Network Setup
-------------

The reader should be familiar with Linux VRF-lite routing. For this walk-through
the following Linux configuration for the irx interface is assumed:

irx VRF:

    ip link add vrf-irx type vrf table 10
    ip link set dev vrf-irx up
    ip link set dev irx master vrf-irx
    ip link set dev irx up
    ip addr add 172.20.16.1 dev vrf-ir
    ip route add table 10 default via 192.20.16.250

The grx and sgi interfaces are handled by VPP.

erGW Installation
-----------------

1. Checkout the Erlang release for a GTP-C node

       git clone https://github.com/travelping/ergw-gtp-c-node.git

2. Adjust the erGW git setting in rebar.config to point to the desired erGW version

       {deps, [
           {ergw, {git, "git://github.com/travelping/ergw", {branch, "master"}}},
           {netdata, ".*", {git, "git://github.com/RoadRunnr/erl_netdata", "master"}}
       ]}.

3. Build a release

       rebar3 release

4. Install the release in /opt/ergw-gtp-c-node and the config in /etc/ergw-gtp-c-node

       sudo cp -aL _build/default/rel/ergw-gtp-c-node /opt
       sudo mkdir /etc/ergw-gtp-c-node
       sudo cp config/ergw-gtp-c-node.config /etc/ergw-gtp-c-node/ergw-gtp-c-node.config

5. Adjust  /etc/ergw-gtp-c-node/ergw-gtp-c-node.config, for the walk-through the following config is used:

       %-*-Erlang-*-
       [{setup, [{data_dir, "/var/lib/ergw"},
             {log_dir,  "/var/log/gtp-c-node"}             %% NOTE: lager is not using this
            ]},

        {ergw, [{'$setup_vars',
             [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
            {http_api,
             [{port, 8080},
              {ip, {0,0,0,0}}
             ]},
            {sockets,
             [{irx, [{type, 'gtp-c'},
                 {ip,  {172,20,16,1}},
                 {netdev, "irx"}
                ]}
             ]},

            {sx_socket,
             [{node, 'ergw'},
              {name, 'ergw'},
              {ip, {0,0,0,0}
              }
             ]},

            {handlers,
              {s11, [{handler, saegw_s11},
                  {sockets, [irx]},
                  {node_selection, [default]}
                 ]}
             ]},

            {node_selection,
             [{default,
               {static,
                [
                 %% APN NAPTR alternative
                 {"_default.apn.$ORIGIN", {300,64536},
                  [{"x-3gpp-pgw","x-s5-gtp"},{"x-3gpp-pgw","x-s8-gtp"},
                   {"x-3gpp-sgw","x-s5-gtp"},{"x-3gpp-sgw","x-s8-gtp"}],
                  "topon.s1u.saegw.$ORIGIN"},
                 {"_default.apn.$ORIGIN", {300,64536},
                  [{"x-3gpp-upf","x-sxb"}],
                  "topon.sx.saegw01.$ORIGIN"},

                 %% A/AAAA record alternatives
                 {"topon.s1u.saegw.$ORIGIN", [172,20,17,1], []},
                 {"topon.sx.saegw01.$ORIGIN", [192,168,1,1], []}
                ]
               }
              }
             ]
            }
           ]},

        {ergw_aaa, [
                {ergw_aaa_provider, {ergw_aaa_mock, [{shared_secret, <<"MySecret">>}]}}
               ]},

        {hackney, [
               {mod_metrics, exometer}
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
           ]},

        {lager, [
             {log_root, "/var/log/gtp-c-node"},
             {colored, true},
             {error_logger_redirect, true},
             {crash_log, "crash.log"},
             {handlers, [
                     {lager_console_backend, [{level, debug}]},
                     {lager_file_backend, [{file, "error.log"}, {level, error}]},
                     {lager_file_backend, [{file, "console.log"}, {level, debug}]}
                    ]}
            ]}
       ].

6. Start the erGW:

       /opt/ergw-gtp-c-node/bin/ergw-gtp-c-node foreground

VPP Installation
----------------

1. Checkout the VPP with GTP UP plugin to /usr/src/vpp

       cd /usr/src
       git clone https://github.com/RoadRunnr/vpp.git
       cd vpp
       git checkout feature/gtp-dp

2. Install the VPP build depedencies

       make install-dep

3. build VPP

       make bootstrap
       make build

4. create startup.conf in /usr/src/vpp

       unix {
         nodaemon
         log /tmp/vpp.log
         full-coredump
         gid vpp
         interactive
         cli-listen localhost:5002
         exec init.conf
       }

       api-trace {
         on
       }

       api-segment {
         gid vpp
       }

       plugins {
           path /usr/src/vpp/build-root/install-vpp_debug-native/vpp/lib64/vpp_plugins/
           plugin dpdk_plugin.so { disable }
           plugin gtpu_plugin.so { disable }
       }

5. create a init.conf file in /usr/src/vpp

       create host-interface name grx
       set interface ip table host-grx 1
       set interface ip address host-grx 172.20.17.1/24
       set interface state host-grx up
       create host-interface name sgi
       set interface ip table host-sgi 2
       set interface ip address host-sgi 172.20.18.1/24
       set interface state host-sgi up
       tap connect vpptap
       set int ip address tapcli-0 192.168.1.1/24
       set int state tapcli-0 up
       ip route add 0.0.0.0/0 table 1 via 172.20.17.250 host-grx
       ip route add 0.0.0.0/0 table 2 via 172.20.18.250 host-sgi
       gtpdp nwi create label irx vrf 1
       gtpdp nwi set gtpu address label irx 172.20.17.1 teid 0x80000000/2
       gtpdp nwi set interface type label irx access interface host-grx
       gtpdp nwi set interface type label irx cp interface tapcli-0
       gtpdp nwi create label sgi vrf 2
       gtpdp nwi set interface type label sgi sgi interface host-sgi
       gtpdp sx

6. create a ```vpp``` group

       groupadd vpp

7. start vpp

       sudo build-root/install-vpp_debug-native/vpp/bin/vpp -v startup.conf

8. configure vpptap (from a another shell)

       sudo ip addr add 192.16.1.2/24 dev vpptap

Status Checks
-------------

Check that the Erlang erGW CP is listening to the GTP-C and Sx UDP ports

    sudo ss -aunp \( sport = 2123 or sport = 8805 \)

Check that the VPP gtpdp setup is working, on the vpp cli

    show gtpdp nwi

After a GTP session has been created, on the vpp cli list all sessions

    show gtpdp session
