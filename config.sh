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
# HOME 在 cloud-init / 部分非交互环境下可能未设置，做个 fallback
export HOME="${HOME:-/root}"
export GOPATH="${HOME}/go"
export GOBIN="${GOPATH}/bin"
GO_BIN="${GOBIN}"
# 避免 go 在编译时因 go.mod 要求更高版本而静默下载新 toolchain
# （如果确实需要更新版本的 go，请手动升级 golang-go / 官方 tarball，
#  而不是让每次 go install 都可能触发一次隐藏的 SDK 下载）
export GOTOOLCHAIN="${GOTOOLCHAIN:-auto}"

# Non-root user (created if not exists)
CREATE_USER="false"
USER_NAME="recon"

# Timezone
TIMEZONE="Asia/Shanghai"

# ---------- system bootstrap behavior ----------
# 全量 apt upgrade 很慢且和装工具无关，默认关闭；
# 需要时手动设为 "true" 或单独执行一次 apt-get upgrade
SYSTEM_UPGRADE="${SYSTEM_UPGRADE:-false}"
# bootstrap 的系统级设置（swap/limits/sysctl/timezone/ssh 加固）只需做一次，
# 完成后写标记文件，重复执行 bootstrap.sh 时跳过，避免反复调试时空耗时间
BOOTSTRAP_MARKER="${TOOLS_DIR}/.bootstrap_done"

# Tool enable/disable flags (set to "false" to skip)
INSTALL_PROJECTDISCOVERY="true"
INSTALL_FFUF="true"
INSTALL_GAU="true"
INSTALL_WAYBACKURLS="true"
INSTALL_ONEFORALL="true"
INSTALL_DIRSEARCH="true"
INSTALL_GODNS="false"          # Multiple repos exist; default skip
INSTALL_GOST="true"          # Lightweight HTTP/SOCKS5 proxy

# Base packages (apt)
BASE_PACKAGES="git curl wget unzip file vim tmux jq python3 python3-pip python3-venv golang-go gcc make dnsutils net-tools ca-certificates"

# Logging helpers (used by other scripts)
log()  { echo "[+] $1" | tee -a "${INSTALL_LOG}"; }
warn() { echo "[!] $1" | tee -a "${INSTALL_LOG}"; }
# err(): 用于真正致命、必须终止全流程的错误（比如基础依赖装不上）
err()  { echo "[-] $1" | tee -a "${INSTALL_LOG}"; exit 1; }
# soft_err(): 单个工具装失败不该拖垮整条流水线，记录后继续往下走
soft_err() { echo "[-] $1 (non-fatal, continuing)" | tee -a "${INSTALL_LOG}"; }
