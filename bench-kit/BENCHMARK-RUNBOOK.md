# Benchmark Runbook: 3× Radeon AI PRO R9700

A step-by-step guide to running benchmarks that other people can trust and reproduce.
Written for this rig (Ryzen 9 9950X, 3× R9700, ROCm 7.2 in containers), but designed to work for any model and, in Part 5, other engines.

**The three rules**
1. Record the setup *before* the numbers: no provenance, no publish.
2. Change one thing at a time: the model, the GPUs, a setting. Never two at once.
3. Repeat and check: n≥5 per test, and repeat the first config at the end (heat-soak check).

---

## Part 0: One-time setup

Copy the `bench-kit` folder to your PC, then:

```bash
mkdir -p ~/bench
cp -r bench-kit/scripts ~/bench/
chmod +x ~/bench/scripts/*.sh
nano ~/bench/scripts/bench.env      # check the paths and settings match your machine
```

**What's in `scripts/`**

| Script | What it does |
|---|---|
| `bench.env` | Your settings: model folder, results folder, image, PCIe ports, standard bench args |
| `stop-services.sh` | Stops all `ods-*` containers and saves the list, so the GPUs are clean |
| `restore-services.sh` | Starts exactly what was stopped |
| `provenance.sh` | Records OS, kernel, CPU, governor, RAM, PCIe links, ROCm, llama.cpp commit, model hash |
| `gpu-logger.sh` | Logs busy %, power and temperature for every GPU to CSV (the "load profile") |
| `run-llamabench.sh` | Runs a full matrix: provenance + logger + llama-bench, saved in one timestamped folder |

**Your bench image** (already built): `bench-rocm72-patched:b8763`.
To rebuild it, or build one for another llama.cpp version, without touching ODS:

```bash
cd ~/ods/extensions/services/llama-server
docker build -f Dockerfile.amd --target builder \
  --build-arg AMDGPU_TARGET=gfx1201 --build-arg LLAMA_CPP_REF=b8763 \
  -t bench-rocm72-patched:b8763 .
```

For a different version, change `LLAMA_CPP_REF` (and `ROCM_VERSION=` for ROCm 10) and give it a new tag, e.g. `bench-rocm10:bXXXX`. Then point `IMAGE` in `bench.env` at it.

---

## Part 1: The standard run (llama.cpp)

### Step 1. Free the GPUs

```bash
~/bench/scripts/stop-services.sh
```

Check that the R9700s (GPU 0-2) show **0%** VRAM. GPU 3 is the iGPU and can be ignored.

### Step 2. Run the matrix

```bash
~/bench/scripts/run-llamabench.sh Qwen3.6-35B-A3B-UD-Q4_K_M.gguf "0 1 2 0,1 0,2 1,2 0,1"
```

- **First argument:** the model file name, from your models folder.
- **Second argument:** GPU configs, separated by spaces. `0` = GPU 0 alone, `0,1` = GPUs 0 and 1 together.
- **Always end with a repeat of the first multi-GPU config** (the trailing `0,1`). That's your heat-soak check.
- **Extra arguments go on the end** and are added to the standard settings, e.g. `-ts 1,3` (see Part 2).

### Step 3. Restore your stack

```bash
~/bench/scripts/restore-services.sh
```

### Step 4. Read the results

Every run creates a folder in `~/bench/results/` containing:

| File | Contents |
|---|---|
| `provenance.md` | The full setup, including the model's sha256 |
| `results.md` | The llama-bench tables |
| `gpu-log.csv` | Busy %, power and temperature per GPU every 0.2 s |

Compact summary for a screenshot (hide your prompt first with `export PS1='$ '; clear`):

```bash
grep -E "^== |tg128|pp2048" ~/bench/results/<run-folder>/results.md
```

### GPU map for this rig

| HIP index | `-ot` name | PCIe bus | Link |
|---|---|---|---|
| 0 | ROCm0 | 03:00.0 | PCIe 5.0 x8 (CPU) |
| 1 | ROCm1 | 07:00.0 | PCIe 5.0 x8 (CPU) |
| 2 | ROCm2 | 0c:00.0 | PCIe 4.0 x4 (chipset) |
| 3 | ROCm3 | 13:00.0 | **iGPU: never use** |

> ⚠️ **Always set the GPUs explicitly.** The bench image can see the iGPU as `ROCm3`. The run script always sets `HIP_VISIBLE_DEVICES` for you. If you run llama-bench by hand, add `-e HIP_VISIBLE_DEVICES=0,1,2` for all three cards.

---

## Part 2: Controlling layer placement

| Option | What it does | Example |
|---|---|---|
| `-ts` / `--tensor-split` | Proportion of the model on each visible GPU | `-ts 1,1,1` equal thirds; `-ts 2,2,1` less on the chipset card |
| `-ot` / `--override-tensor` | Pins specific tensors to a specific device using a pattern | `-ot "blk\.([0-9]|1[0-9])\.=ROCm0"` puts layers 0-19 on GPU 0 |

Example: keep the chipset card's share smaller on the 80B:

```bash
~/bench/scripts/run-llamabench.sh Qwen3-Coder-Next-UD-Q6_K.gguf "0,1,2" -ts 2,2,1
```

Both options were confirmed present in `llama-server` and `llama-bench` in build b8763.

---

## Part 3: Testing other models

1. **Check it fits.** The model file size plus the context cache must fit in the VRAM of the GPUs you list. Leave ~3-4 GB per card of headroom.
2. **Check the source and hash.** Note the Hugging Face repo and compare the file's SHA256 with the one on its Hugging Face file page.
3. **Pick configs that make sense:**
   - Fits on one card → `"0 1 2 0,1 0,2 1,2 0,1"` (topology test)
   - Needs two cards → `"0,1 0,2 1,2 0,1"`
   - Needs three cards → `"0,1,2 0,1,2"` (run twice to check variance and heat soak)
4. **Same settings across models,** unless the setting is the thing you're testing.

**Quick sanity check: is the number physically possible?**
Decode t/s × (active weight bytes per token) must be well below the card's memory bandwidth (640 GB/s for the R9700). With layer split, cards work one after another, so use one card's bandwidth, not the total.
Example: 75 t/s × ~1.8 GB ≈ 137 GB/s → plausible. If your result implies more than 640 GB/s, something is wrong.

---

## Part 4: Load profile and power

`gpu-logger.sh` runs automatically during `run-llamabench.sh`. To log while using the server normally (e.g. testing via Open WebUI):

```bash
~/bench/scripts/gpu-logger.sh ~/bench/results/manual-$(date +%H%M).csv 0.1
# ...use the model... then press Ctrl+C to stop
```

Columns are named by PCIe bus (e.g. `0000:03:00.0_busy`), so you always know which card is which.

**Power: three layers, each cross-checking the others**

| Layer | Source | Status |
|---|---|---|
| Wall (AC) | Plug-in meter with a display | Ground truth, and your photo. Record idle and under load |
| PSU | AX1600i via USB | Check Linux tool support first |
| GPUs | sysfs `power1_average` / `power1_input` (logged by `gpu-logger.sh`) | rocm-smi's power reading fails under load, so use this instead |

Cost per million tokens = (wall watts ÷ 1000) × hours to generate 1M tokens × electricity price per kWh.
Hours for 1M tokens = 1,000,000 ÷ (tokens/s × 3600).

---

## Part 5: Other engines (templates, verify before relying on them)

These are starting points, not tested recipes. Engine flags change between versions, so check each image's `--help` first and note the image tag in your results.

### 5a. llama-server API test (what users actually experience)

Measures the full server path, not just the kernels. Start the model in llama-server (or Lemonade), then:

```bash
curl -s http://localhost:<PORT>/v1/chat/completions -H "Content-Type: application/json" \
  -d '{"model":"<MODEL>","messages":[{"role":"user","content":"Explain PCIe in 200 words."}],"max_tokens":300}' \
  | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r.get("timings", "no timings field - query llama-server directly"))'
```

llama-server includes a `timings` field (prompt and generation speed). If you go through Lemonade or LiteLLM and it's missing, query llama-server's own port directly.

### 5b. vLLM (tensor or pipeline parallel)

- **Model format:** Hugging Face safetensors (BF16/FP8), *not* GGUF. Results are therefore not directly comparable with llama.cpp runs; label them as a separate study.
- **On this rig:** tensor parallel works with 2 cards (TP=2). TP=3 is usually impossible because attention-head counts rarely divide by 3. Multi-GPU vLLM on consumer RDNA4 is less mature, so expect setup friction.
- **Template:**

```bash
docker run --rm -it --device /dev/kfd --device /dev/dri --group-add video --group-add render \
  --security-opt seccomp=unconfined --ipc=host --shm-size 16g \
  -e HIP_VISIBLE_DEVICES=0,1 -v ~/hf-models:/models -p 8000:8000 \
  <vllm-rocm-image:tag> \
  <model> --tensor-parallel-size 2 --max-model-len 16384
```

- **Benchmark:** recent vLLM versions include `vllm bench` subcommands. Check `vllm bench --help` inside your image.

### 5c. Hugging Face Transformers / Accelerate

- `device_map` lets you assign every layer to a GPU by hand, giving the most control over placement but usually the slowest serving. Good for experiments, not for headline speed numbers.

---

## Part 6: Before you publish

- [ ] `provenance.md` saved with the results
- [ ] n≥5, variance looks small (± values), heat-soak repeat matches
- [ ] Sanity check passed (Part 3)
- [ ] Only one variable changed between compared runs
- [ ] Wording: "points to" unless you've actually proven it
- [ ] Screenshots: no hostname, no `/home/<user>` paths, no IPs, no window titles
- [ ] Anyone else's numbers: their permission, credited, quoted exactly
- [ ] Results file backed up off the rig (USB or private repo)

---

## Part 7: Known gotchas on this rig

| Symptom | Cause | Fix |
|---|---|---|
| `failed to load model` | Wrong path or placeholder left in the command | Check `MODELS_DIR` and the file name |
| Benchmark numbers vary wildly | A service loaded a model mid-run | Run `stop-services.sh` first and check VRAM is 0% |
| Model appears loaded when you didn't load it | Hermes, n8n or another agent sent a request | Stop all services before benchmarking |
| rocm-smi power reads ERROR under load | Known rocm-smi limitation | Use `gpu-logger.sh` (sysfs) |
| llama.cpp sees 4 devices | The iGPU appears as ROCm3 | Always set `HIP_VISIBLE_DEVICES` |
| `-fa 1` rejected | Newer llama.cpp changed the flag | Use `-fa on` |
| Card shows 32 GT/s x16 but the slot isn't x16 | That's the GPU's internal switch link | Read `LnkSta` on the upstream ports (in `provenance.md`) |
| Stopped services, then restored too early | Order matters | stop → check VRAM → bench → wait for it to finish → restore |

---

## Results log template

| Date | Model (file + sha256 prefix) | Image | GPUs | pp512 | pp2048 | tg128 | Notes |
|---|---|---|---|---|---|---|---|
| 2026-10-07 | Qwen3.6-35B-A3B-UD-Q4_K_M (ac0e2c11) | bench-rocm72-patched:b8763 | 0 | 2292 | 2257 | 75.4 | Baseline |
| | | | | | | | |
