erGW - 3GPP GGSN/P-GW in Erlang
===============================
[![Build Status](https://travis-ci.org/travelping/ergw.svg?branch=master)](https://travis-ci.org/travelping/ergw)

This is a 3GPP GGSN and PGW implemented in Erlang.

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

```
[
{ergw, [{apns,
	 [{[<<"example">>, <<"com">>], [{protocols, [{gn,   [{handler, ggsn_gn},
							     {sockets, [irx]},
							     {data_paths, [grx]}
							    ]},
						     {s5s8, [{handler, pgw_s5s8},
							     {sockets, [irx]},
							     {data_paths, [grx]}
							    ]},
						     {s2a,  [{handler, pgw_s2a},
							     {sockets, [irx]},
							     {data_paths, [grx]}
							    ]}
						    ]},
					{routes, [{{10, 180, 0, 0}, 16}]},
					{pools,  [{{10, 180, 0, 0}, 16},
						  {{16#8001, 0, 0, 0, 0, 0, 0, 0}, 48}]}
				       ]}
	 ]},

	{sockets,
	 [{irx, [{type, 'gtp-c'},
		 {ip,  {192,0,2,16}},
		 {netdev, "grx"},
		 freebind
		]},
	  {grx, [{type, 'gtp-u'},
		 {node, 'gtp-u-node@localhost'},
		 {name, 'grx'}]}
	 ]},

{ergw_aaa, [
	    %% {ergw_aaa_provider, {ergw_aaa_mock, [{secret, <<"MySecret">>}]}}
	    {ergw_aaa_provider,
	     {ergw_aaa_radius,
	      [{nas_identifier,<<"nas01.example.com">>},
	       {radius_auth_server,{{192,0,2,32},1812,<<"secret">>}},
	       {radius_acct_server,{{192,0,2,32},1813,<<"secret">>}}
	      ]}
	    }
	   ]}
].
```

This process can be simplified by using [enit](https://github.com/travelping/enit). A sample config that only requires minimal adjustment for IP's, hostnames and interfaces can be found in priv/enit/ggsn.
Install those files to / (root) and start with ```enit startfg ergw```.
