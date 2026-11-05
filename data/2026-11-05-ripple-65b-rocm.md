# Ripple-65B Preview on ROCm: does it compute correctly? (5 Nov 2026)

**Question:** Ricursive's Ripple-65B Preview (65B dense, Apache 2.0) needs an unmerged llama.cpp PR ([#31692](https://github.com/ggml-org/llama.cpp/pull/31692)) that its author tested on CPU and CUDA only. Does it run, and compute correctly, on ROCm with 3× R9700?

**Answer:** Yes. Perplexity on the same Q8_0 file agrees between ROCm and the CPU backend to **0.05%**, chunk by chunk. No speed numbers yet (those come next, A–B–A).

## Setup

| | |
|---|---|
| Weights | Official BF16 safetensors, `ricursiveAI/Ripple-65B-Preview`, 16 shards (sha256 of each in the bundle) |
| Engine | llama.cpp PR #31692 head `6414d5b0c9e5895473036c90c2bd305ce4ceccc4`, ROCm 7.2.1 Docker image, gfx1201, `--target full` |
| Image | `lab-llama:ripple-pr31692-6414d5b0c-rocm7.2.1` |
| GPUs | 3× Radeon AI PRO R9700 (96 GB), `-ngl 99 -sm layer -fa on` |
| CPU reference | Same image, no GPU devices passed to the container (`ggml_cuda_init: no ROCm-capable device is detected`), 16 threads |
| Script | [`bench-kit/scripts/ripple-pr.sh`](../bench-kit/scripts/ripple-pr.sh) (build, convert, quant, ppl) |

## Steps

1. **Convert** BF16 safetensors to BF16 GGUF with the PR's converter: 1,203 tensors, 129.6 GB, 3 minutes from a Gen5 NVMe. The converter declined to run the repo's custom Python and read `config.json` instead (safe, and it found everything it needed). One harmless warning: the chat template was present twice, the `chat_template.jinja` copy was kept.
2. **Check the sliding-window keys.** The PR's automated review warned that RoPE is silently skipped if they are missing. Present: `ricursive.attention.sliding_window`, `ricursive.attention.sliding_window_pattern`.
3. **Quantise** to Q8_0 and Q6_K (about 75 s and 135 s), then sha256 every file.
4. **Perplexity**, wikitext-2 raw test set, ctx 2048, Q8_0: full set on ROCm, first 20 chunks on CPU.

## Results

| Backend | Chunks | PPL | Time |
|---|---|---|---|
| ROCm, 3× R9700 | 141 (full set) | **8.1264 ± 0.0596** | 4 min 21 s (1.78 s per chunk) |
| ROCm, at chunk 20 | 20 | 8.1069 | |
| CPU, 16 threads | 20 | **8.1106 ± 0.1570** | 40 min (116 s per chunk) |

Chunk by chunk (running average):

| Chunk | ROCm | CPU | Diff |
|---|---|---|---|
| 1 | 7.1701 | 7.2120 | +0.58% |
| 5 | 8.6294 | 8.6390 | +0.11% |
| 10 | 7.6731 | 7.6754 | +0.03% |
| 15 | 8.0608 | 8.0640 | +0.04% |
| 17 | 8.2906 | 8.2945 | +0.05% |
| 18 | 8.2582 | 8.2613 | +0.04% |
| 20 | 8.1069 | 8.1106 | +0.05% |

The gap settles at about 0.05%, well inside the error bar, which is what different summation order between backends looks like. A broken kernel or skipped RoPE shows up as perplexity in the hundreds or as NaN, not in the third decimal.

## Caveats

- **8.13 is not comparable to the 3.01 in the PR.** The PR does not state the dataset or context length, and Ripple Preview ships with a chat and tool-call template, so it is likely instruction-tuned; those score much worse on Wikipedia text than base models. Here perplexity is a "does it compute correctly" check, not a quality score.
- My script's first guess ("above 5 = broken") was too strict for that reason. The CPU cross-check is what settles it.
- The CPU vs GPU time ratio (~65× per chunk) is a single run each, not A–B–A. Rough only.
- Q6_K was made and hashed but not yet checked.

## Gotcha

The first ROCm run failed in 17 seconds with `cudaMalloc failed: out of memory` on GPU0: another model (lab-llm, Qwen3.8) still held 33.2 GB on GPU0 and 31.5 GB on GPU1. Q8_0 is about 69 GB, so it needs all three cards empty. The script now refuses to start `ppl` while any container is running (a2e7e2a).

## Model shape (from the converter)

Embedding 5,120 · 80 query heads, 8 KV heads · FFN 40,960 · RoPE theta 10,000 · context length in metadata 2,097,152 (not tested) · extra per-layer tensors `attn_gate` and `attn_vres_lambda`.

## Hashes

| File | sha256 |
|---|---|
| ripple-65b-bf16.gguf | `6b9789df3d17a90e84293c412b6e5a77aa70004e00cf3a6e331883826100d522` |
| ripple-65b-q8_0.gguf | `1e4e245f8013834c1c7be26a70dba0ed37c0bc0a88a8c5aef2ea37968d281d89` |
| ripple-65b-q6_k.gguf | `cd9999bb7e02784940e25160ea9ab2afba01035ad35129c38d23acb1a9ce3d40` |

GGUFs made from an unmerged PR; not published. Safetensors hashes, full logs and per-chunk values: [`ripple-bundle.txt`](2026-11-05-ripple-65b-rocm/ripple-bundle.txt).

## Next

Speed A–B–A (tg and pp, Q8_0 and Q6_K) · Q6_K perplexity · a comment on PR #31692 with these results · Ripple in the next blind eval round.
