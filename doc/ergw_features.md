## Features

### Implemented Features  

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

### Experimental Features
Experimental features may change or be removed at any moment. Configuration settings
for them are not guaranteed to work across versions. Check [CONFIG.md](CONFIG.md) and
[NEWS.md](NEWS.md) on version upgrades.

 * Rate limiting, defaults to 100 requests/second
 * Metrics, see [METRICS.md](METRICS.md)

### Missing Features
The following procedures are assumed/known to be not working:

 * Secondary PDP Context Activation Procedure
 * Secondary PDP Context Activation Procedure using S4

Other shortcomings:

 * QoS parameters are hard-coded
