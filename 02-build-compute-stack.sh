#!/usr/bin/env bash
# =============================================================================
# b70-prereqs-install.sh
# Installs the Intel dependencies and llama.cpp SYCL build needed to run
# a local LLM stack on an Intel Arc Pro B70 (USB4 eGPU).
#
# Assumes:
#   - Ubuntu 24.04 (or compatible)
#   - Kernel 7.x (xe driver already present — no kernel changes needed)
#   - B70 connected via USB4 and visible to lspci
#   - You have sudo access
#
# Run with: bash b70-prereqs-install.sh
# =============================================================================

# Re-exec under bash if invoked as sh (dash doesn't support [[ or arrays)
if [ -z "$BASH_VERSION" ]; then
  exec bash "$0" "$@"
fi

set -euo pipefail

# ── Configuration — adjust if needed ─────────────────────────────────────────

# Where to clone and build llama.cpp
LLAMA_DIR="$HOME/llama.cpp"

# Compute-runtime version. Leave empty to auto-fetch the latest release.
# Pin to a specific tag if needed, e.g.: CR_VERSION="26.09.32308.3"
CR_VERSION=""

# Number of parallel compile jobs
JOBS=$(nproc)

# ─────────────────────────────────────────────────────────────────────────────

log()  { echo ""; echo "==> $*"; }
info() { echo "    $*" >&2; }   # stderr so it doesn't pollute $() captures
die()  { echo ""; echo "ERROR: $*" >&2; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not found."; }

# ── 0. Sanity checks ─────────────────────────────────────────────────────────

log "Checking environment..."

if lspci | grep -qi "Arc Pro B70"; then
  info "Intel Arc Pro B70 detected."
elif lspci | grep -qi "Battlemage"; then
  info "Intel Battlemage GPU detected."
else
  echo ""
  echo "WARN: Arc Pro B70 not found in lspci output."
  echo "      Make sure the eGPU is connected via USB4 before continuing."
  printf "      Continue anyway? [y/N] "
  read -r yn
  case "$yn" in
    [yY]) ;;
    *) exit 1 ;;
  esac
fi

# This fails despite xe being loaded.
#if lsmod | grep -q "^xe "; then
#  info "xe kernel driver is loaded."
#else
#  die "xe driver not loaded. Try: sudo modprobe xe"
#fi

require_cmd curl
require_cmd git

# ── 1. System build dependencies ─────────────────────────────────────────────

log "Installing system build dependencies..."
sudo apt-get update -qq
sudo apt-get install -y \
  build-essential \
  cmake \
  ninja-build \
  git \
  curl \
  wget \
  pkg-config \
  python3 \
  python3-pip \
  gpg \
  jq \
  lsb-release \
  ca-certificates \
  ocl-icd-opencl-dev \
  opencl-headers

# ── 2. Intel compute-runtime ─────────────────────────────────────────────────
#
# The APT repo version is too old for Battlemage (Xe2).
# We install directly from GitHub releases.

log "Installing Intel compute-runtime from GitHub releases..."

if [ -z "$CR_VERSION" ]; then
  info "Fetching latest compute-runtime version..."
  CR_VERSION=$(curl -fsSL \
    "https://api.github.com/repos/intel/compute-runtime/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d '"' -f 4 || true)
  info "Latest version: $CR_VERSION"
fi

# Check if already installed at a matching version
INSTALLED_CR=$(dpkg -l libze-intel-gpu1 2>/dev/null | awk '/^ii/{print $3}' | head -1 || true)
SKIP_CR=0
if [ -n "$INSTALLED_CR" ]; then
  info "compute-runtime already installed: $INSTALLED_CR"
  CR_MAJOR=$(echo "$CR_VERSION" | cut -d'.' -f1-2)
  case "$INSTALLED_CR" in
    "${CR_MAJOR}"*)
      info "Version looks current — skipping compute-runtime download."
      SKIP_CR=1
      ;;
    *)
      info "Installed version ($INSTALLED_CR) differs from target ($CR_VERSION) — upgrading."
      ;;
  esac
fi

if [ "$SKIP_CR" -eq 0 ]; then
  CR_TMP=$(mktemp -d)
  # shellcheck disable=SC2064
  trap "rm -rf '$CR_TMP'" EXIT

  info "Fetching release metadata for $CR_VERSION..."
  RELEASE_JSON=$(curl -fsSL \
    "https://api.github.com/repos/intel/compute-runtime/releases/tags/${CR_VERSION}")

  # Download a single .deb by grep pattern; print the local path on success
  download_deb() {
    local pattern="$1"
    local url
    url=$(echo "$RELEASE_JSON" \
      | grep "browser_download_url" \
      | grep "$pattern" \
      | grep -v ".sha256" \
      | head -1 \
      | cut -d '"' -f 4 || true)
    if [ -z "$url" ]; then
      echo "WARN: No package matching '$pattern' found — skipping." >&2
      return 0
    fi
    local fname
    fname=$(basename "$url")
    info "  Downloading $fname..."
    curl -fsSL -o "$CR_TMP/$fname" "$url"
    echo "$CR_TMP/$fname"
  }

  # --- compute-runtime packages (opencl-icd, libze, ocloc, igdgmm) ---
  DEB_LIST="$CR_TMP/deb_list.txt"
  : > "$DEB_LIST"
  for pattern in \
    "intel-opencl-icd.*amd64.deb" \
    "libze-intel-gpu.*amd64.deb" \
    "intel-ocloc.*amd64.deb" \
    "libigdgmm.*amd64.deb"
  do
    f=$(download_deb "$pattern")
    if [ -n "$f" ]; then
      echo "$f" >> "$DEB_LIST"
    fi
  done

  DEB_COUNT=$(wc -l < "$DEB_LIST")
  if [ "$DEB_COUNT" -eq 0 ]; then
    die "No .deb packages downloaded. Check: https://github.com/intel/compute-runtime/releases/tag/${CR_VERSION}"
  fi

  # --- Intel Graphics Compiler (IGC) packages ---
  # Since compute-runtime ~26.x, intel-igc-core and intel-igc-opencl are
  # released separately from intel/intel-graphics-compiler on GitHub.
  info "Fetching latest Intel Graphics Compiler (IGC) version..."
  IGC_VERSION=$(curl -fsSL \
    "https://api.github.com/repos/intel/intel-graphics-compiler/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d '"' -f 4 || true)
  info "IGC version: $IGC_VERSION"

  IGC_JSON=$(curl -fsSL \
    "https://api.github.com/repos/intel/intel-graphics-compiler/releases/tags/${IGC_VERSION}")

  for pattern in \
    "intel-igc-core.*amd64.deb" \
    "intel-igc-opencl.*amd64.deb"
  do
    f=$(echo "$IGC_JSON" \
      | grep "browser_download_url" \
      | grep "$pattern" \
      | grep -v ".sha256" \
      | head -1 \
      | cut -d '"' -f 4 || true)
    if [ -n "$f" ]; then
      fname=$(basename "$f")
      info "  Downloading $fname..."
      curl -fsSL -o "$CR_TMP/$fname" "$f"
      echo "$CR_TMP/$fname" >> "$DEB_LIST"
    else
      info "WARN: IGC package matching '$pattern' not found in release $IGC_VERSION — skipping."
    fi
  done

  TOTAL=$(wc -l < "$DEB_LIST")
  info "Installing $TOTAL packages..."
  xargs sudo dpkg -i < "$DEB_LIST" || sudo apt-get install -f -y

  info "compute-runtime $CR_VERSION + IGC $IGC_VERSION installed."
fi

# ── 2.5. Level Zero loader ───────────────────────────────────────────────────
#
# libze-intel-gpu1 provides the driver, but libze_loader.so (from the Level Zero
# SDK) is what the oneAPI runtime uses to discover and talk to that driver.
# Without it, sycl-ls falls back to the OpenCL adapter, adding unnecessary
# overhead for every kernel dispatch, memory copy, and sync point.

log "Installing Level Zero loader..."

# Check if already installed
if dpkg -l libze1 >/dev/null 2>&1; then
  info "Level Zero loader already installed — skipping."
else
  ZE_LOADER_VERSION=$(curl -fsSL \
    "https://api.github.com/repos/oneapi-src/level-zero/releases/latest" \
    | grep '"tag_name"' | head -1 | cut -d '"' -f 4 | sed 's/^v//' || true)
  info "Level Zero SDK version: $ZE_LOADER_VERSION"

  # Determine Ubuntu codename for deb selection
  UBUNTU_CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")
  # Map newer codenames back to closest supported debs
  case "$UBUNTU_CODENAME" in
    resolute|oracular|noble)
      ZE_DEB_SUFFIX="u24.04"
      ;;
    jammy|mantic)
      ZE_DEB_SUFFIX="u22.04"
      ;;
    *)
      ZE_DEB_SUFFIX="u24.04"
      ;;
  esac

  ZE_DEB_NAME="libze1_${ZE_LOADER_VERSION}+${ZE_DEB_SUFFIX}_amd64.deb"
  ZE_DEB_URL="https://github.com/oneapi-src/level-zero/releases/download/v${ZE_LOADER_VERSION}/${ZE_DEB_NAME}"

  info "Downloading ${ZE_DEB_NAME}..."
  ZE_TMP=$(mktemp -d)
  curl -fsSL -o "$ZE_TMP/libze1.deb" "$ZE_DEB_URL"
  sudo dpkg -i "$ZE_TMP/libze1.deb" || sudo apt-get install -f -y
  sudo ldconfig
  rm -rf "$ZE_TMP"

  info "Level Zero loader $ZE_LOADER_VERSION installed."
fi

# Verify Level Zero is now the active backend
log "Verifying Level Zero backend..."

if command -v sycl-ls >/dev/null 2>&1; then
  SYCL_OUTPUT=$(sycl-ls 2>&1)
  if echo "$SYCL_OUTPUT" | grep -qi "level_zero"; then
    info "B70 is visible as a Level Zero device."
    echo "$SYCL_OUTPUT" | grep -i "Arc" | sed 's/^/    /' || true
  else
    info "WARN: B70 is still using OpenCL backend. Verify libze_loader.so is present:"
    info "  ldconfig -p | grep libze_loader"
    info "  sycl-ls --verbose"
  fi
else
  info "(sycl-ls not available — skipping Level Zero verification)"
fi

# Verify
log "Verifying compute-runtime..."
if command -v clinfo >/dev/null 2>&1; then
  if clinfo | grep -qi "Intel(R) Arc(TM) Pro B70"; then
    info "clinfo confirms B70 is visible to OpenCL."
  else
    info "WARN: B70 not listed in clinfo yet — a re-login or reboot may be needed."
  fi
else
  info "(clinfo not installed — skipping OpenCL verification)"
fi

# ── 3. Intel oneAPI (targeted packages only) ─────────────────────────────────
#
# We install only the three packages llama.cpp SYCL actually needs:
#   intel-oneapi-dpcpp-cpp  — icpx/icx DPC++ compiler
#   intel-oneapi-mkl-devel  — Math Kernel Library (BLAS backend)
#   intel-oneapi-tbb-devel  — Threading Building Blocks
#
# We deliberately avoid intel-basekit because it includes intel-oneapi-vtune,
# whose vtsspp kernel sampling driver fails to build on kernel 7.x
# (KTIME_MONOTONIC_RES was removed from the kernel). VTune is not needed
# for GPU inference.

log "Setting up Intel oneAPI APT repository..."

ONEAPI_GPG="/usr/share/keyrings/oneapi-archive-keyring.gpg"
ONEAPI_LIST="/etc/apt/sources.list.d/oneAPI.list"

if [ ! -f "$ONEAPI_GPG" ]; then
  wget -qO- https://apt.repos.intel.com/intel-gpg-keys/GPG-PUB-KEY-INTEL-SW-PRODUCTS.PUB \
    | gpg --dearmor \
    | sudo tee "$ONEAPI_GPG" > /dev/null
  info "oneAPI GPG key installed."
fi

if [ ! -f "$ONEAPI_LIST" ]; then
  echo "deb [signed-by=${ONEAPI_GPG}] https://apt.repos.intel.com/oneapi all main" \
    | sudo tee "$ONEAPI_LIST" > /dev/null
  info "oneAPI APT source added."
fi

sudo apt-get update -qq

if command -v icpx >/dev/null 2>&1; then
  info "icpx already on PATH — skipping oneAPI package install."
elif [ -f /opt/intel/oneapi/compiler/latest/bin/icpx ]; then
  info "oneAPI compiler already installed — skipping."
else
  log "Installing Intel oneAPI compiler, MKL, and TBB (~3 GB)..."
  sudo apt-get install -y \
    intel-oneapi-dpcpp-cpp \
    intel-oneapi-mkl-devel \
    intel-oneapi-tbb-devel
  info "oneAPI packages installed."
fi

log "Sourcing oneAPI environment..."
# setvars.sh writes to stdout and may exit non-zero in some configurations.
# shellcheck disable=SC1091
source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 \
  || die "Failed to activate oneAPI environment."
info "oneAPI environment active."

if command -v icpx >/dev/null 2>&1; then
  info "icpx: $(icpx --version 2>&1 | head -1)"
else
  die "icpx not found after sourcing oneAPI — installation may have failed."
fi

log "Checking SYCL device enumeration..."
if sycl-ls 2>/dev/null | grep -qi "Arc"; then
  info "B70 is visible as a SYCL device."
  sycl-ls 2>/dev/null | grep -i "Arc" | sed 's/^/    /' || true
else
  info "WARN: B70 not found in sycl-ls yet. A reboot may be required."
  info "Full sycl-ls output:"
  sycl-ls 2>/dev/null | sed 's/^/    /' || true
fi

# ── 4. Build llama.cpp with SYCL ─────────────────────────────────────────────

log "Setting up llama.cpp..."

if [ -d "$LLAMA_DIR" ]; then
  info "llama.cpp already cloned at $LLAMA_DIR — pulling latest..."
  git -C "$LLAMA_DIR" pull
else
  info "Cloning llama.cpp..."
  git clone https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
fi

log "Building llama.cpp with SYCL (this takes several minutes)..."
info "Using $JOBS parallel jobs."

# Re-source oneAPI in case the environment was reset
# shellcheck disable=SC1091
source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 \
  || die "Failed to activate oneAPI environment."
info "oneAPI environment active."

cd "$LLAMA_DIR"

cmake -S . -B build -G Ninja \
  -DGGML_SYCL=ON \
  -DCMAKE_C_COMPILER=icx \
  -DCMAKE_CXX_COMPILER=icpx \
  -DCMAKE_BUILD_TYPE=Release

cmake --build build -j"$JOBS"

LLAMA_SERVER="$LLAMA_DIR/build/bin/llama-server"
if [ -f "$LLAMA_SERVER" ]; then
  info "Build succeeded: $LLAMA_SERVER"
else
  die "Build finished but llama-server binary not found at $LLAMA_SERVER"
fi

log "Verifying llama.cpp SYCL device detection..."
"$LLAMA_DIR/build/bin/llama-cli" --list-devices 2>/dev/null || true

# ── 5. Persist oneAPI in ~/.bashrc ───────────────────────────────────────────

log "Adding oneAPI to ~/.bashrc..."
SETVARS_LINE='source /opt/intel/oneapi/setvars.sh --force 2>/dev/null'
if grep -qF "setvars.sh" "$HOME/.bashrc" 2>/dev/null; then
  info "oneAPI already present in ~/.bashrc — skipping."
else
  {
    echo ""
    echo "# Intel oneAPI — required for llama.cpp SYCL and direct llama-server use"
    echo "$SETVARS_LINE"
  } >> "$HOME/.bashrc"
  info "Added to ~/.bashrc."
fi

# ── Done ─────────────────────────────────────────────────────────────────────

cat <<SUMMARY

=============================================================================
  Prerequisites installed successfully
=============================================================================
  Intel compute-runtime : $CR_VERSION
  llama.cpp             : $LLAMA_DIR/build/bin/llama-server

Next steps:
  1. Reload your shell:   source ~/.bashrc
  2. Verify the B70:      sycl-ls
  3. Download GGUF models to ~/.lmstudio/models/
  4. Run scripts 03 and 04 to register models and start the service

Quick server test (replace with your actual GGUF path):
  source /opt/intel/oneapi/setvars.sh
  $LLAMA_DIR/build/bin/llama-server \\
    --model ~/.lmstudio/models/your-model.gguf \\
    --n-gpu-layers 999 --host 127.0.0.1 --port 9000
=============================================================================
SUMMARY
