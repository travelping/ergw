erGW metrics
============

erGW uses prometheus.erl to implement various operation metrics.

The following metrics exist:



| Name                                            | Type      | Labels                                         | Metric                                                   |
| ----------------------------------------------- | --------- | -----------------------------------------------| ---------------------------------------------------------|
| gtp\_path\_messages\_processed\_total           | counter   | name, remote, direction, version, type         | Total number of GTP message processed on path            |
| gtp\_path\_messages\_duplicates\_total          | counter   | name, remote, version, type                    | Total number of duplicate GTP message received on path   |
| gtp\_path\_messages\_retransmits\_total         | counter   | name, remote, version, type                    | Total number of retransmited GTP message on path         |
| gtp\_path\_messages\_timeouts\_total            | counter   | name, remote, version, type                    | Total number of timed out GTP message on path            |
| gtp\_path\_messages\_replies\_total             | counter   | name, remote, direction, version, type, result | Total number of reply GTP message on path                |
| gtp\_path\_rtt\_milliseconds                    | histogram | name, ip, version, type                        | GTP path round trip time                                 |
| gtp\_path\_contexts\_total                      | gauge     | name, ip, version                              | Total number of GTP contexts on path                     |
| gtp\_c\_socket\_messages\_processed\_total      | counter   | name, direction, version, type                 | Total number of GTP message processed on socket          |
| gtp\_c\_socket\_messages\_duplicates\_total     | counter   | name, version, type                            | Total number of duplicate GTP message received on socket |
| gtp\_c\_socket\_messages\_retransmits\_total    | counter   | name, version, type                            | Total number of retransmited GTP message on socket       |
| gtp\_c\_socket\_messages\_timeouts\_total       | counter   | name, version, type                            | Total number of timed out GTP message on socket          |
| gtp\_c\_socket\_messages\_replies\_total        | counter   | name, direction, version, type, result         | Total number of reply GTP message on socket              |
| gtp\_c\_socket\_errors\_total                   | counter   | name, direction, error                         | Total number of GTP errors on socket                     |
| gtp\_c\_socket\_request\_duration\_microseconds | histogram | name, version, type                            | GTP Request execution time.                              |
| gtp\_u\_socket\_messages\_processed\_total      | counter   | name, direction, version, type                 | Total number of GTP message processed on socket          |
| ergw\_local\_pool\_free                         | gauge     | name, type, id                                 | Number of free IPs                                       |
| ergw\_local\_pool\_used                         | gauge     | name, type, id                                 | Number of used IPs                                       |
| termination\_cause\_total                       | counter   | name, type                                     | Total number of termination causes                       |

The label `name` is is taken from the configuration of the GTP socket and PeerIP is the IP address of
the peer GSN.

The path `rtt` is the round trip time histogram for each request/response
message pair.

The label `direction` has the value `tx` or `rx` for transmitted or received.
The `timeout` counter exists only for requests that require a response.

The `request_duration` metric is a histogram of the total processing time for the last
incoming message of that type.

The label `type` is the GTP Messages types. For GTPv1-C messages the following types exist:

 * create\_mbms\_context\_request
 * create\_mbms\_context\_response
 * create\_pdp\_context\_request
 * create\_pdp\_context\_response
 * data\_record\_transfer\_request
 * data\_record\_transfer\_response
 * delete\_mbms\_context\_request
 * delete\_mbms\_context\_response
 * delete\_pdp\_context\_request
 * delete\_pdp\_context\_response
 * echo\_request
 * echo\_response
 * error\_indication
 * failure\_report\_request
 * failure\_report\_response
 * forward\_relocation\_complete
 * forward\_relocation\_complete\_acknowledge
 * forward\_relocation\_request
 * forward\_relocation\_response
 * forward\_srns\_context
 * forward\_srns\_context\_acknowledge
 * identification\_request
 * identification\_response
 * initiate\_pdp\_context\_activation\_request
 * initiate\_pdp\_context\_activation\_response
 * mbms\_de\_registration\_request
 * mbms\_de\_registration\_response
 * mbms\_notification\_reject\_request
 * mbms\_notification\_reject\_response
 * mbms\_notification\_request
 * mbms\_notification\_response
 * mbms\_registration\_request
 * mbms\_registration\_response
 * mbms\_session\_start\_request
 * mbms\_session\_start\_response
 * mbms\_session\_stop\_request
 * mbms\_session\_stop\_response
 * mbms\_session\_update\_request
 * mbms\_session\_update\_response
 * ms\_info\_change\_notification\_request
 * ms\_info\_change\_notification\_response
 * node\_alive\_request
 * node\_alive\_response
 * note\_ms\_gprs\_present\_request
 * note\_ms\_gprs\_present\_response
 * pdu\_notification\_reject\_request
 * pdu\_notification\_reject\_response
 * pdu\_notification\_request
 * pdu\_notification\_response
 * ran\_information\_relay
 * redirection\_request
 * redirection\_response
 * relocation\_cancel\_request
 * relocation\_cancel\_response
 * send\_routeing\_information\_for\_gprs\_request
 * send\_routeing\_information\_for\_gprs\_response
 * sgsn\_context\_acknowledge
 * sgsn\_context\_request
 * sgsn\_context\_response
 * supported\_extension\_headers\_notification
 * unsupported
 * update\_mbms\_context\_request
 * update\_mbms\_context\_response
 * update\_pdp\_context\_request
 * update\_pdp\_context\_response
 * version\_not\_supported

For GTPv2-C messages the following types exist:

 * alert\_mme\_acknowledge
 * alert\_mme\_notification
 * bearer\_resource\_command
 * bearer\_resource\_failure\_indication
 * change\_notification\_request
 * change\_notification\_response
 * configuration\_transfer\_tunnel
 * context\_acknowledge
 * context\_request
 * context\_response
 * create\_bearer\_request
 * create\_bearer\_response
 * create\_forwarding\_tunnel\_request
 * create\_forwarding\_tunnel\_response
 * create\_indirect\_data\_forwarding\_tunnel\_request
 * create\_indirect\_data\_forwarding\_tunnel\_response
 * create\_session\_request
 * create\_session\_response
 * cs\_paging\_indication
 * delete\_bearer\_command
 * delete\_bearer\_failure\_indication
 * delete\_bearer\_request
 * delete\_bearer\_response
 * delete\_indirect\_data\_forwarding\_tunnel\_request
 * delete\_indirect\_data\_forwarding\_tunnel\_response
 * delete\_pdn\_connection\_set\_request
 * delete\_pdn\_connection\_set\_response
 * delete\_session\_request
 * delete\_session\_response
 * detach\_acknowledge
 * detach\_notification
 * downlink\_data\_notification
 * downlink\_data\_notification\_acknowledge
 * downlink\_data\_notification\_failure\_indication
 * echo\_request
 * echo\_response
 * forward\_access\_context\_acknowledge
 * forward\_access\_context\_notification
 * forward\_relocation\_complete\_acknowledge
 * forward\_relocation\_complete\_notification
 * forward\_relocation\_request
 * forward\_relocation\_response
 * identification\_request
 * identification\_response
 * isr\_status\_indication
 * mbms\_session\_start\_request
 * mbms\_session\_start\_response
 * mbms\_session\_stop\_request
 * mbms\_session\_stop\_response
 * mbms\_session\_update\_request
 * mbms\_session\_update\_response
 * modify\_bearer\_command
 * modify\_bearer\_failure\_indication
 * modify\_bearer\_request
 * modify\_bearer\_response
 * pgw\_downlink\_triggering\_acknowledge
 * pgw\_downlink\_triggering\_notification
 * pgw\_restart\_notification
 * pgw\_restart\_notification\_acknowledge
 * ran\_information\_relay
 * release\_access\_bearers\_request
 * release\_access\_bearers\_response
 * relocation\_cancel\_request
 * relocation\_cancel\_response
 * resume\_acknowledge
 * resume\_notification
 * stop\_paging\_indication
 * suspend\_acknowledge
 * suspend\_notification
 * trace\_session\_activation
 * trace\_session\_deactivation
 * ue\_activity\_acknowledge
 * ue\_activity\_notification
 * unsupported
 * update\_bearer\_request
 * update\_bearer\_response
 * update\_pdn\_connection\_set\_request
 * update\_pdn\_connection\_set\_response
 * version\_not\_supported

The label `type` is the Termination Causes types. For Termination causes the following types exist:
 * normal
 * administrative
 * link_broken
 * upf_failure
 * remote_failure
 * inactivity_timeout
 * peer_restart

The HTTP API exports the metrics in Prometheus format at `/metrics`:

    curl -X GET "http://localhost:8080/metrics" -H  "accept: text/plain;version=0.0.4"

For further details check the Prometheus documentation on [Metric names and labels](https://prometheus.io/docs/concepts/data_model/#metric-names-and-labels).
