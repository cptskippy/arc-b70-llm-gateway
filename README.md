# Intel Battlemage GPU Local LLM Stack

Single-port OpenAI-compatible chat-completions endpoint, backed by `llama.cpp` (SYCL/Level-Zero → XMX) and fronted by `llama-swap` for transparent model switching on an Intel Battlemage GPU. Compatible with Arc B570, B580, Pro B70, and other Battlemage (Xe2) GPUs.

## Architecture

```
OpenAI client
      ↓  POST /v1/chat/completions  { "model": "<any registered model>" }
http://127.0.0.1:8080
  llama-swap                          ← model registry: ~/.config/llama-swap/llama-swap.yaml
      ↓  routes to group, swaps within group, runs groups in parallel
http://127.0.0.1:9000  http://127.0.0.1:9001  ...
  llama-server (SYCL) ─────→ Intel Battlemage GPU (XMX matmul)
                              GGUFs: ~/.lmstudio/models/...
```

Models within the same group swap in and out of VRAM on demand. Models in different groups can run simultaneously (controlled by the `exclusive` setting in `llama-swap.yaml`). First request to a cold model triggers a load (~20–30 s for a 27B model); subsequent requests stay warm. Loaded models go idle and unload after `ttl: 1800` s of no traffic.

GGUFs live under `~/.lmstudio/models/` so LM Studio sees them too — both stacks coexist. Use LM Studio or any other tool to download models, then run scripts 03 and 04 to register them.

## Workflow

**Initial setup** (run once per machine):
1. `01-install-firmware.sh` — firmware, driver, permissions
2. `02-build-compute-stack.sh` — Intel compute stack + llama.cpp build

**Add or update models** (run any time after initial setup):
1. Drop GGUF files into `~/.lmstudio/models/` (e.g., via LM Studio)
2. `bash 03-discover-models.sh` — generates per-model params from `llama.cpp.params.defaults`
3. `bash 04-setup-service.sh` — builds `llama-swap.yaml`, configs, starts the service

Scripts 03 and 04 are idempotent: safe to re-run whenever your model library changes. Script 03 skips existing `.params` files, so per-model customizations are preserved.

## Quick Start

Run the four scripts in order on Ubuntu 24.04+ with kernel ≥ 6.8 (≥ 6.17 preferred) and a Battlemage GPU visible to `lspci`:

```bash
# 1. Install xe firmware, load driver, set permissions
sudo bash 01-install-firmware.sh

# 2. Install Intel compute-runtime, oneAPI, build llama.cpp with SYCL
bash 02-build-compute-stack.sh

# 3. Auto-discover GGUF models and generate per-model params files
bash 03-discover-models.sh

# 4. Install llama-swap service, opencode, pi, and wire everything together
bash 04-setup-service.sh
```

Total time: ~30–60 minutes (llama.cpp SYCL build is the longest step).

### Script overview

| Script | What it does |
|---|---|
| `01-install-firmware.sh` | Clones `linux-firmware`, installs `bmg_guc_70.bin` and `bmg_huc.bin`, loads the `xe` driver, adds user to `render`/`video` groups |
| `02-build-compute-stack.sh` | Installs Intel compute-runtime + IGC from GitHub releases, Level Zero loader, oneAPI (compiler/MKL/TBB), clones and builds `llama.cpp` with SYCL backend |
| `03-discover-models.sh` | Scans `~/.lmstudio/models/` for all `.gguf` files and generates per-model `llama.cpp.params` files from a shared defaults template |
| `04-setup-service.sh` | Downloads `llama-swap` binary, installs `llm-swap` CLI helper, reads generated params files to build `llama-swap.yaml`, creates systemd user service, configures `opencode` and `pi`, enables linger, starts the service |

## Service Control

```bash
# Status / start / stop / restart
systemctl --user status  llama-swap.service
systemctl --user start   llama-swap.service
systemctl --user stop    llama-swap.service
systemctl --user restart llama-swap.service        # do this after re-running 03 and 04, or editing llama-swap.yaml

# Live logs
journalctl --user -u llama-swap.service -f
```

## CLI Helper: `llm-swap`

```bash
llm-swap <model>                            # preload (returns when warm — ~20–30 s cold, instant if already loaded)
llm-swap list                               # configured models
llm-swap status                             # currently loaded model(s)
llm-swap unload                             # unload all models
llm-swap unload <model>                     # unload a specific model
```

## Using opencode

```bash
opencode                                    # interactive TUI, default model (first discovered)
opencode -m local/<model>               # interactive TUI, specific model
opencode run "summarize this file" @file.py  # one-shot, default model
```

Inside the TUI, `/model` switches between models transparently.

## Using pi

```bash
pi --provider local --model <model>
pi --provider local --model <model> -p "one-shot prompt"
```

## Using the API Directly

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "<model>",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 100
  }'
```

## Adding Another Model

1. Drop the GGUF under `~/.lmstudio/models/` (e.g., via LM Studio).
2. Re-run:
   ```bash
   bash 03-discover-models.sh
   bash 04-setup-service.sh
   ```
   This auto-generates params from `llama.cpp.params.defaults`, rebuilds `llama-swap.yaml`, and refreshes opencode/pi configs. Script 04 starts the service automatically.

To customize per-model parameters (context size, temperature, etc.), edit the model's `.llama.cpp.params` file before re-running the scripts. Script 03 skips existing params files, so customizations are preserved.

## File Locations

| Component | Path |
|---|---|
| llama.cpp build | `~/llama.cpp/build/bin/` |
| llama-swap binary | `~/.local/bin/llama-swap` |
| llama-swap config | `~/.config/llama-swap/llama-swap.yaml` |
| params defaults template | `llama.cpp.params.defaults` (in repo) |
| per-model params | `<gguf>.llama.cpp.params` (next to each GGUF) |
| systemd unit | `~/.config/systemd/user/llama-swap.service` |
| opencode config | `~/.config/opencode/opencode.json` |
| pi config | `~/.pi/agent/models.json` |
| GGUFs | `~/.lmstudio/models/` |
| Intel oneAPI | `/opt/intel/oneapi/` |

## Troubleshooting

**`502 Bad Gateway` on first request** — the spawned llama-server crashed. Check `journalctl --user -u llama-swap -n 50`. Common causes: bad `cmd:` quoting in YAML, missing GGUF, OOM (KV cache too big for free VRAM).

**Server won't start, "out of memory" / "free memory target"** — VRAM is fragmented from prior process churn. Reboot is the cleanest fix; the `xe` driver doesn't always release Level-Zero allocations promptly.

**Slow first response after switching models** — expected. The new model is loading from NVMe into VRAM. ~20–30 s for a 27B model. Keeps warm after that.

**`sycl-ls` or `icpx` not found** — source oneAPI first: `source /opt/intel/oneapi/setvars.sh`. The systemd unit already does this.

**`FATAL: Unknown device: deviceId: e223`** — compute-runtime is too old. Install the latest from [GitHub releases](https://github.com/intel/compute-runtime/releases).


## Credits

This project is based heavily on the work of:

- **[jeffgrover/b70-setup](https://github.com/jeffgrover/b70-setup)** — The original llama.cpp SYCL + llama-swap stack for the Intel Arc Pro B70, including the service architecture, model swapping approach, `llm-swap` CLI helper pattern, and opencode/pi integration. The script structure, systemd service design, and configuration patterns are derived from this work.
- **[Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server](https://github.com/Hal9000AIML/arc-pro-b70-inference-setup-ubuntu-server)** — The automated B70 setup scripts for Ubuntu Server, contributing the compute-runtime installation approach (GitHub releases, IGC packages, Level Zero loader), oneAPI targeted install, and the firmware/driver loading methodology.

Additional thanks to the upstream projects that make this possible:
- [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) — SYCL backend and inference engine
- [mostlygeek/llama-swap](https://github.com/mostlygeek/llama-swap) — Model-swapping proxy
- [intel/compute-runtime](https://github.com/intel/compute-runtime) — GPU drivers and Level-Zero backend
- [oneapi-src/level-zero](https://github.com/oneapi-src/level-zero) — Level Zero SDK and loader
