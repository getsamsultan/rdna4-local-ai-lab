#!/usr/bin/env bash
# DeepSeek-V4.1-Flash IQ1_M, unattended: three server loads (lazy on → auto → on, A–B–A), each warmed up
# until generation plateaus, then measured; disk I/O logged the whole time; eval answers collected at the end.
# Usage: ./ds41-session.sh            (asks for sudo once, to restart the monitoring agent first)
#        SKIP_EVAL=1 ./ds41-session.sh   (benchmarks only)
#        REVIEW_DOC=~/review/design-doc.md ./ds41-session.sh   (also a design review of that doc, see eval/review.py)
set -uo pipefail

IMAGE="${IMAGE:-lab-llama:ds41-b72050d-rocm7.2.1}"
MODELS_DIR="${MODELS_DIR:-$HOME/models}"
MODEL="${MODEL:-ds41-iq1m/UD-IQ1_M/DeepSeek-V4.1-Flash-1017-UD-IQ1_M-00001-of-00005.gguf}"
PORT=8098; CTX="${CTX:-32768}"   # 32K so a ~9K-token document plus a long review fits
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$HOME/bench/ds41-session-$(date +%F-%H%M)"
mkdir -p "$OUT"
URL="http://127.0.0.1:$PORT"
mark() { echo "$(date -Is) $*" | tee -a "$OUT/phases.log"; }

# Disk that holds the model (for iostat), e.g. nvme0n1
DISK=$(lsblk -no PKNAME "$(df --output=source "$MODELS_DIR" | tail -1)" 2>/dev/null | head -1)
DISK=${DISK:-nvme0n1}

sudo -v && sudo systemctl restart netdata && mark "netdata restarted (see data/2026-10-31-netdata-aba.md)"
docker stop lab-llm >/dev/null 2>&1; mark "lab-llm stopped"
cleanup() {
  docker rm -f ds41 >/dev/null 2>&1
  kill "$IOS" "$MPS" 2>/dev/null
  docker start lab-llm >/dev/null; mark "lab-llm restarted"
}
trap cleanup EXIT

iostat -dxmt 5 "$DISK" > "$OUT/iostat.log" & IOS=$!
mpstat -P ALL 5 > "$OUT/mpstat.log" & MPS=$!
mark "logging iostat ($DISK) and mpstat"

# Fixed prompts. SHORT measures generation (256 tokens forced), LONG measures prompt reading (~2000 tokens).
SHORT="Explain in detail how a mixture-of-experts language model routes each token to its experts, and why that saves compute."
LONG=$(python3 -c "print(' '.join(['The rack PDU logs power every fifteen minutes, and the operator compares each reading with the previous one to spot rollover.']*90))")

req() {  # req <prompt> <n_predict>  -> prints "prompt_n pp_tps predicted_n tg_tps"
  jq -n --arg p "$1" --argjson n "$2" '{prompt:$p, n_predict:$n, ignore_eos:true, cache_prompt:false, temperature:0}' |
    curl -s -m 1800 "$URL/completion" -H 'Content-Type: application/json' -d @- |
    jq -r '.timings | "\(.prompt_n) \(.prompt_per_second) \(.predicted_n) \(.predicted_per_second)"'
}

session() {  # session <name> <lazy-mode>
  local name=$1 mode=$2 t0 ok=0
  mark "== $name: starting server, --lazy-mode $mode"
  t0=$(date +%s)
  docker run -d --name ds41 --device /dev/kfd --device /dev/dri --group-add video --group-add render \
    -e HIP_VISIBLE_DEVICES=0,1,2 -v "$MODELS_DIR:/models" -p 127.0.0.1:$PORT:8080 \
    "$IMAGE" --server -m "/models/$MODEL" -sm layer -fa on --lazy-mode "$mode" \
    -c "$CTX" -np 1 --jinja --no-reasoning-preserve -lv 4 --host 0.0.0.0 --port 8080 >/dev/null
  for _ in $(seq 1 240); do   # up to 40 min
    if curl -sf "$URL/health" >/dev/null; then ok=1; break; fi
    docker ps -q -f name=ds41 | grep -q . || break
    sleep 10
  done
  docker logs ds41 > "$OUT/$name.server.log" 2>&1
  grep -E 'layers \(.*overflowing\)|successfully fit|model buffer size' "$OUT/$name.server.log" > "$OUT/$name.fit.txt"
  if [ $ok != 1 ]; then mark "!! $name: server did not come up, see $name.server.log"; docker rm -f ds41 >/dev/null; return 1; fi
  echo "$(( $(date +%s) - t0 ))" > "$OUT/$name.load_s"; mark "$name: loaded in $(cat "$OUT/$name.load_s") s"
  free -m > "$OUT/$name.free"; rocm-smi --showmeminfo vram > "$OUT/$name.vram" 2>/dev/null

  # Warm-up: repeat SHORT until the last 3 generation speeds are within 3% (max 15 runs)
  mark "$name: warm-up"
  : > "$OUT/$name.warmup"
  for i in $(seq 1 15); do
    req "$SHORT" 256 | tee -a "$OUT/$name.warmup"
    if [ "$i" -ge 3 ] && tail -3 "$OUT/$name.warmup" | awk '{v[NR]=$4} END{mn=v[1];mx=v[1];for(k in v){if(v[k]<mn)mn=v[k];if(v[k]>mx)mx=v[k]} exit !(mx/mn<1.03)}'; then
      mark "$name: plateau after $i runs"; break; fi
  done

  # Measure: 5 × generation, 5 × prompt reading
  mark "$name: measure tg256"
  for i in 1 2 3 4 5; do req "$SHORT" 256; done > "$OUT/$name.tg"
  mark "$name: measure pp (~2000 tokens)"
  for i in 1 2 3 4 5; do req "$LONG" 16; done > "$OUT/$name.pp"
  mark "$name: done"
}

session 1-lazy-on on
docker rm -f ds41 >/dev/null
session 2-lazy-auto auto
docker rm -f ds41 >/dev/null
session 3-lazy-on on

if [ -z "${SKIP_EVAL:-}" ] && curl -sf "$URL/health" >/dev/null; then
  mark "eval: collecting answers (15 prompts)"
  ( cd "$REPO/eval" && python3 run.py --url "$URL/v1" --label ds41-iq1m --max-tokens 8192 ) > "$OUT/eval-run.log" 2>&1
  cp "$REPO/eval/answers-ds41-iq1m.jsonl" "$OUT/" 2>/dev/null
  mark "eval: done ($(grep -c . "$OUT/answers-ds41-iq1m.jsonl" 2>/dev/null || echo 0) answers)"
fi

if [ -n "${REVIEW_DOC:-}" ] && [ -f "$REVIEW_DOC" ] && curl -sf "$URL/health" >/dev/null; then
  mark "review: $(basename "$REVIEW_DOC")"
  python3 "$REPO/eval/review.py" --url "$URL/v1" --label ds41-iq1m --doc "$REVIEW_DOC" --out-dir "$(dirname "$REVIEW_DOC")" \
    > "$OUT/review-run.log" 2>&1 && mark "review: done" || mark "!! review failed, see review-run.log"
fi

# Summary
{
  echo "| Session | Load (s) | Warm-up runs | tg256 t/s (5 runs) | pp t/s (5 runs, ~prompt_n) |"
  echo "|---|---|---|---|---|"
  for s in 1-lazy-on 2-lazy-auto 3-lazy-on; do
    [ -f "$OUT/$s.tg" ] || { echo "| $s | failed | | | |"; continue; }
    tg=$(awk '{printf "%.2f ", $4}' "$OUT/$s.tg"); pp=$(awk '{printf "%.1f ", $2}' "$OUT/$s.pp")
    pn=$(awk '{print $1}' "$OUT/$s.pp" | head -1)
    echo "| $s | $(cat "$OUT/$s.load_s" 2>/dev/null) | $(grep -c . "$OUT/$s.warmup") | $tg | $pp (~$pn tok) |"
  done
} | tee "$OUT/summary.md"
mark "all done, results in $OUT"
