# Upgrading ODS from the Lemonade era to llama.cpp on 3× R9700 (ROCm), with a newer engine

> **Outcome (2026-10-24):** steps 0 and 4 worked (the stack reached v3.0.0 after the permissions fix). Step 3 did not: v3.0.0 rejects any override of its core `llama-server` service ("collides with a built-in core service name"), so the newer engine can't be swapped in this way. The supported alternative is to run your own llama-server and connect the stack to it as an external OpenAI-compatible server (`./install.sh --external-llm-url … --external-llm-provider openai-compatible`). I chose to leave the stack instead. Kept here as a record.

**Goal:** move a Lemonade-era ODS install (v2.6.0) to current ODS `main`, keep running on **ROCm** (not the new Vulkan default), use a **newer llama.cpp build** than ODS pins so Qwen3.8-Flash-Next (`qwen4exp`) loads, and keep two other models switchable for testing.

**Why the override:** as of 22 Oct 2026, ODS pins AMD to llama.cpp **b9014**, and ODS's own `config/llama-cpp-architectures.json` shows b9014 doesn't include `qwen4exp`. ODS auto-includes a `docker-compose.override.yml` if one exists (`installers/lib/compose-select.sh`), so the engine can be changed without editing ODS's files.

Paths assume ODS lives in `~/ods`.

## 0. Back up (changes nothing)

```bash
cd ~/ods
cp .compose-flags ~/ods-compose-flags-before-upgrade.txt 2>/dev/null
tar czf ~/ods-backup-before-upgrade.tgz .env .compose-flags docker-compose*.yml config 2>/dev/null
ods backup
docker ps --format '{{.Names}}' > ~/ods-running-before-upgrade.txt
docker images --format '{{.Repository}}:{{.Tag}} {{.ID}}' | grep -iE "lemonade|llama" > ~/ods-images-before-upgrade.txt
```

Model files in `data/models` are never touched by the upgrade.

## 1. Pull the newer ROCm server image and record its digest

```bash
docker pull ghcr.io/ggml-org/llama.cpp:server-rocm-b11804
docker image inspect ghcr.io/ggml-org/llama.cpp:server-rocm-b11804 --format '{{index .RepoDigests 0}}'
```

Build 11804 is the one benchmarked in this repo (`full-rocm` image, same build). If that exact tag doesn't exist, use `server-rocm` and pin whatever digest it gives you.

## 2. Move the Qwen3.8 files to where ODS looks for models

ODS serves `/models/${GGUF_FILE}`. A split model needs all its parts in one folder, so move them up a level (same disk, instant):

```bash
mv ~/ods/data/models/Qwen3.8-Flash-Next/UD-Q3_K_XL/Qwen3.8-Flash-Next-UD-Q3_K_XL-0000*-of-00003.gguf ~/ods/data/models/
ls -l ~/ods/data/models/ | grep -E "Qwen3.8|Coder-Next|3.6-35B"
```

## 3. Create the override file (before running the installer)

Replace the digest with the one from step 1.

```bash
cat > ~/ods/docker-compose.override.yml <<'YAML'
# Local override: newer ROCm llama.cpp build than ODS pins (needed for qwen4exp).
services:
  llama-server:
    image: ghcr.io/ggml-org/llama.cpp:server-rocm-b11804@sha256:REPLACE_WITH_DIGEST
    devices:
      - /dev/kfd:/dev/kfd
      - /dev/dri:/dev/dri
    environment:
      # GPU choice is left to ODS's assignment (LLAMA_SERVER_GPU_INDICES → ROCR_VISIBLE_DEVICES).
      # Setting HIP_VISIBLE_DEVICES here as well would clash with it.
      LLAMA_ARG_SPLIT_MODE: "layer"
      LLAMA_ARG_FLASH_ATTN: "on"
      # Qwen3.8 reasoning level; other models' templates ignore it.
      LLAMA_ARG_CHAT_TEMPLATE_KWARGS: '{"reasoning_effort":"medium"}'
YAML
grep -n REPLACE ~/ods/docker-compose.override.yml && echo "^ put the digest in first"
```

## 4. Run the new installer

```bash
git clone --depth 1 https://github.com/Osmantic/ODS.git ~/ods-update
cd ~/ods-update/ods && ./install.sh
```

Answer the prompts with the same choices as the original install.

**If it stops at phase 06 with** `/etc/nsswitch.conf: cannot establish a local private group`: one of `~/ods`, `config`, `config/litellm` or `config/litellm/cloud.yaml` is group-writable (Ubuntu creates folders `rwxrwxr-x` by default, so `~/ods` itself usually is), and the installer only repairs that automatically when `passwd`/`group` in `/etc/nsswitch.conf` list nothing but `files`/`systemd`. Remove the group-write bit yourself, then re-run:

```bash
chmod g-w ~/ods ~/ods/config ~/ods/config/litellm ~/ods/config/litellm/cloud.yaml
ls -ld ~/ods ~/ods/config ~/ods/config/litellm ~/ods/config/litellm/cloud.yaml   # no w in the group column
```

**GPU assignment:** on this rig the installer put llama-server on GPU0+GPU1 (the CPU-lane slots) and whisper, ComfyUI and embeddings on GPU2 (chipset slot). That suits Qwen3.8 (fits on two cards, 4% faster there), but the 80B can't hold 128K context on two cards, so it gets 32K below. The installer moves the Lemonade settings in `.env` to llama.cpp, keeps `data/`, sets `AMD_INFERENCE_BACKEND=vulkan`, and should log `Including docker-compose.override.yml (user overrides)`. Save its output.

## 5. Set ROCm and the active model

```bash
cd ~/ods
set_env() { grep -q "^$1=" .env && sed -i "s|^$1=.*|$1=$2|" .env || echo "$1=$2" >> .env; }
set_env AMD_INFERENCE_BACKEND rocm
set_env GGUF_FILE Qwen3.8-Flash-Next-UD-Q3_K_XL-00001-of-00003.gguf
set_env CTX_SIZE 65536
set_env N_GPU_LAYERS 99
set_env LLAMA_PARALLEL 1
set_env LLAMA_REASONING auto
rm -f .compose-flags
ods restart
```

`rm .compose-flags` makes ODS rebuild its Compose file list, including the override and the ROCm overlay.

## 6. Keep outbound services off until audited

```bash
docker ps --format '{{.Names}}' | grep -iE "egress|tunnel|remote-provider"
```

Stop anything listed with `docker stop <name>`, or disable it with `ods disable <service>`.

## 7. Verify

```bash
docker inspect ods-llama-server --format '{{.Config.Image}}'
docker inspect ods-llama-server --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E "HIP_VISIBLE|SPLIT|FLASH|REASON|TEMPLATE_KWARGS"
docker logs ods-llama-server 2>&1 | tail -5
curl -s http://127.0.0.1:11434/v1/models | python3 -m json.tool | grep '"id"'
rocm-smi --showmeminfo vram | grep Used
```

Expect: the b11804 image; ~57.7 GiB across GPU0 and GPU1 with Qwen3.8 loaded; the model id is the GGUF file name. Then one real request through ODS to check speed against the 35–36 t/s benchmark:

```bash
python3 -c "
import json,urllib.request
b=json.dumps({'model':'x','messages':[{'role':'user','content':'Write 400 words on Modbus TCP.'}],'max_tokens':800}).encode()
r=json.load(urllib.request.urlopen(urllib.request.Request('http://127.0.0.1:11434/v1/chat/completions',b,{'Content-Type':'application/json'})))
print(round(r['timings']['predicted_per_second'],1),'t/s')"
```

## 8. Switch models for testing

```bash
cat > ~/ods-model.sh <<'SH'
#!/usr/bin/env bash
# Usage: ods-model.sh qwen38 | coder80 | qwen35
set -e; cd ~/ods
case "$1" in
  qwen38)  F=Qwen3.8-Flash-Next-UD-Q3_K_XL-00001-of-00003.gguf; C=65536 ;;
  coder80) F=Qwen3-Coder-Next-UD-Q6_K.gguf; C=32768 ;;   # 2 cards: 128K does not fit
  qwen35)  F=Qwen3.6-35B-A3B-UD-Q4_K_M.gguf; C=131072 ;;
  *) echo "Usage: $0 qwen38|coder80|qwen35"; exit 1 ;;
esac
sed -i "s|^GGUF_FILE=.*|GGUF_FILE=$F|; s|^CTX_SIZE=.*|CTX_SIZE=$C|" .env
ods restart llama-server
echo "Switched to $F (ctx $C). Check: docker logs ods-llama-server 2>&1 | tail -3"
SH
chmod +x ~/ods-model.sh
```

If `ods restart llama-server` doesn't pick up the `.env` change, recreate it instead: `docker compose $(cat .compose-flags) up -d --force-recreate --no-deps llama-server`.

## Rollback

1. `cd ~/ods && ./ods-update.sh rollback` (restores the installer's pre-update snapshot), or
2. by hand: `tar xzf ~/ods-backup-before-upgrade.tgz -C ~/ods`, remove `docker-compose.override.yml`, then `docker compose $(cat ~/ods-compose-flags-before-upgrade.txt) up -d`. The Lemonade image stays on disk after the upgrade, so the old stack can start again.

## Notes

- `LLAMA_ARG_CHAT_TEMPLATE_KWARGS` and `LLAMA_REASONING=auto` are the intended settings; if the server log shows either rejected, remove it from the override/.env and set reasoning per request instead.
- After the upgrade, re-run the SDMA check from Finding 02 and the blind eval through ODS, so the numbers are comparable.
