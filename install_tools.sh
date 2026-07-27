#!/usr/bin/env bash
# ============================================================
# File: install_tools.sh
# Install security research tools into /home/tools
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "${SCRIPT_DIR}/config.sh"

mkdir -p "${LOG_DIR}" "${BIN_DIR}" "${GOBIN}"
touch "${INSTALL_LOG}"

export PATH="${BIN_DIR}:${GO_BIN}:${PATH}"
export GOPATH="${HOME}/go"
export GOBIN="${GOPATH}/bin"

log "===== tool installation started ====="

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

install_go_tool() {
    local name="$1"
    local package="$2"

    if is_installed "${name}"; then
        log "${name} already installed, skipping"
        return 0
    fi

    log "Installing ${name} ..."
    if go install -v "${package}" >> "${INSTALL_LOG}" 2>&1; then
        link_bin "${GOBIN}/${name}" "${name}"
        log "${name} installed successfully"
    else
        err "Failed to install ${name}. Check ${INSTALL_LOG}"
    fi
}

# ---------- ProjectDiscovery tools ----------
if [[ "${INSTALL_PROJECTDISCOVERY}" == "true" ]]; then
    log "Installing ProjectDiscovery suite..."
    install_go_tool "subfinder" "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
    install_go_tool "httpx"     "github.com/projectdiscovery/httpx/cmd/httpx@latest"
    install_go_tool "nuclei"    "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"
    install_go_tool "dnsx"      "github.com/projectdiscovery/dnsx/cmd/dnsx@latest"
    install_go_tool "naabu"     "github.com/projectdiscovery/naabu/v2/cmd/naabu@latest"
    install_go_tool "katana"    "github.com/projectdiscovery/katana/cmd/katana@latest"

    # Update nuclei templates (optional, quiet)
    if is_installed nuclei; then
        log "Updating nuclei templates..."
        nuclei -update-templates -silent >> "${INSTALL_LOG}" 2>&1 || true
        if [[ -d "${HOME}/nuclei-templates" ]]; then
            ln -sfn "${HOME}/nuclei-templates" "${WORDLIST_DIR}/nuclei-templates"
        fi
    fi
fi

# ---------- ffuf ----------
if [[ "${INSTALL_FFUF}" == "true" ]]; then
    install_go_tool "ffuf" "github.com/ffuf/ffuf/v2@latest"
fi

# ---------- gau ----------
if [[ "${INSTALL_GAU}" == "true" ]]; then
    install_go_tool "gau" "github.com/lc/gau/v2/cmd/gau@latest"
fi

# ---------- waybackurls ----------
if [[ "${INSTALL_WAYBACKURLS}" == "true" ]]; then
    install_go_tool "waybackurls" "github.com/tomnomnom/waybackurls@latest"
fi

# ---------- OneForAll ----------
if [[ "${INSTALL_ONEFORALL}" == "true" ]]; then
    OFA_DIR="${TOOLS_DIR}/OneForAll"
    if [[ -d "${OFA_DIR}" ]]; then
        log "OneForAll already present, skipping clone"
    else
        log "Cloning OneForAll..."
        git clone --depth 1 https://github.com/shmilylty/OneForAll.git "${OFA_DIR}" \
            >> "${INSTALL_LOG}" 2>&1 || err "Failed to clone OneForAll"
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
            >> "${INSTALL_LOG}" 2>&1 || err "Failed to clone dirsearch"
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

# ---------- cleanup ----------
log "Cleaning Go build cache..."
go clean -cache 2>/dev/null || true

# ---------- wordlist placeholder ----------
cat > "${WORDLIST_DIR}/README" <<EOF
Place common wordlists here:
  dir/         - directory / path dictionaries
  subdomain/   - subdomain dictionaries
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
echo "TOOLS_DIR : ${TOOLS_DIR}"
echo "BIN_DIR   : ${BIN_DIR}"
echo "LOG       : ${INSTALL_LOG}"
echo
echo "Installed tools (version check):"
for t in subfinder httpx nuclei dnsx naabu katana ffuf gau waybackurls; do
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