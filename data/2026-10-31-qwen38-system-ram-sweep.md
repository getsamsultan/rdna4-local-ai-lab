# 2026-10-31 — Qwen3.8 177B: what does moving experts to system RAM cost? (A–B–A)

**Question:** if I move some of the MoE experts off the GPUs and into system RAM (`--n-cpu-moe`), how much speed do I lose, how much VRAM do I get back, and do CPU threads matter?

**Model:** Qwen3.8-Flash-Next UD-Q3_K_XL (176.94 B, 83.80 GiB, 3 files; sha256 in [the first-run note](2026-10-23-qwen38-flash-next-first-run.md))
**Engine:** llama.cpp build 11804, ROCm 7.2.1 (local image `lab-llama:b11804-rocm7.2.1`), `llama-bench`
**GPUs:** 0,1 only (both PCIe 5.0 x8, CPU lanes). GPU2 idle. CPU: Ryzen 9 9950X (16 cores / 32 threads), 91 GiB usable system RAM.
**Flags, every run:** `-ngl 99 -sm layer -fa 1 -p 512 -n 128 -r 3`, plus the variable under test. One discarded warm-up run first.
**Scripts:** [`ncmoe-sweep.sh`](../bench-kit/scripts/ncmoe-sweep.sh), [`ncmoe-vram.sh`](../bench-kit/scripts/ncmoe-vram.sh)

`--n-cpu-moe N` keeps the expert weights of the **first N layers** in system RAM; everything else stays on the GPUs. The model has 48 layers.

## 1. Experts in RAM vs speed (16 threads)

| Order | `--n-cpu-moe` | pp512 (t/s) | tg128 (t/s) | tg vs 0 |
|---|---|---|---|---|
| 1 | 0 | 1418.85 ± 19.82 | 37.76 ± 0.12 | — |
| 2 | 6 | 890.85 ± 22.35 | 32.96 ± 0.20 | −12.7% |
| 3 | 12 | 705.95 ± 26.70 | 29.80 ± 0.32 | −21.1% |
| 4 | 24 | 547.16 ± 12.36 | 26.03 ± 0.13 | −31.0% |
| 5 | 0 | 1403.67 ± 21.20 | 37.74 ± 0.11 | — |

The two baseline runs agree within 0.1% (generation) and 1.1% (prompt), so there was no drift.

- **Generation degrades gently.** Half the layers' experts in RAM costs 31%.
- **Prompt reading is hit much harder:** −37%, −50%, −61%.

## 2. VRAM given back

Peak VRAM during a `llama-bench` run (pp512 + tg128, `-r 2`), GiB:

| `--n-cpu-moe` | GPU0 | GPU1 | Total | Freed | tg cost |
|---|---|---|---|---|---|
| 0 | 29.81 | 28.58 | 58.39 | — | — |
| 6 | 23.26 | 28.42 | 51.68 | 6.71 | −12.7% |
| 12 | 17.04 | 28.42 | 45.46 | 12.93 | −21.1% |
| 24 | 4.60 | 28.42 | 33.02 | 25.37 | −31.0% |

- **About 1.1 GiB per layer of experts**, close to linear.
- **All of it comes off GPU0.** `--n-cpu-moe` takes the first N layers, and with `-sm layer` those all live on GPU0. To actually *use* the freed memory (more context, another model) you'd need to rebalance with `-ts`. Not tested yet.
- At 24 the whole model needs 33 GiB of VRAM, about one card's worth.

## 3. CPU threads (`--n-cpu-moe 12`)

| Order | `-t` | pp512 | tg128 |
|---|---|---|---|
| 1 | 16 | 715.43 ± 18.42 | 29.93 ± 0.07 |
| 2 | 8 | 713.70 ± 19.17 | 29.39 ± 0.19 |
| 3 | **32** | 713.47 ± 18.02 | **13.47 ± 2.62** |
| 4 | 16 | 713.85 ± 19.03 | 29.69 ± 0.24 |

- **Don't use SMT threads.** 32 threads (16 cores + SMT) more than halves generation and makes it unstable.
- **8 threads ≈ 16** (−1.5%), so generation with experts in RAM looks memory-bandwidth-bound, not core-bound.
- **Prompt reading doesn't care about threads at all.** See section 4.

## 4. Why doesn't prompt reading care about CPU threads? (`--no-op-offload`, `--n-cpu-moe 12`)

By default llama.cpp can copy CPU-resident weights to the GPU for large batches ("op offload") instead of computing them on the CPU. Turning that off:

| Order | `-nopo` | pp512 | tg128 |
|---|---|---|---|
| 1 | 0 (default) | 715.27 ± 23.09 | 29.35 ± 0.16 |
| 2 | 1 | **572.54 ± 13.17** | 29.45 ± 0.17 |
| 3 | 0 (default) | 713.66 ± 17.70 | 29.76 ± 0.08 |

- **Op offload is active and worth +25% prompt speed** with experts in RAM. Generation is unaffected. Keep the default.
- My guess was that prompt reading is then limited by copying weights over PCIe. **The maths doesn't fit.** At `--n-cpu-moe 24`, prompt reading takes 0.57 s longer per 512 tokens than with everything on the GPUs. If that were all copying 25.4 GiB of experts, it would need ~47 GB/s, more than a PCIe 5.0 x8 link carries (~31.5 GB/s). At 12 it would need ~38 GB/s. So either not all of it is copied, or something else is going on. **Open question.**
- It probably isn't selective copying saving the day: the model has 512 experts with 10 used per token, so one 512-token ubatch makes 5,120 picks per layer. With anything close to even routing that touches nearly every expert.
- Asked on the llama.cpp Discussions: [ggml-org/llama.cpp#31450](https://github.com/ggml-org/llama.cpp/discussions/31450). I'll update this note with the answer.
- Next test to separate the two: `--n-cpu-moe 12` with a larger micro-batch (`-ub 2048`). If prompt speed jumps, it's copy-bound; if it stays flat, it isn't.

## What I'm doing with it

- `lab-llm` stays at `--n-cpu-moe 0`: the model fits, and GPU0 has almost no headroom at 64K context anyway (33.2 GB in use).
- When a model *doesn't* fit, offloading experts is a reasonable trade for generation, much less so for long prompts.
- Never set `-t` above the physical core count.

## Not yet done

- CPU use per run was logged (`mpstat -P ALL 5`) but not analysed yet.
- `-ts` rebalance to turn freed GPU0 memory into context.
- The `-ub 2048` test above.
