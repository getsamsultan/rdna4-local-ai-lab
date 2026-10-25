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
- [x] Reported upstream: [Osmantic/ODS #7786](https://github.com/Osmantic/ODS/issues/7786) and [#7787](https://github.com/Osmantic/ODS/issues/7787). The maintainer showed the SDMA setting came from my local config, not ODS; corrected after checking the full ODS history
- [x] Update to current ODS `main`: done (v3.0.0), but superseded; see Phase 7

### Phase 5 — How many cards does the 80B need? · 2026-10-20
- [x] Two vs three cards, A–B–A order: two CPU-lane cards 57.3 t/s vs 54.6 / 54.1 on three (+5%)
- [x] 128K context on two cards: four attempts, all ~1 GB short → three cards for long context ([data](data/2026-10-20-80b-two-vs-three-cards.md))

### Phase 6 — A 177B preview of Qwen4 on 96 GB · 2026-10-23
- [x] Qwen3.8-Flash-Next UD-Q3_K_XL (83.8 GiB) loads on three cards with build 11804: 57.7 GiB on GPUs, 27.5 GiB n-gram table in system RAM
- [x] First numbers: 1,251 t/s prompt, 36 t/s generation; two cards 4% faster (A–B–A) ([data](data/2026-10-23-qwen38-flash-next-first-run.md))
- [x] Blind eval vs the 80B: 177B wins on quality (27–28 vs 18–23 of 30), 80B ~3.7× faster → [Finding 04](findings/04-qwen38-vs-80b-blind-eval.md)
- [ ] Why generation is slower than the 80B; context limit on two cards; MTP speculative decoding

### Phase 7 — Engine and stack · 2026-10-24 → 25
- [x] Same 80B, same cards: engine image b8763 / ROCm 7.2.0 → b11804 / ROCm 7.2.1 = **+13–19%** (51.8–54.5 → 61.8 t/s, A–B–A) ([data](data/2026-10-25-engine-upgrade-aba.md))
- [x] Upgraded the third-party stack to its v3.0.0; it pins AMD to an older engine (b9014) that can't load Qwen3.8 and rejects engine overrides by design. Decision: **leave it and build my own minimal, offline-first ROCm stack** ([upgrade notes](docs/ods-upgrade-rdna4.md))
- [x] **ROCm 7.2.1 vs 10.1.0**, same llama.cpp build: no difference on the 80B; Qwen3.8 2.7–3.9% slower on 10.1 ([data](data/2026-10-25-rocm-7.2.1-vs-10.1.md))
- [ ] Find why the old engine dropped from 54.7 to 51.8 t/s between 20 and 25 Oct: governor ruled out; restarting the host monitoring agent restored it; re-test in 24 h ([notes](data/2026-10-25-engine-upgrade-aba.md#open-question-the-547--518-drop-investigation-2026-10-25))

## Next

- [ ] **Blind eval round 2** (Sunday 1 Nov): more executable checks, style stripping, length-matched scoring, a human blind pass, split reporting → [design](eval/README.md#round-2-design-planned-from-community-feedback-on-round-1)

- [ ] **Re-test the 35B through the stack** after the SDMA fix (earlier ~45 t/s vs 75 t/s benchmark — likely the same cause)
- [ ] **Physical slot swap** to confirm the chipset-slot result is the slot, not the card
- [x] **ROCm 10 side-by-side**: 80B no difference; Qwen3.8 −2.7% generation, −3.9% prompt on 10.1 (A–B–A–B after warm-up). Staying on 7.2.1 for serving
- [ ] **Multi-user serving** — how batching changes cost per token
- [ ] **What does "local" send out?** Audit outbound traffic from the stack's containers
- [ ] **PSU telemetry** — read the AX1600i (if Linux can see it) to measure power-supply losses, wall vs DC
- [ ] **Apartment energy monitoring** — ESP32 on the meter's pulse LED, Pi historian, Grafana: a mini EPMS
- [ ] **OT security lab** — expose that data over Modbus and show what an unauthenticated industrial protocol looks like on the wire
- [ ] **Cross-rig comparison** with another builder's server-class setup

## Learning

- [ ] **AMD ROCm Certified: Associate** (ROCm fundamentals, HIP programming, single-GPU optimisation) · target: Oct 2026
- [ ] **Professional** (multi-GPU inference, vLLM/SGLang serving, multi-node) · when released
- [ ] **Expert** (capstone: multi-GPU optimisation, MLOps, fleet management) · when released
