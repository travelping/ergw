#!/bin/sh

base=$PWD

echo "Waiting for VPP...."

until ping -c1 172.20.21.2 > /dev/null  2>&1 ; do :; done

echo "... VPP is reachable."

cd /usr/src/erlang/ergw
ERL_AFLAGS="+C multi_time_warp" \
  rebar3 shell \
	  --config $base/tmux/ergw.config \
	  --apps ergw
