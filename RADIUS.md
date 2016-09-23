List of RADIUS attributes
=========================

See [3GPP TS 29.061](http://www.etsi.org/deliver/etsi_ts/129000_129099/129061/13.04.00_60/ts_129061v130400p.pdf) for a complete description of RADIUS of Gi/SGi

| Attr Id | Attribute Name                   |  Access-Request  |  Access-Accept   |
| ------- | -------------------------------- |:----------------:|:----------------:|
| 1       | User-Name                        |        X         |        O         |
| 2       | User-Password                    |        C         |        -         |
| 60      | CHAP-Challenge                   |        C         |        -         |
| 3       | CHAP-Password                    |        C         |        -         |
| 4       | NAS-IP-Address                   |        X         |        -         |
| 32      | NAS-Identifier                   |        X         |        -         |
| 6       | Service-Type                     |      Framed      |      Framed      |
| 7       | Framed-Protocol                  | GPRS-PDP-Context | GPRS-PDP-Context |
| 25      | Class                            |        -         |        O         |
| 30      | Called-Station-Id                |        X         |        -         |
| 31      | Calling-Station-Id               |        X         |        -         |
| 61      | NAS-Port-Type                    |        X         |        -         |
| 26/311  | MS- Primary-DNS-Server           |        -         |        O         |
| 26/311  | MS-Secondary-DNS-Server          |        -         |        O         |
| 26/311  | MS-Primary-NBNS-Server           |        -         |        O         |
| 26/311  | MS-Secondary-NBNS-Server         |        -         |        O         |
| 3GPP 1  | 3GPP-IMSI                        |        C         |        -         |
| 3GPP 3  | 3GPP-PDP-Type                    |        C         |        -         |
| 3GPP 5  | 3GPP-GPRS-Negotiated-QoS-Profile |        C         |        -         |
| 3GPP 6  | 3GPP-SGSN-Address                |        C         |        -         |
| 3GPP 7  | 3GPP-GGSN-Address                |        C         |        -         |
| 3GPP 8  | 3GPP-IMSI-MCC-MNC                |        C         |        -         |
| 3GPP 10 | 3GPP-NSAPI                       |        C         |        -         |
| 3GPP 12 | 3GPP-Selection-Mode              |        C         |        -         |
| 3GPP 13 | 3GPP-Charging-Characteristics    |        C         |        -         |
| 3GPP 18 | 3GPP-SGSN-MCC-MNC                |        C         |        -         |
| 3GPP 20 | 3GPP-IMEISV                      |        C         |        -         |
| 3GPP 21 | 3GPP-RAT-Type                    |        C         |        -         |
| 3GPP 22 | 3GPP-User-Location-Info          |        C         |        -         |
| 3GPP 23 | 3GPP-MS-TimeZone                 |        C         |        -         |

For the Access-Request and Access-Accept column the follow applies:

* X: always present in requests
* O: optional in responses
* C: conditional in requests
* -: ignored if present

