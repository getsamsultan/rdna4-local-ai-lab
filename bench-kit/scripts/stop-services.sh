#!/usr/bin/env bash
# Stops every running ods-* container (including llama-server) and remembers which ones, so restore is exact.
# Refuses to overwrite a saved list if nothing is running (so running it twice can't lose your list).
source "$(dirname "$0")/bench.env"
mkdir -p "$(dirname "$STATE_FILE")"
RUNNING=$(docker ps --format '{{.Names}}' | grep '^ods-' || true)
if [ -z "$RUNNING" ]; then
  echo "No ods-* containers running. Keeping existing list at $STATE_FILE ($(wc -l < "$STATE_FILE" 2>/dev/null || echo 0) entries)."
  exit 0
fi
echo "$RUNNING" > "$STATE_FILE"
echo "Stopping $(wc -l < "$STATE_FILE") containers (list saved to $STATE_FILE)"
docker stop $(cat "$STATE_FILE") > /dev/null
sleep 5
echo "VRAM now (R9700s should read 0%):"
rocm-smi --showmemuse | grep "VRAM%"
