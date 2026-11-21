#!/usr/bin/env bash
# Inkling 2 Mini (Thinking Machines, Apache-2.0, looped MoE) on ROCm with current llama.cpp master.
# Support landed upstream 15-20 Nov 2026 (#32217, #32429, #32657, #32694). Stages, in order, or "all":
#   build    worktree of llama.cpp at REF (default: current master) + ROCm image (--target full, includes the converter)
#   convert  official safetensors (NVFP4/MXFP8) -> BF16 GGUF. The converter unpacks the 4-bit weights, so BF16 is an
#            essentially exact copy of the release. Text backbone only (vision and MTP are skipped by the converter).
#            CHECKS the GGUF says inkling2_loop and carries loop keys.
#   quant    BF16 -> Q8_0 and Q4_K_M, sha256 of everything
#   ppl      perplexity on wikitext-2, ctx 2048: BF16, Q8_0, Q4_K_M on 3 GPUs
#   kld      CPU BF16 reference (20 chunks, saves logits), then ROCm BF16 / Q8_0 / Q4_K_M scored against it
# Usage: [REF=<commit>] [QUANTS="bf16 q8_0"] [GPU_ARGS="-ngl 99 -sm layer -fa on -ts 6,36,6"] ./inkling-mini.sh <stage>|all
#   Needs: no containers holding the GPUs (docker stop lab-llm lemon)
#   Note: with -sm layer, llama.cpp appears to split by layer PASSES (48), not stored layers (24), so the default even
#   split puts stored layers 0-15 on GPU0 (BF16: 34 GB, out of memory). -ts 6,36,6 keeps the 12 looped layers on GPU1.
set -euo pipefail
STAGE="${1:?usage: $0 build|convert|quant|ppl|kld|all}"
SRC="${SRC:-$HOME/llama.cpp}"                    # existing upstream clone, left untouched
WT="${WT:-$HOME/llama-inkling}"                  # separate worktree
HFDIR="${HFDIR:-/mnt/models/inkling-2-mini}"     # hf download thinkingmachines/Inkling-2-Mini --local-dir $HFDIR
OUTDIR="${OUTDIR:-/mnt/models/inkling-2-mini-gguf}"
OUT="$HOME/bench/inkling-$(date +%F)"; mkdir -p "$OUT" "$OUTDIR"
QUANTS="${QUANTS:-bf16 q8_0 q4_k_m}"
GPU_ARGS="${GPU_ARGS:--ngl 99 -sm layer -fa on}"
TAG="${TAG:-}"   # suffix for log names, e.g. TAG=-ts6-36-6
log() { echo "$(date -Is) $*" | tee -a "$OUT/inkling.log"; }
image() { cat "$OUT/image.txt" 2>/dev/null || ls -t "$HOME"/bench/inkling-*/image.txt 2>/dev/null | head -1 | xargs -r cat || true; }
gpus_free() {
  local busy; busy=$(docker ps --format '{{.Names}}')
  [ -z "$busy" ] || { log "STOP: running containers may hold VRAM: $(echo $busy). docker stop them first, start them after."; exit 1; }
}
run() {  # run <gpu|cpu> <entrypoint> <args...>
  local mode=$1 ep=$2 img; shift 2
  img=$(image); [ -n "$img" ] || { log "STOP: no image, run the build stage first"; exit 1; }
  local dev=(); [ "$mode" = gpu ] && dev=(--device /dev/kfd --device /dev/dri --group-add video --group-add render -e HIP_VISIBLE_DEVICES="${HIP:-0,1,2}")
  docker run --rm "${dev[@]}" -v "$HFDIR:/hf:ro" -v "$OUTDIR:/out" -v "$OUT:/log" --entrypoint "$ep" "$img" "$@"
}

build() {
  cd "$SRC" && git fetch -q origin master
  [ -d "$WT" ] || git worktree add -q --detach "$WT" origin/master
  cd "$WT" && git fetch -q origin master && git checkout -q --detach "${REF:-origin/master}"
  local sha; sha=$(git rev-parse --short HEAD)
  ls src/models/inkling2-loop.cpp >/dev/null 2>&1 || { log "STOP: $sha has no inkling2-loop support"; exit 1; }
  local tag="lab-llama:inkling-$sha-rocm7.2.1"
  log "building $tag from llama.cpp $sha ($(git log -1 --format=%cd --date=short))"
  docker build -f .devops/rocm.Dockerfile --target full --build-arg ROCM_DOCKER_ARCH=gfx1201 -t "$tag" . > "$OUT/build.log" 2>&1 \
    || { log "STOP: build failed, see $OUT/build.log"; tail -20 "$OUT/build.log"; exit 1; }
  echo "$tag" > "$OUT/image.txt"; log "built $tag"
}

convert() {
  [ -f "$HFDIR/config.json" ] || { log "STOP: no config.json in $HFDIR: is the download finished?"; exit 1; }
  log "converting safetensors -> BF16 GGUF (dequantises NVFP4/MXFP8)"
  run cpu python3 /app/convert_hf_to_gguf.py /hf --outtype bf16 --outfile /out/inkling-2-mini-bf16.gguf > "$OUT/convert.log" 2>&1 \
    || { log "STOP: convert failed"; tail -20 "$OUT/convert.log"; exit 1; }
  run cpu python3 -c "import gguf,sys; r=gguf.GGUFReader('/out/inkling-2-mini-bf16.gguf'); \
a=bytes(r.fields['general.architecture'].parts[-1]).decode(); k=[f for f in r.fields if 'loop' in f]; \
print('arch', a); print('\n'.join(k) or 'NO LOOP KEYS'); sys.exit(0 if a=='inkling2_loop' and k else 1)" | tee "$OUT/arch-check.txt" \
    || { log "STOP: GGUF is not inkling2_loop or has no loop keys"; exit 1; }
  log "arch check: $(tr '\n' ' ' < "$OUT/arch-check.txt")"
  grep -E 'n_tensors|total_size|successfully' "$OUT/convert.log" | tee -a "$OUT/inkling.log" || true
}

quant() {
  for q in Q8_0 Q4_K_M; do
    log "quantising $q"
    run cpu /app/llama-quantize /out/inkling-2-mini-bf16.gguf "/out/inkling-2-mini-$(echo $q | tr A-Z a-z).gguf" "$q" > "$OUT/quant-$q.log" 2>&1
  done
  log "hashing"; (cd "$OUTDIR" && sha256sum *.gguf) | tee "$OUT/gguf.sha256"
  (cd "$HFDIR" && sha256sum *.safetensors) > "$OUT/hf-weights.sha256"
}

wiki() {
  [ -f "$OUTDIR/wiki.test.raw" ] && return
  [ -f /mnt/models/ripple-65b-gguf/wiki.test.raw ] && { cp /mnt/models/ripple-65b-gguf/wiki.test.raw "$OUTDIR/"; return; }
  (cd "$OUTDIR" && bash "$WT/scripts/get-wikitext-2.sh" >/dev/null && mv wikitext-2-raw/wiki.test.raw . && rm -rf wikitext-2-raw*)
}

ppl() {
  gpus_free; wiki
  for q in $QUANTS; do
    log "perplexity $q, ctx 2048, 3 GPUs, $GPU_ARGS"
    run gpu /app/llama-perplexity -m "/out/inkling-2-mini-$q.gguf" -f /out/wiki.test.raw -c 2048 $GPU_ARGS \
      > "$OUT/ppl-$q$TAG.log" 2>&1 || true
    grep -E 'model buffer size' "$OUT/ppl-$q$TAG.log" | sed "s/^/$q: /" | tee -a "$OUT/inkling.log" || true
    grep -E 'Final estimate' "$OUT/ppl-$q$TAG.log" | sed "s/^/$q: /" | tee -a "$OUT/inkling.log" || log "$q: no final estimate, see ppl-$q$TAG.log"
  done
}

kld() {
  gpus_free; wiki
  local base=/out/kld-cpu-bf16-c20.bin
  if [ ! -s "$OUTDIR/kld-cpu-bf16-c20.bin" ]; then
    log "CPU BF16 reference, 20 chunks (saves logits)"
    run cpu /app/llama-perplexity -m /out/inkling-2-mini-bf16.gguf -f /out/wiki.test.raw -c 2048 --chunks 20 -t 16 \
      --kl-divergence-base "$base" > "$OUT/kld-cpu-base.log" 2>&1
    grep 'Final estimate' "$OUT/kld-cpu-base.log" | sed 's/^/cpu bf16: /' | tee -a "$OUT/inkling.log"
  fi
  for q in $QUANTS; do
    log "KLD: ROCm $q vs CPU BF16, $GPU_ARGS"
    run gpu /app/llama-perplexity -m "/out/inkling-2-mini-$q.gguf" -c 2048 --chunks 20 $GPU_ARGS \
      --kl-divergence-base "$base" --kl-divergence > "$OUT/kld-rocm-$q$TAG.log" 2>&1 || true
    grep -E 'Mean +KLD|Same top p|Mean PPL\(Q\)/PPL\(base\)' "$OUT/kld-rocm-$q$TAG.log" | sed "s/^/$q: /" | tee -a "$OUT/inkling.log"
  done
}

case "$STAGE" in
  build) build ;; convert) convert ;; quant) quant ;; ppl) ppl ;; kld) kld ;;
  all) build; convert; quant; ppl; kld ;;
  *) echo "unknown stage $STAGE"; exit 1 ;;
esac
log "stage $STAGE done; results in $OUT"
