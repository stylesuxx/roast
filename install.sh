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
BOLD='\033[1m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $*"; }
err() { echo -e "${RED}[x]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root (use sudo)."
    exit 1
fi

log "Installing git..."
apt-get update -qq
apt-get install -y -qq git

if [[ -d "$ROAST_DIR/.git" ]]; then
    log "R.O.A.S.T. already cloned, updating..."
    cd "$ROAST_DIR"
    git pull --ff-only
else
    log "Cloning R.O.A.S.T...."
    rm -rf "$ROAST_DIR"
    git clone "$ROAST_REPO" "$ROAST_DIR"
fi

chmod +x "$ROAST_DIR/roast-setup.sh"
chmod +x "$ROAST_DIR/roast.sh"
ln -sf "$ROAST_DIR/roast-setup.sh" /usr/local/bin/roast-setup
ln -sf "$ROAST_DIR/roast.sh" /usr/local/bin/roast

log "R.O.A.S.T. installed. Starting setup..."
echo ""

# Pass through any arguments (e.g. --coreforge)
exec "$ROAST_DIR/roast-setup.sh" "$@"
