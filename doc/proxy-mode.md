Proxy Mode
==========

The GTP proxy handler pgw_s5s8_proxy and ggsn_gn_proxy forward incomming requests
to destination PGWs/GGSNs and remap TEIDs as required.

Forward PGW/GGSN selection
--------------------------

The destination gateway is select based on the APN. A node selection query
(either DNS or static from config) is performed for APN. The mechanism follows
3GPP TS 29.303 Section 5.1.1.

Example:

1. split the incomming APN into APN-NI and APN-OI, if no APN-OI is present,
   the a APN-OI is contructed from the MCC and MNC configure for the proxy.

   Incomming: apn.example.com.mnc123.mcc001.gprs:
   APN-NI: apn.example.com
   APN-OI: mnc042.mcc001.grps
   MNC:  42
   MCC: 001

2. translate into EPC APN FQDN for DNS lookup:

   APN-FQDN: apn.example.com.apn.epc.mnc042.mcc001.3gppnetwork.org

3. perform DNS S-NAPTR procedure on APN-FQDN (see 3GPP TS 29.303, Appendix C).

4. if step 3. did not return a candidate, perform another S-NAPTR procedure,
   replace APN-NI with "_default".

   APN-FQDN: _default.apn.epc.mnc042.mcc001.3gppnetwork.org

   Note: "_default" is not a valid DNS label, this step is therefore only relevant
		 when a datasource (e.g. static) is used that is not DNS. For DNS the same
		 effect can be achived by using a wildcard label ("*") in the DNS zone.


Note: GTPv2 specification require that the APN always contain a Operator Identity (OI).
	  Since the retry _default APN is derived from the APN-OI of the incomming request,
	  a universal default next PGW (a PGW that handles traffic no matter what the OI is)
	  can not be specified.
