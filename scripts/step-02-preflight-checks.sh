#!/usr/bin/env bash
# step-02-preflight-checks.sh
# Verifies system requirements before cluster creation:
#   - Docker daemon running
#   - Available RAM (≥ 10 GB recommended, 8 GB minimum)
#   - Available disk space (≥ 25 GB)
#   - Required ports free
#   - Internet connectivity
#   - Docker memory allocation (macOS)

set -euo pipefail

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${B}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${G}[OK]${NC}    $*"; }
log_warn() { echo -e "${Y}[WARN]${NC}  $*"; }
log_err()  { echo -e "${R}[ERR]${NC}   $*"; }

PASS=0; WARN=0; FAIL=0

check() {
    local label="$1" result="$2" msg="$3"
    case "$result" in
        ok)   log_ok   "$label — $msg"; PASS=$((PASS+1)) ;;
        warn) log_warn "$label — $msg"; WARN=$((WARN+1)) ;;
        fail) log_err  "$label — $msg"; FAIL=$((FAIL+1)) ;;
    esac
}

# ── Docker daemon ──────────────────────────────────────────────
if docker info &>/dev/null 2>&1; then
    check "Docker daemon" ok "running"
else
    check "Docker daemon" fail "NOT running — start Docker and retry"
fi

# ── RAM ────────────────────────────────────────────────────────
ram_gb=0
if [[ "$(uname -s)" == "Darwin" ]]; then
    ram_gb=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1024/1024/1024}')
else
    ram_gb=$(awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null)
fi

if   [[ "${ram_gb:-0}" -ge 10 ]]; then check "Available RAM" ok   "${ram_gb} GB (≥ 10 GB recommended)"
elif [[ "${ram_gb:-0}" -ge 8  ]]; then check "Available RAM" warn "${ram_gb} GB (minimum met, 12 GB recommended)"
else                                    check "Available RAM" fail "${ram_gb} GB (< 8 GB — increase Docker Desktop memory or free system RAM)"
fi

# ── WSL2 .wslconfig verification ──────────────────────────────
# The single most impactful fix for memory-constrained laptops.
# Without a memory cap, WSL2 grows to consume all available host RAM,
# leaving Windows starved and causing kube-scheduler / kube-apiserver
# to OOM-crash (which cascades into every operator CrashLoopBackOff).
if grep -qi "microsoft" /proc/version 2>/dev/null; then
    WSLCONFIG_PATH="${USERPROFILE}/.wslconfig"

    if [[ -f "${WSLCONFIG_PATH}" ]]; then
        # Check that memory is explicitly capped
        wsl_mem=$(grep -i "^memory=" "${WSLCONFIG_PATH}" 2>/dev/null             | head -1 | sed 's/[^0-9]//g')
        if [[ -n "${wsl_mem}" ]] && [[ "${wsl_mem}" -le 10 ]]; then
            check "WSL2 .wslconfig (memory cap)" ok                 "${wsl_mem} GB cap found — Windows retains $((16 - wsl_mem)) GB"
        elif [[ -n "${wsl_mem}" ]] && [[ "${wsl_mem}" -le 12 ]]; then
            check "WSL2 .wslconfig (memory cap)" warn                 "${wsl_mem} GB — recommend ≤ 10 GB on a 16 GB system"
        else
            check "WSL2 .wslconfig (memory cap)" fail                 "memory= not set or too high. Copy .wslconfig to %USERPROFILE% and run: wsl --shutdown"
        fi
        # Check swap is configured
        wsl_swap=$(grep -i "^swap=" "${WSLCONFIG_PATH}" 2>/dev/null             | head -1 | sed 's/[^0-9]//g')
        if [[ -n "${wsl_swap}" ]] && [[ "${wsl_swap}" -ge 4 ]]; then
            check "WSL2 .wslconfig (swap)" ok "${wsl_swap} GB swap configured"
        else
            check "WSL2 .wslconfig (swap)" warn                 "swap not set or < 4 GB — add swap=4GB to .wslconfig for RocksDB/JVM stability"
        fi
        # Check autoMemoryReclaim
        if grep -qi "autoMemoryReclaim" "${WSLCONFIG_PATH}" 2>/dev/null; then
            check "WSL2 autoMemoryReclaim" ok "enabled — vmmem will shrink after cluster teardown"
        else
            check "WSL2 autoMemoryReclaim" warn                 "not set — vmmem may stay high after cluster teardown (add autoMemoryReclaim=gradual)"
        fi
    else
        check "WSL2 .wslconfig" fail             ".wslconfig not found at %USERPROFILE%\.wslconfig — WSL2 has no memory cap!
  Copy the provided .wslconfig file there, then run: wsl --shutdown
  Without this, WSL2 will consume all 16 GB and crash the Kubernetes control plane."
    fi
fi


# ── Disk ───────────────────────────────────────────────────────
disk_gb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')
if   [[ "${disk_gb:-0}" -ge 25 ]]; then check "Free disk"    ok   "${disk_gb} GB"
elif [[ "${disk_gb:-0}" -ge 15 ]]; then check "Free disk"    warn "${disk_gb} GB (25 GB recommended for image cache)"
else                                     check "Free disk"    fail "${disk_gb} GB (< 15 GB — Docker image pulls may fail)"
fi

# ── Docker memory (macOS Desktop) ─────────────────────────────
if [[ "$(uname -s)" == "Darwin" ]]; then
    docker_mem_gb=$(docker info --format '{{.MemTotal}}' 2>/dev/null \
        | awk '{printf "%d", $1/1024/1024/1024}')
    if   [[ "${docker_mem_gb:-0}" -ge 10 ]]; then check "Docker Desktop memory" ok   "${docker_mem_gb} GB"
    elif [[ "${docker_mem_gb:-0}" -ge 8  ]]; then check "Docker Desktop memory" warn "${docker_mem_gb} GB (12 GB preferred: Settings → Resources → Memory)"
    else                                           check "Docker Desktop memory" fail "${docker_mem_gb} GB (increase to ≥ 10 GB: Settings → Resources → Memory)"
    fi
fi

# ── Required ports ─────────────────────────────────────────────
# NodePorts mapped from kind cluster to localhost
PORTS=(8080 8081 8082 8083 9000 9001 9090 3000 9092)
PORT_NAMES=("Kafka UI" "Schema Registry" "Flink UI" "Trino" "MinIO S3" "MinIO Console" "Prometheus" "Grafana" "Kafka External")

for i in "${!PORTS[@]}"; do
    p="${PORTS[$i]}"
    name="${PORT_NAMES[$i]}"
    if lsof -i ":${p}" &>/dev/null 2>&1 || ss -tlnp "sport = :${p}" &>/dev/null 2>&1; then
        check "Port ${p} (${name})" warn "already in use — may conflict with kind NodePort mapping"
    else
        check "Port ${p} (${name})" ok "free"
    fi
done

# ── Internet connectivity ──────────────────────────────────────
if curl -sf --max-time 8 https://registry-1.docker.io/v2/ &>/dev/null; then
    check "Docker Hub connectivity"    ok  "reachable"
else
    check "Docker Hub connectivity"    warn "unreachable — image pulls may fail (check proxy/firewall)"
fi

if curl -sf --max-time 8 https://repo1.maven.org/maven2/ &>/dev/null; then
    check "Maven Central (Flink JARs)" ok  "reachable"
else
    check "Maven Central (Flink JARs)" warn "unreachable — Flink connector JARs may fail to download"
fi

# ── Summary ────────────────────────────────────────────────────
echo ""
log_info "Pre-flight results: ${PASS} passed, ${WARN} warnings, ${FAIL} failed."

if [[ $FAIL -gt 0 ]]; then
    log_err "Pre-flight FAILED. Fix the errors above before proceeding."
    exit 1
elif [[ $WARN -gt 0 ]]; then
    log_warn "Pre-flight passed with warnings. Deployment will proceed but may encounter issues."
else
    log_ok "All pre-flight checks passed."
fi
