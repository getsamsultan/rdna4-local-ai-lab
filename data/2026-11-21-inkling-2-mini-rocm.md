# Inkling 2 Mini on ROCm: correct, and a multi-GPU split trap (21 Nov 2026)

**Question:** Inkling 2 Mini (Thinking Machines, released 20 Nov 2026, Apache-2.0) is a *looped* mixture-of-experts: 24 stored layers, the middle 12 run three times. llama.cpp support landed the same week (#32217, #32429, #32657, #32694). Does it compute correctly on ROCm, and what do the quants cost?

**Answer:** Yes. ROCm against CPU on the same full-precision file: mean KL divergence **0.0026**, the size of ordinary backend rounding. Q8_0 is practically lossless; Q4_K_M costs 0.7% perplexity and keeps the same top token 95% of the time. Along the way: with `-sm layer`, llama.cpp's default split puts most of the weights on the first card and none on the last, which ran BF16 out of memory.

## Setup

| | |
|---|---|
| Weights | `thinkingmachines/Inkling-2-Mini` (NVFP4/MXFP8 release) |
| Engine | llama.cpp master `46eb1742d` (21 Nov 2026), ROCm 7.2.1 Docker image `lab-llama:inkling-46eb1742d-rocm7.2.1`, gfx1201 |
| GPUs | 3x Radeon AI PRO R9700 (32 GB each) |
| Script | [`bench-kit/scripts/inkling-mini.sh`](../bench-kit/scripts/inkling-mini.sh) (build, convert, quant, ppl, kld) |

## Conversion

`convert_hf_to_gguf.py --outtype bf16`. The converter unpacks the 4-bit weights, so the BF16 GGUF is an essentially exact copy of the release. Text backbone only (the converter skips vision and multi-token prediction). Checked: architecture `inkling2_loop`, loop keys present (`loop.start`, `loop.end`, `loop.count`, `loop.gate_rank`, `loop.varying`). 704 tensors, 48.6 GiB; every stored layer is 1.95 GiB.

| File | sha256 |
|---|---|
| inkling-2-mini-bf16.gguf | `a27e238e40dc634bdbc80735a15b82d3d84077e4c180e015586fe20f3942c261` |
| inkling-2-mini-q8_0.gguf | `cf5315ada5535dfb21b019c168ea418bdd56f1dd29f11961d25affb40fe583af` |
| inkling-2-mini-q4_k_m.gguf | `4c3ab725c69bedd1efd4d9fa6fe8994684e875f205c0c8be78c16d317a946b22` |

## Perplexity (wikitext-2, ctx 2048, full set, ROCm)

| | PPL | vs BF16 |
|---|---|---|
| BF16 | 5.9341 ± 0.0353 | |
| Q8_0 | 5.9356 ± 0.0353 | +0.03% |
| Q4_K_M | 5.9764 ± 0.0355 | +0.71% |

## KL divergence against a CPU BF16 reference (20 chunks)

The reference is the BF16 file run on CPU (no GPUs in the container), logits saved with `--kl-divergence-base` (reference PPL 5.9658, logits sha256 `b8f0fcf69d6e239d1a7020f841385d693be6968079e23d49d1eb9d51cb797f97`). Each ROCm run is scored against it.

| ROCm vs CPU BF16 | Mean KLD | Same top token | PPL ratio |
|---|---|---|---|
| BF16 (backend only) | 0.002558 ± 0.000063 | 97.918 ± 0.100% | 1.000954 ± 0.000625 |
| Q8_0 | 0.003315 ± 0.000107 | 97.732 ± 0.104% | 1.001124 ± 0.000683 |
| Q4_K_M | 0.014351 ± 0.000228 | 95.039 ± 0.152% | 1.007343 ± 0.001412 |

The BF16 row measures the backend alone: 0.0026 is in line with Ripple-65B's 0.0022 on the same rig, so the new looped code computes correctly on ROCm. Q8_0 adds almost nothing; Q4_K_M costs about five times the backend gap.

Written down before the run: ROCm BF16 KLD under 0.005 (right), same top token above 98% (wrong: 97.9%), Q4_K_M KLD 0.01 to 0.05 and same top token 93 to 97% (right). Publish gate set in advance: ROCm BF16 KLD above 0.05 means do not publish. Passed by a factor of 20.

## The multi-GPU split trap

BF16 (48.6 GiB) should fit 3x 32 GB. It failed: `allocating 34043.06 MiB on device 0: out of memory`. With `-ts 6,36,6` it failed again with the **same 34,043 MiB**, on device 1. Every stored layer is 1.955 GiB, so 34,043 MiB is exactly 17 layers.

The rule, from the source (`src/models/inkling2-loop.cpp`, `src/llama-model.cpp`):

- The loop model sets `n_layer_all` to the number of **cache slots**: 24 stored + 2 extra passes x 12 looped = 48, so every pass has its own KV cache.
- `-sm layer` assigns slot `il` to the device whose cumulative split share covers `il / 49` (48 slots + output).
- Weights exist only at slots 0 to 23; slots 24 to 47 reuse them.

So the default 3-card split puts stored layers 0 to 16 (17 layers) on GPU0, 17 to 23 on GPU1, and **no weights on GPU2**. `-ts 6,36,6` puts 0 to 6 on GPU0 and 7 to 23 (17 layers) on GPU1. A split that matches the rule, `-ts 8,8,33`, gives 8 stored layers per card, and BF16 loaded. During that run GPU2, holding the last 8 layers and the KV slots of the repeat passes, was the busiest card (90% vs 37% on GPU0).

Speed hint (one run each, not A-B-A): full-set Q8_0 perplexity took 15 min 35 s with the default split and 10 min 35 s with `-ts 6,36,6`, with identical results. A plausible reason: repeat passes keep their KV cache on a different card from their weights, so looped layers cross PCIe. Next: Q8_0 on one card (`-sm none`) to remove the hops, then a llama.cpp issue with the numbers.

## Published

Q8_0 and Q4_K_M with this verification: [askthesultans/Inkling-2-Mini-GGUF](https://huggingface.co/askthesultans/Inkling-2-Mini-GGUF). Quantised copies only; no other changes to the weights.

## Caveats

- One evaluation text (wikitext-2); a coding-tuned model may weigh other text differently. KLD on 20 chunks.
- Text only. Vision and multi-token prediction are not in these files.
- Tested on RDNA4 only.
