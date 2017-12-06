#!/bin/bash -x
# set -o errexit

echo ">> SEND client_done"
lava-send client_done

echo "<< Wait server_done"
lava-wait server_done

echo "A10"
