# Roadmap

Why this exists: to stand in the shoes of the people deciding whether to run AI on their own hardware — build it, break it, measure it, and report what's true.

## Done

### Phase 1 — Build and bring-up
- [x] Built a 3× Radeon AI PRO R9700 workstation (96 GB VRAM) on a consumer B850 board
- [x] Got the ODS local AI stack (originally built for Strix Halo) running on discrete RDNA4 — the installer had picked the CPU's integrated GPU target (gfx1036); fixed to gfx1201, plus device-detection and GPU-visibility fixes
- [x] Verified which binary actually serves requests (hash match, process path, Dockerfile)

### Phase 2 — Baseline and topology · 2026-10-07
- [x] Mapped real PCIe links at the upstream switch ports (5.0 x8 / 5.0 x8 / 4.0 x4 chipset)
- [x] Built an isolated benchmark image from the stack's own build stage, leaving the production stack untouched
- [x] ROCm 7.2 baseline: chipset slot −12% generation; layer split −7% writing / +50% reading; ~1 ms hand-off independent of link width → [Finding 01](findings/01-pcie-topology-and-layer-split.md)

### Phase 3 — Method and tooling · 2026-10-11
- [x] Benchmark runbook and scripts: provenance capture, sysfs GPU logger, benchmark matrix, safe stop/restore of services → [bench-kit](bench-kit/)
- [x] Power-monitoring design: wall meter → smart plug → Pi historian → ESP32 meter-LED reader → Modbus

### Phase 4 — Power, cost and a 61% fix · 2026-10-17 → 18
- [x] Wall meter installed; idle, generation and prompt-reading power measured for an 80B model on three cards
- [x] Cost per million tokens, local vs rented vs a frontier-lab small model, including hardware payback → [Finding 03](findings/03-power-and-cost.md)
- [x] Found a 2.6× gap between benchmark and real serving; bisected it across nine hypotheses to `HSA_ENABLE_SDMA=0`; fixed (21.0 → 54.3 t/s) → [Finding 02](findings/02-hsa-enable-sdma.md)
- [x] Reported upstream: [Osmantic/ODS #7786](https://github.com/Osmantic/ODS/issues/7786) and discrete-RDNA4 setup notes

## Next

- [ ] **Re-test the 35B through the stack** after the SDMA fix (earlier ~45 t/s vs 75 t/s benchmark — likely the same cause)
- [ ] **Physical slot swap** to confirm the chipset-slot result is the slot, not the card
- [ ] **ROCm 10 side-by-side** — same matrix, separate image
- [ ] **Multi-user serving** — how batching changes cost per token
- [ ] **What does "local" send out?** Audit outbound traffic from the stack's containers
- [ ] **PSU telemetry** — read the AX1600i (if Linux can see it) to measure power-supply losses, wall vs DC
- [ ] **Apartment energy monitoring** — ESP32 on the meter's pulse LED, Pi historian, Grafana: a mini EPMS
- [ ] **OT security lab** — expose that data over Modbus and show what an unauthenticated industrial protocol looks like on the wire
- [ ] **Cross-rig comparison** with another builder's server-class setup
