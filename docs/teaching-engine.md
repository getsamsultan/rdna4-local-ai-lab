# A teaching inference engine for RDNA4 (design sketch)

**Status:** design only, not started. Working name to be chosen.

**Goal:** write a small LLM inference engine from scratch, one piece at a time, to learn how engines like llama.cpp actually work, and to grow it later into an engine whose outputs can be audited. Every milestone ends in a test against a reference, and every result gets the lab's usual treatment: a guess written down first, a null test, A-B-A for speed, raw data in the repo.

This is not an attempt to beat llama.cpp. llama.cpp is the reference it is measured against.

## Scope

| In | Out (for now) |
|---|---|
| One model family: **Qwen3 dense** (0.6B for fast iteration, 4B and 8B for real speed numbers) | Mixture-of-experts, looped models, vision |
| One GPU: one R9700 (gfx1201), HIP | Multi-GPU, Vulkan, CUDA |
| GGUF files (the same files llama.cpp reads, so comparisons are like for like) | Safetensors loading, own conversion |
| BF16 first, then Q8_0 | K-quants, I-quants |
| Batch size 1, then a few concurrent requests | Large-scale batching, paged attention |
| A plain C++ CPU path, kept forever as the correctness reference | Fast CPU inference |

Why Qwen3 dense: a standard modern decoder (grouped-query attention, RoPE, RMSNorm, SwiGLU feed-forward, plus a per-head RMSNorm on Q and K) with small sizes that load in seconds, and GGUFs that llama.cpp already runs well.

Language: C++20 and HIP. No PyTorch in the engine itself; Python only for test scripts.

## Architecture

```
gguf/        GGUF reader: header, metadata, tensor table, memory-mapped data
tokenizer/   BPE from the GGUF vocabulary and merges; chat template for Qwen3 (hard-coded at first)
model/       Qwen3 config and weights; the forward pass written once against a small op interface
cpu/         reference ops in plain C++ (fp32 accumulate): matmul, RMSNorm, RoPE, softmax, attention, SwiGLU
hip/         the same ops as HIP kernels, first naive, then tuned
kv/          KV cache: allocation, append, reuse rules
sample/      greedy, temperature, top-k/top-p, logprobs output
server/      minimal OpenAI-compatible /v1/chat/completions with logprobs
audit/       manifest and hash checks at load, run records
tests/       op tests (HIP vs CPU), end-to-end checks vs llama.cpp
```

The forward pass is written once and calls ops through one interface, so the CPU and GPU paths can never drift apart in structure, only in numbers. That is what makes the CPU path a useful reference.

## Milestones

Each milestone has a **gate**: it is not done until the test passes.

| # | Build | Gate (how it is proven) |
|---|---|---|
| M0 | GGUF reader and tokenizer | Token IDs match `llama-tokenize` on a fixed text set, 100% |
| M1 | CPU forward pass, fp32 accumulate, greedy | Top token matches llama.cpp CPU on 20 prompts; KL divergence from llama.cpp's logits at backend-noise level |
| M2 | KV cache, sampling, chat template, streaming | A chat answer identical to the M1 path with the cache off |
| M3 | HIP ops, naive (one simple kernel per op; rocBLAS allowed for matmul) | Each op matches the CPU op within tolerance; end-to-end KLD vs the CPU path at the size of Ripple and Inkling backend gaps (about 0.002 to 0.003) |
| M4 | Own kernels: GEMV for decode, tiled GEMM for prefill, a fused attention kernel | Same KLD gate as M3; decode speed as a percentage of the card's memory bandwidth |
| M5 | Q8_0: dequantise inside the matmul kernels | KLD vs BF16 close to llama.cpp's Q8_0 vs BF16 on the same file |
| M6 | **Repeatable by design**: fixed reduction order in every kernel, no kernel choice that depends on batch size or cache state | `squeeze check` null test 20/20 identical **with the prompt cache on** (llama.cpp on ROCm does not pass this; see the lab's prompt-cache finding) |
| M7 | Server with logprobs, hardened defaults: localhost only, API key required, no debug endpoints | `squeeze check` runs against it unchanged; the playbook's F2 server checks pass |
| M8 | Provenance: weights and template hashed against a manifest at load; each run records commit, flags and hashes | A tampered GGUF (one byte changed) refuses to load; every result traces to a run record |

M0 to M3 are the core lessons. M4 is where most of the speed and most of the learning about GPUs lives. M6 to M8 are what make it more than a copy of llama.cpp: they are the "engine you can audit" from the agentic security track.

## How it is measured

- **Correctness first:** op tests against the CPU path, then end-to-end KLD and top-token agreement against llama.cpp on the same GGUF. A null test (the engine against itself) sets the noise floor before any comparison.
- **Speed against physics, not just against llama.cpp:** decode on a dense model is memory-bound, so the ceiling is roughly the card's memory bandwidth divided by the bytes of weights read per token. Report tokens/s *and* the percentage of that ceiling (Ripple-65B on llama.cpp reached about 90%).
- **Speed against llama.cpp:** same GGUF, same card, A-B-A with `llama-bench` settings matched, prompt and generation separately.
- **Profiling:** rocprofv3 traces for M3 and M4 kernels; what takes the time, before changing anything.

## What each milestone teaches

| Milestone | Lesson |
|---|---|
| M0 | How a model file is laid out; why tokenizers cause subtle bugs |
| M1 | What a transformer layer actually computes, line by line |
| M2 | Why the KV cache exists and what it costs in memory |
| M3 | Moving data to the GPU; kernels, threads, blocks; where numerical differences come from |
| M4 | Memory bandwidth, tiling, LDS, wavefronts on RDNA4; why prefill and decode need different kernels |
| M5 | Quantisation formats and why dequantising inside the kernel matters |
| M6 | Why the same input can give a different output, and the price of preventing it |
| M7 | What a server adds, and its attack surface |
| M8 | Supply-chain integrity for model files |

Each one is also a write-up and a post.

## Ground rules

- The lab's method applies: guess first, one variable at a time, A-B-A, raw data kept.
- Written with an AI assistant, disclosed in the repo, and every part understood well enough to explain without it.
- Reading llama.cpp's source to learn is fine; copying its code is not the point. Where an idea comes from llama.cpp or a paper, say so in the code.
- The engine lives in its own repo once M0 starts; this file stays as the design record.

## First steps

1. Pick the exact Qwen3 0.6B GGUF (BF16) and record its hash; dump its metadata with `gguf_dump.py`.
2. M0: the GGUF reader, tested by listing every tensor name, shape and type and diffing against `gguf_dump.py`.
3. Then the tokenizer, tested against `llama-tokenize`.
