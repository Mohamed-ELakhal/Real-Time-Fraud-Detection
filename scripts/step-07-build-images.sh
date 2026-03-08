#!/usr/bin/env bash
# step-07-build-images.sh
# Builds the producer and flink-jobs Docker images and loads them
# directly into the kind cluster — no registry required.
#
# Images built:
#   fraud-detection/producer:latest    — Python transaction generator
#   fraud-detection/flink-jobs:latest  — PyFlink + connector JARs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CLUSTER_NAME="fraud-detection"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${B}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${G}[OK]${NC}    $*"; }
log_warn() { echo -e "${Y}[SKIP]${NC}  $*"; }
log_err()  { echo -e "${R}[ERR]${NC}   $*"; }

images_loaded() {
    # FIX: check ALL worker nodes, not just the first one.
    #
    # Previously this only checked "${CLUSTER_NAME}-worker". With 2 worker
    # nodes (worker + worker2) the second worker was never verified.
    # A pod scheduled on worker2 would get ImagePullBackOff because its
    # containerd didn't have the image — but the step guard passed anyway.
    local all_loaded=true
    local workers
    workers=$(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null | grep worker)
    if [[ -z "$workers" ]]; then
        return 1
    fi
    while IFS= read -r node; do
        docker exec "${node}" ctr -n k8s.io images ls 2>/dev/null             | grep -q "fraud-detection/producer"  || { all_loaded=false; break; }
        docker exec "${node}" ctr -n k8s.io images ls 2>/dev/null             | grep -q "fraud-detection/flink-jobs" || { all_loaded=false; break; }
    done <<< "$workers"
    $all_loaded || return 1
}

if images_loaded; then
    log_warn "Images already loaded into all worker nodes — skipping build."
    exit 0
fi

# ── Build producer image ───────────────────────────────────────
log_info "Building fraud-detection/producer:latest..."
docker build \
    -t fraud-detection/producer:latest \
    "${ROOT_DIR}/producer" \
    --progress=plain 2>&1 | tail -5

log_ok "Producer image built."

# ── Build flink-jobs image ─────────────────────────────────────
log_info "Building fraud-detection/flink-jobs:latest (downloads connector JARs)..."
log_info "This may take 10–15 minutes on first run — building without cache to apply Dockerfile optimizations."
# FIX: Force --no-cache so the optimized Dockerfile (gcc removed after install,
# JARs consolidated into one RUN) actually executes instead of serving old layers
# from Docker's build cache. Without this flag, Docker matches the instruction
# hashes against the cache and returns the old 1.89GB / 19-layer image unchanged.
# The image must be rebuilt from scratch once to get the ~1.5GB / 9-layer result.
# Subsequent builds after this will be fast (all layers cached).
docker rmi fraud-detection/flink-jobs:latest 2>/dev/null || true
docker build \
    --no-cache \
    -t fraud-detection/flink-jobs:latest \
    "${ROOT_DIR}/flink-jobs" \
    --progress=plain 2>&1 | tail -10

log_ok "Flink jobs image built."

# ── Load images into kind ──────────────────────────────────────
# FIX: Load to WORKER nodes only, sequentially, with a hard timeout.
#
# Loading to the control-plane is wasteful (it never schedules app pods)
# and caused an indefinite hang when the control-plane containerd was
# resource-starved and couldn't complete the import. Loading in parallel
# to all nodes also spikes RAM enough to destabilise other pods.
# Sequential loading with timeout 300s ensures a stalled import is
# detected and reported rather than hanging the whole pipeline.

WORKER_NODES=$(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null \
    | grep worker | tr '\n' ',')
WORKER_NODES="${WORKER_NODES%,}"   # strip trailing comma

if [[ -z "${WORKER_NODES}" ]]; then
    log_err "No worker nodes found in cluster '${CLUSTER_NAME}'."
    exit 1
fi
log_info "Target nodes: ${WORKER_NODES}"

load_image_sequential() {
    local image="$1"
    local nodes_csv="$2"
    IFS=',' read -ra node_arr <<< "${nodes_csv}"
    for node in "${node_arr[@]}"; do
        log_info "  → ${image} into ${node}..."
        if ! timeout 300 kind load docker-image "${image}" \
                --name "${CLUSTER_NAME}" --nodes "${node}"; then
            log_err "  Load of ${image} into ${node} timed out or failed."
            log_err "  The node containerd may be resource-starved."
            return 1
        fi
        log_ok "  Loaded into ${node}."
    done
}

log_info "Loading images into kind cluster '${CLUSTER_NAME}'..."
log_info "  Loading producer image (sequential, workers only)..."
load_image_sequential "fraud-detection/producer:latest" "${WORKER_NODES}"
log_ok "  Producer image loaded."

log_info "  Loading flink-jobs image (sequential, workers only)..."
load_image_sequential "fraud-detection/flink-jobs:latest" "${WORKER_NODES}"
log_ok "  Flink jobs image loaded."

# ── Verify ────────────────────────────────────────────────────
log_info "Verifying images in worker nodes..."
IFS=',' read -ra verify_nodes <<< "${WORKER_NODES}"
for node in "${verify_nodes[@]}"; do
    count=$(docker exec "${node}" ctr -n k8s.io images ls 2>/dev/null \
        | grep "fraud-detection" | wc -l | tr -d ' ')
    log_ok "  ${node}: ${count} fraud-detection images loaded"
done
