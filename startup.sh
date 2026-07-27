#!/usr/bin/env bash
# ============================================================
# File: startup.sh
# Vultr Startup Script entry point (keep under 20 lines)
# ============================================================
set -euo pipefail

REPO_URL="https://github.com/THENRA1N/vultr_env.git"
REPO_DIR="/opt/vps-security-env"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git curl

if [[ -d "${REPO_DIR}/.git" ]]; then
    cd "${REPO_DIR}" && git pull --ff-only
else
    git clone --depth 1 "${REPO_URL}" "${REPO_DIR}"
fi

cd "${REPO_DIR}"
chmod +x bootstrap.sh install_tools.sh
./bootstrap.sh
