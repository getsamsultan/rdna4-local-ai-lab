#!/usr/bin/env bash
# Does a long-running Netdata agent cost generation speed? A–B–A: running as found → stopped → freshly restarted.
# Re-test of the open question in data/2026-10-25-engine-upgrade-aba.md (same model, flags and order).
# Usage: [MODELS_DIR=...] [MODEL=...] ./netdata-aba.sh      (asks for sudo once, to stop/start netdata)
set -euo pipefail

MODELS_DIR="${MODELS_DIR:-$HOME/ods/data/models}"
MODEL="${MODEL:-Qwen3-Coder-Next-UD-Q6_K.gguf}"
IMAGE="${IMAGE:-lab-llama:b11804-rocm7.2.1}"
ARGS=(-ngl 99 -sm layer -fa 1 -ub 256 -p 512 -n 2048 -r 5 -o jsonl)
OUT="$HOME/bench/netdata-aba-$(date +%F-%H%M)"
mkdir -p "$OUT"
sudo -v

bench() { docker run --rm --device /dev/kfd --device /dev/dri --group-add video --group-add render \
            -e HIP_VISIBLE_DEVICES=0,1,2 -v "$MODELS_DIR:/models" \
            --entrypoint /app/llama-bench "$IMAGE" -m "/models/$MODEL" "${ARGS[@]}"; }

snapshot() {  # what the agent looks like right now
  { echo "== $(date -Is)"
    systemctl show netdata -p ActiveState -p ActiveEnterTimestamp 2>/dev/null
    netdata -v 2>/dev/null || true
    ps -eo pid,etime,%cpu,rss,comm --sort=-%cpu | head -15
  } >> "$OUT/$1.snapshot"
}

step() {  # step <name>
  echo "== $1  $(date +%T)"
  snapshot "$1"
  mpstat -P ALL 5 > "$OUT/$1.mpstat" & local mp=$!
  bench > "$OUT/$1.jsonl" 2> "$OUT/$1.log" || echo "   !! $1 failed, see $1.log"
  kill "$mp" 2>/dev/null; wait "$mp" 2>/dev/null || true
}

echo "Netdata as found:"; systemctl show netdata -p ActiveEnterTimestamp | tee "$OUT/agent-age.txt"
echo "Stopping lab-llm..."
docker stop lab-llm >/dev/null || true
trap 'sudo systemctl start netdata; echo "Restarting lab-llm..."; docker start lab-llm >/dev/null' EXIT

step warmup                       # discarded: page cache
step 1-running-as-found
sudo systemctl stop netdata;  sleep 10
step 2-stopped
sudo systemctl start netdata; sleep 60   # let plugins settle
step 3-fresh-restart

echo
printf '%-22s %-7s %10s %8s\n' step test t/s "±"
for f in "$OUT"/[1-3]-*.jsonl; do
  n=$(basename "$f" .jsonl)
  jq -r --arg n "$n" 'select(.avg_ts) |
    "\($n) \(if .n_gen>0 then "tg\(.n_gen)" else "pp\(.n_prompt)" end) \(.avg_ts*100|floor/100) \(.stddev_ts*100|floor/100)"' "$f"
done | column -t | tee "$OUT/summary.txt"
echo "Results in $OUT"
