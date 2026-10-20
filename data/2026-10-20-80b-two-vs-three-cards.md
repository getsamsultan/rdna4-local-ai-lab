# 2026-10-20 — 80B on two cards vs three (A–B–A)

**Model:** Qwen3-Coder-Next-UD-Q6_K.gguf (61.27 GiB, 79.67 B params)
**sha256:** `b5d46e98cbc6867404ab264e00b10b0d45b565ff2bc5b23227924869e325d240`
**Image:** `bench-rocm72-patched:b8763` (ROCm 7.2, llama.cpp b8763)
**Serving stack:** stopped for the duration

## Command

Identical flags for every run; only `HIP_VISIBLE_DEVICES` changes. Run order 3 → 2 → 3 so drift (heat, warm-up) shows up as a difference between the two 3-card runs.

```bash
for g in 0,1,2 0,1 0,1,2; do
  docker run --rm --device /dev/kfd --device /dev/dri --group-add video --group-add render \
    --security-opt seccomp=unconfined -v "$MODELS":/models:ro \
    -e HIP_VISIBLE_DEVICES=$g bench-rocm72-patched:b8763 build/bin/llama-bench \
    -m /models/Qwen3-Coder-Next-UD-Q6_K.gguf -ngl 99 -sm layer -fa 1 -ub 256 -p 0 -n 2048 -r 5 -o md
done
```

## Results (tg2048, tokens/s, mean ± sd, n = 5)

| Order | GPUs | Slots | tg2048 |
|---|---|---|---|
| 1 | 0,1,2 | x8 + x8 + chipset x4 | 54.64 ± 0.02 |
| 2 | 0,1 | x8 + x8 (CPU lanes) | **57.28 ± 0.17** |
| 3 | 0,1,2 | x8 + x8 + chipset x4 | 54.08 ± 0.02 |

An earlier single 2-card run on the same flags gave 57.60 ± 0.05.

## Reading

- Two cards are faster than both 3-card runs: +4.8% and +5.9% (+5.4% against their mean).
- The two 3-card runs differ by 1.0%, which is small next to the gap. The later run is the slower one, consistent with heat soak.
- Consistent with Finding 01: dropping the third card removes one ~1 ms hand-off and the chipset-slot card (−12% alone).
- **But 128K context doesn't fit on two cards** — see below.

## Does a 128K context fit on two cards?

`llama-server`, GPUs 0,1, `-ngl 99 -sm layer -fa on -c 131072 -np 1`. All cards confirmed empty first (~60 MB used each; the display runs on the CPU's integrated GPU).

| Attempt | Extra flags | Result |
|---|---|---|
| 1 | f16 cache, `-ub 256` | ❌ card 0 out of memory allocating the 1,536 MiB KV cache |
| 2 | `-ctk q8_0 -ctv q8_0`, `-ub 256` | ❌ card 0 out of memory allocating 816 MiB KV cache |
| 3 | q8_0 cache, `-ts 47,53`, `-ub 256` | ❌ KV cache fit (1,632 MiB, 12 attention layers); card 0 out of memory on the 632 MiB compute buffer |
| 4 | q8_0 cache, `-ts 44,56`, `-ub 128 -b 128` | ❌ card 1 out of memory loading its 33,952 MiB share of the weights |

**Conclusion:** two cards are about 1 GB short of 128K even with an 8-bit cache. Only a 4-bit cache (accuracy cost on long code) or a shorter context would fit. For 128K work the 80B stays on three cards: 5% slower, full-precision 128K context.

Measured KV cache size matches the architecture: 12 of 48 layers use full attention, ~24 KB per token at f16 (128K ≈ 3 GiB).
