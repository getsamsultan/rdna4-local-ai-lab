# 2026-10-31 — ROCm vs Vulkan, same llama.cpp commit, same cards (A–B–A–B)

**Question:** on RDNA4, is llama.cpp faster on ROCm (HIP) or on Vulkan (Mesa RADV)?

**Model:** Qwen3.8-Flash-Next UD-Q3_K_XL (176.94 B, 83.80 GiB, 3 files), fully on the GPUs (`--n-cpu-moe 0`)
**Engine:** llama.cpp commit `c7fc50941` (build 11804), both images built from upstream `.devops/*.Dockerfile` with no changes, `--target full`:

| | ROCm image | Vulkan image |
|---|---|---|
| Tag | `lab-llama:b11804-rocm7.2.1` | `lab-llama:b11804-vulkan` |
| Base | `rocm/dev-ubuntu-24.04:7.2.1-complete` | Ubuntu 26.04.1 LTS (Dockerfile default) |
| Driver stack | ROCm 7.2.1, `ROCM_DOCKER_ARCH=gfx1201` | Mesa RADV 26.0.8-1ubuntu0.3, libvulkan1 1.4.341.0-1 |
| Devices | `HIP_VISIBLE_DEVICES=0,1` | `GGML_VK_VISIBLE_DEVICES=1,2` |

**GPUs:** the same two Radeon AI PRO R9700 (gfx1201) on both backends, PCIe 5.0 x8 each on CPU lanes. GPU2 idle.
**Flags, every run:** `-ngl 99 -sm layer -fa 1 -n 128`, plus `-p` and `-r` per session below.
**Order:** one discarded warm-up per backend (page cache, and Vulkan's first-run shader compile), then ROCm → Vulkan → ROCm → Vulkan.
**Script:** [`rocm-vs-vulkan.sh`](../bench-kit/scripts/rocm-vs-vulkan.sh). It records image IDs, kernel and Mesa version, and peak VRAM per GPU for every step.

## Making sure Vulkan uses the same cards

Vulkan numbers devices differently from ROCm and also lists the iGPU. `--list-devices` while another model was loaded on GPU0 and GPU1:

| Vulkan index | Device | Free VRAM | = ROCm |
|---|---|---|---|
| 0 | Ryzen 9 9950X iGPU (RADV RAPHAEL_MENDOCINO) | (shared RAM) | excluded |
| 1 | R9700 | 992 MiB | GPU0 |
| 2 | R9700 | 2580 MiB | GPU1 |
| 3 | R9700 | 32566 MiB | GPU2 |

Peak VRAM during every step confirmed it: GPU0 ~29.4–29.9 GiB, GPU1 ~28.2–28.7 GiB, GPU2 0.06 GiB, on both backends. Vulkan used ~0.45 GiB less per card.

## Session 1 (`-p 512,2048 -r 3`)

| Order | Backend | pp512 | pp2048 | tg128 |
|---|---|---|---|---|
| 1 | ROCm | 1299.89 ± 40.94 | 2079.98 ± 5.92 | 36.95 ± 0.18 |
| 2 | Vulkan | 969.75 ± 36.87 | 1686.90 ± 59.22 | 38.48 ± 0.66 |
| 3 | ROCm | 1020.95 ± 99.07 | 2079.23 ± 30.17 | 37.06 ± 0.10 |
| 4 | Vulkan | 1050.21 ± 50.80 | 1745.88 ± 89.97 | 39.15 ± 0.26 |

pp512 was not usable: the two ROCm runs are 24% apart with ± up to 99. pp512 was the first test after each model load.

## Session 2 (`-p 2048,512 -r 5`, pp512 moved after pp2048)

| Order | Backend | pp2048 | pp512 | tg128 |
|---|---|---|---|---|
| 1 | ROCm | 2048.68 ± 51.62 | 1326.23 ± 19.37 | 36.96 ± 0.07 |
| 2 | Vulkan | 1712.04 ± 124.74 | 1303.04 ± 65.17 | 38.07 ± 0.70 |
| 3 | ROCm | 2068.12 ± 14.24 | 1218.24 ± 12.60 | 36.93 ± 0.17 |
| 4 | Vulkan | 1585.08 ± 120.06 | 1204.98 ± 18.11 | 38.55 ± 0.52 |

## Result

| Test | ROCm (4 runs) | Vulkan (4 runs) | |
|---|---|---|---|
| **tg128** | 36.98 | 38.56 | **Vulkan +4.3%** |
| **pp2048** | 2069.0 | 1682.5 | **ROCm +23.0%** |
| pp512 (session 2 only) | 1272.2 | 1254.0 | about a tie (ROCm +1.5%) |

- **Generation: Vulkan is faster.** All four Vulkan runs beat all four ROCm runs (38.07–39.15 vs 36.93–37.06).
- **Long prompts: ROCm is clearly faster.** All four ROCm runs beat all four Vulkan runs (2049–2080 vs 1585–1746). Vulkan's prompt numbers are also noisier (± up to 125 vs ± up to 52).
- **Short prompts: call it a tie.** In session 2 each ROCm/Vulkan pair is within 2%, but both backends drifted ~8% down between the first and second pass, so I'm not reading anything into the small gap.
- **Practical take:** for chat-style use (short prompts, long answers) Vulkan is a touch quicker; for long documents, RAG and agents (big prompts) ROCm wins by more. `lab-llm` stays on ROCm for now.

## Gotchas

- The Vulkan image is plain Ubuntu with no `render` group, so `--group-add render` fails. Pass the host's numeric group IDs instead (the script does).
- `radv is not a conformant Vulkan implementation, testing use only` is printed for gfx1201 on this Mesa. Everything ran fine.
- Putting pp512 first after a fresh model load gave unstable numbers on both backends. Moving it after pp2048 cut ROCm's ± from 41–99 to 13–19.

## Not yet done

- The 80B Q6 and all three cards (the original plan). This note is Qwen3.8 on two cards only.
- Why pp512 drifted ~8% between passes on both backends.
- Vulkan with experts in system RAM (`--n-cpu-moe`), to compare with the [ROCm sweep](2026-10-31-qwen38-system-ram-sweep.md).
