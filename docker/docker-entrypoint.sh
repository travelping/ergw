#!/bin/sh
# copy of configuration files
RELPATH=$(find /opt/ergw-c-node/releases/ -mindepth 1 -maxdepth 1 -type d)

CONFIG_FILES="sys.config sys.config.src vm.args vm.args.src"
for f in $CONFIG_FILES
do
    [ -f /config/ergw-c-node/$f ] && ln -sf /config/ergw-c-node/$f $RELPATH/$f
done

exec "$@"
