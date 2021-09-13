## Walk-Through SAE-GW (combined S-GW/PGW)

This walk-through creates a combined S-GW/PGW (sometimes also called
a SAE-GW) which support the S11, S1-U and SGi 3GPP reference points.

### Requirements

* Working MME and eNode-B
* Linux bare metal system with at least 3 network interfaces
* 2 IPv4 addresses for EPC (Enhanced Packet Core) connection
* 1 IPv4 address for SGi interface
* 1 IPv4 network range for SGi LAN

________________________________________________________________________________
**Warning**:
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
________________________________________________________________________________

### Setup


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

The interfaces and VRFs are named accordingly to their function (irx, grx, sgi).
For communication on the Sx reference point between CP and UP the 192.168.1.0/24
network is used. The UP is using 192.168.1.1 and the CP is using 192.168.1.2.

### Network Setup

The reader should be familiar with Linux VRF-lite routing. For this walk-through
the following Linux configuration for the irx interface is assumed:

irx VRF:

    ip link add vrf-irx type vrf table 10
    ip link set dev vrf-irx up
    ip link set dev irx master vrf-irx
    ip link set dev irx up
    ip addr add 172.20.16.1 dev vrf-irx
    ip route add table 10 default via 192.20.16.250

The grx and sgi interfaces are handled by VPP.

### erGW Installation

#### Prerequisites
* Supported Erlang is installed on the Linux system, at least 20.1.7 and that
   the installed version is using the latest patch release of Erlang.
______________________________________________________________________________
**Note**: Check your vendors documentation and consult [erlang.org](http:/www.erlang.org) for installation instructions. When in doubt install
   the newest version using    [kerl](https://github.com/kerl/kerl) or use a package
   from [Erlang Solutions](https://www.erlang-solutions.com/resources/download.html)
______________________________________________________________________________
* When using OTP 20.1, ensure that at least 20.1.7 is installed. Prior version
   have a known problem with gen_statem.

#### Steps

1. Checkout the Erlang release for a GTP-C node

       git clone https://github.com/travelping/ergw.git

2. Build a release

       rebar3 release

3. Install the release in /opt/ergw-c-node and the configuration in /etc/ergw-c-node

       sudo cp -aL _build/default/rel/ergw-c-node /opt
       sudo mkdir /etc/ergw-c-node
       sudo cp config/ergw-c-node.config /etc/ergw-c-node/ergw-c-node.config

4. Adjust  /etc/ergw-c-node/ergw-c-node.config, for the walk-through the following config is used:

       %% -*-Erlang-*-
       [{setup, [{data_dir, "/var/lib/ergw"},
                 {log_dir,  "/var/log/ergw-c-node"}
                ]},

        {kernel,
         [{logger,
           [{handler, default, logger_std_h,
             #{level => debug,
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
                {http_api,
                 [{port, 8080},
                  {ip, {0,0,0,0}}
                 ]},

                {node_id, <<"saegw">>},
                {sockets,
                 [{cp, [{type, 'gtp-u'},
                    {vrf, cp},
                    {ip,  {127,0,0,1}},
                    freebind,
                    {reuseaddr, true}
                  ]},
                 {epc, [{type, 'gtp-c'},
                         {ip,  {172,20,16,1}},
                         {netdev, "vrf-irx"}
                        ]},
                        {sx, [{type, 'pfcp'},
                           {socket, cp},
                           {ip,  {172,21,16,2}}
                        ]}
                 ]},

                {vrfs,
                 [{sgi, [{pools,  [{{10, 180, 0, 1}, {10, 180, 255, 254}, 32}]},
                         {'MS-Primary-DNS-Server', {8,8,8,8}},
                         {'MS-Secondary-DNS-Server', {8,8,4,4}},
                         {'MS-Primary-NBNS-Server', {127,0,0,1}},
                         {'MS-Secondary-NBNS-Server', {127,0,0,1}}
                        ]}
                 ]},

                {handlers,
                 [{s11, [{handler, saegw_s11},
                         {sockets, [epc]},
                         {node_selection, [default]}
                        ]}
                 ]},

                {apns,
                 [{[<<"APN1">>], [{vrf, sgi}]},
                  {['_'], [{vrf, sgi}]}                         %% wildcard APN
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
                     {"topon.s1u.saegw.$ORIGIN", [{172,20,17,1}], []},
                     {"topon.sx.saegw01.$ORIGIN", [{192,168,1,1}], []}
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
                ]}
       ].

The VRF names have to match the network instances (nwi's) in the VPP configuration.

5. Start the erGW:

       /opt/ergw-c-node/bin/ergw-c-node foreground

### VPP Installation

1. Checkout the VPP with GTP UP plugin to /usr/src/vpp

       cd /usr/src
       git clone https://github.com/travelping/vpp.git
       cd vpp
       git checkout feature/gtp-up

2. Install the VPP build depedencies

       make install-dep

3. Build VPP

       make bootstrap
       make build

4. Create startup.conf in /usr/src/vpp

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

5. Create a init.conf file in /usr/src/vpp

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
       gtp-up nwi create label epc
       gtp-up nwi set gtpu address label epc 172.20.17.1 teid 0x80000000/2
       gtp-up nwi set interface type label epc access interface host-grx
       gtp-up nwi set interface type label epc cp interface tapcli-0
       gtp-up nwi create label sgi
       gtp-up nwi set interface type label sgi sgi interface host-sgi

6. Create a ```vpp``` group

       sudo groupadd vpp

7. Start vpp

       sudo build-root/install-vpp_debug-native/vpp/bin/vpp -c startup.conf

8. Configure vpptap (from a another shell)

       sudo ip addr add 192.168.1.2/24 dev vpptap

### Status Checks

* Check that the Erlang erGW CP is listening to the GTP-C and Sx UDP ports

    sudo ss -aunp \( sport = 2123 or sport = 8805 \)

* Check that the VPP gtp-up setup is working, on the vpp cli

    show gtp-up nwi

* After a GTP session has been created, on the vpp cli list all sessions

    show gtp-up session

### Sending GTP Requests Manually

####  Understanding Path Keep-Alive

GTP nodes learn the IPs of peer node from the GSN Node IP (v1) and Fq-TEID (v2)
information elements in create requests. They will then start sending Echo Requests
to those node and expect Echo Replies back from them. If the peer node fails to
answer the Echo Requests or if the Restart Counter changes, they will terminate
all existing GTP context on that path.

To test a GTP Node it is therefore not enough to just send requests, the test system
also needs to be able to handle Echo Request on GTP-C and GTP-U.


#### Procedures

To start a Erlang CLI on a test client with the simulator code run

    rebar3 as simulator shell

##### E-UTRAN Initial Attach

3GPP TS 23.401, Figure 5.3.2.1-1, Step 12, 16, 23 and 24

| Parameter | Value      |
| --------- | ---------- |
| APN       | `internet` |
| IMEI      | `12345`    |
| IMSI      | `12345`    |
| MSISDN    | `89000000` |
| PDP Type  | `IPv4`     |

In the Erlang CLI execute a EUTRAN Initial Attachment on S11 with

    ergw_sim:start("172.20.16.150", "172.20.17.150").
    ergw_sim:s11("172.20.16.1", initial_attachment, <<"internet">>, <<"12345">>, <<"12345">>, <<"89000000">>, ipv4).

172.20.16.150 is the GTP-C IP address of the MME, 172.20.17.150 is the GTP-U address
of the eNode-B and 172.20.16.1 is the SAE-GW GTP-C address.

*Make sure you have those IP's configured on your test client*

##### erGW Logging

erGW with debug logging will produce a lot of error messages if the 
PFCP requests are not answered by VPP.

If you've followed the setup procedure above, the log level should 
be `debug` (see the "logger" section of the ergw-c-node.config).

##### VPP Session Status

On the VPP CLI, the session status can be checked with 
`show gtp-up sessions`
