# 2026-10-18 — Qwen3-Coder-Next 80B: speed, power and the SDMA bisection

Model: Qwen3-Coder-Next-UD-Q6_K.gguf (61.27 GiB, 79.67B params, qwen3next 80B.A3B) · 3× R9700 · llama.cpp b8763 (ff5ef82) · ROCm 7.2

## llama-bench (`-ngl 99 -sm layer -fa 1`)

| test | t/s |
|---|---|
| pp512 | 1136.68 ± 7.80 |
| pp2048 | 2093.59 ± 4.31 |
| tg128 | 55.03 ± 0.07 |
| tg2048 (`-p 0 -n 2048 -r 5`) | 54.65 ± 0.01 |
| pp4096 (`-p 4096 -n 0 -r 10`), run A | 2372.66 ± 16.30 |
| pp4096, run B | 2359.71 ± 16.44 |

## Wall power (plug-in meter, rig only)

| phase | watts |
|---|---|
| idle, serving stack stopped | 80.5 (most consistent) |
| idle, stack running, no model | ~116–119 |
| idle, stack running, 80B loaded | ~132 |
| model loading | 81 → 240 |
| pp512 | 386–516 |
| pp2048 | 708–788 |
| tg2048 steady | 425–440 |
| pp4096 | 710–886 |
| real request through stack (before fix, 21 t/s) | ~267 steady, 382 peak |

## Real request (1,500-token coding prompt, 51 prompt tokens)

| configuration | generation t/s |
|---|---|
| through stack, `HSA_ENABLE_SDMA=0` | 21.0, 21.0, 21.0 (plus one earlier run: 21.02) |
| llama-server outside stack, stack's exact flags | 54.4 |
| llama-server outside stack, `--ctx-size 8192 -np 1` | 54.6 |
| llama-server outside stack, `--ctx-size 131072 -np 1` | 54.5 |
| llama-server outside stack, stack running alongside | 54.4 |
| stack image, direct, all stack env vars | 21.0 |
| stack image, direct, no extra env | 54.3 |
| + `ROCBLAS_USE_HIPBLASLT=1` | 54.4 |
| + `HSA_XNACK=1` | 54.4 |
| + `HSA_ENABLE_SDMA=0` | 21.0 |
| + `HSA_DISABLE_P2P=1` | 54.4 |
| through stack, `HSA_ENABLE_SDMA=1` | 54.3, 54.3, 54.3 |

## llama-bench with stack env vars (tg256, `-p 0 -n 256 -r 3`)

| env | t/s |
|---|---|
| none | 54.59 ± 0.01 |
| HSA_DISABLE_P2P=1 | 54.77 ± 0.01 |
| HSA_ENABLE_SDMA=0 | 54.76 ± 0.01 |
| HIP_ENABLE_DEVICE_MEM_POOL=0 | 54.61 ± 0.01 |
| HSA_XNACK=1 | 54.71 ± 0.02 |
| all four | 54.70 ± 0.02 |

## File hashes (identical in stack image and clean ROCm 7.2 build)

| file | sha256 (prefix) |
|---|---|
| llama-server | 357bac05bd872136 |
| libllama.so.0.0.1 | c592d99af20af148 |
| libggml-hip.so.0.9.11 | 3ad1cf6b94f867ad |
| libggml.so.0.9.11 | fb5a413bf9b85654 |
| libggml-base.so.0.9.11 | d28c94ebc312c5ee |
| libggml-cpu.so.0.9.11 | d680a08f1422a9fa |
| libamdhip64.so.7 | 3e75825df52d1e18 |
| libhsa-runtime64.so.1 | 5a7697364ebc55ed |
| librocblas.so.5 | eb3a962769bb7c34 |
| libhipblaslt.so.1 | d70e6a341fbcca1b |
| libhipblas.so.3 | 4a8375b529bad2cd |
