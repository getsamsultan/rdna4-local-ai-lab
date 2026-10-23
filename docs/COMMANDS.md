# Command reference: the less obvious ones

The commands in this repo that aren't everyday Linux: what each one does, when I reached for it, and which part of the [ROCm certification](https://www.amd.com/en/developer/resources/technical-articles/2026/announcing-the-rocm-certification-program.html) and my learning roadmap it belongs to.

**Roadmap phases:** A1 Foundations · A2 Serving at scale · A3 Under the hood · A4 Bridge to NVIDIA (inference track). **Cert:** Associate = ROCm fundamentals, HIP, memory, single-GPU profiling · Professional = multi-GPU inference and serving.

## Seeing the GPUs

| Command | What it does | When and why I used it | Cert · Phase |
|---|---|---|---|
| `rocminfo \| grep -E "Marketing Name\|gfx\|Compute Unit\|Wavefront"` | Lists every device the ROCm runtime can see, with its gfx target, compute units and wavefront size | Bring-up: confirming the runtime saw three gfx1201 cards, not just the CPU's gfx1036 iGPU that the installer had picked | Associate · A1 |
| `rocm-smi --showmeminfo vram` | VRAM total and used per GPU, in bytes | Before the 128K-context test, to prove the cards were empty (~60 MB each) and the display was on the iGPU | Associate · A1 |
| `rocm-smi --showmemuse` | VRAM use as a percentage | Logged in every provenance file: a benchmark must start from ~0% | Associate · A1 |
| `cat /sys/class/drm/card*/device/gpu_busy_percent` | GPU busy % straight from the kernel driver | `rocm-smi`'s power reading errors under load, so `gpu-logger.sh` reads sysfs directly | Associate (profiling) · A3 |
| `cat /sys/class/drm/card*/device/hwmon/hwmon*/power1_average` | GPU board power in microwatts | Same logger: per-card power alongside the wall meter | Associate (profiling) · A3 |

## Choosing and configuring GPUs

| Command / variable | What it does | When and why I used it | Cert · Phase |
|---|---|---|---|
| `HIP_VISIBLE_DEVICES=0,1` | Limits which GPUs a HIP program can see, renumbered from 0 | Two-vs-three-card test; excluding the iGPU from the serving stack | Associate (HIP runtime) · A2 |
| `HSA_ENABLE_SDMA=0` | Turns off the GPU's copy engines, so host↔device copies fall back to slower paths | Finding 02: this one line cost 61% of serving speed on discrete cards | Associate (memory transfers) · A3 |
| `HSA_OVERRIDE_GFX_VERSION` | Makes ROCm treat a GPU as a different gfx target | Set to an empty string in a compose file, it broke device detection; removing the line fixed it | Associate (targets, toolchain) · A3 |
| `--device /dev/kfd --device /dev/dri` | Gives a container the ROCm compute driver (`kfd`) and the GPU render nodes (`dri`) | Every benchmark container | Associate (fundamentals) · A2 |
| `--group-add 44 --group-add 992` | Adds the container user to the host's `video` and `render` groups by number | The ODS image had no `render` group name, so names failed and numbers worked | Associate (fundamentals) · A2 |

## PCIe and the host

| Command | What it does | When and why I used it | Cert · Phase |
|---|---|---|---|
| `sudo lspci -vv -s <port> \| grep LnkSta` | Negotiated PCIe speed and width for a device | Reading the **upstream switch port**, not the GPU: each card reports its internal x16 link, which hides the real slot width | Professional (multi-GPU) · A2 |
| `lspci -tv` | The whole PCIe tree | Finding which upstream port each card hangs off (two CPU x8 slots, one chipset x4) | Professional (multi-GPU) · A2 |
| `cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor` | CPU frequency policy | Provenance: a `powersave` governor quietly slows the host side of inference | Associate (system setup) · A1 |
| `sudo dmidecode -t memory` | Installed RAM modules and their configured speed | Provenance: checking DDR5 actually runs at its rated speed | Associate (system setup) · A1 |

## llama.cpp

| Command / flag | What it does | When and why I used it | Cert · Phase |
|---|---|---|---|
| `llama-bench -p 0 -n 2048 -r 5 -o md` | Generation-only test, 2,048 tokens, 5 repeats, markdown table | Every generation number in the README | Associate (benchmarking) · A1 |
| `-sm layer` | Splits the model by layers across GPUs (pipeline parallelism) | All multi-card runs; Finding 01 measured ~1 ms per hand-off | Professional · A2 |
| `-ts 47,53` | Sets how much of the model each GPU gets | Rebalancing two cards to make room for context on card 0 | Professional · A2 |
| `-ub 256` / `-b 128` | Micro-batch and batch size: smaller means smaller compute buffers but slower prompt reading | Squeezing an 80B plus 128K context onto two cards | Associate (memory) · A2 |
| `-ctk q8_0 -ctv q8_0` | Stores the KV cache at 8-bit instead of 16-bit, halving its memory | The 128K-on-two-cards attempts | Associate (memory) · A1 (quantization) |
| `-fa 1` / `-fa on` | Flash attention: less memory, faster long contexts | Every run; needed for a quantized V cache | Associate (kernels) · A3 |
| `grep -ac qwen4exp /app/libllama.so` | Counts how often a string appears in a binary | Checking a llama.cpp build supports a new architecture before a 90 GB download | Associate (toolchain) · A3 |

## Reproducibility

| Command | What it does | When and why I used it | Cert · Phase |
|---|---|---|---|
| `sha256sum <file>` | Fingerprints a file | Model files and binaries in every result. In Finding 02, identical hashes ruled out the engine in two commands | Good practice · all |
| `docker image inspect --format '{{.Id}}' <image>` | The image's exact ID | Provenance: tags move, IDs don't | Good practice · A2 |
| `docker inspect <c> --format '{{index .Config.Labels "com.docker.compose.project.config_files"}}'` | Which compose files started a container | Recreating one service with exactly the same compose files | Good practice · A2 |
| `git log --all -S 'HSA_ENABLE_SDMA'` | Finds every commit that added or removed a string ("pickaxe" search) | Proving the setting never existed upstream, which led to the correction in Finding 02 | Good practice · all |

## Long jobs

| Command | What it does | When and why I used it | Cert · Phase |
|---|---|---|---|
| `pgrep -af "[h]f download"` | Finds a running process by its command line | The `[h]` stops `pgrep` from matching its own command | Good practice · all |
| `nohup bash -c '…' > log 2>&1 &` | Runs a job that survives closing the terminal, with output to a log | Unattended model downloads | Good practice · all |
| A flag file (`touch done`) plus a watcher loop | One job signals completion; another waits for the file, then acts | Powering the rig off only after a download truly finished | Good practice · all |

## Next to learn

| Command | What it's for | Cert · Phase |
|---|---|---|
| `rocprofv3 --kernel-trace` | Which GPU kernels take the time in one token | Associate (profiling) · A3 |
| `amd-smi` | The newer replacement for `rocm-smi` | Associate · A1 |
| `hipcc --offload-arch=gfx1201` | Compiling HIP for exactly this GPU | Associate (HIP) · A3 |
| `rocgdb` | Debugging GPU kernels at the wavefront level | Professional · A3 |
| `hipify-perl` | Converting CUDA source to HIP | Associate · A4 |
