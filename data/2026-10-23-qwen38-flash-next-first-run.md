# 2026-10-23 — Qwen3.8-Flash-Next (177B, qwen4exp) first run

**Model:** unsloth/Qwen3.8-Flash-Next-GGUF, UD-Q3_K_XL, 3 files, 83.80 GiB

| File | sha256 |
|---|---|
| Qwen3.8-Flash-Next-UD-Q3_K_XL-00001-of-00003.gguf | `f2ef4328929d8b8c8930e2856eef52128dd4ce3425302f04bc3c657431cc4c49` |
| Qwen3.8-Flash-Next-UD-Q3_K_XL-00002-of-00003.gguf | `7d230e7c9421d868b89eebaf23033af0ea1a4e046956df00fb156814fb62346e` |
| Qwen3.8-Flash-Next-UD-Q3_K_XL-00003-of-00003.gguf | `21d4f90f9cd7b7c3a1582667c20cb22f7b03de895b88a23bb20aaeaa44f2c199` |

**Engine:** `ghcr.io/ggml-org/llama.cpp:full-rocm`, build 11804 (commit c7fc50941). The older b8763 image used elsewhere in this repo can't load the `qwen4exp` architecture.

## What the model is (from the GGUF metadata and load log)

| Property | Value |
|---|---|
| Total parameters | 176.94 B, of which **51.2 B is one n-gram embedding table** (`per_layer_token_embd`, IQ4_NL, ~26.8 GiB). The "125B" quoted elsewhere excludes it |
| Active per token | ~3 B ("A3B"): 512 experts, 10 used, expert FFN 640 |
| Layers | 48, full attention every 4th layer, the rest linear-attention (SSM-style) |
| New in this architecture | hyper-connections (4), sparse-attention indexer (top 2,048 tokens), compressed attention on some layers, 3-gram per-layer embeddings |
| Embedding width / context | 2,560 / 262,144 |

## Where it loads (3 cards, `-ngl 99`)

| Buffer | Size |
|---|---|
| ROCm0 / ROCm1 / ROCm2 | 20,524 / 18,707 / 18,466 MiB (57.7 GiB total) |
| CPU_Mapped (system RAM) | 27,466 + 644 MiB: the n-gram table and token embeddings |

All 49 layers are offloaded. llama.cpp keeps the embedding lookups in system RAM by design; each token reads only a few rows.

## Speed (llama-bench, `-ngl 99 -sm layer -fa 1`)

| Test | GPUs | t/s |
|---|---|---|
| pp512 (`-r 3`) | 0,1,2 | 1,251.19 ± 7.01 |
| tg128 (`-r 3`) | 0,1,2 | 35.83 ± 0.12 |

Two vs three cards, `-ub 256 -p 0 -n 2048 -r 3`, A–B–A order:

| Order | GPUs | tg2048 |
|---|---|---|
| 1 | 0,1,2 | 36.04 ± 0.26 |
| 2 | 0,1 (CPU lanes) | **37.45 ± 0.02** |
| 3 | 0,1,2 | 36.28 ± 0.05 |

Two cards are ~4% faster (+3.6% against the 3-card mean), the same direction as the 80B (+5%). The 3-card runs agree within 0.7%.

## Open questions

- Generation is slower than the 80B (36 vs 55 t/s) despite a similar active size. Candidates: the new operations (hyper-connections, indexer) may not be optimised for ROCm yet; 10 small experts per token instead of fewer larger ones; the embedding lookups in RAM. Not yet tested.
- How much context fits on two cards (~4 GiB free after weights and buffers).
- Speculative decoding with the model's MTP module (needs a llama.cpp fork at the time of writing).
