erGW - 3GPP GGSN and PDN-GW in Erlang
=====================================
[![Build Status][travis badge]][travis]
[![Coverage Status][coveralls badge]][coveralls]
[![Erlang Versions][erlang version badge]][travis]

This is a 3GPP GGSN and PDN-GW implemented in Erlang. It strives to eventually support all the functionality as defined by [3GPP TS 23.002](http://www.3gpp.org/dynareport/23002.htm) Section 4.1.3.1 for the GGSN and Section 4.1.4.2.2 for the PDN-GW.

IMPLEMENTED FEATURES
--------------------

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

EXPERIMENTAL FEATURES
---------------------

Experimental features may change or be removed at any moment. Configuration settings
for them are not guaranteed to work across versions. Check [CONFIG.md](CONFIG.md) and
[NEWS.md](NEWS.md) on version upgrades.

 * rate limiting, defaults to 100 requests/second
 * metrics, see [METRICS.md](METRICS.md)

USER PLANE
----------

erGW usese the 3GPP control and user plane separation of EPC nodes architecture as layed out
in [3GPP TS 23.214](http://www.3gpp.org/dynareport/23244.htm) and [3GPP TS 29.244](http://www.3gpp.org/dynareport/29244.htm).

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

*The minimum supported Erlang version is 20.1.*

Using rebar:

    # rebar3 compile

RUNNING
-------

A erGW installation needs a user plane provider to handle the GTP-U path. This instance can be installed on the same host or a different host.

A suitable user plane node based on [VPP](https://wiki.fd.io/view/VPP) can be found at [VPP-UFP](https://github.com/travelping/vpp/tree/feature/upf).

erGW can be started with the normal Erlang command line tools, e.g.:

```
erl -setcookie secret -sname ergw -config ergw.config
Erlang/OTP 19 [erts-8.0.3] [source] [64-bit] [async-threads:10] [kernel-poll:false]

Eshell V8.0.3  (abort with ^G)
(ergw@localhost)1> application:ensure_all_started(ergw).
```

This requires a suitable ergw.config, e.g.:

```erlang
%-*-Erlang-*-
[{setup, [{data_dir, "/var/lib/ergw"},
	  {log_dir,  "/var/log/gtp-c-node"}				%% NOTE: lager is not using this
	 ]},

 {ergw, [{'$setup_vars',
	  [{"ORIGIN", {value, "epc.mnc001.mcc001.3gppnetwork.org"}}]},
	 {plmn_id, {<<"001">>, <<"01">>}},

	 {http_api,
	  [{port, 8080},
	   {ip, {0,0,0,0}}
	  ]},

	 {sockets,
	  [{'cp-socket',
	    [{type, 'gtp-u'},
	     {vrf, cp},
	     {ip,  {127,0,0,1}},
	     freebind,
	     {reuseaddr, true}
	    ]},
	   {irx, [{type, 'gtp-c'},
		  {vrf, epc},
		  {ip,  {127,0,0,1}},
		  {reuseaddr, true}
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

	 {sx_socket,
	  [{node, 'ergw'},
	   {name, 'ergw'},
	   {socket, 'cp-socket'},
	   {ip,  {127,0,0,1}},
	   freebind
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

%% {exometer_core, [{reporters, [{exometer_report_netdata, []}]}]},

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
	  {error_logger_hwm, 5000},
	  {handlers, [
		      {lager_console_backend, [{level, debug}]},
		      {lager_file_backend, [{file, "error.log"}, {level, error}]},
		      {lager_file_backend, [{file, "console.log"}, {level, debug}]}
		     ]}
	 ]}
].
```

The configuration is documented in [CONFIG.md](CONFIG.md)

This process can be simplified by using release application [ergw-gtp-c-node](https://github.com/travelping/ergw-gtp-c-node).
A sample config that only requires minimal adjustment for IP's, hostnames and interfaces can be found in `ergw-gtp-c-node/config/ergw-gtp-c-node.config`.
See [Installing on Ubuntu 16.04](https://github.com/travelping/ergw-gtp-c-node#installing-on-ubuntu-1604) section for futher information.

<!-- Badges -->
[travis]: https://travis-ci.org/travelping/ergw
[travis badge]: https://img.shields.io/travis/travelping/ergw/master.svg?style=flat-square
[coveralls]: https://coveralls.io/github/travelping/ergw
[coveralls badge]: https://img.shields.io/coveralls/travelping/ergw/master.svg?style=flat-square
[erlang version badge]: https://img.shields.io/badge/erlang-R20.1%20to%2021.0-blue.svg?style=flat-square
