#!/usr/bin/env bash
# ============================================================
# File: install_tools.sh
# Install security research tools into /home/tools
#
# 优化说明（相对原版）：
#   1. ProjectDiscovery 系列改用官方 pdtm 拉取预编译二进制，
#      不再对 subfinder/httpx/nuclei/dnsx/naabu/katana 逐个 go install 编译。
#      这是最大的耗时来源：nuclei 等依赖链很重，在低内存 VPS 上编译时
#      内存不够触发 swap，比"编译慢"本身还致命。
#   2. gobuster/ffuf/gau/waybackurls 优先从 GitHub Releases 下载预编译
#      二进制，下载失败才回退到 go install 源码编译。
#   3. 低内存机器（<1.5G 可用）自动创建/复用 swap 文件，避免编译期 OOM/抖动。
#   4. 显式设置 GOPROXY，避免因访问 proxy.golang.org 慢而卡住（可按需改成
#      你所在网络更快的镜像）。
#   5. 需要真正编译时，限制 GOFLAGS="-p=1" 并行度，防止小内存机器上
#      多个编译进程互相抢内存导致更慢。
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

# Use disk-backed temp dir (tmpfs /tmp is too small on 1GB VPS)
mkdir -p "${TOOLS_DIR}/tmp"
export TMPDIR="${TOOLS_DIR}/tmp"
export GOTMPDIR="${TOOLS_DIR}/tmp"

mkdir -p "${LOG_DIR}" "${BIN_DIR}" "${GOBIN}"
touch "${INSTALL_LOG}"

export PATH="${BIN_DIR}:${GO_BIN}:${PATH}"
export GOPATH="${HOME}/go"
export GOBIN="${GOPATH}/bin"

# ---------- network/build tuning ----------
# 如果你的服务器在国内，把下面这行换成更快的镜像，例如：
#   export GOPROXY="https://goproxy.cn,direct"
export GOPROXY="${GOPROXY:-https://proxy.golang.org,direct}"
export GOSUMDB="${GOSUMDB:-sum.golang.org}"
export GOFLAGS="${GOFLAGS:--p=1}"   # 限制编译并行度，避免小内存机器抖动
export CGO_ENABLED=0

log "===== tool installation started ====="
# 注：swap 由 bootstrap.sh 统一创建和管理（/swapfile），这里不再重复处理，
# 避免出现两个不同路径的 swapfile。如果单独运行本脚本（没走 bootstrap.sh），
# 请自行确保已有 swap，否则低内存机器上回退编译时可能 OOM。

# ---------- helper: check + link ----------
is_installed() {
    command -v "$1" &>/dev/null
}

link_bin() {
    local src="$1"
    local name="${2:-$(basename "$src")}"
    if [[ -f "$src" ]]; then
        ln -sf "$src" "${BIN_DIR}/${name}"
        chmod +x "${BIN_DIR}/${name}"
    fi
}

detect_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l) echo "arm" ;;
        *) echo "unknown" ;;
    esac
}
ARCH="$(detect_arch)"
OS="linux"

# ---------- helper: try prebuilt GitHub release binary, fallback to go install ----------
# repo: "owner/name"   asset_name_hint: 用于匹配 release asset 文件名的关键字（不含平台后缀）
install_from_github_release() {
    local name="$1" repo="$2" asset_hint="$3"
    local api_url dl_url tmp_dir asset

    if is_installed "${name}"; then
        log "${name} already installed, skipping"
        return 0
    fi

    if [[ "${ARCH}" == "unknown" ]]; then
        return 1
    fi

    log "尝试下载 ${name} 预编译二进制（${repo}）..."
    api_url="https://api.github.com/repos/${repo}/releases/latest"
    tmp_dir="$(mktemp -d)"

    asset=$(curl -fsSL "${api_url}" 2>>"${INSTALL_LOG}" \
        | grep -oE '"browser_download_url": *"[^"]+"' \
        | cut -d'"' -f4 \
        | grep -iE "${asset_hint}.*(${OS}|linux)" \
        | grep -iE "${ARCH}" \
        | grep -viE '\.sha256$|\.sig$|\.asc$' \
        | head -n1 || true)

    if [[ -z "${asset}" ]]; then
        log "${name}: 未找到匹配的预编译二进制，回退到 go install 编译"
        rm -rf "${tmp_dir}"
        return 1
    fi

    dl_url="${asset}"
    log "下载 ${name}: ${dl_url}"
    if ! curl -fsSL "${dl_url}" -o "${tmp_dir}/asset" >> "${INSTALL_LOG}" 2>&1; then
        warn "${name} 下载失败，回退到 go install 编译"
        rm -rf "${tmp_dir}"
        return 1
    fi

    # 解压（支持 tar.gz / zip / 直接可执行文件）
    if file "${tmp_dir}/asset" | grep -qi gzip; then
        tar -xzf "${tmp_dir}/asset" -C "${tmp_dir}" 2>>"${INSTALL_LOG}" || true
    elif file "${tmp_dir}/asset" | grep -qi zip; then
        (cd "${tmp_dir}" && unzip -q asset) 2>>"${INSTALL_LOG}" || true
    fi

    local bin_path
    bin_path=$(find "${tmp_dir}" -maxdepth 2 -type f -iname "${name}" | head -n1)
    if [[ -z "${bin_path}" ]]; then
        # 有些 release 直接就是裸二进制文件
        bin_path="${tmp_dir}/asset"
    fi

    if [[ -f "${bin_path}" ]] && file "${bin_path}" | grep -qi executable; then
        install -m 0755 "${bin_path}" "${BIN_DIR}/${name}"
        log "${name} 安装成功（预编译二进制）"
        rm -rf "${tmp_dir}"
        return 0
    fi

    warn "${name}: 解压后未找到可执行文件，回退到 go install 编译"
    rm -rf "${tmp_dir}"
    return 1
}

install_go_tool() {
    local name="$1"
    local package="$2"

    if is_installed "${name}"; then
        log "${name} already installed, skipping"
        return 0
    fi

    log "Installing ${name} via go install (source build) ..."
    if go install -v "${package}" >> "${INSTALL_LOG}" 2>&1; then
        link_bin "${GOBIN}/${name}" "${name}"
        log "${name} installed successfully"
    else
        soft_err "Failed to install ${name}. Check ${INSTALL_LOG}"
    fi
}

# 优先预编译，失败再编译；两者合一的封装
install_tool_fast() {
    local name="$1" repo="$2" asset_hint="$3" go_package="$4"
    if install_from_github_release "${name}" "${repo}" "${asset_hint}"; then
        return 0
    fi
    install_go_tool "${name}" "${go_package}"
}

# ---------- ProjectDiscovery tools (用 pdtm 拉预编译二进制) ----------
if [[ "${INSTALL_PROJECTDISCOVERY}" == "true" ]]; then
    log "Installing ProjectDiscovery suite via pdtm (prebuilt binaries)..."

    if ! is_installed pdtm; then
        log "Installing pdtm (tool manager)..."
        go install -v github.com/projectdiscovery/pdtm/cmd/pdtm@latest >> "${INSTALL_LOG}" 2>&1 \
            || warn "pdtm 安装失败，将回退为逐个 go install 编译"
        link_bin "${GOBIN}/pdtm" "pdtm"
    fi

    PD_TOOLS="subfinder,httpx,nuclei,dnsx,naabu,katana"
    if is_installed pdtm; then
        log "Using pdtm to fetch prebuilt binaries: ${PD_TOOLS}"
        pdtm -i "${PD_TOOLS}" >> "${INSTALL_LOG}" 2>&1 \
            || warn "pdtm 批量安装部分失败，请检查 ${INSTALL_LOG}"
        export PATH="$HOME/.pdtm/go/bin:$PATH"
        for t in subfinder httpx nuclei dnsx naabu katana; do
            is_installed "$t" && log "${t} installed successfully" || warn "${t} 未安装成功，回退编译"
            is_installed "$t" || install_go_tool "$t" "github.com/projectdiscovery/${t}/v2/cmd/${t}@latest"
        done
    else
        # pdtm 不可用时，逐个回退编译（保留原逻辑）
        install_go_tool "subfinder" "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
        install_go_tool "httpx" "github.com/projectdiscovery/httpx/cmd/httpx@latest"
        install_go_tool "nuclei" "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
        install_go_tool "dnsx" "github.com/projectdiscovery/dnsx/cmd/dnsx@latest"
        install_go_tool "naabu" "github.com/projectdiscovery/naabu/v2/cmd/naabu@latest"
        install_go_tool "katana" "github.com/projectdiscovery/katana/cmd/katana@latest"
    fi

    # Update nuclei templates in background so it doesn't block the rest of the script
    if is_installed nuclei; then
        log "Updating nuclei templates in background..."
        ( nuclei -update-templates -silent >> "${INSTALL_LOG}" 2>&1 || true
          if [[ -d "${HOME}/nuclei-templates" ]]; then
              ln -sfn "${HOME}/nuclei-templates" "${WORDLIST_DIR}/nuclei-templates"
          fi
        ) &
        NUCLEI_TPL_PID=$!
    fi
fi

# ---------- gobuster ----------
if [[ "${INSTALL_GOBUSTER:-true}" == "true" ]]; then
    log "尝试下载 gobuster 预编译二进制（OJ/gobuster）..."
    
    # 精准匹配官方 Linux_x86_64.tar.gz 格式
    GOBUSTER_URL=$(curl -s https://api.github.com/repos/OJ/gobuster/releases/latest | grep "browser_download_url" | grep "Linux_x86_64.tar.gz" | cut -d '"' -f 4)
    
    if [ -n "$GOBUSTER_URL" ]; then
        TMP_DIR=$(mktemp -d)
        cd "$TMP_DIR"
        
        curl -sL "$GOBUSTER_URL" -o gobuster.tar.gz
        tar -zxvf gobuster.tar.gz >> /dev/null 2>&1
        
        if [ -f "gobuster" ]; then
            cp -f gobuster "${BIN_DIR}/gobuster" 2>/dev/null || sudo cp -f gobuster "${BIN_DIR}/gobuster"
            chmod +x "${BIN_DIR}/gobuster"
            log "gobuster 预编译二进制安装成功！"
        else
            warn "gobuster 解压后未找到二进制，回退到 go install"
            go install github.com/OJ/gobuster/v3@latest
        fi
        
        cd - > /dev/null
        rm -rf "$TMP_DIR"
    else
        warn "gobuster: 未找到匹配的预编译二进制，回退到 go install 编译"
        go install github.com/OJ/gobuster/v3@latest
    fi
fi

# ---------- nmap (apt) ----------
if [[ "${INSTALL_NMAP:-true}" == "true" ]]; then
    if is_installed nmap; then
        log "nmap already installed, skipping"
    else
        log "Installing nmap via apt..."
        apt-get install -y -qq nmap >> "${INSTALL_LOG}" 2>&1 \
            || soft_err "Failed to install nmap"
        log "nmap installed successfully"
    fi
fi

# ---------- ffuf ----------
if [[ "${INSTALL_FFUF}" == "true" ]]; then
    install_tool_fast "ffuf" "ffuf/ffuf" "ffuf" "github.com/ffuf/ffuf/v2@latest"
fi

# ---------- gau ----------
if [[ "${INSTALL_GAU}" == "true" ]]; then
    install_tool_fast "gau" "lc/gau" "gau" "github.com/lc/gau/v2/cmd/gau@latest"
fi

# ---------- waybackurls ----------
if [[ "${INSTALL_WAYBACKURLS}" == "true" ]]; then
    install_tool_fast "waybackurls" "tomnomnom/waybackurls" "waybackurls" "github.com/tomnomnom/waybackurls@latest"
fi

# ---------- OneForAll ----------
if [[ "${INSTALL_ONEFORALL}" == "true" ]]; then
    OFA_DIR="${TOOLS_DIR}/OneForAll"
    if [[ -d "${OFA_DIR}" ]]; then
        log "OneForAll already present, skipping clone"
    else
        log "Cloning OneForAll..."
        git clone --depth 1 https://github.com/shmilylty/OneForAll.git "${OFA_DIR}" \
            >> "${INSTALL_LOG}" 2>&1 || soft_err "Failed to clone OneForAll"
    fi
    log "Installing OneForAll Python dependencies..."
    cd "${OFA_DIR}"
    python3 -m pip install --upgrade pip setuptools wheel >> "${INSTALL_LOG}" 2>&1 || true
    python3 -m pip install -r requirements.txt --break-system-packages \
        >> "${INSTALL_LOG}" 2>&1 || warn "Some OneForAll dependencies may have failed"
    cat > "${BIN_DIR}/oneforall" <<EOF
#!/bin/bash
cd ${OFA_DIR}
python3 oneforall.py "\$@"
EOF
    chmod +x "${BIN_DIR}/oneforall"
    log "OneForAll ready (command: oneforall)"
fi

# ---------- dirsearch ----------
if [[ "${INSTALL_DIRSEARCH}" == "true" ]]; then
    DS_DIR="${TOOLS_DIR}/dirsearch"
    if [[ -d "${DS_DIR}" ]]; then
        log "dirsearch already present, skipping clone"
    else
        log "Cloning dirsearch..."
        git clone --depth 1 https://github.com/maurosoria/dirsearch.git "${DS_DIR}" \
            >> "${INSTALL_LOG}" 2>&1 || soft_err "Failed to clone dirsearch"
    fi
    cat > "${BIN_DIR}/dirsearch" <<EOF
#!/bin/bash
cd ${DS_DIR}
python3 dirsearch.py "\$@"
EOF
    chmod +x "${BIN_DIR}/dirsearch"
    log "dirsearch ready (command: dirsearch)"
fi

# ---------- GoDNS (disabled by default) ----------
if [[ "${INSTALL_GODNS}" == "true" ]]; then
    warn "GoDNS installation is enabled but no single canonical repo is defined."
    warn "Please set a specific package in install_tools.sh if needed."
    # Example (uncomment and adjust):
    # install_go_tool "godns" "github.com/example/godns@latest"
else
    log "GoDNS skipped (INSTALL_GODNS=false). Use dnsx for most DNS tasks."
fi

# ---------- wait for background nuclei template update ----------
if [[ -n "${NUCLEI_TPL_PID:-}" ]]; then
    log "Waiting for nuclei template update to finish..."
    wait "${NUCLEI_TPL_PID}" || true
fi

# ---------- cleanup ----------
# 注意：只清理编译缓存（如果确实用到了源码编译回退），不要每次都清，
# 否则下次运行同一台机器时又要重新下载/编译一遍。
if [[ "${CLEAN_GO_CACHE:-false}" == "true" ]]; then
    log "Cleaning Go build cache..."
    go clean -cache 2>/dev/null || true
fi

# ---------- wordlist placeholder ----------
cat > "${WORDLIST_DIR}/README" <<EOF
Place common wordlists here:
  dir/          - directory / path dictionaries
  subdomain/    - subdomain dictionaries
  nuclei-templates/ - linked to nuclei templates

Suggested sources:
  https://github.com/danielmiessler/SecLists
  https://github.com/assetnote/wordlists
EOF

# ---------- summary ----------
echo
echo "============================================================"
echo " Tool installation finished"
echo "============================================================"
echo "TOOLS_DIR   : ${TOOLS_DIR}"
echo "BIN_DIR     : ${BIN_DIR}"
echo "LOG         : ${INSTALL_LOG}"
echo
echo "Installed tools (version check):"
for t in subfinder httpx nuclei dnsx naabu katana ffuf gau waybackurls gobuster nmap; do
    if is_installed "$t"; then
        ver=$($t -version 2>/dev/null || $t --version 2>/dev/null || echo "ok")
        printf "  %-14s %s\n" "$t" "$ver"
    else
        printf "  %-14s not found\n" "$t"
    fi
done
echo
echo "PATH snippet:"
echo "  export PATH=\"${BIN_DIR}:\$PATH\""
echo "  export PATH=\"${GO_BIN}:\$PATH\""
echo "============================================================"

log "===== tool installation finished ====="
