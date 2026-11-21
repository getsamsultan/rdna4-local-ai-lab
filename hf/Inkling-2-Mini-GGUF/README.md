---
license: apache-2.0
base_model: thinkingmachines/Inkling-2-Mini
base_model_relation: quantized
pipeline_tag: text-generation
tags:
  - gguf
  - llama.cpp
  - rocm
  - amd
  - inkling2_loop
---

# Inkling 2 Mini GGUF (Q8_0, Q4_K_M), verified on AMD ROCm

Q8_0 and Q4_K_M GGUFs of [thinkingmachines/Inkling-2-Mini](https://huggingface.co/thinkingmachines/Inkling-2-Mini) (Apache-2.0), with **measured** quality loss against a full-precision reference, and notes for running it on multiple AMD GPUs.

**Text only.** llama.cpp's converter keeps the language model; the vision encoder and multi-token-prediction heads are not included.

## Files

| File | Size | sha256 |
|---|---|---|
| `inkling-2-mini-q8_0.gguf` | TBD | `cf5315ada5535dfb21b019c168ea418bdd56f1dd29f11961d25affb40fe583af` |
| `inkling-2-mini-q4_k_m.gguf` | 17,478,094,208 bytes (16.3 GiB) | `4c3ab725c69bedd1efd4d9fa6fe8994684e875f205c0c8be78c16d317a946b22` |

## How it was made

1. Official weights (`thinkingmachines/Inkling-2-Mini`, NVFP4/MXFP8) converted with llama.cpp's `convert_hf_to_gguf.py` at commit `46eb1742d` (21 Nov 2026) to BF16. The converter unpacks the 4-bit weights, so the BF16 GGUF is an essentially exact copy of the release (704 tensors, 48.6 GiB, sha256 `a27e238e…942c261`).
2. `llama-quantize` BF16 → Q8_0 and Q4_K_M. No imatrix. No other changes to the weights.
3. Checked that the GGUF declares `inkling2_loop` and carries the loop settings (`loop.start`, `loop.end`, `loop.count`, `loop.gate_rank`, `loop.varying`).

## Verification (3x AMD Radeon AI PRO R9700, gfx1201, ROCm 7.2.1)

Perplexity, wikitext-2 test set, context 2048, full set:

| | PPL |
|---|---|
| BF16 (reference) | 5.9341 ± 0.0353 |
| Q8_0 | 5.9356 ± 0.0353 (+0.03%) |
| **Q4_K_M** | **5.9764 ± 0.0355 (+0.71%)** |

KL divergence against a **CPU BF16 reference** (20 chunks, `llama-perplexity --kl-divergence`), which measures both quantisation loss and GPU-vs-CPU correctness:

| ROCm vs CPU BF16 | Mean KLD | Same top token | PPL ratio |
|---|---|---|---|
| BF16 (backend only) | 0.0026 ± 0.0001 | 97.92 ± 0.10% | 1.0010 ± 0.0006 |
| Q8_0 | 0.0033 ± 0.0001 | 97.73 ± 0.10% | 1.0011 ± 0.0007 |
| **Q4_K_M** | **0.0144 ± 0.0002** | **95.04 ± 0.15%** | **1.0073 ± 0.0014** |

Reading it: the BF16 row is ROCm against CPU on the same full-precision file, so it measures the backend alone. A gap of 0.0026 is ordinary rounding between backends (a 65B dense model measured the same way on this rig: 0.0022), so the new looped code computes correctly on ROCm. Q8_0 adds almost nothing on top of that. Q4_K_M costs about five times the backend gap and keeps the same top token 95% of the time. CPU reference: 20 chunks, PPL 5.9658, logits file sha256 `b8f0fcf6…cb797f97`.

## Running it

Needs a recent llama.cpp: Inkling 2 Mini (`inkling2_loop`) support landed on 20 Nov 2026 (#32694, with fixes in #32429 and #32657). Older builds, and tools that bundle them, will not load it.

**Which file:** Q8_0 is practically lossless (+0.03% perplexity vs BF16) and fits a 32 GB card. Q4_K_M costs about 0.7% and fits a 24 GB card. Tested on RDNA4 (Radeon AI PRO R9700); it should work wherever llama.cpp's ROCm, CUDA, Vulkan, Metal or CPU backends run, but other hardware (including CDNA) was not tested here.

**One GPU:** `-ngl 99 -sm none`.

**Several GPUs: read this.** The looped model gives llama.cpp 48 layer slots (24 stored layers + 2 extra passes of the 12 looped ones). With `-sm layer`, the default split divides those 48 slots across the cards, but weights only live in the first 24, so the first card gets most of the weights and the last card may get none. On 3 cards at BF16 this put 17 of 24 layers (33 GiB) on GPU 0 and failed. A split that matches the rule, `-ts 8,8,33` on three cards, put 8 stored layers on each. Repeat passes may also keep their memory on a different card from their weights, adding PCIe traffic: in one run each, Q8_0 took 15 min 35 s with the default split and 10 min 35 s with `-ts 6,36,6`.

## Credits and licence

Model by [Thinking Machines Lab](https://thinkingmachines.ai), Apache-2.0; this repository redistributes a quantised copy under the same licence. GGUF support by the llama.cpp contributors. Conversion and measurements by Sam Sultan; full method and numbers: [the write-up in rdna4-local-ai-lab](https://github.com/getsamsultan/rdna4-local-ai-lab/blob/main/data/2026-11-21-inkling-2-mini-rocm.md) (GitHub). Not affiliated with Thinking Machines Lab or AMD.
