#!/usr/bin/env bash
# Logs busy %, power (W) and edge temp (C) for every AMD GPU to CSV. Usage: gpu-logger.sh <out.csv> [interval_s]
# Stop it with Ctrl+C, or kill its PID (run-llamabench.sh does this for you).
OUT=$1; INT=${2:-0.2}
cards=()
for c in /sys/class/drm/card[0-9]*; do [ -f "$c/device/gpu_busy_percent" ] && cards+=("$c"); done
hdr="time"
for c in "${cards[@]}"; do b=$(basename "$(readlink -f "$c/device")"); hdr="$hdr,${b}_busy,${b}_power_w,${b}_temp_c"; done
echo "$hdr" > "$OUT"
while true; do
  line=$(date +%s.%N)
  for c in "${cards[@]}"; do
    busy=$(cat "$c/device/gpu_busy_percent" 2>/dev/null)
    hw=$(ls -d "$c"/device/hwmon/hwmon* 2>/dev/null | head -1)
    p=$(cat "$hw/power1_average" 2>/dev/null || cat "$hw/power1_input" 2>/dev/null || echo 0)
    t=$(cat "$hw/temp1_input" 2>/dev/null || echo 0)
    line="$line,$busy,$(awk -v p="$p" 'BEGIN{printf "%.1f", p/1000000}'),$(awk -v t="$t" 'BEGIN{printf "%.1f", t/1000}')"
  done
  echo "$line" >> "$OUT"
  sleep "$INT"
done
