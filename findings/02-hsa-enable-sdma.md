# Finding 02 — One config line cost 61% of generation speed

> **Correction (2026-10-18):** I first reported this as an ODS bug (#7786). The maintainer checked upstream and was right: `HSA_ENABLE_SDMA=0` has never been in the ODS codebase, and current ODS no longer uses the Lemonade container at all. I confirmed it by searching the full ODS git history: the variable never appears in any commit, and neither do `HSA_DISABLE_P2P` or `HIP_ENABLE_DEVICE_MEM_POOL`. These settings had been added to **my local compose files** during setup. The measurements below stand; the attribution was wrong. Lesson added: check upstream before blaming upstream.

**Date:** 2026-10-18 · **Model:** Qwen3-Coder-Next-UD-Q6_K (80B, ~3B active, 61.3 GB, 3 cards) · **Upstream:** [Osmantic/ODS #7786](https://github.com/Osmantic/ODS/issues/7786) (see the correction above)

## The symptom

| Path | Generation |
|---|---|
| `llama-bench` on the same cards | **54.65 t/s** |
| The same model served through my stack (ODS → Lemonade → llama-server) | **21.0 t/s** (3 of 3 runs) |

Same hardware, same model file, and — as it turned out — the same binary. Something was costing 60%.

## How it was found: elimination, one variable at a time

| # | Hypothesis | Test | Result | Verdict |
|---|---|---|---|---|
| 1 | Strix Halo env vars (P2P off, SDMA off, XNACK, mem pool) | `llama-bench` with each var | all ~54.7 | ❌ not visible in llama-bench |
| 2 | Server flags (128K context, 4 slots, context shift) | llama-server with ODS's exact flags, outside ODS | 54.4 | ❌ |
| 3 | Context size or slot count | 8K/1 slot vs 128K/1 slot | 54.6 / 54.5 | ❌ |
| 4 | Other containers competing for CPU/GPU | fast server with all 26 other services running | 54.4 | ❌ |
| 5 | Different engine libraries | sha256 of llama-server, libllama, libggml\* | identical | ❌ |
| 6 | Different ROCm runtime | sha256 of libamdhip64, libhsa-runtime64, rocBLAS, hipBLASLt | identical | ❌ |
| 7 | Missing gfx1201 kernels | count kernel files per GPU target | gfx1201 present | ❌ |
| 8 | Lemonade's launcher | ODS image's llama-server run directly, no Lemonade | 21.0 | ❌ Lemonade innocent — it's the image environment |
| 9 | One env var, in the ODS image, under llama-server | toggle each var individually | see below | ✅ |

### Step 9 — the answer

ODS image, llama-server launched directly, one variable added at a time:

| Extra env var | Generation t/s |
|---|---|
| none | 54.3 |
| `ROCBLAS_USE_HIPBLASLT=1` | 54.4 |
| `HSA_XNACK=1` | 54.4 |
| `HSA_DISABLE_P2P=1` | 54.4 |
| **`HSA_ENABLE_SDMA=0`** | **21.0** |

### The fix, through the real stack

| `docker-compose.amd.yml` | Generation t/s (3 runs) |
|---|---|
| `HSA_ENABLE_SDMA=0` (my local config) | 21.0 / 21.0 / 21.0 |
| `HSA_ENABLE_SDMA=1` (only change) | **54.3 / 54.3 / 54.3** |

## Why (best current understanding)

SDMA is the GPU's dedicated copy engine. With it disabled, transfers between the card and system memory fall back to slower paths. llama-server copies results back after every generated token, so the penalty is paid on every token. `llama-bench` doesn't exercise that path the same way, which is why test 1 missed it. On Strix Halo — where CPU and GPU share one memory pool — disabling SDMA is a known workaround; on discrete cards it acts like a handbrake. The exact mechanism isn't confirmed.

## Lessons

- **Benchmarks can miss what real serving hits.** Always check real requests through the real stack.
- **Settings carry assumptions.** A tweak that suits one chip can quietly cost a lot on another, and it can sit unnoticed in a config for weeks.
- **Check upstream before blaming upstream.** A local config file is not the project's config file. Diff against the source before filing.
- **Hash everything before theorising.** Identical binaries narrowed a huge search space to the environment in two commands.

## Reproduce it

[`repro/sdma-repro.sh`](../repro/sdma-repro.sh) runs the ODS image's llama-server three times with `HSA_ENABLE_SDMA` unset, three times with `=0`, and three times unset again, and records the environment and file hashes to a timestamped report.

```bash
./repro/sdma-repro.sh /path/to/models Qwen3-Coder-Next-UD-Q6_K.gguf 3
```
