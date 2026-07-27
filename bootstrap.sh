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
log "Updating system packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >> "${INSTALL_LOG}" 2>&1
apt-get upgrade -y >> "${INSTALL_LOG}" 2>&1

# ---------- base packages ----------
log "Installing base packages..."
# shellcheck disable=SC2086
apt-get install -y --no-install-recommends ${BASE_PACKAGES} >> "${INSTALL_LOG}" 2>&1
apt-get autoremove -y >> "${INSTALL_LOG}" 2>&1
apt-get clean >> "${INSTALL_LOG}" 2>&1
rm -rf /var/lib/apt/lists/*

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

# ---------- system tuning ----------
log "Applying system tuning..."

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
    cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%s)"
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
    sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 3/' /etc/ssh/sshd_config
    sed -i 's/^#*ClientAliveInterval.*/ClientAliveInterval 300/' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    log "Basic SSH hardening applied"
fi

log "===== bootstrap finished ====="

# Call tool installer
if [[ -x "${SCRIPT_DIR}/install_tools.sh" ]]; then
    log "Starting tool installation..."
    "${SCRIPT_DIR}/install_tools.sh"
else
    warn "install_tools.sh not found or not executable"
fi