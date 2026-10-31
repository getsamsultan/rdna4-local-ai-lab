#!/usr/bin/env bash
# Peak VRAM per --n-cpu-moe step (GPU0+1). Stops/restarts lab-llm.
# Usage: [MODELS_DIR=...] ./ncmoe-vram.sh [model file relative to MODELS_DIR]
set -uo pipefail
MODEL="${1:-Qwen3.8-Flash-Next-UD-Q3_K_XL-00001-of-00003.gguf}"
IMAGE="lab-llama:b11804-rocm7.2.1"

docker stop lab-llm >/dev/null
trap 'docker start lab-llm >/dev/null; echo "lab-llm restarted"' EXIT

used() {  # prints "gpu0_GiB gpu1_GiB"
  rocm-smi --showmeminfo vram | awk -F': ' '/GPU\[[01]\].*Total Used/ {printf "%.2f ", $NF/2^30}'
}

printf '%-6s %8s %8s %8s\n' ncmoe GPU0 GPU1 total
for n in 0 6 12 24; do
  docker run -d --name vramtest \
    --device /dev/kfd --device /dev/dri --group-add video --group-add render \
    -e HIP_VISIBLE_DEVICES=0,1 -v "${MODELS_DIR:-$HOME/models}:/models" \
    --entrypoint /app/llama-bench "$IMAGE" \
    -m "/models/$MODEL" -ngl 99 -sm layer -fa 1 -ncmoe "$n" -p 512 -n 128 -r 2 >/dev/null
  p0=0; p1=0
  while [ "$(docker inspect -f '{{.State.Running}}' vramtest 2>/dev/null)" = true ]; do
    read -r a b <<<"$(used)"
    p0=$(awk -v x="$a" -v y="$p0" 'BEGIN{print (x>y)?x:y}')
    p1=$(awk -v x="$b" -v y="$p1" 'BEGIN{print (x>y)?x:y}')
    sleep 1
  done
  docker rm vramtest >/dev/null
  printf '%-6s %8s %8s %8s\n' "$n" "$p0" "$p1" "$(awk -v x="$p0" -v y="$p1" 'BEGIN{printf "%.2f", x+y}')"
done
