#!/usr/bin/env bash
# ROCm vs Vulkan, same llama.cpp commit, same GPUs, A–B–A–B with llama-bench.
# Usage: [MODELS_DIR=...] [FA=1] [BENCH_ARGS="..."] [VK_DEVICES=1,2] [HIP_DEVICES=0,1] ./rocm-vs-vulkan.sh <model file relative to MODELS_DIR>
#
# VK_DEVICES must point at the SAME physical cards as HIP_DEVICES. Vulkan numbers devices
# differently and also lists the iGPU. Check with --list-devices while another model is
# loaded: the cards with little free VRAM are the busy ones. On my rig Vulkan0 = iGPU,
# Vulkan1 = GPU0, Vulkan2 = GPU1, Vulkan3 = GPU2.
set -euo pipefail

MODEL="${1:?give model path relative to MODELS_DIR}"
MODELS_DIR="${MODELS_DIR:-$HOME/models}"
ROCM_IMAGE="${ROCM_IMAGE:-lab-llama:b11804-rocm7.2.1}"
VK_IMAGE="${VK_IMAGE:-lab-llama:b11804-vulkan}"
HIP_DEVICES="${HIP_DEVICES:-0,1}"
VK_DEVICES="${VK_DEVICES:-1,2}"
FA="${FA:-1}"
read -ra ARGS <<<"${BENCH_ARGS:--ngl 99 -sm layer -fa $FA -p 512,2048 -n 128 -r 3} -o jsonl"
OUT="$HOME/bench/rocm-vs-vulkan-$(date +%F-%H%M)"
mkdir -p "$OUT"

# The Vulkan image is plain Ubuntu with no "render" group, so pass the host's group IDs.
GROUPS_ARGS=(--group-add "$(getent group video | cut -d: -f3)" --group-add "$(getent group render | cut -d: -f3)")

rocm() { docker run --rm --device /dev/kfd --device /dev/dri "${GROUPS_ARGS[@]}" \
           -e HIP_VISIBLE_DEVICES="$HIP_DEVICES" -v "$MODELS_DIR:/models" \
           --entrypoint /app/llama-bench "$ROCM_IMAGE" -m "/models/$MODEL" "${ARGS[@]}"; }
vulkan() { docker run --rm --device /dev/dri "${GROUPS_ARGS[@]}" \
           -e GGML_VK_VISIBLE_DEVICES="$VK_DEVICES" -v "$MODELS_DIR:/models" \
           --entrypoint /app/llama-bench "$VK_IMAGE" -m "/models/$MODEL" "${ARGS[@]}"; }

# Provenance
{
  echo "date: $(date -Is)"; echo "kernel: $(uname -r)"; echo "model: $MODEL"
  echo "args: ${ARGS[*]}"; echo "HIP_VISIBLE_DEVICES=$HIP_DEVICES  GGML_VK_VISIBLE_DEVICES=$VK_DEVICES"
  for img in "$ROCM_IMAGE" "$VK_IMAGE"; do echo "image $img: $(docker image inspect -f '{{.Id}}' "$img")"; done
  docker run --rm --entrypoint sh "$VK_IMAGE" -c \
    "head -1 /etc/os-release; dpkg -l | awk '/mesa-vulkan-drivers|libvulkan1/ {print \$2, \$3}'"
} > "$OUT/provenance.txt"

echo "Stopping lab-llm..."
docker stop lab-llm >/dev/null || true
trap 'echo "Restarting lab-llm..."; docker start lab-llm >/dev/null' EXIT

vram_peak() {  # background: peak VRAM GiB per GPU while a step runs
  local f=$1; declare -A peak
  while :; do
    while read -r g v; do (( v > ${peak[$g]:-0} )) && peak[$g]=$v
    done < <(rocm-smi --showmeminfo vram --csv 2>/dev/null | awk -F, '/^card[0-2],/ {sub("card","",$1); print $1, $3}')
    for g in "${!peak[@]}"; do printf 'GPU%s %.2f GiB\n' "$g" "$(awk -v b="${peak[$g]}" 'BEGIN{print b/2^30}')"; done | sort > "$f"
    sleep 1
  done
}

step() {  # step <name> <rocm|vulkan>
  echo "== $1 ($2)  $(date +%T)"
  vram_peak "$OUT/$1.vram" & local vp=$!
  "$2" > "$OUT/$1.jsonl" 2> "$OUT/$1.log" || echo "   !! $1 failed, see $1.log"
  kill "$vp" 2>/dev/null; wait "$vp" 2>/dev/null || true
}

# Warm-ups (discarded): page cache + Vulkan pipeline compile
step warmup-rocm   rocm
step warmup-vulkan vulkan

# A–B–A–B
step 1-rocm   rocm
step 2-vulkan vulkan
step 3-rocm   rocm
step 4-vulkan vulkan

echo
for f in "$OUT"/[1-4]-*.jsonl; do
  n=$(basename "$f" .jsonl)
  jq -r --arg n "$n" 'select(.avg_ts) |
    "\($n) \(if .n_gen>0 then "tg\(.n_gen)" else "pp\(.n_prompt)" end) \(.avg_ts*100|floor/100) \(.stddev_ts*100|floor/100)"' "$f"
done | column -t | tee "$OUT/summary.txt"
echo; echo "VRAM peaks (check only the intended GPUs were used):"
for f in "$OUT"/[1-4]-*.vram; do echo "$(basename "$f" .vram): $(tr '\n' ' ' < "$f")"; done | tee -a "$OUT/summary.txt"
echo "Results in $OUT"
