#!/usr/bin/env bash
# =============================================================================
# Synthetic benchmark using llama.cpp's built-in llama-bench.
#
# Stops llama-swap before running to avoid VRAM contention, then restarts it.
# Usage:
#   ./bench-llama-bench.sh                          # all models in llama-swap config
#   ./bench-llama-bench.sh qwen3-6-27b-q4-k-m       # specific model only
# =============================================================================

set -euo pipefail

source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1

LLAMA_BENCH="$HOME/llama.cpp/build/bin/llama-bench"
LLAMA_SWAP_CONFIG="$HOME/.config/llama-swap/llama-swap.yaml"
MODELS_DIR="$HOME/.lmstudio/models"
JOBS=$(nproc)
PROMPT="Once upon a time in a world where technology and nature coexisted in perfect harmony, there lived a curious inventor who dreamed of building something extraordinary."
N_TOKENS=256
BATCH_SIZES="4,8,16,32"
ITERATIONS=3

[[ -f "$LLAMA_BENCH" ]] || { echo "ERROR: llama-bench not found at $LLAMA_BENCH"; exit 1; }

# ── Parse args ────────────────────────────────────────────────────────────────
TARGET_MODEL="${1:-}"

# ── Collect models from llama-swap.yaml ───────────────────────────────────────
declare -a MODELS=()

if [[ -n "$TARGET_MODEL" ]]; then
    MODELS=("$TARGET_MODEL")
else
    # Parse model aliases from YAML (lines matching "  <name>:" under "models:")
    in_models=0
    while IFS= read -r line; do
        if [[ "$line" == "models:" ]]; then
            in_models=1
            continue
        fi
        if [[ $in_models -eq 1 ]]; then
            # Group section starts with a non-indented key or "groups:"
            if [[ "$line" =~ ^[a-z] ]] || [[ "$line" == "groups:" ]]; then
                break
            fi
            # Model entry: exactly 2-space indent followed by name and colon
            if [[ "$line" =~ ^\ \ ([a-zA-Z0-9][-a-zA-Z0-9]*):$ ]]; then
                MODELS+=("${BASH_REMATCH[1]}")
            fi
        fi
    done < "$LLAMA_SWAP_CONFIG"
fi

[[ ${#MODELS[@]} -gt 0 ]] && echo "Models to benchmark: ${MODELS[*]}" || { echo "No models found."; exit 1; }

# ── Stop llama-swap ───────────────────────────────────────────────────────────
SERVICE_WAS_ACTIVE=0
if systemctl --user is-active --quiet llama-swap.service 2>/dev/null; then
    echo ""
    echo "==> Stopping llama-swap service..."
    systemctl --user stop llama-swap.service
    sleep 2
    SERVICE_WAS_ACTIVE=1
fi

# Also unload any lingering llama-server processes to free VRAM
echo "==> Unloading models via llm-swap..."
llm-swap unload 2>/dev/null || true
sleep 1

# ── Run benchmarks ────────────────────────────────────────────────────────────
RESULTS_DIR="bench-results"
mkdir -p "$RESULTS_DIR"

for model_alias in "${MODELS[@]}"; do
    echo ""
    echo "==============================================================================="
    echo "  Benchmarking: $model_alias"
    echo "==============================================================================="

    # Find the GGUF for this alias by scanning params files
    gguf_path=""
    while IFS= read -r -d '' params_file; do
        if grep -qF "--alias $model_alias" "$params_file" 2>/dev/null; then
            gguf_path="${params_file%.llama.cpp.params}"
            break
        fi
    done < <(find "$MODELS_DIR" -type f -name '*.llama.cpp.params' -print0)

    if [[ -z "$gguf_path" || ! -f "$gguf_path" ]]; then
        echo "  WARN: No GGUF found for alias '$model_alias' — skipping."
        continue
    fi

    # Read extra flags from the params file (everything except -m, --host, --port, --alias, --verbose)
    extra_flags=""
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]*}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        # Skip flags that llama-bench doesn't use or that we set explicitly
        [[ "$line" == --host* || "$line" == --port* || "$line" == --alias* || "$line" == "--verbose" ]] && continue
        extra_flags+=" $line"
    done < "${gguf_path}.llama.cpp.params"

    outfile="$RESULTS_DIR/${model_alias}.bench.txt"

    echo "  GGUF: $gguf_path"
    echo "  Flags:$extra_flags"
    echo "  Output: $outfile"

    "$LLAMA_BENCH" \
        -m "$gguf_path" \
        $extra_flags \
        -p "$PROMPT" \
        -n "$N_TOKENS" \
        -b "$BATCH_SIZES" \
        -t "$JOBS" \
        -r "$ITERATIONS" \
        2>&1 | tee "$outfile"

    echo ""
    echo "  Results saved to $outfile"
done

# ── Restore llama-swap ────────────────────────────────────────────────────────
echo ""
if [[ $SERVICE_WAS_ACTIVE -eq 1 ]]; then
    echo "==> Restarting llama-swap service..."
    systemctl --user start llama-swap.service
    sleep 2
    if systemctl --user is-active --quiet llama-swap.service; then
        echo "==> llama-swap is running."
    else
        echo "WARN: llama-swap failed to start. Check: journalctl --user -u llama-swap -n 50"
    fi
fi

echo ""
echo "==============================================================================="
echo "  All benchmarks complete. Results in $RESULTS_DIR/"
echo "==============================================================================="
ls -la "$RESULTS_DIR/"
