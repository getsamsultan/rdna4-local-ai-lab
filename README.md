# RDNA4 Local AI Lab

**What it really takes to run large language models on your own AMD hardware: speed, power, cost and failure modes, measured and reproducible.**

I'm Sam Sultan, an infrastructure and operations analyst in Sydney. This is my lab notebook for a three-GPU AMD workstation. Every number here was measured on this rig, every test can be rerun, and the raw data is in the repo.

![The rig: 3× Radeon AI PRO R9700](images/rig.jpg)

## The short version

- **Smart or fast: pick per job.** In a blind test on my own work questions, a 177B model scored **27/30** against an 80B model's **18/30**, but the 80B answered **3.7× faster**. → [Finding 04](findings/04-qwen38-vs-80b-blind-eval.md)
- **Updating the engine image was worth +13–19%.** Same model, same cards, same flags: llama.cpp b8763 → b11804 (and ROCm 7.2.0 → 7.2.1) took the 80B from 51.8–54.5 to 61.8 tokens/s. → [data](data/2026-10-25-engine-upgrade-aba.md)
- **One config line cost 61% of serving speed.** An APU-only setting (`HSA_ENABLE_SDMA=0`) in my own config, found by bisection. → [Finding 02](findings/02-hsa-enable-sdma.md)
- **Electricity is cheap; the hardware isn't.** About A$0.71 (US$0.49) per million tokens generated, but ~17 years to pay back the hardware against renting the same model. Local AI is a control decision. → [Finding 03](findings/03-power-and-cost.md)
- **The PCIe slot matters.** The chipset x4 slot costs ~12% alone, and the 80B runs 5% faster on two CPU-lane cards, though two cards can't hold its 128K context. → [Finding 01](findings/01-pcie-topology-and-layer-split.md)

## Findings

| # | Question | Answer |
|---|---|---|
| [01](findings/01-pcie-topology-and-layer-split.md) | What do PCIe topology and splitting a model across cards cost? | Chipset slot −12%; layer split −7% writing, +50% reading; ~1 ms per hand-off regardless of link width |
| [02](findings/02-hsa-enable-sdma.md) | Why was real serving 2.6× slower than the benchmark? | `HSA_ENABLE_SDMA=0` in my local config: 21.0 → 54.3 t/s once removed |
| [03](findings/03-power-and-cost.md) | What does a local rig cost per token, including hardware? | 80 W idle, 425–440 W generating, ≤886 W reading; A$0.71 per million tokens; cloud wins on total cost |
| [04](findings/04-qwen38-vs-80b-blind-eval.md) | Is the 177B really smarter than the 80B? | Yes: 27–28 vs 18–23 of 30 on two AI judges; the 80B is ~3.7× faster per answer |

## Numbers at a glance

llama.cpp with HIP and flash attention, ROCm 7.2 containers, `-ngl 99 -sm layer -fa 1`. Mean of 3–5 runs; wall power is the whole rig.

| Model | Quant | Cards | Engine | Generation t/s | Prompt t/s |
|---|---|---|---|---|---|
| Qwen3.8-Flash-Next 177B-A3B | UD-Q3_K_XL | 2 (x8 + x8) | b11804 | **37.5** | |
| Qwen3.8-Flash-Next 177B-A3B | UD-Q3_K_XL | 3 | b11804 | 36.2 | 1,251 (pp512) |
| Qwen3-Coder-Next 80B-A3B | UD-Q6_K | 3 | b11804 | **61.8** | |
| Qwen3-Coder-Next 80B-A3B | UD-Q6_K | 3 | b8763 | 51.8 – 54.6 | 2,373 (pp4096) |
| Qwen3-Coder-Next 80B-A3B | UD-Q6_K | 2 (x8 + x8) | b8763 | 57.3 | |
| Qwen3.6-35B-A3B | UD-Q4_K_M | 1 (x8) | b8763 | 75.4 | 2,292 (pp512) |
| Qwen3.6-35B-A3B | UD-Q4_K_M | 1 (chipset x4) | b8763 | 66.2 | 2,271 (pp512) |

Generation is tg2048 except the 35B rows (tg128). The 80B draws 425–440 W at the wall while generating. Qwen3.8 keeps 51B of its parameters (an n-gram lookup table) in system RAM by design. Model hashes, exact commands and every run are in [`data/`](data/).

## How I test

1. **Provenance before numbers:** OS, kernel, CPU governor, PCIe links, engine build and the model's sha256 with every run.
2. **One variable at a time.**
3. **A–B–A, the omega-3 of benchmarking:** baseline, change, baseline again. If the two A runs agree, the difference in B is the change, not heat or drift.
4. **Benchmark *and* real use:** benchmark numbers are checked against real requests through a server. Finding 02 only showed up in real serving.
5. **Check, don't trust:** answers are scored blind against a rubric written in advance, and code is run, not just read ([`eval/`](eval/)).

## Run it on your rig

```bash
llama-bench -m <model>.gguf -ngl 99 -sm layer -fa 1 -p 0 -n 2048 -r 5 -o md
```

The full method is in [`bench-kit/`](bench-kit/); the blind eval is in [`eval/`](eval/). **Different hardware?** [Submit your numbers](https://github.com/getsamsultan/rdna4-local-ai-lab/issues/new?template=rig-results.yml) for a like-for-like comparison.

## The rig

| | |
|---|---|
| GPUs | 3× ASRock Radeon AI PRO R9700 Creator, 32 GB each (gfx1201, RDNA4), 96 GB total |
| PCIe | GPU0 and GPU1: PCIe 5.0 x8 (CPU lanes) · GPU2: PCIe 4.0 x4 (chipset) |
| CPU / memory / board | Ryzen 9 9950X · 2× 48 GB DDR5-5600 · ASUS ProArt B850 |
| Power / cooling | Corsair AX1600i · Lian Li Galahad II 360 AIO · Lian Li O11 Dynamic EVO XL |
| Software | Ubuntu 24.04.5, kernel 7.0 · ROCm 7.2 · llama.cpp in containers (b8763 for Findings 01–03, b11804 from 23 Oct) |
| Metering | Plug-in wall meter (±1.5%), rig only |

## In this repo

```
findings/   One write-up per finding: question, method, data, conclusion
data/       Raw results, eval answers and scores, and the power/cost workbook
eval/       Blind evaluation: prompts, rubric, run / shuffle / judge / compare scripts
bench-kit/  Runbook, power-monitoring guide and benchmark scripts
docs/       Command reference (mapped to the ROCm certification) and upgrade notes
repro/      One-command reproduction of Finding 02
ROADMAP.md  What's done and what's next
```

## Next

A minimal, offline-first ROCm serving stack of my own · R9700 vs MI300X on the same models · multi-user batching and cost per token · a physical slot swap to confirm Finding 01. Details in [ROADMAP.md](ROADMAP.md).

**Sister repo:** [model-editing-lab](https://github.com/getsamsultan/model-editing-lab), on what it costs to change an open model's weights. **Upstream:** [Osmantic/ODS #7786](https://github.com/Osmantic/ODS/issues/7786), [#7787](https://github.com/Osmantic/ODS/issues/7787).

---

<sub>Measurements, hardware and decisions are mine. Write-ups were drafted with an AI assistant and checked against the raw data. Scripts under the MIT licence. Not affiliated with AMD, ASRock, Qwen or any project mentioned.</sub>
