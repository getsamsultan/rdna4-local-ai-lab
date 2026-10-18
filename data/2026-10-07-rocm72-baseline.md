# ROCm 7.2 Baseline — 3× Radeon AI PRO R9700
Date: 2026-10-07 (Sydney)

## Provenance
- Host: Ubuntu 24.04.5 LTS, kernel 7.0.0-38-generic
- ROCm (container): rocm/dev-ubuntu-24.04:7.2-complete
- llama.cpp: tag b8763, commit ff5ef82, built for gfx1201
  - HIP + rocWMMA flash attention (-DGGML_HIP_ROCWMMA_FATTN=ON)
  - One 5-line patch: expf -> __expf in ggml/src/ggml-cuda/fattn-common.cuh
  - MMQ (Strix Halo) patch did NOT apply to b8763
- Bench image: bench-rocm72-patched:b8763 (builder stage of ODS Dockerfile.amd)
  - llama-server sha256 357bac05bd872136de422712ee473875295764d3fb9f7106e9f6b1b511087525 (identical to ODS serving binary)
  - llama-bench sha256 f0650a592544653ddb3cdf2d7b32daa5d5895454573eb2f73487486aa6c5202d
- Model: Qwen3.6-35B-A3B-UD-Q4_K_M.gguf (20.60 GiB, 34.66B params)
- Settings: -ngl 99 -sm layer -fa 1 -p 512,2048 -n 128 -r 5 (default -b 2048 -ub 512)
- All other services stopped; VRAM 0% on GPUs 0-2 before runs

## PCIe topology (measured, upstream switch ports)
| GPU (HIP) | Bus | Path | Negotiated link |
|---|---|---|---|
| 0 | 03:00.0 | CPU root port 01.1 | PCIe 5.0 x8 |
| 1 | 07:00.0 | CPU root port 01.3 | PCIe 5.0 x8 |
| 2 | 0c:00.0 | Chipset (02.1), shared with 2x 5GbE, Wi-Fi, USB, SATA | PCIe 4.0 x4 |

## Results (t/s, mean ± sd, n=5)
| GPUs | pp512 | pp2048 | tg128 |
|---|---|---|---|
| 0 | 2291.79 ± 10.97 | 2256.65 ± 8.45 | 75.39 ± 0.13 |
| 1 | 2300.17 ± 12.35 | 2267.50 ± 7.97 | 75.26 ± 0.20 |
| 2 | 2270.74 ± 12.72 | 2216.70 ± 6.50 | 66.18 ± 0.10 |
| 0,1 | 2196.86 ± 10.40 | 3375.46 ± 5.66 | 70.27 ± 0.31 |
| 0,2 | 2159.88 ± 12.36 | 3309.45 ± 7.08 | 66.17 ± 0.23 |
| 1,2 | 2152.55 ± 13.49 | 3302.71 ± 6.06 | 65.78 ± 0.19 |
| 0,1 (repeat, heat-soak check) | 2182.14 ± 10.55 | 3366.49 ± 6.04 | 70.26 ± 0.32 |

## Analysis
- Chipset card alone: -12% decode vs CPU-lane cards (66.2 vs 75.3), pp within -2%.
- Per-token model: pair time = mean of the two cards' single-card times + hop.
  - Hop cost: 0,1 = 0.96 ms; 0,2 = 0.93 ms; 1,2 = 1.00 ms -> the x4 link itself adds no measurable cost.
- Decode is not bandwidth-bound: ~75 t/s x ~1.8 GB active weights ≈ 137 GB/s vs 640 GB/s.
- Splitting a model that fits on one card: -7% decode, +50% pp2048 (pipelining across micro-batches; pp512 is one micro-batch, no gain).
- Heat-soak check passed (repeat matches first 0,1 run).

## Clock check under load (rocm-smi, 2 s sampling)
| | GPU 0 | GPU 2 |
|---|---|---|
| Peak sclk | 3342-3367 MHz | 3342-3371 MHz |
| Peak mclk | 1258 MHz (level 5) | 1258 MHz (level 5) |
| Peak junction | 53 °C | 55 °C |
- Power readings failed under load (rocm-smi error) — not quoted.
- Conclusion: clocks/temps match -> points to chipset-path latency, not the card. Physical slot swap pending to confirm.

## Open items
- Physical slot swap to confirm card vs slot
- Unpatched build (no __expf) comparison — low priority
- 80B (3-card) llama-bench run with same settings
- Explain earlier rough "~45 t/s on 35B" figure (Lemonade, 3 cards, 128K ctx) vs measured 75 t/s
- Audit outbound traffic from the serving stack
- ROCm 10: build bench-rocm10 side by side, rerun identical matrix
