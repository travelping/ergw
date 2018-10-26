#!/bin/sh
# copy of configuration files
RELPATH=$(find /opt/ergw-c-node/releases/ -mindepth 1 -maxdepth 1 -type d)
[ -f /config/ergw-c-node/sys.config ] && cp /config/ergw-c-node/sys.config $RELPATH/sys.config
[ -f /config/ergw-c-node/vm.args ] && cp /config/ergw-c-node/vm.args $RELPATH/vm.args

exec "$@"
