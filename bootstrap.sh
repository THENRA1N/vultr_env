#!/usr/bin/env bash
# ============================================================
# File: bootstrap.sh
# System initialization, base packages, directories, PATH
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

# Ensure log directory exists early
mkdir -p "${LOG_DIR}"
touch "${INSTALL_LOG}"

log "===== bootstrap started ====="

# ---------- root check ----------
if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root"
fi

# ---------- system update ----------
export DEBIAN_FRONTEND=noninteractive
log "apt-get update..."
apt-get update -y >> "${INSTALL_LOG}" 2>&1

if [[ "${SYSTEM_UPGRADE}" == "true" ]]; then
    log "SYSTEM_UPGRADE=true，执行全量升级（这一步通常是最耗时的部分）..."
    apt-get upgrade -y >> "${INSTALL_LOG}" 2>&1
else
    log "跳过 apt-get upgrade（SYSTEM_UPGRADE=false）。需要时在 config.sh 里改成 true，或手动执行一次。"
fi

# ---------- base packages ----------
log "Installing base packages..."
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends ${BASE_PACKAGES} >> "${INSTALL_LOG}" 2>&1
apt-get autoremove -y >> "${INSTALL_LOG}" 2>&1
apt-get clean >> "${INSTALL_LOG}" 2>&1
rm -rf /var/lib/apt/lists/*

# ---------- Go 版本提示（避免隐藏的 toolchain 下载被误认为"编译慢"）----------
if command -v go &>/dev/null; then
    GO_VER="$(go version 2>/dev/null | awk '{print $3}')"
    log "系统 go 版本: ${GO_VER}（如果后面 go install 某个工具卡很久，先看日志里是不是在下载新 toolchain，而不是在编译）"
fi

# ---------- directory structure ----------
log "Creating ${TOOLS_DIR} structure..."
mkdir -p "${BIN_DIR}" \
         "${WORDLIST_DIR}/dir" \
         "${WORDLIST_DIR}/subdomain" \
         "${WORDLIST_DIR}/nuclei-templates" \
         "${SCRIPTS_DIR}" \
         "${LOG_DIR}"
chmod -R 755 "${TOOLS_DIR}"

# ---------- PATH configuration ----------
log "Configuring PATH..."
cat > /etc/profile.d/tools.sh <<EOF
# vps-security-env paths
export PATH="${BIN_DIR}:\${PATH}"
export PATH="${GO_BIN}:\${PATH}"
export GOPATH="\${HOME}/go"
export GOBIN="\${GOPATH}/bin"
EOF

# Apply to current session
export PATH="${BIN_DIR}:${GO_BIN}:${PATH}"
export GOPATH="${HOME}/go"
export GOBIN="${GOPATH}/bin"
mkdir -p "${GOBIN}"

# Also add to root bashrc for interactive shells
if ! grep -q "${BIN_DIR}" /root/.bashrc 2>/dev/null; then
    {
        echo "export PATH=\"${BIN_DIR}:\$PATH\""
        echo "export PATH=\"${GO_BIN}:\$PATH\""
        echo "export GOPATH=\"\$HOME/go\""
    } >> /root/.bashrc
fi

# ============================================================
# 下面这些系统级调优（swap/文件描述符/sysctl/时区/建用户/SSH加固）
# 只需要做一次。用标记文件跳过重复执行，避免每次重跑 bootstrap.sh
# （比如调试 install_tools.sh 时反复整体重跑）都白白花时间在这上面。
# ============================================================
if [[ -f "${BOOTSTRAP_MARKER}" ]]; then
    log "检测到 ${BOOTSTRAP_MARKER}，系统级调优已做过，跳过（如需强制重跑，删除该文件）"
else
    log "Applying system tuning..."

    # ---------- create swap if memory is low ----------
    # Useful for 1GB VPS when compiling Go tools
    if [[ ! -f /swapfile ]] && ! swapon --show | grep -q .; then
        TOTAL_MEM_MB=$(free -m | awk '/^Mem:/{print $2}')
        if [[ "${TOTAL_MEM_MB}" -le 1200 ]]; then
            log "Low memory detected (${TOTAL_MEM_MB}MB), creating 1G swap..."
            fallocate -l 1G /swapfile
            chmod 600 /swapfile
            mkswap /swapfile
            swapon /swapfile
            # Make it permanent
            if ! grep -q '/swapfile' /etc/fstab; then
                echo '/swapfile none swap sw 0 0' >> /etc/fstab
            fi
            log "Swap created and enabled"
        else
            log "Memory > 1.2GB, skip swap creation"
        fi
    else
        log "Swap already present (file or active), skipping"
    fi

    # File descriptors
    cat > /etc/security/limits.d/99-security.conf <<EOF
* soft nofile 65535
* hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

    # Network / TCP parameters (lightweight)
    cat > /etc/sysctl.d/99-security.conf <<EOF
fs.file-max = 2097152
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_keepalive_time = 300
EOF
    sysctl --system >> "${INSTALL_LOG}" 2>&1 || true

    # Timezone
    timedatectl set-timezone "${TIMEZONE}" 2>/dev/null \
        || ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    log "Timezone set to ${TIMEZONE}"

    # ---------- optional non-root user ----------
    if [[ "${CREATE_USER}" == "true" ]]; then
        if ! id "${USER_NAME}" &>/dev/null; then
            useradd -m -s /bin/bash "${USER_NAME}"
            log "Created user: ${USER_NAME}"
        else
            log "User ${USER_NAME} already exists"
        fi
    fi

    # ---------- light SSH hardening ----------
    if [[ -f /etc/ssh/sshd_config ]]; then
        sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 3600/' /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        log "Basic SSH hardening applied"
    fi

    touch "${BOOTSTRAP_MARKER}"
fi

log "===== bootstrap finished ====="

# Call tool installer
if [[ -x "${SCRIPT_DIR}/install_tools.sh" ]]; then
    log "Starting tool installation..."
    "${SCRIPT_DIR}/install_tools.sh"
else
    warn "install_tools.sh not found or not executable"
fi
