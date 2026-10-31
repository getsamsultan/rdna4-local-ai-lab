# Bench kit

- [BENCHMARK-RUNBOOK.md](BENCHMARK-RUNBOOK.md) — step-by-step method for trustworthy, reproducible llama.cpp benchmarks on multi-GPU ROCm
- [POWER-MONITORING-GUIDE.md](POWER-MONITORING-GUIDE.md) — wall meter → smart plug → Pi historian → ESP32 meter reader → Modbus
- [scripts/](scripts/) — `bench.env` (edit once), `provenance.sh`, `gpu-logger.sh`, `run-llamabench.sh`, `stop-services.sh`, `restore-services.sh`, `ncmoe-sweep.sh` and `ncmoe-vram.sh` (experts-in-RAM sweep, [results](../data/2026-10-31-qwen38-system-ram-sweep.md)), `rocm-vs-vulkan.sh` (same commit, same GPUs, A–B–A–B)

Status: the method and individual commands have been used on the rig; the scripts are syntax-checked but newer than the measurements, so treat them as a starting point and check output on your own system.
