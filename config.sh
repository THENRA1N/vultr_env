# ============================================================
# File: config.sh
# Shared configuration for vps-security-env
# ============================================================

# Base directories
TOOLS_DIR="/home/tools"
BIN_DIR="${TOOLS_DIR}/bin"
WORDLIST_DIR="${TOOLS_DIR}/wordlist"
SCRIPTS_DIR="${TOOLS_DIR}/scripts"
LOG_DIR="${TOOLS_DIR}/logs"
INSTALL_LOG="${LOG_DIR}/install.log"

# Go environment
export GOPATH="${HOME}/go"
export GOBIN="${GOPATH}/bin"
GO_BIN="${GOBIN}"

# Non-root user (created if not exists)
CREATE_USER="true"
USER_NAME="recon"

# Timezone
TIMEZONE="Asia/Shanghai"

# Tool enable/disable flags (set to "false" to skip)
INSTALL_PROJECTDISCOVERY="true"
INSTALL_FFUF="true"
INSTALL_GAU="true"
INSTALL_WAYBACKURLS="true"
INSTALL_ONEFORALL="true"
INSTALL_DIRSEARCH="true"
INSTALL_GODNS="false"          # Multiple repos exist; default skip

# Base packages (apt)
BASE_PACKAGES="git curl wget unzip vim tmux jq python3 python3-pip python3-venv golang-go gcc make dnsutils net-tools ca-certificates"

# Logging helpers (used by other scripts)
log()  { echo "[+] $1" | tee -a "${INSTALL_LOG}"; }
warn() { echo "[!] $1" | tee -a "${INSTALL_LOG}"; }
err()  { echo "[-] $1" | tee -a "${INSTALL_LOG}"; exit 1; }