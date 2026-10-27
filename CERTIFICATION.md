# ROCm certification, practised on real hardware

Every prep topic AMD lists for the three [ROCm certification](https://www.amd.com/en/developer/resources/technical-articles/2026/announcing-the-rocm-certification-program.html) levels, turned into an exercise on 3× Radeon AI PRO R9700, each with a done-when rubric and a public artifact. Tick a box only when its artifact is published.

## Associate: fundamentals, HIP, single-GPU performance · target Nov 2026

Quizzes: Module 1 8/11 (first attempt) · Module 2 passed 25 Oct 2026

- [x] **A1 ROCm fundamentals.** Map the stack: `rocminfo`, `amd-smi`, device files, environment variables. *Done when:* every command explained with when and why. → [docs/COMMANDS.md](docs/COMMANDS.md)
- [ ] **A2 HIP programming.** Vector-add and a reduction kernel, `hipcc --offload-arch=gfx1201`. *Done when:* results checked against the CPU on GPU2. → `hip-lab/01-basics/`
- [ ] **A3 Memory hierarchy.** Copy-kernel bandwidth test; naive vs LDS-tiled matrix multiply. *Done when:* bandwidth as a % of 640 GB/s, and the tiled version measurably faster. → `hip-lab/02-memory/`
- [ ] **A4 Occupancy.** Sweep block size 64–1024 and register use; read occupancy with `rocprofv3`. *Done when:* a block size × occupancy × time table with the best setting explained. → `hip-lab/03-occupancy/`
- [ ] **A5 Streams.** Overlap host-to-device copies and compute with two streams; repeat with `HSA_ENABLE_SDMA=0`. *Done when:* a timeline showing overlap, and the time lost without the copy engines. → `hip-lab/04-streams/` (ties to [Finding 02](findings/02-hsa-enable-sdma.md))
- [ ] **A6 Profiling a real workload.** `rocprofv3 --kernel-trace` on one llama.cpp token. *Done when:* top 10 kernels by time, explained. → a finding
- [ ] **Gate:** A1–A6 published, quizzes under 80% revisited, Associate exam passed.

## Professional: multi-GPU, serving, scaling · Dec 2026 – Feb 2027

- [ ] **P1 RCCL.** `rccl-tests` `all_reduce_perf` on GPU pairs 0+1, 0+2 and all three. *Done when:* bus bandwidth per pair, including the chipset x4 slot's cost. → a finding
- [ ] **P2 Distributed training.** PyTorch DDP (e.g. LoRA on a small Qwen) on 1, 2 and 3 cards, A–B–A. *Done when:* scaling efficiency (speed-up ÷ GPUs) per card count. → [model-editing-lab](https://github.com/getsamsultan/model-editing-lab) Station 7
- [ ] **P3 vLLM serving.** AMD's ROCm vLLM image, a model that fits, tensor parallel 1 vs 2. *Done when:* time to first token, time per output token and total tokens/s at 1, 4, 16 and 32 users. → updates [Finding 03](findings/03-power-and-cost.md) with batched cost per token
- [ ] **P4 SGLang serving.** Same model and load. *Done when:* side by side with vLLM and llama.cpp. → one comparison table
- [ ] **P5 Scaling and topology.** Tensor parallel vs layer split; CPU-lane pair vs a pair with the chipset card. *Done when:* where each wins, and the x4 slot's cost under load. → extends [Finding 01](findings/01-pcie-topology-and-layer-split.md)
- [ ] **P6 Datacentre comparison.** Repeat P3 on MI300X with AMD Developer Cloud credits. *Done when:* the same table, R9700 vs MI300X, with cost per token on each. → a finding
- [ ] **Gate:** P1–P5 (ideally P6) published, Professional exam passed when it opens. vLLM's tensor-parallel size must divide the model's attention heads, so expect TP=2 rather than 3 here.

## Expert: Kubernetes, observability, model lifecycle · from Mar 2027 (capstone)

- [ ] **E1 Kubernetes GPU environment.** Single-node k3s with AMD's GPU device plugin or GPU Operator. *Done when:* a model server pod on GPU0+GPU1 and a small service on GPU2, from YAML.
- [ ] **E2 Monitoring and alerting.** Prometheus, Grafana, AMD's device metrics exporter, own alert rules. *Done when:* live per-card power, VRAM, temperature and tokens/s, and a test alert that fires.
- [ ] **E3 Train and package.** LoRA fine-tune → merge → GGUF and a container image, both hashed. *Done when:* a versioned, reproducible model artifact.
- [ ] **E4 Deploy and observe.** Roll the new model out next to the old one; blind eval plus speed, live. *Done when:* a measured before/after and a one-command rollback.
- [ ] **E5 Continuous optimisation.** Change one setting, A–B–A, keep or revert. *Done when:* three iterations logged with evidence.
- [ ] **E6 Air-gapped operation.** Rebuild the whole stack offline from a local mirror. *Done when:* the egress test passes and the offline rebuild works.
- [ ] **Gate:** E1–E6 written up as one capstone.

## Beyond the exams: the kernel track

Fast inference engines win with hand-tuned GPU kernels for one chip. This track goes from system-level tuning down to tuning a real kernel on RDNA4.

- [x] **K0 System-level tuning.** Settings, engine versions, slots, ROCm versions, A–B–A. → [Finding 02](findings/02-hsa-enable-sdma.md) (61%), [engine](data/2026-10-25-engine-upgrade-aba.md) (~+20%), [ROCm 10](data/2026-10-25-rocm-7.2.1-vs-10.1.md) (no gain)
- [ ] **K1 Read a real kernel.** llama.cpp's HIP matrix-multiply and attention code for gfx1201. *Done when:* a plain-English note on how one kernel maps threads, waves and memory. → `hip-lab/k1-reading-notes.md`
- [ ] **K2 Find the hot kernel.** `rocprofv3` on one token of the 80B and of Qwen3.8 (builds on A6). *Done when:* top kernels by time for each model, and why they differ. → a finding
- [ ] **K3 Port a CUDA kernel.** `hipify` a small open-source CUDA kernel, build for gfx1201. *Done when:* correct output and a timing vs a simple baseline. → `hip-lab/k3-hipify/`
- [ ] **K4 Write a Triton kernel.** One fused kernel (e.g. RMSNorm or softmax) in Triton on ROCm. *Done when:* correct, with its speed measured against the library version. → `hip-lab/k4-triton/`
- [ ] **K5 Use AMD's tuned libraries.** hipBLASLt and Composable Kernel on the R9700; AITER on MI300X via cloud credits. *Done when:* one matrix shape tuned, before/after numbers. → `hip-lab/k5-libraries/`
- [ ] **K6 Tune one llama.cpp kernel on gfx1201.** The hottest kernel from K2; change one thing (tile size, waves per block, memory layout); A–B–A on both models. *Done when:* a measured gain, correctness checked with perplexity. → a finding + a pull request to llama.cpp
- [ ] **K7 Low-precision formats.** MXFP4 on CDNA4 (MI350-class) via cloud credits vs 4-bit GGUFs on RDNA4. *Done when:* speed and quality at each precision. → a finding

**The goal is K6:** a measured speed-up to a real kernel on RDNA4, merged upstream.

---

Move on when the rubric is met, not by the calendar. Exam topics for Professional and Expert will be checked against AMD's published outlines when they open.
