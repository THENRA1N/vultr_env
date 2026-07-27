#!/usr/bin/env bash
# ============================================================
# File: startup.sh
# Vultr Startup Script entry point
# ============================================================
set -euo pipefail

# 把所有输出同时写到本地日志文件 + 标准输出（后者会进 Vultr/cloud-init 的
# console log，出问题时用 vultr-cli / 控制台 console log 或
# /var/log/vps-startup.log 就能看到具体卡在哪一步，不用再靠猜）
LOG_FILE="/var/log/vps-startup.log"
exec > >(tee -a "${LOG_FILE}") 2>&1
echo "[startup] ===== $(date -u '+%Y-%m-%d %H:%M:%S UTC') started ====="

REPO_URL="https://github.com/THENRA1N/vultr_env.git"
REPO_DIR="/opt/vps-security-env"
export DEBIAN_FRONTEND=noninteractive

# ---------- wait for network ----------
echo "[startup] waiting for network..."
for i in $(seq 1 30); do
    if getent hosts github.com &>/dev/null; then
        echo "[startup] network ready"
        break
    fi
    sleep 2
done

# ---------- wait for apt/dpkg lock ----------
# 新开的机器上 unattended-upgrades / cloud-init 自身的 apt 任务可能正占着锁，
# 不等的话 apt-get 会直接失败，set -e 下整个脚本会静默终止
echo "[startup] waiting for apt/dpkg lock..."
for i in $(seq 1 60); do
    if ! fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       && ! fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
       && ! fuser /var/lib/apt/lists/lock >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

echo "[startup] apt-get update/install..."
apt-get update -qq
apt-get install -y -qq git curl

echo "[startup] syncing repo ${REPO_URL} -> ${REPO_DIR}"
if [[ -d "${REPO_DIR}/.git" ]]; then
    git -C "${REPO_DIR}" pull --ff-only
else
    git clone --depth 1 "${REPO_URL}" "${REPO_DIR}"
fi

cd "${REPO_DIR}"
chmod +x bootstrap.sh install_tools.sh

echo "[startup] handing off to bootstrap.sh"
./bootstrap.sh

echo "[startup] ===== $(date -u '+%Y-%m-%d %H:%M:%S UTC') finished ====="
