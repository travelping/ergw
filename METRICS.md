erGW metrics
============

erGW uses exometer core to implement various operation metrics.

The following metrics exist:

| Metric                                                               | Type      |
| -------------------------------------------------------------------- | --------- |
| path.\<SocketName\>.\<PeerIP\>.contexts                              | gauge     |
| path.\<SocketName\>.\<PeerIP\>.rtt.v1.\<GTPv1-C-MessageName\>        | histogram |
| path.\<SocketName\>.\<PeerIP\>.rtt.v2.\<GTPv2-C-MessageName\>        | histogram |
| path.\<SocketName\>.\<PeerIP\>.rx.v1.create\_pdp\_context\_request   | counter   |
| path.\<SocketName\>.\<PeerIP\>.tx.v1.create\_pdp\_context\_response  | counter   |
| path.\<SocketName\>.\<PeerIP\>.rx.v1.echo_request                    | counter   |
| path.\<SocketName\>.\<PeerIP\>.rx.v1.echo\_response                  | counter   |
| path.\<SocketName\>.\<PeerIP\>.tx.v1.echo\_request                   | counter   |
| path.\<SocketName\>.\<PeerIP\>.tx.v1.echo\_response                  | counter   |
| socket.gtp-c.\<SocketName\>.rx.v1.\<GTPv1-C-MessageName\>.count      | counter   |
| socket.gtp-c.\<SocketName\>.rx.v1.\<GTPv1-C-MessageName\>.duplicate  | counter   |
| socket.gtp-c.\<SocketName\>.tx.v1.\<GTPv1-C-MessageName\>.count      | counter   |
| socket.gtp-c.\<SocketName\>.tx.v1.\<GTPv1-C-MessageName\>.timeout    | counter   |
| socket.gtp-c.\<SocketName\>.tx.v1.\<GTPv1-C-MessageName\>.retransmit | counter   |
| socket.gtp-c.\<SocketName\>.rr.v1.\<GTPv1-C-MessageName\>.count      | counter   |
| socket.gtp-c.\<SocketName\>.rx.v2.\<GTPv2-C-MessageName\>.count      | counter   |
| socket.gtp-c.\<SocketName\>.rx.v2.\<GTPv2-C-MessageName\>.duplicate  | counter   |
| socket.gtp-c.\<SocketName\>.tx.v2.\<GTPv2-C-MessageName\>.count      | counter   |
| socket.gtp-c.\<SocketName\>.tx.v2.\<GTPv2-C-MessageName\>.timeout    | counter   |
| socket.gtp-c.\<SocketName\>.tx.v2.\<GTPv2-C-MessageName\>.retransmit | counter   |
| socket.gtp-c.\<SocketName\>.rr.v1.\<GTPv2-C-MessageName\>.count      | counter   |
| socket.gtp-c.\<SocketName\>.pt.v1.\<GTPv1-C-MessageName\>            | histogram |
| socket.gtp-c.\<SocketName\>.pt.v2.\<GTPv2-C-MessageName\>            | histogram |

\<SocketName\> is taken from the configuration and PeerIP is the IP address of
the peer GSN.

The path `rtt` is the round trip time histogram for each request/response
message pair.

The `tx` and `rx` metrics count the number of message of a given type
transmitted and received. The `rr` metric count the number of message processed
in GTP redirector mode. The `timeout` counter exists only for requests that 
require a response.

The `pt` metrics are a histogram of the total processing time for the last
incoming message of that type.

All timing values in the histograms are in microseconds (µs).

Counters for the following GTPv1-C Messages types exist:

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

Counters for the following GTPv2-C Messages types exist:

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

If the HTTP API has been enable the metrics can be read at `/metrics`.
Stepping into the result is also possible, e.g.:

    curl -X GET "http://localhost:8080/metrics/socket/gtp-c/irx/rx/v1" -H  "accept: application/json"

Also, erGW can provide metrics in Prometheus format:

    curl -X GET "http://localhost:8080/metrics" -H  "accept: text/plain;version=0.0.4"

or more specific:

    curl -X GET "http://localhost:8080/metrics/socket/" -H  "accept: text/plain;version=0.0.4"
    # TYPE socket_gtp_c_irx_tx_v2_mbms_session_start_response_retransmit gauge
    socket_gtp_c_irx_tx_v2_mbms_session_start_response_retransmit 0

    # TYPE socket_gtp_c_irx_tx_v2_mbms_session_start_response_count gauge
    socket_gtp_c_irx_tx_v2_mbms_session_start_response_count 0

Please read Prometheus [Metric names and labels](https://prometheus.io/docs/concepts/data_model/#metric-names-and-labels)
that means all '.' and '-' in metric names which presented above will be replaced by '_'.
