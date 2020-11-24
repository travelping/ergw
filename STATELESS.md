# NOTES ON CURRENT STATE OF THE `STATELESS` WORK

# HIGH LEVEL DESIGN

Sessions are externalized (load/store) into UDSF as needed.

Store happens after 500ms of *inactivity*. Load as needed.

# DISCOVERED PROBLEMS

Some (in fact many) things still need state. 5G has much less state due to the changed split
of functions. In 4G (and older) that is not as easy to achive.

## RESOURCE CLEANUP

Resorce cleanup (TEID, IPs, counters) used to happen by linking to or monitoring the process
that requested a resource. Externalizing the session state also terminates the session process
(otherwise what would be the point of externalizing in the first place).

Rersource now need to be explicitly released when the session is terminated. For some resources
that is simple (e.g. TEID are released when the UDSF entries is deleted), for others is more
complex.

### IPs

* need to be deleted explicetly
* maitaining a pool in DB is not trivial
* when DHCP is used, something needs to run the timers for renewal

### TEIDs

Alloc a random TEID and check for collision on UDSF. Cleanup happens when the UDSF entry is
removed.

* potential for race condition on insert

## PATH STATUS

In order to run path maintenance (GTP echo) and terminate all context with a specific peer,
a binding of contexts/sessions and peer need to be maintained (again monitoring Erlang
processes no longer works)

* again, explicit resource cleanup
* all context on a peer need to be retrieved from UDSF to delete them when that peer is
  considered dead/restarted (potential load problem)
* open question: how does path maintenance work when a clustered PGW/GGSN is used? Which
  instance run path maintenance and how does it know how many contexts are alive on a given
  path

## TIMERS

Some per session things need timers and something needs to handle those even when the session
is swapped out:

* GTP-C idle timeout
* quota validity time (can be implemented with UPF VTIME feature, but that feature is optional)

## UPG SMF-SET SUPPORT

This is needed for restoring a session on a different C node

## RACE CONDITIONS

* 500ms of detecting session idleness is not enough, retransmitted GTP message may arrive later
  and might need to be handled (especially in the proxy case)
