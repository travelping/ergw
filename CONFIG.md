erGW configuration (WiP)
========================

Concepts
--------

### VRF's ###

A VRF (Virtual Routing Function) encapsulates a IP routing domin. All devices
in a VRF get their IP's from a common pool and are in the same routing domain.

Configuration settings per VRF:

* IP pool
* IP routes (from the GGSN to MS)
* default DNS server
* default Wins (NBNS) server

The AAA provider can override the DNS and NBNS server settings and assign
IP addresses. The assigned IP address has to be reachable through the routes.

### APN ###

3GPP TS 23.003, Section 9 defines an APN in terms of selecting a GGSN:

> In the GPRS backbone, an Access Point Name (APN) is a reference to a GGSN. To
> support inter-PLMN roaming, the internal GPRS DNS functionality is used to
> translate the APN into the IP address of the GGSN.

However, once a GTP tunnel request has been reached a erGW, the APN message
element is just a selector to choose the final settings for a given tunnel.

### GTP routes ###

GTP routes are used to map an incomming GTP tunnel/bearer request to a AAA
provider. The outcome of the AAA decission then connects the GTP tunnel to
a VRF. If the AAA provider does not return a VRF selection, the default
VRF for a give APN is used.

The dummy (mock) AAA provider accepts all session and always connects to the
default VRF of a APN.

### GTP socket ###

A GTP socket is a GTP-C or GTP-U IP endpoint.

### GTP Redirector ###

The redirection mode means that a GTP request will be transferred to a GTP backed 
with saving source IP and port. For the GTP backend, such request looks like it 
came from particular GTP client directly. See the GTP socket configuration example 
for more information.

Pictures
--------

Some picture putting the above description into context would be nice.

Socket to VRF wiring:

![Alt text][socket-wiring]

[socket-wiring]: priv/ConfigMsgRouting.jpeg "Socket to VRF connection"

Configuration
-------------

The configuration is processed through the [Erlang setup](https://github.com/uwiger/setup/blob/master/doc/setup.md) application. Therefor variable expansion as described there is available.

### PLMN Id ###

     {plmn_id, {<<"001">>, <<"01">>}

The PLMN identifier is the MCC and MNC of the served network.

* plmn_id: `{plmn_id, {MCC :: binary(), MNC :: binary()}}`

### GTP socket ###

    {sockets, [
        {irx, [
            {type, 'gtp-c'},
                {ip,  {172,20,16,89}},
                {netdev, "grx"},
                freebind
                {netns, "/var/run/netns/grx"}
        ]},
        {grx, [
            {type, 'gtp-u'},
            {node, 'gtp-u-node@vlx159-tpmd'},
            {name, 'grx'}
        ]},
        {rrx, [
            {type, 'gtp-c'},
            {ip, {192, 168, 1, 100}},
            {reuseaddr, true},
            {redirector, [
                {keep_alive_timeout, 60000},
                {retransmit_timeout, 10000},
                {lb_type, random},
                {nodes, [
                    {node, [
                        {name, <<"gsn">>},
                        {keep_alive_version, v1},
                        {address, {192, 168, 1, 16}}
                    ]}
                ]},
                {rules, [
                    {rule, [
                        {conditions, [
                            {sgsn_ip, {192, 255, 127, 127}},
                            {version, [v1, v2]}
                        ]},
                        {nodes, [<<"gsn">>]}
                    ]}
                ]}
            ]} 
        ]}
    ]}

Defines a list of named sockets. The format is (in Erlang type syntax):

* sockets: `{sockets, [socket_definition()]}`
* socket_definition: `{socket_name(), [socket_options()]}`
* socket_name: `atom()`
* gtp_version: `v1 | v2`
* socket_options:

  - `{type, 'gtp-c' | 'gtp-u'}`

    the type of the socket

  - `{ip, inet:ip_address()}`

    IP address to bind to, the wildcard IP if allowed

  - `{netdev, string()}`

    network device to bind this socket to (use for VRF-Lite setups)

  - `freebind`

    bind to an IP that does not yet and may never exists

  - `{netns, string()}`

    open the socket in the give network namespace

  - `{node, atom()}`

    name of a remote node where the GTP-U datapath resides

  - `{name, socket_name()}`

    name the datapath on a remote node

  - `{redirector, redirector_options()}`

    if defined socket works in redirector mode

* redirector_options:

  - `{keep_alive_timeout, non_neg_integer()}`

    (ms) how often redirector socket will send echo_request to nodes to keep connection up

  - `{retransmit_timeout, non_neg_integer()}`

    (ms) how long request will be memorized to use previously selected node

  - `{lb_type, random}`

    how to select node from list of nodes. now only `random` is supported

  - `{nodes, [node()]}`
  
    list of nodes to redirect requests

  - `{rules, [rule()]}`
  
    list of rules to make decision about redirecting of the requests

* node: `{node, [node_definition()]}`

* rule: `{rule, [rule_definition()]}`

* node_definition:

  - `{name, binary()}`

    name will be used to describe nodes to make routing in `rules` section

  - `{keep_alive_version, gtp_version()}`

    version to build echo_request

  - `{address, inet:ip_address())}`

    IP addres of node. Only ipv4 for now

* rule_definition:

  - `{conditions, [condition()]}`

    list of conditions to match rule

  - `{nodes, [binary()]}`

    list of node's names to redirect request. Node will be selected with using `lb_type` logic

* condition:

  - `{sgsn_ip, inet:ip_address())}`

    SGSN IP

  - `{imsi, binary())}`

    IMSI

  - `{version, [gtp_version()]}`

    GTP version

### Handlers ###

    {handlers,
      [{gn, [{handler, ggsn_gn},
             {protocol, gn},
             {sockets, [irx]},
             {data_paths, [grx]},
             {aaa, [{'Username',
                     [{default, ['IMSI', <<"@">>, 'APN']}]}]},

Defines a list of handler's, what reference point that handler is serving, on
which sockets, the AAA provider and the defaults AAA attribute mapping.

* handlers: `{handlers, [handler_definition()]}`
* handler_definition: `{handler_name(), handler_options}`
* handler_name: `atom()`
* handler_options:

  - `{handler, atom()}`

    the protocol handler module, ergw ships with handlers for Gn, S5/S8 and S2a

  - `{protocol, atom()}`

    the 3GPP interface that is served by the handler.
	Versions before 1.12 did derive the protocol from the handler_name. For backward
	compatibility this option can be omitted it the handler name is 'gn' or 's5s8'.

  - `{sockets, [socket_name()]}`

    the GTP-C sockets that are served by this handler

  - `{data_paths, [socket_name()]}`

    the GTP-U data paths that are served by this handler

  - `{aaa, [aaa_options()]}`

    mapping rules to derive defaults for some fields before passing them on
    to the AAA provider

* aaa_options:

  - `{'AAA-Application-Id', atom()}`
  - `{'Username', mapping_spec()}`
  - `{'Password', mapping_spec()}`


### VRF's ###

     {vrfs,
      [{upstream, [{pools,  [{{10, 180, 0, 1}, {10, 180, 255, 254}, 32},
                             {{16#8001, 0, 0, 0, 0, 0, 0, 0}, {16#8001, 0, 0, 16#FFFF, 0, 0, 0, 0}, 64}
                            ]},
                   {'MS-Primary-DNS-Server', {8,8,8,8}},
                   {'MS-Secondary-DNS-Server', {8,8,4,4}},
                   {'MS-Primary-NBNS-Server', {127,0,0,1}},
                   {'MS-Secondary-NBNS-Server', {127,0,0,1}}
                  ]}
      ]}

Defines the IP routing domains and their defaults.

* vrfs: `{vrfs, [vrf_definition()]}`
* vrf_definition: `{vrf_name(), [vrf_options() | session_defaults()]}`
* vrf_name: `atom()`
* vrf_options:

  - `{pools, [vrf_pool()]}`

* vrf_pool: `{Start :: ip_address(), End :: ip_address()}`

  defines a range of IP addresses (Start to End) for allocation to clients

### APN's ###

     {apns,
      [{[<<"tpip">>, <<"net">>], [{vrf, upstream} | session_defaults()]}]},

Routes provided default mappings of APN's into VRF's. A route is applied after
the AAA provider if it did not return a VRF destination for the request.
At the very minimum, the catch all APN '_' needs to be configured.

* routes: `{apns, [route_definition()]}`
* route_definition: `{apn_name(), [apn_options()]}`
* apn_name: `atom()`
* apn_options:

  - `{vrf, vrf_name()}`

Session Options
---------------

Session defaults can be defined at the VRF and APN level. AAA providers
can overwrite those defaults. Options defined at an APN will overwrite
VRF options and AAA providers will overwrite both.

* session_defaults:

  - `{'MS-Primary-DNS-Server', inet:ip4_address()}`

  - `{'MS-Secondary-DNS-Server', inet:ip4_address()}`

  - `{'MS-Primary-NBNS-Server', inet:ip4_address()}`

  - `{'MS-Secondary-NBNS-Server', inet:ip4_address()}`

Handler Configuration
---------------------

Protocol handlers can extend the handler configuration with use case specific
options.

### ggsn_gn_proxy ###

    {handlers,
     [{gn, [{handler, ggsn_gn_proxy},
            {sockets, [irx]},
            {data_paths, [grx]},
            {proxy_sockets, ['irx-1']},
            {proxy_data_paths, ['grx-1']},
            {ggns, {127, 0, 0, 1}},
            {contexts, [{<<"ams">>, [{proxy_sockets, ['irx-ams']},
                                     {proxy_data_paths, ['grx-ams']}]},
                        {<<"us">>,  [{proxy_sockets, ['irx-us']},
                                     {proxy_data_paths, ['grx-us']}]}]}
            ]}]}

* handler_options:

  - `{proxy_sockets, [socket_name()]}`

    the default GTP-C socket for forwarding requests

  - `{data_paths, [socket_name()]}`

    the default GTP-U data paths for forwarding requests

  - `{ggsn, inet:ip_address()}`

    the default GGSN IP address

  - `{contexts, [context()]}`

    list of forwarding context. Forwarding can be selected by the proxy
    data source

* context: `{context_name(), [{proxy_sockets, [socket_name()]}, {data_paths, [socket_name()]}]}`

  a context comprises of proxy GTP-c sockets and proxy GTP-u data paths

  - context_name: `binary()`

    the context name

Operation Modes
---------------

### PGW with co-located GGSN function ###

A PGW can be operated with a co-located GGSN function to support 3GPP TS 23.401
Annex D, Interoperation with Gn/Gp SGSNs.
In this case the PGW handles the Gn/Gp and the S8/S5 protocol. The GTP sockets
can not be shared with an independent GGSN instance.

Sample handler configuration:

    {handlers,
     [{gn, [{handler, pgw_s5s8},
            {sockets, [irx]},
            {data_paths, [grx]}
           ]},
      {s5s8, [{handler, pgw_s5s8},
              {sockets, [irx]},
              {data_paths, [grx]}
             ]}]}

NAPTR records for APN's on such a gateway should use "Service Parameters" of
"x-3gpp-pgw:x-s5-gtp", "x-3gpp-pgw:x-s8-gtp", "x-3gpp-pgw:x-gn" and
"x-3gpp-pgw:x-gp"

### PGW ###

Sample handler configuration for a S5/S8 only PGW

    {handlers,
     [{s5s8, [{handler, pgw_s5s8},
              {sockets, [irx]},
              {data_paths, [grx]}
             ]}]}

NAPTR records for APN's on such a gateway should use "Service Parameters" of
"x-3gpp-pgw:x-s5-gtp" and "x-3gpp-pgw:x-s8-gtp"

### GGSN ###

Sample handler configuration for Gn/Gp only GGSN

    {handlers,
     [{gn, [{handler, ggsn_gn},
            {sockets, [irx]},
            {data_paths, [grx]}
           ]}]}

NAPTR records for APN's on such a gateway should use "Service Parameters" of
"x-3gpp-ggsn:x-gn" and "x-3gpp-ggsn:x-gp"

### PGW and GGSN sharing the same GTP port ###

NOTE: 3GPP TS 23.401 Annex D, Interoperation with Gn/Gp SGSNs is not supported
      in this configuration.

Sample handler configuration:

    {handlers,
     [{gn, [{handler, ggsn_gn},
            {sockets, [irx]},
            {data_paths, [grx]}
           ]},
      {s5s8, [{handler, pgw_s5s8},
              {sockets, [irx]},
              {data_paths, [grx]}
             ]}]}

NAPTR records for APN's on such a gateway should use "Service Parameters" of
"x-3gpp-ggsn:x-gn", "x-3gpp-ggsn:x-gp", "x-3gpp-pgw:x-s5-gtp" and
"x-3gpp-pgw:x-s8-gtp". "Service Parameters" of "x-3gpp-pgw:x-gn" and
"x-3gpp-pgw:x-gp" **should not** be used.

Rate Limiting
-------------

erGW uses the [Erlang jobs](https://github.com/uwiger/jobs/blob/master/README.md)
to apply rate limiting to all incoming GTP messages.

GTP messages are classified into `create`, `delete` and `other` classes. Each class
has its own rules. Messages exceeding the configured rate are rejected with
`No resources available`.

It is recommended to configure the `delete` class with a counter queuing class that
will limit the delete messages per second but not drop them.

The internal default correspond to this setup:

    {jobs, [{queues,
             [{path_restart,
               [{path_restart, [{standard_counter, 100}]},
                {create, [{standard_rate, 100}, {max_size, 10}]},
                {delete, [{standard_counter, 100}]},
                {other, [{standard_rate, 100}, {max_size, 10}]}
               ]}
             ]}
           ]}
