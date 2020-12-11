#!/bin/bash

ERL_AFLAGS="+C multi_time_warp" \
	rebar3 shell \
		--setcookie secret \
		--sname "ergw-c-node-$1" \
		--config "priv/dev-$1.config" \
		--apps ergw $@
