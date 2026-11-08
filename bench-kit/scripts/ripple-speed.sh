#!/usr/bin/env bash
# Ripple-65B speed, A-B-A: Q8_0 / Q6_K / Q8_0 on 3x R9700, llama-bench pp512, pp2048, tg128, r=5.
# One warm-up first (discarded). GPU temperature and power logged every 10 s alongside (hot-day check).
# Usage: ./ripple-speed.sh      Needs: no other containers on the GPUs (stop lab-llm first, start it after).
set -euo pipefail
IMG="${IMG:-$(cat ~/bench/ripple-2026-11-05/image.txt)}"
D="${D:-/mnt/models/ripple-65b-gguf}"
ARGS="${ARGS:--ngl 99 -sm layer -fa 1 -p 512,2048 -n 128 -r 5}"
OUT=~/bench/ripple-speed-$(date +%F-%H%M); mkdir -p "$OUT"
mark() { echo "$(date -Is) $*" | tee -a "$OUT/session.log"; }

busy=$(docker ps --format '{{.Names}}')
[ -z "$busy" ] || { echo "STOP: containers running (hold VRAM, skew timing): $(echo $busy). docker stop them first."; exit 1; }
if systemctl is-active -q netdata 2>/dev/null; then
  sudo -v && sudo systemctl restart netdata && mark "netdata restarted (see data/2026-10-31-netdata-aba.md)"; sleep 30
fi

( while true; do echo "$(date -Is) $(rocm-smi --showtemp --showpower --csv 2>/dev/null | tail -n +2 | tr '\n' ' ')"; sleep 10; done ) > "$OUT/gpu.log" &
LOGGER=$!; trap 'kill $LOGGER 2>/dev/null' EXIT

bench() {  # bench <gguf> <extra args...>
  local m=$1; shift
  docker run --rm --device /dev/kfd --device /dev/dri --group-add video --group-add render \
    -e HIP_VISIBLE_DEVICES=0,1,2 -v "$D:/out:ro" --entrypoint /app/llama-bench "$IMG" -m "/out/$m" "$@" -o jsonl 2>>"$OUT/stderr.log"
}

mark "image $IMG; args $ARGS"
mark "warm-up (discarded)"; bench ripple-65b-q8_0.gguf -ngl 99 -sm layer -fa 1 -p 512 -n 32 -r 1 > "$OUT/0-warmup.jsonl"
i=1
for m in q8_0 q6_k q8_0; do
  mark "run $i: $m"; bench "ripple-65b-$m.gguf" $ARGS > "$OUT/$i-$m.jsonl"; i=$((i+1))
done
# hash AFTER the runs (not in the background: it competed for the disk, and a bare `wait` also waited on the endless GPU logger)
mark "hashing models"; sha256sum "$D"/ripple-65b-q8_0.gguf "$D"/ripple-65b-q6_k.gguf > "$OUT/models.sha256"

mark "summary (t/s, mean ± stddev of 5)"
for f in "$OUT"/[1-9]-*.jsonl; do
  jq -r --arg f "$(basename "$f" .jsonl)" \
    'if .n_gen>0 then "\($f)\ttg\(.n_gen)\t\(.avg_ts*100|round/100) ± \(.stddev_ts*100|round/100)" else "\($f)\tpp\(.n_prompt)\t\(.avg_ts*100|round/100) ± \(.stddev_ts*100|round/100)" end' "$f"
done | tee -a "$OUT/session.log"
mark "last GPU temp/power reading (full series in gpu.log):"; tail -1 "$OUT/gpu.log" | tee -a "$OUT/session.log"
mark "done; results in $OUT. Now: docker start lab-llm"
