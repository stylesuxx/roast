#!/usr/bin/env bash
#
# R.O.A.S.T. Model Manager
# Radeon On ARM, Serving Tokens
#
# Download GGUF models from HuggingFace, verify them, and manage
# systemd services for llama-server instances.
#
# Usage:
#   sudo roast add <hf-url> [--port PORT] [--gpu-layers NGL] [--context-size CTX] [--parallel NP] [--enable]
#   sudo roast list
#   sudo roast enable <model-name>
#   sudo roast disable <model-name>
#   sudo roast remove <model-name>
#   sudo roast status
#   sudo roast bench <model-name>
#
# Examples:
#   sudo roast add https://huggingface.co/TheBloke/Mistral-7B-v0.1-GGUF/resolve/main/mistral-7b-v0.1.Q4_K_M.gguf --port 8080 --gpu-layers 99 --context-size 32768 --enable
#   sudo roast list
#   sudo roast disable mistral-7b-v0.1.Q4_K_M

set -euo pipefail

# --- Configuration ---
ROAST_REPO="https://github.com/stylesuxx/roast.git"
ROAST_DIR="/opt/roast"
LLAMA_DIR="/opt/llama.cpp"
LLAMA_SERVER="$LLAMA_DIR/build/bin/llama-server"
MODELS_DIR="/opt/llama.cpp/models"
SERVICE_PREFIX="roast"
DEFAULT_PORT=8080
DEFAULT_NGL=""
DEFAULT_CTX=32768
DEFAULT_NP=1

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }
info() { echo -e "${BLUE}[i]${NC} $*"; }

usage() {
    echo "R.O.A.S.T. Model Manager"
    echo ""
    echo "Usage:"
    echo "  $(basename "$0") add <hf-url> [--port PORT] [--gpu-layers NGL] [--context-size CTX] [--parallel NP] [--enable]"
    echo "  $(basename "$0") list"
    echo "  $(basename "$0") enable <model-name>"
    echo "  $(basename "$0") disable <model-name>"
    echo "  $(basename "$0") remove <model-name>"
    echo "  $(basename "$0") status"
    echo "  $(basename "$0") bench <model-name>"
    echo ""
    echo "Options for 'add':"
    echo "  --port PORT   Port for llama-server (default: $DEFAULT_PORT)"
    echo "  --gpu-layers NGL     Number of GPU layers (default: auto-fit, use 0 for CPU only)"
    echo "  --context-size CTX     Context size (default: $DEFAULT_CTX)"
    echo "  --parallel NP  Number of parallel request slots (default: $DEFAULT_NP)"
    echo "  --enable      Enable and start the service immediately"
    echo ""
    echo "Model name is the GGUF filename without extension."
    exit 1
}

# --- Preflight ---
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"

if [[ ! -x "$LLAMA_SERVER" ]]; then
    err "llama-server not found at $LLAMA_SERVER"
    err "Run roast-setup.sh first."
    exit 1
fi

mkdir -p "$MODELS_DIR"

# --- Helpers ---

# Derive a clean model name from a GGUF filename
model_name_from_file() {
    local filename="$1"
    basename "$filename" .gguf
}

# Get the service unit name for a model
service_name() {
    echo "${SERVICE_PREFIX}-$(echo "$1" | tr '.' '-' | tr '[:upper:]' '[:lower:]')"
}

# Check if a port is already used by another roast service
check_port_conflict() {
    local port="$1"
    local exclude_model="${2:-}"
    for unit in /etc/systemd/system/${SERVICE_PREFIX}-*.service; do
        [[ -f "$unit" ]] || continue
        local unit_model
        unit_model=$(basename "$unit" .service | sed "s/^${SERVICE_PREFIX}-//")
        if [[ -n "$exclude_model" && "$unit_model" == "$exclude_model" ]]; then
            continue
        fi
        if grep -q "\-\-port $port" "$unit" 2>/dev/null; then
            echo "$unit"
            return 0
        fi
    done
    return 1
}

# Validate a GGUF file by checking the magic number
validate_gguf() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        return 1
    fi
    # GGUF magic bytes: 47 47 55 46 ("GGUF" in ASCII)
    local magic
    magic=$(od -A n -t x1 -N 4 "$file" 2>/dev/null | tr -d ' ')
    if [[ "$magic" == "47475546" ]]; then
        return 0
    fi
    return 1
}

# --- Commands ---

cmd_add() {
    local url=""
    local port="$DEFAULT_PORT"
    local ngl="$DEFAULT_NGL"
    local ctx="$DEFAULT_CTX"
    local np="$DEFAULT_NP"
    local enable_after=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)  port="$2"; shift 2 ;;
            --gpu-layers)   ngl="$2"; shift 2 ;;
            --context-size)   ctx="$2"; shift 2 ;;
            --parallel)   np="$2"; shift 2 ;;
            --enable) enable_after=true; shift ;;
            -*)      err "Unknown option: $1"; usage ;;
            *)
                if [[ -z "$url" ]]; then
                    url="$1"
                else
                    err "Unexpected argument: $1"
                    usage
                fi
                shift
                ;;
        esac
    done

    if [[ -z "$url" ]]; then
        err "No URL provided."
        usage
    fi

    # Validate URL looks like a HuggingFace GGUF link
    if [[ "$url" != *".gguf"* ]]; then
        warn "URL does not end in .gguf - are you sure this is a GGUF model?"
        read -rp "Continue? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || exit 1
    fi

    # Extract filename from URL
    local filename
    filename=$(basename "$url" | sed 's/?.*//')
    local model_name
    model_name=$(model_name_from_file "$filename")
    local model_path="$MODELS_DIR/$filename"
    local svc
    svc=$(service_name "$model_name")

    info "Model:   $model_name"
    info "File:    $model_path"
    info "Service: $svc"
    info "Port:    $port"
    info "GPU layers: $ngl"
    info "Context: $ctx"
    echo ""

    # Check port conflicts
    local conflict
    if conflict=$(check_port_conflict "$port"); then
        err "Port $port is already used by: $(basename "$conflict")"
        err "Choose a different port with --port"
        exit 1
    fi

    # Download if not already present
    if [[ -f "$model_path" ]]; then
        log "Model file already exists at $model_path"
    else
        log "Downloading model..."

        # Download with wget (available on RPi OS) or fall back to curl
        if command -v wget &>/dev/null; then
            wget --progress=bar:force -O "$model_path" "$url"
        elif command -v curl &>/dev/null; then
            curl -fL --progress-bar -o "$model_path" "$url"
        else
            err "Neither wget nor curl found. Install one and try again."
            exit 1
        fi

        if [[ ! -f "$model_path" || ! -s "$model_path" ]]; then
            err "Download failed or file is empty."
            rm -f "$model_path"
            exit 1
        fi

        log "Download complete: $(du -h "$model_path" | cut -f1)"
    fi

    # Validate GGUF magic
    log "Validating GGUF file..."
    if validate_gguf "$model_path"; then
        log "Valid GGUF file."
    else
        err "File does not appear to be a valid GGUF file (bad magic number)."
        err "The download may be corrupted or the URL may be wrong."
        read -rp "Keep the file anyway? [y/N] " ans
        if [[ ! "$ans" =~ ^[Yy]$ ]]; then
            rm -f "$model_path"
            exit 1
        fi
    fi

    chown "$REAL_USER":"$REAL_USER" "$model_path"

    # Create systemd service
    local unit_path="/etc/systemd/system/${svc}.service"
    log "Creating systemd service: $svc"

    # Build ExecStart command
    local exec_cmd="$LLAMA_SERVER -m $model_path --host 0.0.0.0 --port $port -c $ctx -np $np"
    if [[ -n "$ngl" ]]; then
        exec_cmd="$exec_cmd -ngl $ngl"
    fi

    # Check if the patched radv is needed (Coreforge method)
    local env_lines="Environment=HOME=/home/$REAL_USER"
    if grep -qxF "needs-patched-radv" /var/lib/roast-setup-state 2>/dev/null; then
        env_lines="$env_lines
Environment=LD_PRELOAD=/usr/local/lib/memcpy.so
Environment=VK_ICD_FILENAMES=/usr/local/share/vulkan/icd.d/radeon_fixed_icd.json"
    fi

    cat > "$unit_path" <<EOF
[Unit]
Description=R.O.A.S.T. llama-server - ${model_name}
After=network.target
ConditionPathExists=/dev/dri/renderD128
StartLimitIntervalSec=120
StartLimitBurst=5

[Service]
Type=simple
User=$REAL_USER
ExecStartPre=/bin/sleep 10
ExecStart=$exec_cmd
Restart=on-failure
RestartSec=5
$env_lines

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    log "Service created: $unit_path"

    if $enable_after; then
        log "Enabling and starting $svc..."
        systemctl enable --now "$svc"
        log "Service running on port $port"
    else
        info "To start: sudo systemctl enable --now $svc"
    fi
}

cmd_list() {
    echo -e "${BOLD}R.O.A.S.T. Models${NC}"
    echo ""

    local found=false
    printf "%-40s %-8s %-10s %s\n" "MODEL" "PORT" "STATUS" "SERVICE"
    printf "%-40s %-8s %-10s %s\n" "-----" "----" "------" "-------"

    for unit in /etc/systemd/system/${SERVICE_PREFIX}-*.service; do
        [[ -f "$unit" ]] || continue
        found=true

        local svc
        svc=$(basename "$unit" .service)
        local port
        port=$(grep -oP '\-\-port \K\d+' "$unit" 2>/dev/null || echo "?")
        local model_file
        model_file=$(grep -oP '\-m \K\S+' "$unit" 2>/dev/null || echo "?")
        local model_name
        model_name=$(model_name_from_file "$model_file")

        local status
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            status="${GREEN}running${NC}"
        elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            status="${YELLOW}enabled${NC}"
        else
            status="stopped"
        fi

        printf "%-40s %-8s %-10b %s\n" "$model_name" "$port" "$status" "$svc"
    done

    if ! $found; then
        info "No models installed. Use 'add' to download one."
    fi
}

cmd_enable() {
    local model_name="$1"
    local svc
    svc=$(service_name "$model_name")

    if [[ ! -f "/etc/systemd/system/${svc}.service" ]]; then
        err "Service not found: $svc"
        err "Use 'list' to see available models."
        exit 1
    fi

    log "Enabling and starting $svc..."
    systemctl enable --now "$svc"
    log "Done."
}

cmd_disable() {
    local model_name="$1"
    local svc
    svc=$(service_name "$model_name")

    if [[ ! -f "/etc/systemd/system/${svc}.service" ]]; then
        err "Service not found: $svc"
        exit 1
    fi

    log "Stopping and disabling $svc..."
    systemctl disable --now "$svc"
    log "Done."
}

cmd_remove() {
    local model_name="$1"
    local svc
    svc=$(service_name "$model_name")
    local unit_path="/etc/systemd/system/${svc}.service"

    if [[ ! -f "$unit_path" ]]; then
        err "Service not found: $svc"
        exit 1
    fi

    # Get model path before removing
    local model_file
    model_file=$(grep -oP '\-m \K\S+' "$unit_path" 2>/dev/null || echo "")

    # Stop and remove service
    systemctl disable --now "$svc" 2>/dev/null || true
    rm -f "$unit_path"
    systemctl daemon-reload
    log "Service removed: $svc"

    # Optionally remove model file
    if [[ -n "$model_file" && -f "$model_file" ]]; then
        local size
        size=$(du -h "$model_file" | cut -f1)
        read -rp "Also delete model file ($size)? [y/N] " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            rm -f "$model_file"
            log "Deleted: $model_file"
        fi
    fi
}

cmd_status() {
    echo -e "${BOLD}R.O.A.S.T. Status${NC}"
    echo ""

    # llama-server binary
    if [[ -x "$LLAMA_SERVER" ]]; then
        log "llama-server: $LLAMA_SERVER"
    else
        err "llama-server: not found"
    fi

    # Vulkan devices (via llama-cli)
    local llama_cli="$LLAMA_DIR/build/bin/llama-cli"
    if [[ -x "$llama_cli" ]]; then
        local devices
        devices=$("$llama_cli" --list-devices 2>/dev/null || true)
        if [[ -n "$devices" ]]; then
            echo "$devices" | while IFS= read -r line; do
                if [[ "$line" == *"Vulkan"* ]]; then
                    log "Device: $line"
                fi
            done
        else
            warn "No Vulkan devices found"
        fi
    else
        warn "llama-cli not found, cannot list devices"
    fi

    # Models
    local model_count=0
    local running_count=0
    for unit in /etc/systemd/system/${SERVICE_PREFIX}-*.service; do
        [[ -f "$unit" ]] || continue
        ((model_count++))
        local svc
        svc=$(basename "$unit" .service)
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            ((running_count++))
        fi
    done
    info "Models: $model_count installed, $running_count running"

    # Disk usage
    if [[ -d "$MODELS_DIR" ]]; then
        info "Models disk usage: $(du -sh "$MODELS_DIR" 2>/dev/null | cut -f1)"
    fi

    echo ""
    cmd_list
}

cmd_bench() {
    local model_name="$1"
    local llama_bench="$LLAMA_DIR/build/bin/llama-bench"

    if [[ ! -x "$llama_bench" ]]; then
        err "llama-bench not found at $llama_bench"
        exit 1
    fi

    # Find the model file from an existing service or the models directory
    local model_path=""
    local svc
    svc=$(service_name "$model_name")
    local unit_path="/etc/systemd/system/${svc}.service"

    if [[ -f "$unit_path" ]]; then
        model_path=$(grep -oP '\-m \K\S+' "$unit_path" 2>/dev/null || true)
    fi

    # Fall back to looking in models directory
    if [[ -z "$model_path" || ! -f "$model_path" ]]; then
        model_path="$MODELS_DIR/${model_name}.gguf"
    fi

    if [[ ! -f "$model_path" ]]; then
        err "Model file not found for: $model_name"
        err "Use 'list' to see available models."
        exit 1
    fi

    # Stop the model's service if running to free the GPU
    local was_running=false
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        warn "Stopping $svc for benchmark..."
        systemctl stop "$svc"
        was_running=true
    fi

    log "Benchmarking: $model_name"
    info "Model: $model_path"
    echo ""

    cd /
    local bench_env=()
    if grep -qxF "needs-patched-radv" /var/lib/roast-setup-state 2>/dev/null; then
        bench_env=(env LD_PRELOAD=/usr/local/lib/memcpy.so VK_ICD_FILENAMES=/usr/local/share/vulkan/icd.d/radeon_fixed_icd.json)
    fi
    "${bench_env[@]}" "$llama_bench" -m "$model_path" -ngl 99

    # Restart service if it was running
    if $was_running; then
        log "Restarting $svc..."
        systemctl start "$svc"
    fi
}


# --- Main ---
if [[ $# -lt 1 ]]; then
    usage
fi

COMMAND="$1"
shift

case "$COMMAND" in
    add)
        [[ $# -lt 1 ]] && { err "Missing URL."; usage; }
        cmd_add "$@"
        ;;
    list)
        cmd_list
        ;;
    enable)
        [[ $# -lt 1 ]] && { err "Missing model name."; usage; }
        cmd_enable "$1"
        ;;
    disable)
        [[ $# -lt 1 ]] && { err "Missing model name."; usage; }
        cmd_disable "$1"
        ;;
    remove)
        [[ $# -lt 1 ]] && { err "Missing model name."; usage; }
        cmd_remove "$1"
        ;;
    status)
        cmd_status
        ;;
    bench)
        [[ $# -lt 1 ]] && { err "Missing model name."; usage; }
        cmd_bench "$1"
        ;;
    *)
        err "Unknown command: $COMMAND"
        usage
        ;;
esac
