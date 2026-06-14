# Local LLM Gateway — Intel Arc Pro B70

Single-port OpenAI-compatible chat-completions endpoint, backed by `llama.cpp` (SYCL/Level-Zero → XMX) and fronted by `llama-swap` for transparent model switching on a single Intel Arc Pro B70 GPU.

## Architecture

```
OpenAI client
      ↓  POST /v1/chat/completions  { "model": "qwen3.6-27b" | "gemma-4-31b" | "deepseek-r1-32b" }
http://127.0.0.1:8080
  llama-swap                          ← model registry: ~/.config/llama-swap/llama-swap.yaml
      ↓  spawns/kills based on requested model
http://127.0.0.1:9000
  llama-server (SYCL build) ─────→ Intel Arc Pro B70 (XMX matmul)
                                    GGUFs: ~/.lmstudio/models/...
```

Only one `llama-server` runs at a time. First request to a different model triggers a swap (~20–30 s cold load); subsequent requests stay warm. Models go idle and unload after `ttl: 600` s of no traffic.

## Models

| Model | Path | Quant | Context | VRAM |
|---|---|---|---|---|
| `qwen3.6-27b` | `~/.lmstudio/models/lmstudio-community/Qwen3.6-27B-GGUF/Qwen3.6-27B-Q4_K_M.gguf` | Q4_K_M | 256 K (q8_0 KV) | ~25 GB |
| `gemma-4-31b` | `~/.lmstudio/models/lmstudio-community/gemma-4-31B-it-GGUF/gemma-4-31B-it-Q4_K_M.gguf` | Q4_K_M | 128 K (q8_0 KV) | ~20 GB |
| `deepseek-r1-32b` | `~/.lmstudio/models/lmstudio-community/DeepSeek-R1-Distill-Qwen-32B-GGUF/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf` | Q4_K_M | 128 K (q8_0 KV) | ~20 GB |

GGUFs live under `~/.lmstudio/models/` so LM Studio sees them too — both stacks coexist.

## Quick Start

Run the three scripts in order on Ubuntu 24.04+ with kernel ≥ 6.17 and the B70 visible to `lspci`:

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
systemctl --user restart llama-swap.service        # do this after editing llama-swap.yaml

# Live logs
journalctl --user -u llama-swap.service -f
```

## CLI Helper: `llm-swap`

```bash
llm-swap qwen3.6-27b                        # preload (returns when warm — ~22 s cold, instant if already loaded)
llm-swap gemma-4-31b
llm-swap deepseek-r1-32b
llm-swap list                               # configured models
llm-swap status                             # currently loaded model(s)
llm-swap unload                             # unload all models
llm-swap unload qwen3.6-27b                 # unload a specific model
```

## Using opencode

```bash
opencode                                    # interactive TUI, default model (qwen3.6-27b)
opencode -m local-b70/gemma-4-31b           # interactive TUI, Gemma
opencode -m local-b70/deepseek-r1-32b       # interactive TUI, DeepSeek
opencode run "summarize this file" @file.py  # one-shot, default model
```

Inside the TUI, `/model` switches between models transparently.

## Using pi

```bash
pi --provider local-b70 --model qwen3.6-27b
pi --provider local-b70 --model gemma-4-31b -p "one-shot prompt"
pi --provider local-b70 --model deepseek-r1-32b
```

## Using the API Directly

```bash
curl http://127.0.0.1:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-27b",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 100
  }'
```

## Adding Another Model

1. Drop the GGUF under `~/.lmstudio/models/<owner>/<repo>/`.
2. Add a stanza to `~/.config/llama-swap/llama-swap.yaml` (copy a `cmd:` block, change `-m`, `-c`, `--alias`).
3. Add the model to `~/.config/opencode/opencode.json` (under `provider.local-b70.models`).
4. Add the model to `~/.pi/agent/models.json` (under the `local-b70` provider's `models` array).
5. `systemctl --user restart llama-swap`.

## File Locations

| Component | Path |
|---|---|
| llama.cpp build | `~/llama.cpp/build/bin/` |
| llama-swap binary | `~/.local/bin/llama-swap` |
| llama-swap config | `~/.config/llama-swap/llama-swap.yaml` |
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
