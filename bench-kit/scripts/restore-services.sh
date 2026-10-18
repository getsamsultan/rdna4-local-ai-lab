#!/usr/bin/env bash
# Starts exactly the containers stop-services.sh stopped.
source "$(dirname "$0")/bench.env"
[ -s "$STATE_FILE" ] || { echo "No saved list at $STATE_FILE - nothing to restore"; exit 1; }
docker start $(cat "$STATE_FILE") > /dev/null && echo "Restored $(wc -l < "$STATE_FILE") containers"
