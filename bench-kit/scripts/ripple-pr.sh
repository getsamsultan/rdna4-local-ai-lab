#!/usr/bin/env bash
# Ripple-65B Preview on ROCm via the unmerged llama.cpp PR #31692. Stages, run in order or "all":
#   build    worktree of the PR + ROCm image (--target full, so the converter is included)
#   convert  official BF16 safetensors -> BF16 GGUF, then CHECK the sliding-window key is present
#   quant    BF16 GGUF -> Q8_0 and Q6_K, sha256 of every file
#   ppl      perplexity on wikitext-2 (Q8_0, GPUs 0,1,2): the "check that can fail" before any speed tests
# Usage: ./ripple-pr.sh all        (or one stage)      Logs and hashes go to ~/bench/ripple-<date>/
set -euo pipefail
STAGE="${1:?usage: $0 build|convert|quant|ppl|all}"
PR=31692
SRC="${SRC:-$HOME/llama.cpp}"                 # existing upstream clone (b11804 lives here, untouched)
WT="${WT:-$HOME/llama-ripple}"                # separate worktree for the PR
HFDIR="${HFDIR:-/mnt/models/ripple-65b}"      # official weights from: hf download ricursiveAI/Ripple-65B-Preview
OUTDIR="${OUTDIR:-/mnt/models/ripple-65b-gguf}"
OUT="$HOME/bench/ripple-$(date +%F)"; mkdir -p "$OUT" "$OUTDIR"
log() { echo "$(date -Is) $*" | tee -a "$OUT/ripple.log"; }

image() { cat "$OUT/image.txt" 2>/dev/null || { echo "run the build stage first" >&2; exit 1; }; }
run() {  # run <entrypoint> <args...>  (mounts weights read-only, output dir read-write)
  local ep=$1; shift
  docker run --rm --device /dev/kfd --device /dev/dri --group-add video --group-add render \
    -e HIP_VISIBLE_DEVICES="${HIP:-0,1,2}" -v "$HFDIR:/hf:ro" -v "$OUTDIR:/out" -v "$OUT:/log" \
    --entrypoint "$ep" "$(image)" "$@"
}

build() {
  cd "$SRC"
  git fetch -q origin "pull/$PR/head:pr-$PR-ripple"
  [ -d "$WT" ] || git worktree add -q "$WT" "pr-$PR-ripple"
  cd "$WT" && git checkout -q "pr-$PR-ripple" && git pull -q --ff-only origin "pull/$PR/head" 2>/dev/null || true
  local sha; sha=$(git rev-parse --short HEAD)
  local tag="lab-llama:ripple-pr$PR-$sha-rocm7.2.1"
  log "building $tag from PR #$PR head $sha"
  docker build -f .devops/rocm.Dockerfile --target full --build-arg ROCM_DOCKER_ARCH=gfx1201 -t "$tag" . > "$OUT/build.log" 2>&1
  echo "$tag" > "$OUT/image.txt"; log "built $tag"
}

convert() {
  [ -f "$HFDIR/config.json" ] || { log "no config.json in $HFDIR: is the download finished?"; exit 1; }
  log "converting BF16 safetensors -> GGUF"
  run python3 /app/convert_hf_to_gguf.py /hf --outtype bf16 --outfile /out/ripple-65b-bf16.gguf > "$OUT/convert.log" 2>&1
  # Bot review on the PR: if the sliding-window key is missing, RoPE is silently skipped on every layer.
  run python3 -c "import gguf,sys; r=gguf.GGUFReader('/out/ripple-65b-bf16.gguf'); \
k=[f for f in r.fields if 'sliding_window' in f]; print('\n'.join(k) or 'MISSING'); sys.exit(0 if k else 1)" \
    | tee "$OUT/swa-key.txt" || { log "STOP: no sliding_window key in the GGUF (RoPE would be skipped). Report on the PR."; exit 1; }
  log "sliding-window key present: $(tr '\n' ' ' < "$OUT/swa-key.txt")"
}

quant() {
  for q in Q8_0 Q6_K; do
    log "quantising $q"
    run /app/llama-quantize /out/ripple-65b-bf16.gguf "/out/ripple-65b-$(echo $q | tr A-Z a-z).gguf" "$q" > "$OUT/quant-$q.log" 2>&1
  done
  log "hashing"; (cd "$OUTDIR" && sha256sum *.gguf) | tee "$OUT/gguf.sha256"
  (cd "$HFDIR" && sha256sum *.safetensors) > "$OUT/hf-weights.sha256"
}

ppl() {
  local txt="$OUTDIR/wiki.test.raw"
  if [ ! -f "$txt" ]; then
    log "fetching wikitext-2 test set"
    (cd "$OUTDIR" && bash "$WT/scripts/get-wikitext-2.sh" >/dev/null && mv wikitext-2-raw/wiki.test.raw . && rm -rf wikitext-2-raw*)
  fi
  log "perplexity, Q8_0, ctx 2048, 3 GPUs"
  run /app/llama-perplexity -m /out/ripple-65b-q8_0.gguf -f /out/wiki.test.raw -c 2048 -ngl 99 -sm layer -fa on \
    > "$OUT/ppl-q8_0.log" 2>&1 || true
  grep -E 'Final estimate' "$OUT/ppl-q8_0.log" | tee -a "$OUT/ripple.log" || log "no final estimate: check ppl-q8_0.log"
  log "compare: PR author reports BF16 PPL 3.01 (dataset/ctx not stated). Near ~3 = plausible. Far above (e.g. >5) = ROCm path likely broken."
}

case "$STAGE" in
  build) build ;; convert) convert ;; quant) quant ;; ppl) ppl ;;
  all) build; convert; quant; ppl ;;
  *) echo "unknown stage $STAGE"; exit 1 ;;
esac
log "stage $STAGE done; results in $OUT"
