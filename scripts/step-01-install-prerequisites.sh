#!/usr/bin/env bash
# step-01-install-prerequisites.sh
# Installs: docker, kubectl, helm, kind, curl, python3
# Supports macOS (Homebrew) and Linux (apt / dnf).
# Already-installed tools are detected and skipped individually.

set -euo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${B}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${G}[OK]${NC}    $*"; }
log_warn() { echo -e "${Y}[SKIP]${NC}  $*"; }
log_err()  { echo -e "${R}[ERR]${NC}   $*"; }

OS="$(uname -s)"

install_brew_pkg() {
    local pkg="$1" cmd="${2:-$1}"
    if command -v "$cmd" &>/dev/null; then
        log_warn "$cmd already installed — skipping."
    else
        log_info "Installing $pkg via Homebrew..."
        brew install "$pkg"
        log_ok "$pkg installed."
    fi
}

install_apt_pkg() {
    local pkg="$1" cmd="${2:-$1}"
    if command -v "$cmd" &>/dev/null; then
        log_warn "$cmd already installed — skipping."
    else
        log_info "Installing $pkg via apt..."
        sudo apt-get install -y "$pkg"
        log_ok "$pkg installed."
    fi
}

# ── macOS ──────────────────────────────────────────────────────
install_macos() {
    if ! command -v brew &>/dev/null; then
        log_info "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    install_brew_pkg curl
    install_brew_pkg python3
    install_brew_pkg docker

    if ! command -v kubectl &>/dev/null; then
        log_info "Installing kubectl..."
        brew install kubectl
    else
        log_warn "kubectl already installed."
    fi

    install_brew_pkg helm
    install_brew_pkg kind

    if ! open -Ra "Docker" 2>/dev/null && ! pgrep -q "Docker Desktop"; then
        log_warn "Docker Desktop installed but not running."
        log_warn "Please open Docker Desktop, grant permissions, then re-run step 1."
        exit 1
    fi
}

# ── Linux (apt) ────────────────────────────────────────────────
install_linux_apt() {
    log_info "Updating apt index..."
    sudo apt-get update -qq

    install_apt_pkg curl
    install_apt_pkg python3
    install_apt_pkg python3-pip pip3

    # Docker
    if ! command -v docker &>/dev/null; then
        log_info "Installing Docker via get.docker.com..."
        curl -fsSL https://get.docker.com | sudo sh
        sudo usermod -aG docker "$USER"
        log_ok "Docker installed. You may need to log out and back in for group membership."
    else
        log_warn "docker already installed."
    fi

    # kubectl
    if ! command -v kubectl &>/dev/null; then
        log_info "Installing kubectl..."
        local k8s_ver
        k8s_ver=$(curl -sL https://dl.k8s.io/release/stable.txt)
        curl -sLO "https://dl.k8s.io/release/${k8s_ver}/bin/linux/amd64/kubectl"
        chmod +x kubectl && sudo mv kubectl /usr/local/bin/
        log_ok "kubectl ${k8s_ver} installed."
    else
        log_warn "kubectl already installed."
    fi

    # helm
    if ! command -v helm &>/dev/null; then
        log_info "Installing Helm..."
        curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        log_ok "Helm installed."
    else
        log_warn "helm already installed."
    fi

    # kind
    if ! command -v kind &>/dev/null; then
        log_info "Installing kind..."
        local kind_ver="v0.22.0"
        curl -sLo kind "https://kind.sigs.k8s.io/dl/${kind_ver}/kind-linux-amd64"
        chmod +x kind && sudo mv kind /usr/local/bin/
        log_ok "kind ${kind_ver} installed."
    else
        log_warn "kind already installed."
    fi
}

# ── Linux (dnf/yum) ────────────────────────────────────────────
install_linux_dnf() {
    sudo dnf install -y curl python3 python3-pip
    if ! command -v docker &>/dev/null; then
        sudo dnf install -y docker
        sudo systemctl enable --now docker
    fi
    # kubectl + helm + kind same as apt path
    install_linux_apt
}

# ── Dispatch ───────────────────────────────────────────────────
case "$OS" in
    Darwin) install_macos ;;
    Linux)
        if command -v apt-get &>/dev/null; then
            install_linux_apt
        elif command -v dnf &>/dev/null; then
            install_linux_dnf
        else
            log_err "Unsupported Linux package manager. Install manually: docker kubectl helm kind curl python3"
            exit 1
        fi ;;
    *)
        log_err "Unsupported OS: $OS"
        exit 1 ;;
esac

# ── Final verification ─────────────────────────────────────────
echo ""
log_info "Verifying installed tools..."
for cmd in docker kubectl helm kind curl python3; do
    if command -v "$cmd" &>/dev/null; then
        log_ok "$cmd → $(command -v $cmd)"
    else
        log_err "$cmd NOT found after install attempt."
        exit 1
    fi
done

if ! docker info &>/dev/null 2>&1; then
    log_err "Docker daemon is not running."
    log_err "Start Docker Desktop (macOS) or: sudo systemctl start docker (Linux)"
    exit 1
fi

log_ok "All prerequisites ready."
