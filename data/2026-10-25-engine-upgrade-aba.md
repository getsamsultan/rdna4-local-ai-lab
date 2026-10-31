# 2026-10-25 — Same model, same cards: old vs new engine image (A–B–A)

**Question:** how much speed does updating the inference engine image give, with the model, cards and flags unchanged?

**Model:** Qwen3-Coder-Next-UD-Q6_K.gguf (61.27 GiB), sha256 `b5d46e98cbc6867404ab264e00b10b0d45b565ff2bc5b23227924869e325d240`
**GPUs:** 0,1,2 (PCIe 5.0 x8 + 5.0 x8 + chipset 4.0 x4), no other GPU workloads running

| Engine | Image |
|---|---|
| old | `bench-rocm72-patched:b8763`: llama.cpp b8763 with the old stack's source patches, **ROCm 7.2.0**, built from that stack's build stage (see Finding 01) |
| new | `ghcr.io/ggml-org/llama.cpp:full-rocm@sha256:c3bd46248ccb95308c017d168c1ff5bf5796e7cb2ba62a4d24537f62701ae68f`: official llama.cpp build 11804 (commit c7fc50941), **ROCm 7.2.1** |

Identical flags for every run: `-ngl 99 -sm layer -fa 1 -ub 256 -p 0 -n 2048 -r 5`, run in A–B–A order (old, new, old).

## Results (tg2048, tokens/s, mean ± sd, n = 5)

| Order | Engine | tg2048 |
|---|---|---|
| 1 | old (b8763) | 51.82 ± 0.02 |
| 2 | **new (b11804)** | **61.81 ± 0.09** |
| 3 | old (b8763) | 51.84 ± 0.01 |

**The newer engine image is +19.3% faster** (61.81 vs 51.83). The two old-engine runs agree within 0.02 t/s, so there was no drift during the session.

**What changed between the images:** the llama.cpp version (b8763 → b11804, over 3,000 builds apart), the ROCm point release (7.2.0 → 7.2.1), and the build itself (patched build from the old stack vs the official image). Most of the gain is very likely llama.cpp, but this test can't separate the three. Correction 2026-10-25: first published as "llama.cpp alone".

Note: this A–B–A ran while a host monitoring agent was in a slow state (see below), for **both** engines, so +19% is a fair same-conditions comparison. After restarting the agent, the old engine measured 54.3–54.5; the new engine hasn't been re-measured in that state yet. If the agent slowed only the old engine, the gain would be closer to **+13%**. To re-test: both engines, agent freshly restarted, A–B–A.

Through a real server on the new engine (`llama-server`, 64K context, 1 slot, eval run of 2026-10-23), generation measured 64.4–64.7 t/s.

## Open question: the 54.7 → 51.8 drop (investigation, 2026-10-25)

The old engine measured **54.65** with the same image and flags on 2026-10-20, and **51.8** on the morning of the 25th. Today's old-vs-new comparison is unaffected (same session, A–B–A). Investigation so far, all with the old engine, 3 cards, tg2048, `-r 5`:

**CPU governor: ruled out.**

| Order | Governor | tg2048 |
|---|---|---|
| 1 | powersave | 51.73 ± 0.04 |
| 2 | performance | 51.87 ± 0.05 |
| 3 | powersave | 51.63 ± 0.02 |

**Packages since the 20th:** no kernel, GPU firmware, amdgpu or ROCm changes. Mesa was upgraded (not used by the ROCm containers). A host monitoring agent (Netdata, nightly build with eBPF, perf and apps plugins) auto-upgrades daily. GPU power caps 300 W on all three cards.

**Host monitoring agent:**

| Order | Netdata | tg2048 |
|---|---|---|
| 1 | running (long-lived, since before today) | 51.69 ± 0.08 |
| 2 | stopped | 54.47 ± 0.05 |
| 3 | **freshly restarted** | 54.31 ± 0.02 |

The A–B–A did its job: run 3 shows Netdata *running* isn't the cost. **Restarting it restored ~5%.** Working hypothesis: something in the long-running agent built up (a plugin spinning, or accumulated tracing probes). Next: leave it running, re-measure in 24 h, and capture per-process CPU (`ps -eo pid,etime,%cpu,rss,comm --sort=-%cpu`) when slow vs fast. Not a finding until it reproduces.

**Update (2026-10-31): reproduced** on build 11804 (−5.3%), but the agent was only 43 minutes old when slow, so the "builds up over time" guess above is wrong. See [the re-test](2026-10-31-netdata-aba.md).

**Update (later on 2026-10-25):** with the agent freshly restarted, a build-11804 image measured 65.07–65.35 t/s against the old image's 54.31–54.47, so the like-for-like gain is **~+20%** and the +13% bound above no longer applies. See [ROCm 7.2.1 vs 10.1](2026-10-25-rocm-7.2.1-vs-10.1.md).
