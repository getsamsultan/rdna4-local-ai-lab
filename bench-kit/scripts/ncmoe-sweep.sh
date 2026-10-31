#!/usr/bin/env bash
# Qwen3.8 system-RAM + thread sweep (A–B–A), llama-bench, GPU0+1 only.
# Usage: [MODELS_DIR=...] ./ncmoe-sweep.sh <model file relative to MODELS_DIR (default ~/models)>
set -euo pipefail

MODEL="${1:?give model path relative to MODELS_DIR}"
IMAGE="lab-llama:b11804-rocm7.2.1"
OUT="$HOME/bench/qwen38-ram-$(date +%F-%H%M)"
mkdir -p "$OUT"

bench() {  # bench <extra llama-bench args...>
  docker run --rm \
    --device /dev/kfd --device /dev/dri --group-add video --group-add render \
    -e HIP_VISIBLE_DEVICES=0,1 \
    -v "${MODELS_DIR:-$HOME/models}:/models" \
    --entrypoint /app/llama-bench "$IMAGE" "$@"
}

# Sanity: llama-bench must know -ncmoe
help=$(bench -h 2>&1 || true)   # llama-bench -h exits non-zero; don't let pipefail trip on it
grep -q -- '-ncmoe' <<<"$help" || { echo "llama-bench has no -ncmoe in this image"; exit 1; }

echo "Stopping lab-llm..."
docker stop lab-llm >/dev/null || true
trap 'echo "Restarting lab-llm..."; docker start lab-llm >/dev/null' EXIT

step() {  # step <name> <ncmoe> <threads>
  local name=$1 ncmoe=$2 t=$3
  echo "== $name  (ncmoe=$ncmoe, t=$t)  $(date +%T)"
  free -m > "$OUT/$name.free"
  mpstat -P ALL 5 > "$OUT/$name.mpstat" & local mp=$!
  bench -m "/models/$MODEL" -ngl 99 -sm layer -fa 1 \
        -ncmoe "$ncmoe" -t "$t" -p 512 -n 128 -r 3 -o jsonl \
        > "$OUT/$name.jsonl" 2> "$OUT/$name.log" || echo "   !! $name failed, see $name.log"
  kill "$mp" 2>/dev/null; wait "$mp" 2>/dev/null || true
}

# Warm-up (discarded): fills page cache so step A isn't cold
step warmup   0 16

# RAM sweep, A–B–A: 0 → 6 → 12 → 24 → 0
step ncmoe00a 0  16
step ncmoe06  6  16
step ncmoe12  12 16
step ncmoe24  24 16
step ncmoe00b 0  16

# Thread sweep at ncmoe 12, A–B–A: 16 → 8 → 32 → 16
step t16a 12 16
step t08  12 8
step t32  12 32
step t16b 12 16

# Summary
echo
printf '%-10s %6s %6s %10s\n' step test tok/s "±"
for f in "$OUT"/*.jsonl; do
  n=$(basename "$f" .jsonl); [ "$n" = warmup ] && continue
  jq -r --arg n "$n" 'select(.avg_ts) |
    "\($n) \(if .n_gen>0 then "tg\(.n_gen)" else "pp\(.n_prompt)" end) \(.avg_ts*100|floor/100) \(.stddev_ts*100|floor/100)"' "$f"
done | column -t | tee "$OUT/summary.txt"
echo "Results in $OUT"
