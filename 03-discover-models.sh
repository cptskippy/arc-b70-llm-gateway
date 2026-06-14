#!/usr/bin/env bash
# =============================================================================
# Discover GGUF models and ensure a params file exists for each one.
#
# Scans MODELS_DIR for all .gguf files. For any GGUF that lacks a corresponding
# params file (named <gguf>.llama.cpp.params in the same directory), creates it
# from the defaults template (LLAMA_CPP_DEFAULTS), substituting model-specific
# values.
#
# Intended to be run before 04-setup-service.sh so that per-model parameters
# are in place for llama-swap or any other tooling that consumes them.
# =============================================================================

set -euo pipefail

# ── Configuration — edit these before running ────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Root directory that contains model folders (each folder holds one or more
# .gguf files).  Matches the LM Studio default layout.
MODELS_DIR="$HOME/.lmstudio/models"

# Path to the defaults template.  Each non-empty, non-comment line becomes a
# parameter in the generated llama.cpp.params file.
# Two placeholders are substituted:
#   __MODEL_NAME__  → kebab-case alias derived from the GGUF filename
#   __PORT__        → shared llama-server port (all models use the same one)
LLAMA_CPP_DEFAULTS="$SCRIPT_DIR/llama.cpp.params.defaults"

# Shared port for llama-server.  Since llama-swap swaps models in and out of
# GPU memory on demand, every model binds to the same port.
LLAMA_SERVER_PORT=9000

# ─────────────────────────────────────────────────────────────────────────────

log()  { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }
die()  { echo "ERROR: $*" >&2; exit 1; }

# ── 0. Sanity checks ─────────────────────────────────────────────────────────

log "Checking prerequisites..."

[[ -d "$MODELS_DIR" ]] \
  || die "Models directory not found at $MODELS_DIR. Set MODELS_DIR in this script."

[[ -f "$LLAMA_CPP_DEFAULTS" ]] \
  || die "Defaults file not found at $LLAMA_CPP_DEFAULTS. Create it or adjust LLAMA_CPP_DEFAULTS."

# ── 1. Discover GGUF files ───────────────────────────────────────────────────

log "Scanning $MODELS_DIR for GGUF models..."

# Collect individual .gguf file paths.
declare -a GGUF_FILES=()
while IFS= read -r -d '' gguf_path; do
  GGUF_FILES+=("$gguf_path")
done < <(find "$MODELS_DIR" -type f -iname '*.gguf' -print0 2>/dev/null)

if [[ ${#GGUF_FILES[@]} -eq 0 ]]; then
  warn "No GGUF models found under $MODELS_DIR."
  exit 0
fi

log "Found ${#GGUF_FILES[@]} GGUF file(s):"
for f in "${GGUF_FILES[@]}"; do
  log "  $f"
done

# ── 2. Read defaults template ────────────────────────────────────────────────

# Filter out blank lines and comments, store remaining flags in an array.
declare -a DEFAULT_LINES=()
while IFS= read -r line; do
  # Strip leading/trailing whitespace.
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  # Skip empty lines and comments.
  [[ -z "$line" ]] && continue
  [[ "$line" == \#* ]] && continue
  DEFAULT_LINES+=("$line")
done < "$LLAMA_CPP_DEFAULTS"

if [[ ${#DEFAULT_LINES[@]} -eq 0 ]]; then
  die "Defaults file is empty or contains only comments."
fi

log "Loaded ${#DEFAULT_LINES[@]} default parameter lines."

# ── 3. Write missing params files ────────────────────────────────────────────

created=0
skipped=0

# Derive a kebab-case alias from a GGUF filename (strips .gguf extension).
_to_kebab() {
  local name="${1%.gguf}"
  echo "$name" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]/-/g' -e 's/-\+/-/g' -e 's/^-//;s/-$//'
}

for gguf_path in "${GGUF_FILES[@]}"; do
  gguf_dir="$(dirname "$gguf_path")"
  params_file="$gguf_dir/$(basename "$gguf_path").llama.cpp.params"

  if [[ -f "$params_file" ]]; then
    log "  Already exists: $params_file — skipping."
    skipped=$((skipped + 1))
    continue
  fi

  model_name="$(_to_kebab "$(basename "$gguf_path")")"

  log "  Creating $params_file  (alias=$model_name, port=$LLAMA_SERVER_PORT)..."

  # Write params file: substitute placeholders in each default line.
  {
    for param_line in "${DEFAULT_LINES[@]}"; do
      echo "$param_line" \
        | sed -e "s|__MODEL_NAME__|${model_name}|g" \
              -e "s|__PORT__|${LLAMA_SERVER_PORT}|g"
    done
  } > "$params_file"

  created=$((created + 1))
done

# ── Done ──────────────────────────────────────────────────────────────────────

cat <<SUMMARY

=============================================================================
  Model discovery complete
=============================================================================

  GGUF files found : ${#GGUF_FILES[@]}
  Params created   : $created
  Already exist    : $skipped

  Shared server port: $LLAMA_SERVER_PORT
  Models directory  : $MODELS_DIR
  Defaults template : $LLAMA_CPP_DEFAULTS

=============================================================================
SUMMARY
