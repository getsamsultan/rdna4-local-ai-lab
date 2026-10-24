# 2026-10-25 — Same model, same cards: old vs new llama.cpp (A–B–A)

**Question:** how much of the 80B's speed comes from the engine version alone?

**Model:** Qwen3-Coder-Next-UD-Q6_K.gguf (61.27 GiB), sha256 `b5d46e98cbc6867404ab264e00b10b0d45b565ff2bc5b23227924869e325d240`
**GPUs:** 0,1,2 (PCIe 5.0 x8 + 5.0 x8 + chipset 4.0 x4), no other GPU workloads running

| Engine | Image |
|---|---|
| old | `bench-rocm72-patched:b8763` (llama.cpp b8763, ROCm 7.2; built from the stack's own build stage, see Finding 01) |
| new | `ghcr.io/ggml-org/llama.cpp:full-rocm@sha256:c3bd46248ccb95308c017d168c1ff5bf5796e7cb2ba62a4d24537f62701ae68f` (build 11804, commit c7fc50941) |

Identical flags for every run: `-ngl 99 -sm layer -fa 1 -ub 256 -p 0 -n 2048 -r 5`, run in A–B–A order (old, new, old).

## Results (tg2048, tokens/s, mean ± sd, n = 5)

| Order | Engine | tg2048 |
|---|---|---|
| 1 | old (b8763) | 51.82 ± 0.02 |
| 2 | **new (b11804)** | **61.81 ± 0.09** |
| 3 | old (b8763) | 51.84 ± 0.01 |

**The newer engine alone is +19.3% faster** (61.81 vs 51.83). The two old-engine runs agree within 0.02 t/s, so there was no drift during the session.

Through a real server on the new engine (`llama-server`, 64K context, 1 slot, eval run of 2026-10-23), generation measured 64.4–64.7 t/s.

## Open question

The old engine measured **54.65** with the same image and flags on 2026-10-20, and **51.8** today: about 5% slower. Today's comparison is valid (same session, A–B–A), but something on the host changed in between, possibly the stack upgrade, CPU governor or ambient temperature. To check with `bench-kit/scripts/provenance.sh`.
