#!/usr/bin/env bash
# step-03-create-cluster.sh
# Creates the local kind cluster using kind-config.yaml.
# Idempotent — skips creation if cluster already exists.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="fraud-detection"
CONFIG="${ROOT_DIR}/k8s/00-cluster/kind-config.yaml"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${B}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${G}[OK]${NC}    $*"; }
log_warn() { echo -e "${Y}[SKIP]${NC}  $*"; }
log_err()  { echo -e "${R}[ERR]${NC}   $*"; }

# ── Already exists? ────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
    log_warn "Kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
    kubectl config use-context "kind-${CLUSTER_NAME}" &>/dev/null
    log_ok "Context set to kind-${CLUSTER_NAME}."
    exit 0
fi

# ── Verify config file ─────────────────────────────────────────
if [[ ! -f "$CONFIG" ]]; then
    log_err "kind config not found at: ${CONFIG}"
    exit 1
fi

# ── Create cluster ─────────────────────────────────────────────
log_info "Creating kind cluster '${CLUSTER_NAME}' with config: ${CONFIG}"
kind create cluster \
    --name "${CLUSTER_NAME}" \
    --config "${CONFIG}" \
    --wait 120s

# ── Set context ────────────────────────────────────────────────
kubectl config use-context "kind-${CLUSTER_NAME}"
log_ok "kubectl context set to kind-${CLUSTER_NAME}."

# ── Apply namespace + RBAC ─────────────────────────────────────
log_info "Applying namespace and RBAC..."
kubectl apply -f "${ROOT_DIR}/k8s/00-cluster/namespace.yaml"

# ── Verify ────────────────────────────────────────────────────
log_info "Verifying cluster nodes..."
kubectl get nodes
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "${NODE_COUNT}" -ge 2 ]]; then
    log_ok "Cluster ready with ${NODE_COUNT} nodes."
else
    log_err "Expected ≥ 2 nodes, got ${NODE_COUNT}."
    exit 1
fi
