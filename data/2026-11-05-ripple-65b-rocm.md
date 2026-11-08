# Ripple-65B Preview on ROCm: does it compute correctly? (5 Nov 2026)

**Question:** Ricursive's Ripple-65B Preview (65B dense, Apache 2.0) needs an unmerged llama.cpp PR ([#31692](https://github.com/ggml-org/llama.cpp/pull/31692)) that its author tested on CPU and CUDA only. Does it run, and compute correctly, on ROCm with 3× R9700?

**Answer:** Yes. Perplexity on the same Q8_0 file agrees between ROCm and the CPU backend to **0.05%**, chunk by chunk, and KL divergence against a CPU reference is 0.0022 (98.7% same top token). Speed on 3× R9700: **8.4 t/s generation at Q8_0, 10.8 at Q6_K**; prompts about 1,100 to 1,200 t/s at Q8_0 and half that at Q6_K.

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

## Update 8 Nov: KL divergence against a CPU reference

Suggested by a reader on AMD Community: perplexity only scores the correct token, KLD compares the whole probability distribution at every token. Method: CPU run of Q8_0 (20 chunks, ctx 2048, no GPUs in the container) saved its logits with `--kl-divergence-base`; ROCm runs were then scored against that file with `--kl-divergence`. To give the backend gap a scale, Q6_K on ROCm was scored against the same Q8_0 CPU reference (so that row mixes the quantisation step and the backend change).

| ROCm vs CPU Q8_0 reference | Q8_0 (backend only) | Q6_K (quant step + backend) |
|---|---|---|
| Mean KLD | **0.0022 ± 0.0003** | 0.0083 ± 0.0006 |
| Median KLD | 0.00023 | 0.0013 |
| 99th percentile KLD | 0.022 | 0.103 |
| Same top token | **98.71 ± 0.08%** | 96.97 ± 0.12% |
| RMS Δp | 1.12 ± 0.13% | 2.21 ± 0.13% |
| Mean Δp (bias) | 0.003 ± 0.008% (none) | −0.033 ± 0.015% |
| PPL ratio vs reference | 1.000000 ± 0.000619 | 0.9967 ± 0.0011 |
| Seconds per 2048-token chunk (ROCm) | 1.78 | 3.40 |

**Reading:** the CPU vs ROCm difference on the same file is about a quarter of the Q8_0 to Q6_K step by mean KLD, about a fifth by median, and shows no bias. That is the size of normal rounding differences between backends, not a broken kernel. The ~1.3% of tokens where the top choice flips are near-ties.

Guess written down before the run: mean KLD under 0.01 (met), same top token above 99% (missed: 98.7%), no bias (met).

Small note: perplexity recomputed from the stored base file is 8.106938, against 8.1106 printed by the live CPU run. The base file stores probabilities in compact form, which moves PPL by about 0.05%, the same size as the CPU vs ROCm gap reported above. Q6_K came out 0.33% *lower* in perplexity than the Q8_0 reference (about 3 standard errors). That happens with quants on a single text and is not a quality gain; KLD is the better measure here. Q6_K also took nearly twice as long per chunk on ROCm, a hint to check in the speed tests.

Raw logs: [`cpu-base.log`](2026-11-05-ripple-65b-rocm/kld/cpu-base.log) (slow first pass: another run was competing for the CPU until it was stopped; results are unaffected and identical to 5 Nov), [`rocm-q8-vs-cpu.log`](2026-11-05-ripple-65b-rocm/kld/rocm-q8-vs-cpu.log), [`rocm-q6k-vs-cpu.log`](2026-11-05-ripple-65b-rocm/kld/rocm-q6k-vs-cpu.log).

## Update 8 Nov: speed, A–B–A (Q8_0 / Q6_K / Q8_0)

llama-bench, 3× R9700, `-ngl 99 -sm layer -fa 1`, r=5, image 6414d5b, netdata restarted first, GPU temperature, power and clocks logged every 10 s. Script: [`ripple-speed.sh`](../bench-kit/scripts/ripple-speed.sh). Two sessions: one starting on cold cards (16:21), one after 5 minutes of warm-up load (17:47).

| t/s | Cold: Q8_0 | Q6_K | Q8_0 | Warm: Q8_0 | Q6_K | Q8_0 |
|---|---|---|---|---|---|---|
| Generation, tg128 | **8.43** | **10.78** | **8.39** | **8.43** | **10.77** | **8.40** |
| Prompt, pp512 | 632 | 318 | 557 | 624 | 315 | 574 ± 28 |
| Prompt, pp2048 | 1,199 | 617 | 1,084 ± 25 | 1,187 | 612 | 1,109 ± 30 |

**Generation is clean:** both A runs agree, in both sessions, to 0.05 t/s. Q6_K generates 28% faster than Q8_0, almost exactly their size ratio (about 53.2 GB vs 68.9 GB, 1.30×). That is memory-bound generation: about 575 GB/s for either file, roughly 90% of the R9700's 640 GB/s, with one card reading at a time under `-sm layer`.

**Q6_K reads prompts at half the speed of Q8_0** on ROCm (gfx1201), far beyond any run-to-run noise here, and consistent with the 3.40 vs 1.78 s per chunk seen in the KLD runs. Practical choice: Q6_K for chat (faster replies), Q8_0 for long documents and agents.

**Q8_0 prompt speed is not settled.** In both sessions the second Q8_0 run is 7 to 12% slower with a large spread, while the first is tight. Per-repetition values from the warm session show it is two levels, not a slow decline:

| Warm session | rep 1 | 2 | 3 | 4 | 5 |
|---|---|---|---|---|---|
| Run 1 Q8_0, pp2048 | 1187.8 | 1187.3 | 1187.1 | 1186.1 | 1185.6 |
| Run 3 Q8_0, pp2048 | 1078.1 | 1129.0 | 1131.5 | 1129.7 | 1074.3 |
| Run 3 Q8_0, pp512 | 560.8 | 623.3 | 558.9 | 564.3 | 563.5 |

My first guess (cold cards boost higher, so run 1 is faster) was wrong: the warm session shows the same pattern. Discrete steps point at a clock or power state switching between levels rather than temperature. Next test: the same A–B–A with a fixed performance level, then with a power cap. Until then, read Q8_0 prompt speed as **about 1,080 to 1,200 t/s at 2048 tokens**.

PCIe links seen under load in the GPU log: GPU0 and GPU1 PCIe 5.0 x8 (32 GT/s), GPU2 PCIe 4.0 x4 (16 GT/s).

## Update 8 Nov: re-check at the newer PR commit

The PR gained six commits after 6414d5b (explicit RoPE/NoPE pattern, per-layer SwiGLU clamp, model RoPE parameters on the sliding layers, chat template override dropped). The current head (cccba7f, "match #31733 refactor") does not build on its own: it needs that refactor from master. Built ebe7f66 instead, which has all the maths changes, and re-ran perplexity on the same Q8_0 file: **8.1264 ± 0.0596, identical** to 6414d5b. The results above hold for the current PR maths.

## Caveats

- **8.13 is not comparable to the 3.01 in the PR.** The PR does not state the dataset or context length, and Ripple Preview ships with a chat and tool-call template, so it is likely instruction-tuned; those score much worse on Wikipedia text than base models. Here perplexity is a "does it compute correctly" check, not a quality score.
- My script's first guess ("above 5 = broken") was too strict for that reason. The CPU cross-check is what settles it.
- The CPU vs GPU time ratio (~65× per chunk) is a single run each, not A–B–A. Rough only.

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

Q8_0 prompt-speed dip (fixed performance level, then power cap) · a comment on PR #31692 with these results · Ripple in the next blind eval round.
