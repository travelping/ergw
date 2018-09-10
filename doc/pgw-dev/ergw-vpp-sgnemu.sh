#!/bin/sh

set -x

if [ $(id -u) -ne 0 ]; then
    exec sudo -E "$0" "$@"
fi

cd $(dirname $0)

vrf() {
    ip netns del $1 > /dev/null 2>&1
    ip netns add $1
    ip -n $1 link set dev lo up
}


# create veth pair between network namespaces
# $1 1st netns
# $2 ifname in 1st netns
# $3 2nd netns
# $4 ifname in 1st netns

veth_link() {
    ip link del dev $2 > /dev/null 2>&1
    ip link del dev $4 > /dev/null 2>&1
    ip link add name $2 type veth peer name $4

    ip link set dev $2 up
    test "$1" != "root" && ip link set dev $2 netns $1 up
    ip link set dev $4 up
    test "$3" != "root" && ip link set dev $4 netns $3 up
}

#create namespaces
vrf access
vrf ergw
vrf vpp

# create and configure CP veth pair
veth_link ergw grx-cp access grx-cp-access
ip -n ergw addr add 172.20.20.1/24 dev grx-cp

# create and configure UP veth pair
veth_link vpp grx-up access grx-up-access

# create and configure CP/UP veth pair
veth_link ergw sxb-cp vpp sxb-up
ip -n ergw addr add 172.20.21.1/24 dev sxb-cp

# create and configure host/UP veth pair
veth_link vpp sgi-up root sgi
ip addr add 172.20.22.1/24 dev sgi
ip route add 10.80.0.0/16 via 172.20.22.2

ip -n access link add grx type bridge
ip -n access link set dev grx-cp-access master grx
ip -n access link set dev grx-up-access master grx
ip -n access addr add 172.20.20.150/24 dev grx
ip -n access link set dev grx up

tmux kill-session -C -t pgw-dev
tmux new-session -d -s pgw-dev -n 'PGW DEV' 'cat tmux/run-sgsnemu.txt; ip netns exec access $SHELL'

tmux new-window -t pgw-dev:1 'ip netns exec ergw tmux/ergw.sh; $SHELL'
tmux new-window -t pgw-dev:2 'ip netns exec vpp /usr/src/vpp/build-root/install-vpp_debug-native/vpp/bin/vpp -c tmux/startup.conf; $SHELL'
tmux new-window -t pgw-dev:3 'cat tmux/run-ue.txt; ip netns exec access $SHELL'

tmux select-window -t pgw-dev:0

tmux join-pane -s pgw-dev:1 -t pgw-dev:0
tmux join-pane -s pgw-dev:2 -t pgw-dev:0
tmux join-pane -s pgw-dev:3 -t pgw-dev:0
tmux select-layout -t pgw-dev tiled

tmux -2 attach-session -t pgw-dev
