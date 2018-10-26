#!/bin/bash

#
# capsh from libcap2 git master (newer that 2.25) is needed
#

cmd="ERL_AFLAGS=\"+C multi_time_warp\" rebar3 shell --setcookie secret --sname ergw-c-node --apps ergw $@"

sudo capsh --caps="cap_net_raw,cap_sys_admin+eip cap_setpcap,cap_setuid,cap_setgid+ep" --keep=1 --user=$USER --addamb=cap_net_raw,cap_sys_admin -- -c "$cmd"
