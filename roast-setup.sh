#!/usr/bin/env bash
#
# R.O.A.S.T. Setup
# Radeon On ARM, Serving Tokens
#
# Full setup script for llama.cpp with Vulkan on Raspberry Pi 5 + AMD GPU (RX 5700 XT)
# Target OS: Debian Trixie (aarch64, RPi OS)
#
# This script:
#   1. Fixes locale
#   2. Updates the system
#   3. Installs build dependencies and AMD firmware
#   4. Builds the Coreforge GPU-enabled kernel (if needed)
#   5. Builds a patched Vulkan driver (radv) and memcpy fix
#   6. Builds llama.cpp with Vulkan backend
#   7. Installs the R.O.A.S.T. CLI
#   8. Optionally sets up Open WebUI via Docker
#
# Usage:
#   chmod +x roast-setup.sh
#   sudo ./roast-setup.sh
#
# The script is idempotent - it skips steps that are already complete.
# A reboot is required after kernel installation before continuing.
# Re-run the script after reboot to complete remaining steps.

set -euo pipefail

# --- Configuration ---
ROAST_REPO="https://github.com/stylesuxx/roast.git"
ROAST_DIR="/opt/roast"
KERNEL_REPO="https://github.com/Coreforge/linux.git"
KERNEL_BRANCH_PREFERRED="rpi-6.12.y-gpu"
KERNEL_BRANCH_FALLBACK="rpi-6.6.y-gpu"
KERNEL_NAME="kernel_2712"
KERNEL_BUILD_DIR="/usr/src/coreforge-linux"
LLAMA_DIR="/opt/llama.cpp"
LLAMA_MODELS_DIR="/opt/llama.cpp/models"
BUILD_JOBS=$(nproc)
OPEN_WEBUI_PORT=3000
REAL_USER="${SUDO_USER:-$USER}"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }
step() { echo -e "\n${BOLD}=== $* ===${NC}"; }

# --- Preflight checks ---
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
    exit 1
fi

if [[ "$(uname -m)" != "aarch64" ]]; then
    err "This script is intended for aarch64 (ARM64). Detected: $(uname -m)"
    exit 1
fi

if ! grep -qi 'trixie\|sid' /etc/os-release 2>/dev/null; then
    warn "This script targets Debian Trixie. Detected: $(. /etc/os-release && echo "$PRETTY_NAME")"
    read -rp "Continue anyway? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || exit 1
fi

# Remove armhf multiarch - Pi 5's 16K page kernel breaks 32-bit ARM libs
if dpkg --print-foreign-architectures 2>/dev/null | grep -q armhf; then
    warn "armhf multiarch is enabled - removing it (incompatible with Pi 5's 16K page kernel)."
    ARMHF_PKGS=$(dpkg -l | grep ':armhf' | awk '{print $2}' || true)
    if [[ -n "$ARMHF_PKGS" ]]; then
        log "Removing armhf packages first..."
        apt-get remove -y $ARMHF_PKGS
    fi
    dpkg --remove-architecture armhf
    log "armhf multiarch removed."
fi

# --- State file to track progress across reboots ---
STATE_FILE="/var/lib/roast-setup-state"
touch "$STATE_FILE"

state_done()    { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
state_mark()    { echo "$1" >> "$STATE_FILE"; }

# =====================================================================
# Step 1: Fix locale
# =====================================================================
step "Step 1: Fix locale"
log "Ensuring en_US.UTF-8 locale..."
apt-get install -y locales
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
log "Locale set to en_US.UTF-8."

# =====================================================================
# Step 2: System update
# =====================================================================
step "Step 2: System update"
if state_done "system-updated"; then
    log "Already done, skipping."
else
    DEBIAN_FRONTEND=noninteractive apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -o Dpkg::Options::="--force-confnew"
    apt-get autoremove -y
    state_mark "system-updated"
    log "System updated."
fi

# =====================================================================
# Step 3: Install build dependencies
# =====================================================================
step "Step 3: Install build dependencies"
KERNEL_BUILD_DEPS=(
    git bc flex bison libncurses-dev libssl-dev
    build-essential cmake libcurl4-openssl-dev
    libvulkan-dev vulkan-tools glslc
    firmware-amd-graphics
    nvtop
)
apt-get install -y "${KERNEL_BUILD_DEPS[@]}"
log "Build dependencies installed."

# =====================================================================
# Step 4: Check if amdgpu is already loaded (kernel already built)
# =====================================================================
step "Step 4: Check current kernel for amdgpu support"

NEED_KERNEL=true
if lsmod | grep -q amdgpu 2>/dev/null; then
    log "amdgpu module is already loaded. Kernel build not needed."
    NEED_KERNEL=false
elif modprobe amdgpu 2>/dev/null; then
    log "amdgpu module loaded successfully. Kernel build not needed."
    NEED_KERNEL=false
elif find "/lib/modules/$(uname -r)" -name 'amdgpu.ko*' 2>/dev/null | grep -q .; then
    log "amdgpu module found but failed to load. It may need firmware or a reboot."
    NEED_KERNEL=false
fi

# =====================================================================
# Step 5: Build Coreforge kernel (if needed)
# =====================================================================
if $NEED_KERNEL; then
    step "Step 5: Build Coreforge GPU-enabled kernel"

    if state_done "kernel-installed"; then
        warn "Kernel was installed previously but amdgpu not detected."
        warn "You may need to reboot. Run this script again after reboot."
        echo ""
        read -rp "Reboot now? [Y/n] " ans
        [[ "$ans" =~ ^[Nn]$ ]] || { log "Rebooting..."; reboot; }
        exit 0
    fi

    # Determine which branch to use
    KERNEL_BRANCH=""
    AVAILABLE_BRANCHES=$(git ls-remote --heads "$KERNEL_REPO" 2>/dev/null)
    if echo "$AVAILABLE_BRANCHES" | grep -q "$KERNEL_BRANCH_PREFERRED"; then
        KERNEL_BRANCH="$KERNEL_BRANCH_PREFERRED"
    elif echo "$AVAILABLE_BRANCHES" | grep -q "$KERNEL_BRANCH_FALLBACK"; then
        KERNEL_BRANCH="$KERNEL_BRANCH_FALLBACK"
    else
        err "No GPU-enabled branch found in Coreforge repo."
        err "Available branches with 'gpu':"
        echo "$AVAILABLE_BRANCHES" | grep gpu || echo "  (none)"
        exit 1
    fi
    log "Using kernel branch: $KERNEL_BRANCH"

    # Clone kernel source
    if [[ -d "$KERNEL_BUILD_DIR/.git" ]]; then
        log "Kernel source already cloned at $KERNEL_BUILD_DIR"
        cd "$KERNEL_BUILD_DIR"
        CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
        if [[ "$CURRENT_BRANCH" != "$KERNEL_BRANCH" ]]; then
            warn "Existing clone is on branch '$CURRENT_BRANCH', expected '$KERNEL_BRANCH'."
            warn "Removing and re-cloning..."
            cd /
            rm -rf "$KERNEL_BUILD_DIR"
            git clone -b "$KERNEL_BRANCH" --depth=1 "$KERNEL_REPO" "$KERNEL_BUILD_DIR"
            cd "$KERNEL_BUILD_DIR"
        fi
    else
        log "Cloning Coreforge kernel (branch: $KERNEL_BRANCH)..."
        rm -rf "$KERNEL_BUILD_DIR"
        git clone -b "$KERNEL_BRANCH" --depth=1 "$KERNEL_REPO" "$KERNEL_BUILD_DIR"
        cd "$KERNEL_BUILD_DIR"
    fi

    # Configure kernel
    log "Configuring kernel..."
    make bcm2712_defconfig

    # Enable amdgpu as module if not already enabled
    if ! grep -q 'CONFIG_DRM_AMDGPU=m' .config; then
        log "Enabling amdgpu module in kernel config..."
        # Enable DRM and amdgpu dependencies
        scripts/config --module CONFIG_DRM_AMDGPU
        scripts/config --enable CONFIG_DRM_AMD_DC
        scripts/config --enable CONFIG_DRM_AMD_ACP
        # Run olddefconfig to resolve any new dependencies
        make olddefconfig
    fi

    # Verify amdgpu is configured
    if grep -q 'CONFIG_DRM_AMDGPU=m' .config; then
        log "amdgpu configured as module."
    elif grep -q 'CONFIG_DRM_AMDGPU=y' .config; then
        log "amdgpu configured as built-in."
    else
        err "Failed to enable amdgpu in kernel config."
        err "You may need to run 'make menuconfig' manually at: $KERNEL_BUILD_DIR"
        err "Navigate to: Device Drivers → Graphics Support → AMD GPU → enable as module (M)"
        exit 1
    fi

    # Build kernel
    log "Building kernel with $BUILD_JOBS jobs (this will take a while)..."
    make -j"$BUILD_JOBS" Image.gz modules dtbs

    # Install modules
    log "Installing kernel modules..."
    make -j"$BUILD_JOBS" modules_install

    # Backup and install kernel image
    log "Backing up current kernel..."
    if [[ -f "/boot/firmware/${KERNEL_NAME}.img" ]]; then
        cp "/boot/firmware/${KERNEL_NAME}.img" "/boot/firmware/${KERNEL_NAME}-backup.img"
        log "Backup saved as ${KERNEL_NAME}-backup.img"
    fi

    log "Installing new kernel..."
    cp arch/arm64/boot/Image.gz "/boot/firmware/${KERNEL_NAME}.img"
    cp arch/arm64/boot/dts/broadcom/*.dtb /boot/firmware/
    cp arch/arm64/boot/dts/overlays/*.dtb* /boot/firmware/overlays/
    cp arch/arm64/boot/dts/overlays/README /boot/firmware/overlays/

    state_mark "kernel-installed"
    log "Kernel installed successfully."

    # Enable PCIe Gen 3
    if ! grep -q 'dtparam=pciex1_gen=3' /boot/firmware/config.txt; then
        log "Enabling PCIe Gen 3 in config.txt..."
        echo 'dtparam=pciex1_gen=3' >> /boot/firmware/config.txt
    else
        log "PCIe Gen 3 already enabled."
    fi

    warn "A reboot is required for the new kernel to take effect."
    warn "After reboot, run this script again to build llama.cpp."
    echo ""
    read -rp "Reboot now? [Y/n] " ans
    [[ "$ans" =~ ^[Nn]$ ]] || { log "Rebooting..."; reboot; }
    exit 0
else
    log "Kernel has amdgpu support. Skipping kernel build."
fi

# =====================================================================
# Step 6: Verify GPU on PCIe bus
# =====================================================================
step "Step 6: Verify AMD GPU"

if lspci 2>/dev/null | grep -qi 'amd.*navi\|radeon'; then
    log "AMD GPU detected on PCIe bus."
else
    warn "AMD GPU not detected on PCIe bus. llama.cpp will run on CPU only."
fi

# =====================================================================
# Step 7: Build patched mesa radv + memcpy fix
# =====================================================================
step "Step 7: Build patched Vulkan driver (radv)"

# The Pi 5 uses a 16K page size kernel. The stock mesa radv driver has two issues:
#
# 1. radv contains unaligned 8-byte stores (str d-reg to non-8-byte-aligned addresses)
#    which cause SIGBUS on aarch64. Rebuilding with -mno-strict-align fixes this.
#
# 2. glibc's optimized memcpy uses 128-bit aligned stores (str q-reg) that also
#    cause SIGBUS when radv passes unaligned buffers. The Coreforge memcpy patch
#    provides a byte-safe fallback via LD_PRELOAD.
#
# Both are needed together - radv fix alone still crashes in glibc memcpy,
# and memcpy patch alone still crashes in radv's own unaligned stores.

MEMCPY_SO="/usr/local/lib/memcpy.so"
RADV_SO="/usr/local/lib/libvulkan_radeon_fixed.so"
RADV_ICD="/usr/local/share/vulkan/icd.d/radeon_fixed_icd.json"
MESA_VERSION="25.0.7"
MESA_BUILD_DIR="/tmp/mesa-${MESA_VERSION}"

# Test if the stock radv works (it won't on 16K page kernels)
NEED_PATCHED_RADV=true
if command -v vulkaninfo &>/dev/null; then
    if vulkaninfo --summary &>/dev/null; then
        log "Stock Vulkan driver works. Skipping mesa rebuild."
        NEED_PATCHED_RADV=false
    fi
fi

if [[ "$NEED_PATCHED_RADV" == false ]]; then
    log "No patched radv needed."
elif [[ -f "$RADV_SO" && -f "$MEMCPY_SO" && -f "$RADV_ICD" ]]; then
    log "Patched radv and memcpy already installed."
else
    # Install mesa build dependencies
    log "Installing mesa build dependencies..."
    apt-get install -y meson ninja-build python3-mako python3-ply python3-yaml \
        libdrm-dev libdrm-amdgpu1 libelf-dev libexpat1-dev libwayland-dev \
        libwayland-egl-backend-dev wayland-protocols libxrandr-dev libxfixes-dev \
        libxcb-shm0-dev libxcb-randr0-dev libxcb-keysyms1-dev libxshmfence-dev \
        glslang-tools llvm-19-dev libzstd-dev libunwind-dev libsensors-dev

    # Download and extract mesa source
    if [[ ! -d "$MESA_BUILD_DIR/build" ]]; then
        log "Downloading mesa ${MESA_VERSION}..."
        cd /tmp
        wget -q "https://archive.mesa3d.org/mesa-${MESA_VERSION}.tar.xz" -O "mesa-${MESA_VERSION}.tar.xz"
        tar xf "mesa-${MESA_VERSION}.tar.xz"
        cd "$MESA_BUILD_DIR"

        log "Configuring mesa radv with -mno-strict-align..."
        meson setup build \
            -Dvulkan-drivers=amd \
            -Dgallium-drivers= \
            -Dplatforms= \
            -Dc_args="-mno-strict-align" \
            -Dcpp_args="-mno-strict-align" \
            -Dllvm=enabled \
            --prefix=/usr \
            --libdir=lib/aarch64-linux-gnu
    fi

    cd "$MESA_BUILD_DIR"
    log "Building radv (this may take a while)..."
    ninja -C build src/amd/vulkan/libvulkan_radeon.so

    # Install patched radv
    cp build/src/amd/vulkan/libvulkan_radeon.so "$RADV_SO"
    mkdir -p "$(dirname "$RADV_ICD")"
    cat > "$RADV_ICD" <<ICDEOF
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "$RADV_SO",
        "api_version": "1.3.274"
    }
}
ICDEOF
    log "Patched radv installed to $RADV_SO"

    # Build and install memcpy alignment fix
    log "Building memcpy alignment patch..."
    MEMCPY_GIST="https://gist.githubusercontent.com/Coreforge/91da3d410ec7eb0ef5bc8dee24b91359/raw/b4848d1da9fff0cfcf7b601713efac1909e408e8/memcpy_unaligned.c"
    rm -f /tmp/memcpy_unaligned.c
    wget -q -O /tmp/memcpy_unaligned.c "$MEMCPY_GIST"
    gcc -shared -fPIC -o "$MEMCPY_SO" /tmp/memcpy_unaligned.c
    log "memcpy patch installed to $MEMCPY_SO"

    # Clean up build artifacts
    cd /
    rm -rf "$MESA_BUILD_DIR" "/tmp/mesa-${MESA_VERSION}.tar.xz" /tmp/memcpy_unaligned.c
fi

# Verify Vulkan works with patched driver
if command -v vulkaninfo &>/dev/null && [[ -f "$RADV_SO" && -f "$MEMCPY_SO" ]]; then
    VKDEV=$(LD_PRELOAD="$MEMCPY_SO" VK_ICD_FILENAMES="$RADV_ICD" vulkaninfo 2>/dev/null | grep 'deviceName' | head -1 | sed 's/.*= //' || true)
    if [[ -n "$VKDEV" ]]; then
        log "Vulkan verified: $VKDEV"
    else
        warn "vulkaninfo did not detect a Vulkan device."
    fi
fi

# =====================================================================
# Step 8: Build llama.cpp
# =====================================================================
step "Step 8: Build llama.cpp with Vulkan backend"

if [[ -x "$LLAMA_DIR/build/bin/llama-server" ]]; then
    log "llama-server already built at $LLAMA_DIR/build/bin/llama-server"
    read -rp "Rebuild? [y/N] " ans
    if [[ ! "$ans" =~ ^[Yy]$ ]]; then
        log "Skipping llama.cpp build."
        SKIP_LLAMA_BUILD=true
    else
        SKIP_LLAMA_BUILD=false
    fi
else
    SKIP_LLAMA_BUILD=false
fi

if [[ "$SKIP_LLAMA_BUILD" == false ]]; then
    if [[ -d "$LLAMA_DIR/.git" ]]; then
        log "Updating existing llama.cpp repo..."
        cd "$LLAMA_DIR"
        git pull --ff-only || {
            warn "Fast-forward pull failed. Rebuilding from scratch."
            cd /
            rm -rf "$LLAMA_DIR"
            git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
            cd "$LLAMA_DIR"
        }
    else
        log "Cloning llama.cpp..."
        rm -rf "$LLAMA_DIR"
        git clone https://github.com/ggerganov/llama.cpp.git "$LLAMA_DIR"
        cd "$LLAMA_DIR"
    fi

    log "Building llama.cpp with Vulkan support ($BUILD_JOBS jobs)..."
    cmake -B build -DGGML_VULKAN=1
    cmake --build build --config Release -j"$BUILD_JOBS"

    # Create models directory
    mkdir -p "$LLAMA_MODELS_DIR"
    chown -R "$REAL_USER":"$REAL_USER" "$LLAMA_MODELS_DIR"

    log "llama.cpp built successfully."
    log "Binary: $LLAMA_DIR/build/bin/llama-server"
fi

# =====================================================================
# Step 9: Install R.O.A.S.T. CLI
# =====================================================================
step "Step 9: Install R.O.A.S.T. CLI"

ROAST_BIN="/usr/local/bin/roast"

if [[ -x "$ROAST_BIN" ]]; then
    log "R.O.A.S.T. CLI already installed at $ROAST_BIN"
    cd "$ROAST_DIR"
    git pull --ff-only 2>/dev/null || warn "Could not update repo, continuing with existing version."
else
    log "Cloning R.O.A.S.T. repo..."
    if [[ -d "$ROAST_DIR/.git" ]]; then
        cd "$ROAST_DIR"
        git pull --ff-only 2>/dev/null || true
    else
        rm -rf "$ROAST_DIR"
        git clone "$ROAST_REPO" "$ROAST_DIR"
    fi
    chmod +x "$ROAST_DIR/roast.sh"
    ln -sf "$ROAST_DIR/roast.sh" "$ROAST_BIN"
    log "R.O.A.S.T. CLI installed: roast"
fi

# =====================================================================
# Step 10: Open WebUI (optional)
# =====================================================================
step "Step 10: Open WebUI setup (optional)"

read -rp "Install Open WebUI via Docker? [y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
    if ! command -v docker &>/dev/null; then
        log "Installing Docker..."
        curl -fsSL https://get.docker.com | sh
        usermod -aG docker "$REAL_USER"
        log "Docker installed."
    fi

    if docker ps -a --format '{{.Names}}' | grep -q '^open-webui$'; then
        log "Open WebUI container already exists."
    else
        docker run -d -p "$OPEN_WEBUI_PORT":8080 \
            --add-host=host.docker.internal:host-gateway \
            -e OPENAI_API_BASE_URLS="http://host.docker.internal:8080/v1" \
            -e OPENAI_API_KEYS="sk-unused" \
            -e ENABLE_OLLAMA_API=false \
            -v open-webui:/app/backend/data \
            --name open-webui \
            --restart always \
            ghcr.io/open-webui/open-webui:main
        log "Open WebUI running at http://$(hostname):$OPEN_WEBUI_PORT"
        echo ""
        echo "  1. Open http://$(hostname):$OPEN_WEBUI_PORT in your browser"
        echo "  2. Create an admin account on first login"
        echo "  3. If the model doesn't appear, go to Settings > Connections"
        echo "     and add: http://host.docker.internal:8080/v1"
    fi
else
    log "Skipping Open WebUI."
fi

# =====================================================================
# Done
# =====================================================================
step "Setup complete"
echo ""
log "llama-server binary: $LLAMA_DIR/build/bin/llama-server"
log "Models directory:    $LLAMA_MODELS_DIR"
echo ""

# --- Optional: install a starter model ---
echo "Would you like to install a model? (fits ~6GB VRAM, Q4_K_M quantization)"
echo ""
echo "  1) Qwen 2.5 7B Instruct        - general purpose"
echo "  2) Qwen 2.5 Coder 7B Instruct  - coding focused"
echo "  3) Mistral 7B Instruct v0.3    - general purpose"
echo "  4) Llama 3.1 8B Instruct       - general purpose"
echo "  5) Skip - I'll add one later"
echo ""

MODEL_URLS=(
    "https://huggingface.co/Qwen/Qwen2.5-7B-Instruct-GGUF/resolve/main/qwen2.5-7b-instruct-q4_k_m.gguf"
    "https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct-GGUF/resolve/main/qwen2.5-coder-7b-instruct-q4_k_m.gguf"
    "https://huggingface.co/MistralAI/Mistral-7B-Instruct-v0.3-GGUF/resolve/main/mistral-7b-instruct-v0.3-q4_k_m.gguf"
    "https://huggingface.co/bartowski/Meta-Llama-3.1-8B-Instruct-GGUF/resolve/main/Meta-Llama-3.1-8B-Instruct-Q4_K_M.gguf"
)

read -rp "Choose [1-5]: " model_choice
case "$model_choice" in
    [1-4])
        MODEL_URL="${MODEL_URLS[$((model_choice - 1))]}"
        log "Installing model..."
        "$ROAST_BIN" add "$MODEL_URL" --port 8080 --enable
        ;;
    *)
        log "Skipping model install."
        echo ""
        echo "Add one later with:"
        echo "  sudo roast add <huggingface-gguf-url> --port 8080 --enable"
        ;;
esac

echo ""
echo "Manage models:"
echo "  sudo roast list"
echo "  sudo roast status"
echo ""
