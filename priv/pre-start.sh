#!/bin/sh

ifup() {
    /sbin/ip netns add $1
    /sbin/ip link set dev $2 netns $1
    /sbin/ip -n $1 addr flush dev $2
    /sbin/ip -n $1 link set dev $2 up
    /sbin/ip -n $1 addr add $3 dev $2
    /sbin/ip -n $1 route add default via $4
}

ifup grx ens224 172.20.16.90/24 172.20.16.1
/sbin/ip -n grx addr add 172.20.16.98/24 dev ens224
/sbin/ip -n grx token set ::10:00:00:5A dev ens224
ifup proxy ens256 172.20.16.91/24 172.20.16.1
/sbin/ip -n proxy token set ::10:00:00:5B dev ens256

exit 0
