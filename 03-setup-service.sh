#!/usr/bin/env bash
# =============================================================================
# b70-setup install script
#
# This script sets up the top-layer tooling (llama-swap service, opencode,
# and pi coding agent). It assumes the lower-level stack (Intel oneAPI,
# llama.cpp SYCL build, Intel compute-runtime) is already in place.
# See PREREQUISITES below.
#
# NOTE: Config file contents (llama-swap.yaml, opencode.json, models.json)
# are bundled with this script. Adjust paths, model names, and ports
# to match your setup before running.
#
# Tested target: Ubuntu 24.04, Intel Arc Pro B70 via USB4 eGPU
# =============================================================================

# --- PREREQUISITES (must be satisfied manually before running this script) ---
#
# HARDWARE
#   [ ] Intel Arc Pro B70 GPU
#   [ ] Host machine
#   [ ] NVMe storage with enough space for GGUF model files
#       - Qwen3.6-27B Q4_K_M  ≈ 17 GB
#       - Gemma 4 32B         ≈  5 GB
#
# OS & KERNEL
#   [ ] Ubuntu 24.04 LTS (or compatible distro)
#   [ ] Kernel with xe driver support for Battlemage (≥6.8; ≥6.17 preferred)
#       Verify: uname -r   and   lsmod | grep xe
#
# INTEL GPU STACK
#   [ ] Intel compute-runtime v26.09+ installed from GitHub releases
#       (the APT repo version is too old for B70)
#       https://github.com/intel/compute-runtime/releases
#       Install the .deb packages: intel-opencl-icd, libze-intel-gpu1,
#       intel-ocloc, intel-igc-core-2, intel-igc-opencl-2
#   [ ] Intel oneAPI Base Toolkit installed at /opt/intel/oneapi/
#       https://www.intel.com/content/www/us/en/developer/tools/oneapi/base-toolkit.html
#       Verify: source /opt/intel/oneapi/setvars.sh && sycl-ls
#       (should list the B70 as a Level Zero device)
#
# LLAMA.CPP (SYCL BUILD)
#   [ ] llama.cpp cloned and built with SYCL support
#       Build in a oneAPI-initialized shell:
#         source /opt/intel/oneapi/setvars.sh
#         cmake -S . -B build -G Ninja \
#           -DGGML_SYCL=ON \
#           -DCMAKE_C_COMPILER=icx \
#           -DCMAKE_CXX_COMPILER=icpx
#         cmake --build build -j$(nproc)
#   [ ] llama-server binary accessible on $PATH or at a known path
#       (e.g. ~/llama.cpp/build/bin/llama-server)
#
# MODELS (GGUFs)
#   [ ] Qwen3.6-27B GGUF downloaded (e.g. Q4_K_M from lmstudio-community or unsloth)
#   [ ] Gemma 4 32B GGUF downloaded
#   [ ] Both placed under ~/.lmstudio/models/<owner>/<repo>/
#       (this lets LM Studio and llama-swap share the same files)
#
# =============================================================================

set -euo pipefail

# ── Configuration — edit these before running ────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# llama-swap
LLAMA_SWAP_VERSION="latest"   # or pin to a specific tag, e.g. "v0.0.32"
LLAMA_SWAP_PORT=8080          # the single OpenAI-compatible endpoint
LLAMA_SERVER_PORT=9000        # internal port llama-swap spawns llama-server on
LLAMA_SWAP_CONFIG="$HOME/.config/llama-swap/llama-swap.yaml"

# llama.cpp binary path (adjust to where you built it)
LLAMA_SERVER_BIN="$HOME/llama.cpp/build/bin/llama-server"

# GGUF model paths (adjust to your actual filenames)
MODELS_DIR="$HOME/.lmstudio/models"
QWEN_GGUF="$MODELS_DIR/lmstudio-community/Qwen3.6-27B-GGUF/Qwen3.6-27B-Q4_K_M.gguf"
GEMMA_GGUF="$MODELS_DIR/lmstudio-community/gemma-4-31B-it-GGUF/gemma-4-31B-it-Q4_K_M.gguf"
DEEP_GGUF="$MODELS_DIR/lmstudio-community/DeepSeek-R1-Distill-Qwen-32B-GGUF/DeepSeek-R1-Distill-Qwen-32B-Q4_K_M.gguf"

# Linger user (the user whose session hosts the systemd unit)
LINGER_USER="${USER}"

# ─────────────────────────────────────────────────────────────────────────────

log()  { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── 0. Sanity checks ─────────────────────────────────────────────────────────

log "Checking prerequisites..."

[[ -f /opt/intel/oneapi/setvars.sh ]] \
  || die "Intel oneAPI not found at /opt/intel/oneapi/setvars.sh. Install it first."

# Source oneAPI so sycl-ls and icpx are on PATH for the rest of this script
# shellcheck disable=SC1091
#source /opt/intel/oneapi/setvars.sh --force 2>/dev/null

#command -v sycl-ls >/dev/null 2>&1 \
#  || die "sycl-ls not found after sourcing oneAPI. Check your oneAPI install."

#sycl-ls | grep -qi "level_zero" \
#  || warn "No Level Zero device found via sycl-ls. The B70 may not be detected yet."

[[ -f "$LLAMA_SERVER_BIN" ]] \
  || die "llama-server not found at $LLAMA_SERVER_BIN. Build llama.cpp with SYCL first."

[[ -f "$QWEN_GGUF" ]] \
  || warn "Qwen GGUF not found at $QWEN_GGUF — update QWEN_GGUF in this script."

[[ -f "$GEMMA_GGUF" ]] \
  || warn "Gemma GGUF not found at $GEMMA_GGUF — update GEMMA_GGUF in this script."

[[ -f "$DEEP_GGUF" ]] \
  || warn "DeepSeek GGUF not found at $DEEP_GGUF — update DEEP_GGUF in this script."

# ── 1. Install llama-swap binary ─────────────────────────────────────────────

log "Installing llama-swap..."
mkdir -p "$HOME/.local/bin"

if command -v llama-swap >/dev/null 2>&1; then
  log "llama-swap already on PATH, skipping download."
else
  # Fetch latest Linux amd64 release archive
  LLAMA_SWAP_URL=$(curl -fsSL \
    "https://api.github.com/repos/mostlygeek/llama-swap/releases/latest" \
    | grep "browser_download_url" \
    | grep "linux_amd64.tar.gz" \
    | head -1 \
    | cut -d '"' -f 4)

  if [[ -z "$LLAMA_SWAP_URL" ]]; then
    die "Could not determine llama-swap download URL. Download manually from https://github.com/mostlygeek/llama-swap/releases"
  fi

  log "Downloading llama-swap from $LLAMA_SWAP_URL..."

  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT

  curl -fsSL -o "$TMPDIR/llama-swap.tar.gz" "$LLAMA_SWAP_URL"

  tar -xzf "$TMPDIR/llama-swap.tar.gz" -C "$TMPDIR"

  LLAMA_SWAP_BIN=$(find "$TMPDIR" -type f -name "llama-swap" | head -1)

  if [[ -z "$LLAMA_SWAP_BIN" ]]; then
    die "Could not find llama-swap binary inside downloaded archive."
  fi

  install -m 755 "$LLAMA_SWAP_BIN" "$HOME/.local/bin/llama-swap"

  log "Installed llama-swap:"
  "$HOME/.local/bin/llama-swap" version || true
fi

# Ensure ~/.local/bin is on PATH
if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
  warn "~/.local/bin is not in PATH. Add it to your shell rc file:"
  warn '  echo '\''export PATH="$HOME/.local/bin:$PATH"'\'' >> ~/.bashrc'
fi

# ── 3. Install the bundled llm-swap helper ──────────────────────────────────

log "Installing llm-swap helper..."
mkdir -p "$HOME/.local/bin"

if [[ -f "$SCRIPT_DIR/llm-swap" ]]; then
  cp "$SCRIPT_DIR/llm-swap" "$HOME/.local/bin/llm-swap"
  chmod +x "$HOME/.local/bin/llm-swap"
  log "Installed llm-swap helper."
else
  warn "llm-swap helper not found in script directory."
fi

# ── 4. Write llama-swap config ────────────────────────────────────────────────

log "Writing llama-swap config to $LLAMA_SWAP_CONFIG..."
mkdir -p "$(dirname "$LLAMA_SWAP_CONFIG")"

# Only write if it doesn't exist, to avoid clobbering a customised version
if [[ -f "$LLAMA_SWAP_CONFIG" ]]; then
  log "llama-swap.yaml already exists — skipping (edit manually if needed)."
else
  # Copy bundled config and substitute paths with user variables
  if [[ -f "$SCRIPT_DIR/llama-swap.yaml.template" ]]; then
    sed -e "s|{{LLAMA_SERVER_BIN}}|${LLAMA_SERVER_BIN}|g" \
        -e "s|{{QWEN_GGUF}}|${QWEN_GGUF}|g" \
        -e "s|{{GEMMA_GGUF}}|${GEMMA_GGUF}|g" \
        -e "s|{{DEEP_GGUF}}|${DEEP_GGUF}|g" \
        "$SCRIPT_DIR/llama-swap.yaml.template" > "$LLAMA_SWAP_CONFIG"
    log "Written. Review and adjust $LLAMA_SWAP_CONFIG before starting the service."
  else
    die "Bundled llama-swap.yaml.template not found in script directory."
  fi
fi

# ── 5. Create systemd user unit for llama-swap ───────────────────────────────

log "Creating systemd user unit for llama-swap..."
UNIT_DIR="$HOME/.config/systemd/user"
mkdir -p "$UNIT_DIR"

cat > "$UNIT_DIR/llama-swap.service" <<UNIT
[Unit]
Description=llama-swap LLM proxy (Intel Arc Pro B70)
After=network.target

[Service]
Type=simple
# Source oneAPI environment so llama-server can find SYCL/Level-Zero
Environment="PATH=/opt/intel/oneapi/compiler/latest/bin:%h/.local/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=/bin/bash -c 'source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 && exec %h/.local/bin/llama-swap --config %h/.config/llama-swap/llama-swap.yaml --listen 0.0.0.0:${LLAMA_SWAP_PORT}'
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
UNIT

systemctl --user daemon-reload
systemctl --user enable llama-swap.service
log "Systemd unit installed and enabled."

# ── 6. Enable linger so the service survives logout ───────────────────────────

log "Enabling linger for $LINGER_USER (requires sudo)..."
sudo loginctl enable-linger "$LINGER_USER" \
  && log "Linger enabled." \
  || warn "Could not enable linger — run manually: sudo loginctl enable-linger $LINGER_USER"

# ── 6. Write opencode config ──────────────────────────────────────────────────

log "Writing opencode config..."
OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
mkdir -p "$OPENCODE_CONFIG_DIR"

if [[ -f "$OPENCODE_CONFIG_DIR/opencode.json" ]]; then
  log "opencode.json already exists — skipping."
else
  cat > "$OPENCODE_CONFIG_DIR/opencode.json" <<JSON

{
  "$schema": "https://opencode.ai/config.json",

  "provider": {
    "local-b70": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local B70 (llama-swap)",
      "options": {
        "baseURL": "http://127.0.0.1:${LLAMA_SWAP_PORT}/v1",
        "apiKey": "local"
      },
      "models": {
        "qwen3.6-27b": {
          "name": "Qwen 3.6 27B"
        },
        "gemma-4-31b": {
          "name": "Gemma 4 31B"
        },
        "deepseek-r1-32b": {
          "name": "DeepSeek R1 32B"
        }
      }
    }
  },

  "model": "local-b70/qwen3.6-27b"
}
JSON
    log "Generated opencode.json."
fi

# Install opencode if not already present
if ! command -v opencode >/dev/null 2>&1; then
  log "Installing opencode..."
  if command -v npm >/dev/null 2>&1; then
    npm install -g opencode-ai
  else
    warn "npm not found. Install Node.js, then run: npm install -g opencode"
  fi
else
  log "opencode already installed: $(command -v opencode)"
fi

# ── 7. Write pi coding agent config ──────────────────────────────────────────

log "Writing pi config..."
PI_CONFIG_DIR="$HOME/.pi/agent"
mkdir -p "$PI_CONFIG_DIR"

if [[ -f "$PI_CONFIG_DIR/models.json" ]]; then
  log "models.json already exists — skipping."
else
  cat > "$PI_CONFIG_DIR/models.json" <<JSON
{
  "providers": {
    "local-b70": {
      "baseUrl": "http://127.0.0.1:${LLAMA_SWAP_PORT}/v1",
      "api": "openai-completions",
      "apiKey": "local",
      "compat": {
        "supportsDeveloperRole": false,
        "supportsReasoningEffort": false,
        "supportsUsageInStreaming": false
      },
      "models": [
        { "id": "qwen3.6-27b", "name": "Qwen 3.6 27B" },
        { "id": "gemma-4-31b", "name": "Gemma 4 31B" },
        { "id": "deepseek-r1-32b", "name": "DeepSeek R1 32B" }

      ]
    }
  }
}
JSON
    log "Generated models.json."
fi

# Install pi if not already present
if ! command -v pi >/dev/null 2>&1; then
  log "Installing pi coding agent..."
  if command -v npm >/dev/null 2>&1; then
    npm install -g @mariozechner/pi-coding-agent
  else
    warn "npm not found. Install Node.js, then run: npm install -g @mariozechner/pi-coding-agent"
  fi
else
  log "pi already installed: $(command -v pi)"
fi

# ── 8. Start the service ─────────────────────────────────────────────────────

log "Starting llama-swap service..."
systemctl --user start llama-swap.service
sleep 3

if systemctl --user is-active --quiet llama-swap.service; then
  log "llama-swap is running."
else
  warn "llama-swap failed to start. Check: journalctl --user -u llama-swap -n 50"
fi

# ── Done ──────────────────────────────────────────────────────────────────────

cat <<SUMMARY

=============================================================================
  Installation complete
=============================================================================

Service management:
  systemctl --user status|start|stop|restart llama-swap.service
  journalctl --user -u llama-swap -f          # live logs

Model preloading:
  llm-swap qwen3.6-27b                        # warm up (~22s cold)
  llm-swap gemma-4-31b
  llm-swap deepseek-r1-32b
  llm-swap list | status | unload

opencode (interactive TUI):
  opencode                                    # default model (qwen3.6-27b)
  opencode -m local-b70/gemma-4-31b           # use Gemma
  opencode -m local-b70/deepseek-r1-32b       # use DeepSeek

pi coding agent:
  pi --provider local-b70 --model qwen3.6-27b
  pi --provider local-b70 --model gemma-4-31b -p "one-shot prompt"
  pi --provider local-b70 --model deepseek-r1-32b
  pi config                                   # TUI for extensions

API endpoint:
  http://127.0.0.1:${LLAMA_SWAP_PORT}/v1/chat/completions
  (OpenAI-compatible; set model: "qwen3.6-27b" or "gemma-4-31b" or "deepseek-r1-32b")

⚠  Review and adjust these files before relying on this setup:
  $LLAMA_SWAP_CONFIG
  $HOME/.config/opencode/opencode.json
  $HOME/.pi/agent/models.json
=============================================================================
SUMMARY
