# 2026-10-31 — The monitoring agent costs ~5% of generation until it's restarted (A–B–A, reproduced)

**Question:** on 25 Oct, restarting the host monitoring agent (Netdata) gave back ~5% of generation speed ([open question](2026-10-25-engine-upgrade-aba.md#open-question-the-547--518-drop-investigation-2026-10-25)). Does it reproduce, on the new engine, and what's different about the agent when it's slow?

**Model:** Qwen3-Coder-Next-UD-Q6_K (the 80B) · **GPUs:** 0,1,2 · **Engine:** llama.cpp build 11804, ROCm 7.2.1 (`lab-llama:b11804-rocm7.2.1`)
**Flags:** `-ngl 99 -sm layer -fa 1 -ub 256 -p 512 -n 2048 -r 5`, the same as the 25 Oct runs. One discarded warm-up first.
**Agent:** Netdata v2.12.0-353-nightly (auto-updates daily), started by systemd at boot.
**Script:** [`netdata-aba.sh`](../bench-kit/scripts/netdata-aba.sh). It records the agent's start time, a process snapshot before each run and `mpstat` during it.

## Result

| Order | Netdata | tg2048 (t/s) | pp512 (t/s) |
|---|---|---|---|
| 1 | running as found (started at boot, 43 min earlier) | **61.86 ± 0.03** | 2358.28 ± 8.18 |
| 2 | stopped | 65.27 ± 0.03 | 2347.29 ± 32.01 |
| 3 | freshly restarted (1 min earlier) | 65.34 ± 0.00 | 2383.72 ± 7.87 |

- **Generation is 5.3% slower with the agent as it was started at boot.** Stopping it or restarting it gives the speed back, and the restarted agent matches "stopped" within 0.1%.
- **It reproduces.** 25 Oct, older engine: 51.69 → 54.47 → 54.31 (−5.1%). Today, build 11804: 61.86 → 65.27 → 65.34 (−5.3%). Two engine builds, six days apart, same shape.
- **Prompt processing isn't affected** (all three within noise). Whatever it is hurts the many small, latency-sensitive steps of generation, not big batched work.

## What I got wrong on 25 Oct

I guessed that something "built up" in the long-running agent. **Today it was only 43 minutes old** (systemd started it at boot, 20:31) and already slow. So it isn't about uptime. The better description is **"the agent as started at boot is slow, a restart fixes it"**. Why is still open.

## What's different about the agent (process snapshots)

| | Slow (started at boot) | Fast (restarted) |
|---|---|---|
| `netdata` memory (RSS) | **842 MB** | 149 MB |
| Plugins in the top 15 by CPU | `apps.plugin`, `debugfs.plugin` | `apps.plugin`, `go.d.plugin`, `debugfs.plugin` |

Caveat: `ps` %CPU is the average over each process's whole life, so these snapshots can't show which plugin was busy *during* the benchmark. Candidates worth testing, not conclusions:

- `debugfs.plugin` reads kernel debug files, possibly including the GPU driver's.
- `ebpf.plugin` / `perf.plugin` attach kernel tracing probes.
- Something that behaves differently when the agent starts before Docker and the GPU containers are up.

## Practical take

- **Restart the agent before any benchmark.** All my published runs since 25 Oct already did this.
- If you run Netdata (or any monitoring agent with eBPF / perf / debugfs collectors) on an inference box, A–B–A it against "stopped" once. It's 5% you may be paying for nothing.

## Next

- Live per-process CPU *during* a slow run (`pidstat -u 5` or `top -b -d 5`), not lifetime averages.
- Turn the plugins off one at a time (debugfs, ebpf, perf, apps, go.d), each with its own A–B–A, to find which one it is.
- Boot test: reboot → bench → restart agent → bench, to confirm "started at boot" is the trigger and not just "started a while ago".
