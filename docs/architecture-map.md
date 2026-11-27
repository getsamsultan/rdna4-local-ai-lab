# Architecture map: where open models are going, and what is worth testing here

**As of 27 November 2026.** A working map of the design choices in current open-weight models, what each one changes when you run it on this rig, and which ones are worth a measurement. Facts about other people's models come from their model cards, papers or reports and are linked; anything not yet checked on this rig is marked as such.

Rig budget for reference: 3x R9700 (96 GB VRAM) plus 91 GiB RAM, so roughly 185 GB for weights, KV cache and buffers combined.

## The seven design axes

### 1. Attention: how each token looks back

| Design | What it does | Examples | What it means here |
|---|---|---|---|
| Grouped-query attention | Standard full attention, with key/value heads shared to shrink the KV cache | Most dense models | The baseline every engine handles well |
| Multi-head latent attention (MLA) | Compresses keys and values into a small latent vector before caching | DeepSeek V3, Kimi K3, GLM-5.3-Flash | Much smaller KV cache; well supported in llama.cpp |
| Sliding window plus global layers | Most layers only see recent tokens, a few see everything | Ripple-65B (tested here) | Cheap long context; RoPE handling per layer type is a source of bugs (seen in the Ripple PR) |
| No position encoding (NoPE) | Drops RoPE entirely | Kimi K3 (every layer) | Fewer moving parts; long-context behaviour is the open question |
| DeepSeek Sparse Attention (DSA) | A small "indexer" picks up to about 2,048 earlier tokens per query; attention runs only over those | DeepSeek V3.2, GLM-5.3-Flash, GigaChat 4, Kimi K3.1 Pro | Long context without the full quadratic cost. Engine support is new and, as far as found, not tested on ROCm |
| Compressed sparse attention (CSA + HCA) | DSA-style selection plus heavily compressed KV for the rest | DeepSeek V4 | The newest variant; llama.cpp supports V4-Flash (ggml-org publishes GGUFs) |

### 2. Linear attention and recurrent layers: a fixed-size state instead of a growing cache

| Design | Examples | What it means here |
|---|---|---|
| Mamba-2 | Nemotron-H, Granite 4, Jamba | State-space layers; supported in llama.cpp |
| Gated DeltaNet | Qwen3-Next and **Qwen3-Coder-Next 80B (runs on this rig)**, GigaChat 4 | The common partner for full or sparse attention, usually 3 linear layers to 1 attention layer |
| Kimi Delta Attention (KDA) | Kimi Linear, Kimi K3 (69 KDA to 24 attention layers), GLM-5.3-Flash | Moonshot's refinement of the delta rule |

Hybrids are now the default for frontier open models: mostly linear layers for cheap long context, a minority of full or sparse attention layers for exact recall. For an engine, that means two kinds of per-request state (a KV cache and a recurrent state), which matters for caching, repeatability and multi-GPU placement.

### 3. Depth: running layers more than once

| Design | Examples | What it means here |
|---|---|---|
| Looped (recurrent-depth) layers | **Inkling 2 Mini (tested here: middle 12 of 24 layers run three times)**; GLM-5.4 reportedly 28 shared layers run twice | More compute per byte of weights. Multi-GPU splits can misplace weights and caches: the lab's Inkling split rule |

### 4. The residual path

| Design | Examples | What it means here |
|---|---|---|
| Manifold-constrained hyper-connections (mHC) | DeepSeek V4, GLM-5.3-Flash | A wider residual stream: more memory traffic per layer, new code paths |
| Attention residuals | Kimi K3 | Layers attend to earlier layers' outputs; about 2% inference cost per Moonshot |

### 5. Feed-forward and memory

| Design | Examples | What it means here |
|---|---|---|
| Fine-grained mixture of experts with a shared expert | Nearly every large open model | Experts can sit in system RAM at a known cost (lab finding: half the 177B's experts in RAM, -31% generation) |
| LatentMoE | Kimi K3, Nemotron 3 Ultra | Experts work in a compressed space |
| Conditional memory: an n-gram lookup table | **Qwen3.8-Flash-Next 177B (runs here: a 51.2B-parameter table, kept in system RAM)**. DeepSeek published the idea as Engram | Knowledge that lives in RAM by design. RAM bandwidth and page cache now matter for speed (seen here in the ROCm 10.1 A-B-A) |

### 6. Decoding: more than one token per step

| Design | Examples | What it means here |
|---|---|---|
| Multi-token prediction (MTP) heads | DeepSeek V3/V4 (depth 1), GigaChat 4 (one layer reused), Inkling (heads not converted by llama.cpp yet) | Built-in speculative decoding. Must be proven not to change outputs (agentic security project 7) |
| Diffusion language models | Several research releases | Generate in parallel and refine. Watch only: little engine support |

### 7. Precision at release

| Design | Examples | What it means here |
|---|---|---|
| FP4 experts at release | DeepSeek V4 (routed experts in FP4), Inkling (NVFP4/MXFP8) | A GGUF in a matching 4-bit format could be close to an exact copy, not a lossy quant. Speed of llama.cpp's 4-bit paths on RDNA4 is untested here |

## Research potential for this lab, ranked

Ranked by: can it run on this rig, is nobody else measuring it on AMD, and does it build on work already done.

| # | Question | Model to use | Why it is worth it | Size of job |
|---|---|---|---|---|
| 1 | **Does sparse attention compute correctly on ROCm?** | DeepSeek V4-Flash first (284B, 13B active; mature llama.cpp support), then GLM-5.3-Flash (320B, 18B active; support merged 30 Sep, checked upstream only on a tiny test model) | DSA work in llama.cpp has targeted CPU and NVIDIA. A full-scale KLD check against a CPU reference on AMD would be a first. V4-Flash is the control (more mature), GLM the new case | Big: large downloads, CPU reference streamed from NVMe |
| 2 | **Does the prompt cache break repeatability more with recurrent state?** | Qwen3-Coder-Next 80B (already on the rig, Gated DeltaNet hybrid) | Extends the lab's prompt-cache finding to hybrid models, where the cache stores a recurrent state too. No download needed | Small: `squeeze check` null tests |
| 3 | **Where does each kind of state live across cards?** | Inkling (loops), Qwen3-Coder-Next (recurrent plus KV), Qwen3.8 (n-gram table in RAM) | Generalises the Inkling split rule into one study of placement for every new layout. Feeds the llama.cpp issue | Medium |
| 4 | **Is a 4-bit GGUF of an FP4-native model lossless, and fast on RDNA4?** | DeepSeek V4-Flash | If the release is already 4-bit, the quality question becomes a conversion question. Speed of 4-bit kernels on gfx1201 is unmeasured | Medium, shares the download with #1 |
| 5 | **Does built-in MTP change outputs?** | Whichever MTP model llama.cpp supports first on ROCm | Agentic security project 7, with real MTP heads | Small once supported |

### Watch list

- **GigaChat 4's 37B-A4B sibling:** mentioned, not yet released. If it shares the 708B's design (Gated DeltaNet plus DSA), it would fit one card and be the cheapest sparse-attention test.
- **GLM-5.4 open weights:** a looped flagship; the Inkling method applies. Too large for this rig at any useful quant.
- **Kimi K3 and K3.1 Pro:** 2.8T parameters, far too large. Watch for smaller Kimi Linear-style releases.
- **Diffusion language models:** wait for engine support.

## Sources

- [Sebastian Raschka, Kimi K3 architecture notes](https://sebastianraschka.com/blog/2026/kimi-k3-architecture-notes.html) and his [LLM architecture gallery](https://sebastianraschka.com/llm-architecture-gallery/models/kimi-k3/)
- [DeepSeek-V4 technical report](https://arxiv.org/abs/2606.19348)
- [DeepSeek-V3.2-Exp](https://github.com/deepseek-ai/DeepSeek-V3.2-Exp)
- [GigaChat4-708B-A41B model card](https://huggingface.co/ai-sage/GigaChat4-708B-A41B)
- [AI Weekly: llama.cpp merges GLM-5.3-Flash support (PR #27773)](https://aiweekly.co/alerts/llamacpp-merges-320b-glm-53-flash-hybrid-text-vision-support)
- [ggml-org DeepSeek-V4-Flash GGUF](https://huggingface.co/ggml-org/DeepSeek-V4-Flash-GGUF) and [llama.cpp discussion #22376, DeepSeek V4 support](https://github.com/ggml-org/llama.cpp/discussions/22376)
- [GLM-5.4 reporting (DEV Community)](https://dev.to/delimitter/zai-releases-glm-54-its-first-loop-transformer-flagship-at-750b-parameters-onf)
- Lab data: [Inkling 2 Mini](../data/2026-11-21-inkling-2-mini-rocm.md), [Ripple-65B](../data/2026-11-05-ripple-65b-rocm.md), [Qwen3.8 first run](../data/2026-10-23-qwen38-flash-next-first-run.md), [system RAM sweep](../data/2026-10-31-qwen38-system-ram-sweep.md)
