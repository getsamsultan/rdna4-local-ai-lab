#!/usr/bin/env bash
# Reproduces the HSA_ENABLE_SDMA=0 slowdown on discrete RDNA4 cards.
# Runs ODS's own llama-server from the ODS image, toggling ONLY HSA_ENABLE_SDMA.
# Read-only for ODS: it starts a temporary container (sdma-test) and removes it afterwards.
# Requirements: no model loaded in Lemonade (GPUs 0-2 near 0% VRAM).
# Usage: ./sdma-repro.sh /path/to/models Qwen3-Coder-Next-UD-Q6_K.gguf [runs]
set -euo pipefail
MODELS_DIR=${1:?models folder}; MODEL=${2:?model file}; RUNS=${3:-3}
IMG=${IMG:-ods-lemonade-server:latest}
GPUS=${GPUS:-0,1,2}
RG=$(getent group render | cut -d: -f3); VG=$(getent group video | cut -d: -f3)
OUT="sdma-results-$(date +%Y%m%d-%H%M%S).md"
PROMPT='Write a Python script that reads a CSV of power readings (timestamp, watts), calculates kWh per day and cost at $0.32/kWh, and prints a weekly summary. Include error handling and comments.'

{
echo "# HSA_ENABLE_SDMA A/B test"
echo "Date: $(date -u +%Y-%m-%dT%H:%MZ)"
echo
echo "## Environment"
echo '```'
echo "OS: $(. /etc/os-release; echo "$PRETTY_NAME")"
echo "Kernel: $(uname -r)"
echo "CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs)"
echo "Docker: $(docker --version)"
echo "Image: $IMG  id=$(docker image inspect "$IMG" --format '{{.Id}}' | cut -c8-19)"
echo "GPUs used (HIP_VISIBLE_DEVICES): $GPUS"
rocm-smi --showproductname 2>/dev/null | grep -E "Card Series|Card SKU|GFX Version" || true
echo "Model: $MODEL  sha256=$(sha256sum "$MODELS_DIR/$MODEL" | cut -c1-16)…"
echo "llama-server sha256: $(docker run --rm --entrypoint sh "$IMG" -c 'sha256sum /opt/llama-custom/llama-server' | cut -c1-16)…"
echo "libggml-hip sha256:  $(docker run --rm --entrypoint sh "$IMG" -c 'sha256sum /opt/llama-custom/libggml-hip.so.0.9.11' | cut -c1-16)…"
echo '```'
echo
echo "## VRAM before test"
echo '```'; rocm-smi --showmemuse 2>/dev/null | grep "VRAM%" || true; echo '```'
echo
echo "## Settings (identical for both runs except HSA_ENABLE_SDMA)"
echo '```'
echo "llama-server -m $MODEL --ctx-size 131072 --jinja --no-mmap -ngl 99 --split-mode layer"
echo "env: HIP_VISIBLE_DEVICES=$GPUS ROCR_VISIBLE_DEVICES=$GPUS LD_LIBRARY_PATH=/opt/llama-custom"
echo "request: 1 chat completion, max_tokens=1500, same prompt every run"
echo '```'
echo
echo "## Results (generation tokens/s, from llama-server timings)"
echo
echo "| HSA_ENABLE_SDMA | Run | Generation t/s | Tokens | Prompt t/s |"
echo "|---|---|---|---|---|"
} | tee "$OUT"

run() {  # $1 = label, rest = extra docker args
  local label=$1; shift
  docker rm -f sdma-test >/dev/null 2>&1 || true
  docker run -d --name sdma-test --device /dev/kfd --device /dev/dri --group-add "$VG" --group-add "$RG" \
    --security-opt seccomp=unconfined -v "$MODELS_DIR":/models:ro \
    -e HIP_VISIBLE_DEVICES="$GPUS" -e ROCR_VISIBLE_DEVICES="$GPUS" -e LD_LIBRARY_PATH=/opt/llama-custom "$@" \
    -p 127.0.0.1:8098:8001 --entrypoint /opt/llama-custom/llama-server "$IMG" \
    -m "/models/$MODEL" --ctx-size 131072 --port 8001 --host 0.0.0.0 --jinja --no-mmap -ngl 99 --split-mode layer >/dev/null
  until curl -sf http://localhost:8098/health >/dev/null; do sleep 3; done
  for i in $(seq 1 "$RUNS"); do
    curl -s http://localhost:8098/v1/chat/completions -H "Content-Type: application/json" \
      -d "$(python3 -c 'import json,sys; print(json.dumps({"messages":[{"role":"user","content":sys.argv[1]}],"max_tokens":1500}))' "$PROMPT")" > /tmp/sdma-r.json
    python3 -c "import json; t=json.load(open('/tmp/sdma-r.json'))['timings']; print('| $label | $i | %.2f | %d | %.1f |' % (t['predicted_per_second'], t['predicted_n'], t['prompt_per_second']))" | tee -a "$OUT"
  done
  docker rm -f sdma-test >/dev/null
}

run "unset (default)"
run "0" -e HSA_ENABLE_SDMA=0
run "unset (repeat)"

echo; echo "Saved: $OUT"
