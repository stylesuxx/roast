#!/usr/bin/env bash
#
# R.O.A.S.T. llama-server systemd service template
#
# Usage: source this file in roast.sh before creating services
#
# Usage:
#   source /opt/roast/templates/roast-service.sh
#
set -euo pipefail

# Model configuration (set from roast.sh)
# MODEL_NAME="..."
# MODEL_PATH="..."
# PORT="${PORT:-8080}"
# CONTEXT_SIZE="${CTX:-16384}"
# GPU_LAYERS="${NGL:-99}"
# PARALLEL="${NP:-1}"
# REAL_USER="${REAL_USER:-}"

# Build ExecStart command
exec_cmd() {
    local model_path="$1"
    local port="$2"
    local ctx="$3"
    local jinja
    jinja="--jinja"
    exec_cmd="$LLAMA_SERVER -m $model_path --host 0.0.0.0 --port $port -c $ctx $jinja"
    if [[ -n "$GPU_LAYERS" ]]; then
        exec_cmd="$exec_cmd -ngl $GPU_LAYERS"
    fi
    if [[ -n "$PARALLEL" ]]; then
        exec_cmd="$exec_cmd -np $PARALLEL"
    fi
    echo "$exec_cmd"
}

# Build environment lines (including RADV patch if needed)
env_lines() {
    local needs_patched_radv="$1"
    echo "Environment=HOME=/home/$REAL_USER"
    if [[ "$needs_patched_radv" == "true" ]]; then
        echo "Environment=LD_PRELOAD=/usr/local/lib/memcpy.so"
        echo "Environment=VK_ICD_FILENAMES=/usr/local/share/vulkan/icd.d/radeon_fixed_icd.json"
    fi
}

# Generate systemd service file
generate_service() {
    local svc="$1"
    local model_name="$2"
    local model_path="$3"
    local port="$4"
    local ctx="$5"
    local ngl="$6"
    local np="$7"
    local needs_patched_radv="$8"

    # Set globals used by exec_cmd()
    GPU_LAYERS="${ngl:-}"
    PARALLEL="${np:-}"

    # Build ExecStart command
    local exec_cmd
    exec_cmd=$(exec_cmd "$model_path" "$port" "$ctx")

    # Build environment lines
    local env_lines
    env_lines=$(env_lines "$needs_patched_radv")

    cat > "/etc/systemd/system/${svc}.service" <<EOF
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
}
