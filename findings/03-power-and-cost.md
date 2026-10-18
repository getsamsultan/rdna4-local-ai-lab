# Finding 03 — What a local AI rig really costs per token

**Date:** 2026-10-18 · **Model:** Qwen3-Coder-Next-UD-Q6_K (80B, 3 cards) · **Meter:** plug-in wall meter (±1.5%), rig only · **Electricity:** A$0.3214/kWh incl. GST

## Power at the wall

| State | Watts |
|---|---|
| Idle, serving stack stopped | 80.5 |
| Idle, serving stack running (no model loaded) | ~117 |
| Generating (llama-bench tg2048, steady after load) | 425–440 |
| Reading long prompts (pp4096) | 710–886 (peak 886) |

Just having the serving stack's ~27 containers running adds ~37 W before any work is done.

## Speed

| Test | Tokens/s |
|---|---|
| Generation, tg2048 (5 runs) | 54.65 ± 0.01 |
| Long-prompt reading, pp4096 (2 × 10 runs) | 2372.66 / 2359.71 |
| Real request through the stack, after Finding 02's fix | 54.3 (3 runs) |

## Cost per million tokens — electricity only, one request at a time

**Writing (output tokens)**

| | Cost per million |
|---|---|
| My rig | **≈ A$0.71** |
| Same model, rented (cheapest provider, US$0.80) | ≈ A$1.15 |
| Comparable-class frontier-lab small model (US$5.00) | ≈ A$7.20 |

**Reading (input tokens)**

| | Cost per million |
|---|---|
| My rig — a million tokens in ~7 minutes | **≈ A$0.03** |
| Same model, rented (US$0.12) | ≈ A$0.17 |
| Comparable-class frontier-lab small model (US$1.00) | ≈ A$1.44 |

USD converted at A$1 = US$0.6946 (last close before 18 Oct 2026). In US dollars: ~US$0.49 per million tokens generated, ~US$0.02 per million read. Cloud prices are list/cheapest-provider prices as of October 2026.

## Then count the hardware

With roughly **A$13,000** (~US$9,000) for the complete build (three GPUs, CPU, board, memory, storage, PSU, case and cooling), the payback period depends entirely on what you compare against:

| Compared with | Saving per million output tokens | Tokens to pay back | Time, generating nonstop at 55 t/s |
|---|---|---|---|
| Renting the same model | A$0.45 (US$0.31) | ~29 billion | **~17 years** |
| A frontier-lab small model | A$6.49 (US$4.51) | ~2.0 billion | **~1.2 years** |

## Conclusion

On cost alone, the cloud wins. Providers batch many users onto every GPU; one person's rig serves one request at a time and sits idle most of the day (80 W idle ≈ A$19/month, ~15% of my household's electricity if left on).

What a business buys with local AI is **control**: data that never leaves the building, no dependency on someone else's availability or policy decisions, reading-heavy workloads at a fraction of a cent per million tokens, and operation where the cloud can't reach — offline sites and OT networks.

## Caveats

- Electricity only unless stated; hardware estimate is approximate.
- Single-stream serving. Batched, multi-user serving would raise throughput and lower local cost per token — a planned test.
- Reading-phase watts are spiky; the midpoint of 710–886 W was used. At the 886 W peak the cost is still ~A$0.033 per million.

Workbook with every formula and assumption: [`data/rig-power-cost.xlsx`](../data/rig-power-cost.xlsx) — change the yellow cells to use your own prices.
