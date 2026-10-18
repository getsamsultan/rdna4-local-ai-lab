#!/usr/bin/env bash
# Runs a llama-bench matrix with provenance + GPU logging, all saved in one timestamped folder.
# Usage: run-llamabench.sh <model-file> "<gpu configs>" [extra llama-bench args...]
# Example: run-llamabench.sh Qwen3.6-35B-A3B-UD-Q4_K_M.gguf "0 1 2 0,1 0,2 1,2 0,1"
set -euo pipefail
source "$(dirname "$0")/bench.env"
MODEL_FILE=$1; CONFIGS=$2; shift 2; EXTRA=("$@")
[ -f "$MODELS_DIR/$MODEL_FILE" ] || { echo "Model not found: $MODELS_DIR/$MODEL_FILE"; exit 1; }
RUN_DIR="$RESULTS_DIR/$(date +%Y%m%d-%H%M%S)-${MODEL_FILE%.gguf}"
mkdir -p "$RUN_DIR"
"$(dirname "$0")/provenance.sh" "$RUN_DIR/provenance.md" "$MODEL_FILE"
"$(dirname "$0")/gpu-logger.sh" "$RUN_DIR/gpu-log.csv" 0.2 &
LOGGER=$!; trap 'kill $LOGGER 2>/dev/null' EXIT
echo "Settings: $BENCH_ARGS ${EXTRA[*]}" | tee "$RUN_DIR/results.md"
for d in $CONFIGS; do
  echo "== GPUs $d  ($(date +%T))" | tee -a "$RUN_DIR/results.md"
  docker run --rm --device /dev/kfd --device /dev/dri --group-add video --group-add render \
    --security-opt seccomp=unconfined -v "$MODELS_DIR":/models:ro \
    -e HIP_VISIBLE_DEVICES="$d" "$IMAGE" build/bin/llama-bench \
    -m "/models/$MODEL_FILE" $BENCH_ARGS "${EXTRA[@]}" -o md | tee -a "$RUN_DIR/results.md"
done
echo; echo "Done. Everything is in: $RUN_DIR"
