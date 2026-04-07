#!/usr/bin/env bash
#
# R.O.A.S.T. Installer
# Radeon On ARM, Serving Tokens
#
# Bootstrap script - installs git, clones the repo, and makes
# roast-setup available globally. Pipe-safe.
#
# Usage:
#   wget -qO- https://raw.githubusercontent.com/stylesuxx/roast/master/install.sh | sudo bash

set -euo pipefail

ROAST_REPO="https://github.com/stylesuxx/roast.git"
ROAST_DIR="/opt/roast"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $*"; }
err() { echo -e "${RED}[x]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
    exit 1
fi

# Retry logic for network-dependent commands (max 3 attempts)
retry_until_success() {
    local max_attempts=3
    local attempt=1
    local backoff=1
    while [[ $attempt -le $max_attempts ]]; do
        if "$@"; then
            return 0
        fi
        log "Attempt $attempt failed, retrying in ${backoff}s..."
        sleep "$backoff"
        ((attempt++))
        backoff=$((backoff * 2))
    done
    return 1
}

# System info logging
log "System: $(uname -o) $(uname -r) $(uname -m)"
log "Raspberry Pi OS version: $(lsb_release -ds 2>/dev/null || echo 'unknown')"

log "Installing git..."
retry_until_success apt-get update -qq || exit 1
retry_until_success apt-get install -y -qq git || exit 1

if [[ -d "$ROAST_DIR/.git" ]]; then
    log "R.O.A.S.T. already cloned, updating..."
    cd "$ROAST_DIR"
    timeout 300 git pull --ff-only || exit 1
else
    log "Cloning R.O.A.S.T...."
    rm -rf "$ROAST_DIR"
    timeout 600 git clone --depth 1 "$ROAST_REPO" "$ROAST_DIR" || exit 1
fi

chmod +x "$ROAST_DIR/roast-setup.sh"
chmod +x "$ROAST_DIR/roast.sh"
ln -sf "$ROAST_DIR/roast-setup.sh" /usr/local/bin/roast-setup
ln -sf "$ROAST_DIR/roast.sh" /usr/local/bin/roast

log "Installation complete. Run 'roast-setup' next."
if ! command -v roast-setup >/dev/null 2>&1; then
    err "roast-setup not found. Installation may be incomplete."
    exit 1
fi

exec "$ROAST_DIR/roast-setup.sh" "$@"
