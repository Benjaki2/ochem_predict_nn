#!/usr/bin/env sh
# Start mongo in this container (preloaded with data), run the python script, then kill mongo

set -e

mongod --fork --dbpath /data/db-chem --logpath /var/log/mongodb.log

python "$@"
