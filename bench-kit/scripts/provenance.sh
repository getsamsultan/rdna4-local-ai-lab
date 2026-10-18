#!/usr/bin/env bash
# Records everything needed to reproduce a run. Usage: provenance.sh <output.md> [model-file]
set -uo pipefail
source "$(dirname "$0")/bench.env"
OUT=$1; MODEL_FILE=${2:-}
{
echo "# Provenance - $(date -Iseconds)"
echo; echo "## Host"
echo "OS: $(lsb_release -ds 2>/dev/null)"; echo "Kernel: $(uname -r)"
lscpu | grep -E "Model name|^CPU\(s\)|max MHz"
echo "Governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)"
echo "Boost: $(cat /sys/devices/system/cpu/cpufreq/boost 2>/dev/null) (1 = on)"
sudo dmidecode -t memory | grep -E "^\s+(Size|Configured Memory Speed):" | grep -v "No Module"
echo; echo "## PCIe links (upstream switch ports - the real slot link)"
for b in $UPSTREAM_PORTS; do echo "$b: $(sudo lspci -vv -s "$b" | grep 'LnkSta:' | xargs)"; done
echo; echo "## Bench image"
echo "Image: $IMAGE ($(docker image inspect --format '{{.Id}}' "$IMAGE" | cut -c1-19))"
echo "ROCm: $(docker run --rm "$IMAGE" cat /opt/rocm/.info/version 2>/dev/null)"
echo "llama.cpp commit: $(docker run --rm "$IMAGE" git rev-parse --short HEAD)"
echo "Source changes vs stock:"; docker run --rm "$IMAGE" git diff --stat
echo "llama-server sha256: $(docker run --rm "$IMAGE" sha256sum build/bin/llama-server | cut -d' ' -f1)"
if [ -n "$MODEL_FILE" ]; then
  echo; echo "## Model"
  echo "File: $MODEL_FILE"
  echo "sha256: $(sha256sum "$MODELS_DIR/$MODEL_FILE" | cut -d' ' -f1)"
fi
echo; echo "## VRAM before run (should be ~0% on the R9700s)"
rocm-smi --showmemuse 2>/dev/null | grep "VRAM%"
} > "$OUT"
echo "Provenance written to $OUT"
