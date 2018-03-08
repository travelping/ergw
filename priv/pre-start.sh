#!/bin/sh

ifup() {
    /sbin/ip link add $1 type vrf table $2
    /sbin/ip link set dev $1 up
    /sbin/ip rule add oif $1 table $2
    /sbin/ip rule add iif $1 table $2

    /sbin/ip link set dev $3 master $1
    /sbin/ip link set dev $3 up
    /sbin/ip addr flush dev $3
    /sbin/ip addr add $4 dev $3
    /sbin/ip route add table $2 default via $5
}


ifup grx 10 ens224 172.20.16.90/24 172.20.16.1
/sbin/ip token set ::10:00:00:5A dev ens224
ifup proxy 20 ens256 172.20.16.91/24 172.20.16.1
/sbin/ip token set ::10:00:00:5B dev ens256

/sbin/ip link add link ens224 name grxdp type macvlan mode bridge
/sbin/ip link set grxdp address 3a:07:c5:80:6e:6f up
/sbin/ip link add link ens256 name grxproxy type macvlan mode bridge
/sbin/ip link set grxproxy address 46:d3:10:f1:04:4b up

exit 0
