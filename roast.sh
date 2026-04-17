#!/usr/bin/env bash
#
# R.O.A.S.T. Model Manager
# Radeon On ARM, Serving Tokens
#
# Download GGUF models from HuggingFace, verify them, and manage
# systemd services for llama-server instances.
#
# Usage:
 #   sudo roast add <repo-id> <filename> [--port PORT] [--gpu-layers NGL] [--context-size CTX] [--parallel NP] [--enable]
 #   sudo roast list
 #   sudo roast enable <model-name>
 #   sudo roast disable <model-name>
 #   sudo roast remove <model-name>
 #   sudo roast config <model-name> [--port PORT] [--gpu-layers NGL] [--context-size CTX]#   sudo roast status
 #   sudo roast bench <model-name>
 #
 # Examples:
 #   sudo roast add TheBloke/Mistral-7B-v0.1-GGUF mistral-7b-v0.1.Q4_K_M.gguf --port 8080 --gpu-layers 99 --context-size 32768 --enable
#   sudo roast list
#   sudo roast disable mistral-7b-v0.1.Q4_K_M-8080

set -euo pipefail

# --- Configuration ---
ROAST_REPO="https://github.com/stylesuxx/roast.git"
ROAST_DIR="/opt/roast"
LLAMA_DIR="/opt/llama.cpp"
LLAMA_SERVER="$LLAMA_DIR/build/bin/llama-server"
MODELS_DIR="/opt/llama.cpp/models"
SERVICE_PREFIX="roast"
DEFAULT_PORT=8080
DEFAULT_NGL=99
DEFAULT_CTX=16384
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
    echo "  $(basename "$0") config <model-name> [--port PORT] [--gpu-layers NGL] [--context-size CTX] [--parallel NP]"
    echo "  $(basename "$0") status"
    echo "  $(basename "$0") bench <model-name>"
    echo ""
    echo "Options for 'add' and 'config':"
    echo "  --port PORT          Port for llama-server (default: $DEFAULT_PORT)"
    echo "  --gpu-layers NGL     Number of GPU layers (default: $DEFAULT_NGL, use 0 for CPU only)"
    echo "  --context-size CTX   Context size (default: $DEFAULT_CTX)"
    echo "  --parallel NP        Number of parallel request slots (default: $DEFAULT_NP)"
    echo "                       Each slot gets its own KV cache (context / NP per user)"
    echo "                       Higher NP = more concurrent users but less context each"
    echo "  --enable             Enable and start the service immediately (add only)"
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

# Get the service unit name for a model (includes port for uniqueness)
service_name() {
    local model="$1"
    local port="${2:-}"
    if [[ -n "$port" ]]; then
        echo "${SERVICE_PREFIX}-$(echo "$model" | tr '.' '-' | tr '[:upper:]' '[:lower:]')-${port}"
    else
        echo "${SERVICE_PREFIX}-$(echo "$model" | tr '.' '-' | tr '[:upper:]' '[:lower:]')"
    fi
}

# Find service file for a model name, port suffix, or full service name
find_service() {
    local name="$1"

    # If already a full service name (starts with roast-), try it directly
    if [[ "$name" == "${SERVICE_PREFIX}-"* ]]; then
        local direct="$(echo "$name" | tr '.' '-' | tr '[:upper:]' '[:lower:]')"
        if [[ -f "/etc/systemd/system/${direct}.service" ]]; then
            echo "$direct"
            return 0
        fi
    fi

    # Try exact match (name includes port)
    local svc="${SERVICE_PREFIX}-$(echo "$name" | tr '.' '-' | tr '[:upper:]' '[:lower:]')"
    if [[ -f "/etc/systemd/system/${svc}.service" ]]; then
        echo "$svc"
        return 0
    fi
    # Try matching by model name prefix (without port)
    local matches=()
    for unit in /etc/systemd/system/${SERVICE_PREFIX}-*.service; do
        [[ -f "$unit" ]] || continue
        local unit_name
        unit_name=$(basename "$unit" .service)
        if [[ "$unit_name" == "${svc}-"* ]]; then
            matches+=("$unit_name")
        fi
    done
    if [[ ${#matches[@]} -eq 1 ]]; then
        echo "${matches[0]}"
        return 0
    elif [[ ${#matches[@]} -gt 1 ]]; then
        err "Multiple services found for '$name':"
        for m in "${matches[@]}"; do
            err "  $m"
        done
        err "Specify the port too, e.g.: $name-8080"
        return 1
    fi
    return 1
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
    local port="$DEFAULT_PORT"
    local ngl="$DEFAULT_NGL"
    local ctx="$DEFAULT_CTX"
    local np="$DEFAULT_NP"
    local enable_after=false

    # Get repo_id and filename as first two arguments
    local repo_id="$1"
    local filename="$2"
    shift 2

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)  port="$2"; shift 2 ;;
            --gpu-layers)   ngl="$2"; shift 2 ;;
            --context-size)   ctx="$2"; shift 2 ;;
            --parallel)   np="$2"; shift 2 ;;
            --enable) enable_after=true; shift ;;
            -*)      err "Unknown option: $1"; usage ;;
            *)       err "Unexpected argument: $1"; usage ;;
        esac
    done

    if [[ -z "$repo_id" || -z "$filename" ]]; then
        err "No repo_id or filename provided."
        usage
    fi

    # Validate filename looks like a GGUF file
    if [[ "$filename" != *.gguf* ]]; then
        warn "Filename does not end in .gguf - are you sure this is a GGUF model?"
        read -rp "Continue? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || exit 1
    fi
    local model_name
    model_name=$(model_name_from_file "$filename")
    local model_path="$MODELS_DIR/$filename"
    local svc
    svc=$(service_name "$model_name" "$port")

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

        # Download using hf CLI
        log "Downloading from HuggingFace..."
        PATH="$HOME/.local/bin:/root/.local/bin:$PATH" hf download "$repo_id" "$filename" --local-dir "$MODELS_DIR"

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

    # Check if patched radv is needed (Coreforge method)
    local needs_patched_radv="false"
    if grep -qxF "needs-patched-radv" /var/lib/roast-setup-state 2>/dev/null; then
        needs_patched_radv="true"
    fi

    # Source template and generate service file
    source /opt/roast/templates/roast-service.sh
    generate_service "$svc" "$model_name" "$model_path" "$port" "$ctx" "$ngl" "$np" "$needs_patched_radv"

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
    printf "%-40s %-6s %-6s %-5s %-4s %-10s %s\n" "MODEL" "PORT" "CTX" "NGL" "NP" "STATUS" "SERVICE"
    printf "%-40s %-6s %-6s %-5s %-4s %-10s %s\n" "-----" "----" "---" "---" "--" "------" "-------"

    for unit in /etc/systemd/system/${SERVICE_PREFIX}-*.service; do
        [[ -f "$unit" ]] || continue
        found=true

        local svc
        svc=$(basename "$unit" .service)
        local port
        port=$(grep -oP '\-\-port \K\d+' "$unit" 2>/dev/null || echo "?")
        local ctx
        ctx=$(grep -oP '\-c \K\d+' "$unit" 2>/dev/null || echo "?")
        if [[ "$ctx" =~ ^[0-9]+$ ]]; then
            ctx="$((ctx / 1024))K"
        fi
        local ngl
        ngl=$(grep -oP '\-ngl \K\d+' "$unit" 2>/dev/null || echo "-")
        local np
        np=$(grep -oP '\-np \K\d+' "$unit" 2>/dev/null || echo "-")
        local model_file
        model_file=$(grep -oP '\-m \K\S+' "$unit" 2>/dev/null || echo "?")
        local model_name
        model_name=$(model_name_from_file "$model_file")

        local status status_display
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            status="running"
            status_display="${GREEN}running${NC}"
        elif systemctl is-enabled --quiet "$svc" 2>/dev/null; then
            status="enabled"
            status_display="${YELLOW}enabled${NC}"
        else
            status="stopped"
            status_display="stopped"
        fi

        printf "%-40s %-6s %-6s %-5s %-4s " "$model_name" "$port" "$ctx" "$ngl" "$np"
        echo -en "$status_display"
        printf "%*s %s\n" $((10 - ${#status})) "" "$svc"
    done

    if ! $found; then
        info "No models installed. Use 'add' to download one."
    fi
}

cmd_enable() {
    local model_name="$1"
    local svc
    svc=$(find_service "$model_name") || exit 1

    log "Enabling and starting $svc..."
    systemctl enable --now "$svc"
    log "Done."
}

cmd_disable() {
    local model_name="$1"
    local svc
    svc=$(find_service "$model_name") || exit 1

    log "Stopping and disabling $svc..."
    systemctl disable --now "$svc"
    log "Done."
}

cmd_remove() {
    local model_name="$1"
    local svc
    svc=$(find_service "$model_name") || exit 1
    local unit_path="/etc/systemd/system/${svc}.service"

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

cmd_config() {
    local model_name="$1"
    shift
    local svc
    svc=$(find_service "$model_name") || exit 1
    local unit_path="/etc/systemd/system/${svc}.service"

    # Read current values from service file
    local cur_port cur_ngl cur_ctx cur_np cur_model
    cur_port=$(grep -oP '\-\-port \K\d+' "$unit_path" 2>/dev/null || echo "$DEFAULT_PORT")
    cur_ngl=$(grep -oP '\-ngl \K\d+' "$unit_path" 2>/dev/null || echo "")
    cur_ctx=$(grep -oP '\-c \K\d+' "$unit_path" 2>/dev/null || echo "$DEFAULT_CTX")
    cur_np=$(grep -oP '\-np \K\d+' "$unit_path" 2>/dev/null || echo "$DEFAULT_NP")
    cur_model=$(grep -oP '\-m \K\S+' "$unit_path" 2>/dev/null || echo "")

    # Parse new values, defaulting to current
    local port="$cur_port"
    local ngl="$cur_ngl"
    local ctx="$cur_ctx"
    local np="$cur_np"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port)  port="$2"; shift 2 ;;
            --gpu-layers)   ngl="$2"; shift 2 ;;
            --context-size)   ctx="$2"; shift 2 ;;
            --parallel)   np="$2"; shift 2 ;;
            -*)      err "Unknown option: $1"; usage ;;
            *)       err "Unexpected argument: $1"; usage ;;
        esac
    done

    # Check port conflicts (exclude current model)
    local svc_model
    svc_model=$(echo "$model_name" | tr '.' '-' | tr '[:upper:]' '[:lower:]')
    if [[ "$port" != "$cur_port" ]]; then
        local conflict
        if conflict=$(check_port_conflict "$port" "$svc_model"); then
            err "Port $port is already used by: $(basename "$conflict")"
            exit 1
        fi
    fi

    # Check if patched radv is needed
    local needs_patched_radv="false"
    if grep -qxF "needs-patched-radv" /var/lib/roast-setup-state 2>/dev/null; then
        needs_patched_radv="true"
    fi

    # Source template and generate service file
    source /opt/roast/templates/roast-service.sh
    generate_service "$svc" "$model_name" "$cur_model" "$port" "$ctx" "$ngl" "$np" "$needs_patched_radv"

    systemctl daemon-reload
    log "Updated $svc: port=$port, context=$ctx, ngl=${ngl:-auto}${np:+, parallel=$np}"

    # Restart if running
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        log "Restarting $svc..."
        systemctl restart "$svc"
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
    svc=$(find_service "$model_name" 2>/dev/null || true)
    local unit_path="/etc/systemd/system/${svc}.service"

    if [[ -n "$svc" && -f "$unit_path" ]]; then
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

    # Read context size and ngl from service config
    local bench_ngl=99
    local bench_ctx=16384
    if [[ -f "$unit_path" ]]; then
        local svc_ngl
        svc_ngl=$(grep -oP '\-ngl \K\d+' "$unit_path" 2>/dev/null || true)
        [[ -n "$svc_ngl" ]] && bench_ngl="$svc_ngl"
        local svc_ctx
        svc_ctx=$(grep -oP '\-c \K\d+' "$unit_path" 2>/dev/null || true)
        if [[ -n "$svc_ctx" && "$svc_ctx" =~ ^[0-9]+$ ]]; then
            bench_ctx="$svc_ctx"
        fi
    fi

    log "Benchmarking: $model_name"
    info "Model: $model_path"
    info "Context: $bench_ctx, GPU layers: $bench_ngl"
    echo ""

    # Wake GPU from runtime suspend before benchmarking
    cat /sys/class/drm/card*/device/power_state &>/dev/null || true

    cd /
    local bench_env=()
    if grep -qxF "needs-patched-radv" /var/lib/roast-setup-state 2>/dev/null; then
        bench_env=(env LD_PRELOAD=/usr/local/lib/memcpy.so VK_ICD_FILENAMES=/usr/local/share/vulkan/icd.d/radeon_fixed_icd.json)
    fi
    "${bench_env[@]}" "$llama_bench" -m "$model_path" -ngl "$bench_ngl"

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
    config)
        [[ $# -lt 1 ]] && { err "Missing model name."; usage; }
        _model="$1"; shift
        cmd_config "$_model" "$@"
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
