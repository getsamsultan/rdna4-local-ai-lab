#!/usr/bin/env bash
# autotune scorer. LOCKED: the agent must never edit this file. It checks its own hash every run.
# Compares a candidate llama-bench config against the current best, with a noise guard and a quality gate.
#
# Usage: ./score.sh            (reads best.args and candidate.args next to this script)
# Output: one JSON line appended to results.jsonl, and printed. "verdict" is "keep" or "reject".
#
# Noise guard: order best, cand, best, cand (A-B-A-B), r=3 each. Keep only if the candidate beats
#   BOTH best runs on the target metric by more than max(MIN_GAIN_PCT, 2 x the larger stddev).
# Quality gate: llama-perplexity on a fixed text with the candidate's numeric-affecting flags must stay
#   within PPL_TOL_PCT of the best config's perplexity.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

# ---- self-check: refuse to run if the scorer or its settings changed since they were locked and committed
LOCK="score.sha256"
if [ -f "$LOCK" ]; then
  sha256sum -c "$LOCK" >/dev/null 2>&1 || { echo '{"verdict":"error","why":"locked file modified (score.sh or autotune.env)"}'; exit 2; }
  git diff --quiet HEAD -- score.sh "$LOCK" autotune.env 2>/dev/null || { echo '{"verdict":"error","why":"uncommitted change to score.sh, score.sha256 or autotune.env"}'; exit 2; }
else
  echo "first run: locking score.sh and autotune.env. Commit score.sha256 before starting the agent."
  sha256sum score.sh autotune.env > "$LOCK"; date +%s > .started; exit 0
fi

source ./autotune.env   # MODEL, MODELS_DIR, IMAGE, HIP_DEVICES, METRIC (tg|pp), PPL_TEXT, MIN_GAIN_PCT, PPL_TOL_PCT, MAX_*

# ---- hard caps, enforced here rather than trusted to the agent
n=$(grep -c . results.jsonl 2>/dev/null || echo 0)
[ "$n" -ge "$MAX_EXPERIMENTS" ] && { echo "{\"verdict\":\"error\",\"why\":\"MAX_EXPERIMENTS ($MAX_EXPERIMENTS) reached\"}"; exit 3; }
start=$(cat .started 2>/dev/null || date +%s)
[ $(( ($(date +%s) - start) / 3600 )) -ge "$MAX_HOURS" ] && { echo "{\"verdict\":\"error\",\"why\":\"MAX_HOURS ($MAX_HOURS) reached\"}"; exit 3; }
BEST="$(cat best.args)"; CAND="$(cat candidate.args)"
[ "$BEST" = "$CAND" ] && { echo '{"verdict":"reject","why":"candidate identical to best"}'; exit 0; }

# allowlist: only llama-bench flags we expect, nothing that runs other programs or touches files
for tok in $CAND; do
  case "$tok" in
    -ngl|-sm|-fa|-ub|-b|-ncmoe|-t|-ts|-ctk|-ctv|-nopo|-mmp|-p|-n|-d|[0-9]*|[0-9]*,*|layer|row|none|on|off|f16|q8_0|q4_0) ;;
    *) echo "{\"verdict\":\"reject\",\"why\":\"flag not allowed: $tok\"}"; exit 0 ;;
  esac
done

bench() {  # bench <args...> -> prints "avg std" for the target metric
  docker run --rm --device /dev/kfd --device /dev/dri --group-add video --group-add render \
    -e HIP_VISIBLE_DEVICES="$HIP_DEVICES" -v "$MODELS_DIR:/models" \
    --entrypoint /app/llama-bench "$IMAGE" -m "/models/$MODEL" "$@" -r 3 -o jsonl 2>/dev/null |
  jq -r --arg m "$METRIC" 'select(.avg_ts) | select(($m=="tg" and .n_gen>0) or ($m=="pp" and .n_gen==0)) | "\(.avg_ts) \(.stddev_ts)"' | tail -1
}
ppl() {  # ppl <args...> -> prints final perplexity (only flags that change numerics are passed through)
  local keep=() a=("$@") i=0
  while [ $i -lt ${#a[@]} ]; do
    case "${a[$i]}" in -fa|-ctk|-ctv|-ngl|-sm|-ncmoe|-ts) keep+=("${a[$i]}" "${a[$((i+1))]}"); i=$((i+2));; *) i=$((i+1));; esac
  done
  docker run --rm --device /dev/kfd --device /dev/dri --group-add video --group-add render \
    -e HIP_VISIBLE_DEVICES="$HIP_DEVICES" -v "$MODELS_DIR:/models" -v "$HERE:/w:ro" \
    --entrypoint /app/llama-perplexity "$IMAGE" -m "/models/$MODEL" -f "/w/$PPL_TEXT" -c 2048 --chunks 8 "${keep[@]}" 2>&1 |
  grep -oE 'Final estimate: PPL = [0-9.]+' | grep -oE '[0-9.]+$'
}

t0=$(date +%s)
read -r a1 s1 <<<"$(bench $BEST)";  read -r b1 t1 <<<"$(bench $CAND)"
read -r a2 s2 <<<"$(bench $BEST)";  read -r b2 t2 <<<"$(bench $CAND)"
[ -z "${b1:-}" ] || [ -z "${b2:-}" ] && { v='{"verdict":"reject","why":"candidate failed to run"}'; echo "$v" | tee -a results.jsonl; exit 0; }

verdict=$(python3 - "$a1" "$a2" "$b1" "$b2" "$s1" "$s2" "$t1" "$t2" "$MIN_GAIN_PCT" <<'EOF'
import sys
a1,a2,b1,b2,s1,s2,t1,t2,mg=map(float,sys.argv[1:])
best=max(a1,a2); noise=2*max(s1,s2,t1,t2); need=max(best*mg/100, noise)
ok=min(b1,b2) > best+need
print(f"{'pass' if ok else 'fail'} {100*(min(b1,b2)/best-1):.2f} {need:.2f}")
EOF
)
read -r speed gain need <<<"$verdict"

pplb=""; pplc=""; q="skipped"
if [ "$speed" = pass ]; then
  pplb=$(ppl $BEST); pplc=$(ppl $CAND)
  q=$(python3 -c "import sys;b,c,t=map(float,sys.argv[1:]);print('pass' if abs(c/b-1)*100<=t else 'fail')" "${pplb:-0}" "${pplc:-0}" "$PPL_TOL_PCT" 2>/dev/null || echo fail)
fi
final=$([ "$speed" = pass ] && [ "$q" = pass ] && echo keep || echo reject)

line=$(jq -cn --arg v "$final" --arg best "$BEST" --arg cand "$CAND" --arg metric "$METRIC" \
  --argjson a "[$a1,$a2]" --argjson b "[$b1,$b2]" --arg gain "$gain" --arg need "$need" \
  --arg speed "$speed" --arg quality "$q" --arg pplb "$pplb" --arg pplc "$pplc" --argjson secs $(( $(date +%s)-t0 )) \
  '{time:(now|todate),verdict:$v,metric:$metric,best:$best,candidate:$cand,best_runs:$a,cand_runs:$b,
    gain_pct:($gain|tonumber),needed_tps:($need|tonumber),speed:$speed,quality:$quality,ppl_best:$pplb,ppl_cand:$pplc,seconds:$secs}')
echo "$line" | tee -a results.jsonl
