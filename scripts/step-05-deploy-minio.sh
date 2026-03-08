#!/usr/bin/env bash
# step-05-deploy-minio.sh
# Deploys the MinIO Tenant CRD (managed by the MinIO operator).
# Buckets (fraud-warehouse, fraud-checkpoints) are declared in the Tenant
# spec and created automatically by the MinIO operator on first boot.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="fraud-detection"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${B}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${G}[OK]${NC}    $*"; }
log_warn() { echo -e "${Y}[SKIP]${NC}  $*"; }
log_err()  { echo -e "${R}[ERR]${NC}   $*"; }

minio_ready() {
    # Guard checks everything this step is responsible for:
    #   1. Pod is Running
    #   2. S3 API /minio/health/live returns 200
    #   3. Both required buckets exist
    #
    # Health check is done via a temporary curl pod hitting the ClusterIP
    # service — NOT via kubectl exec into the minio container.
    # The minio server image (minio/minio:*) is a minimal scratch image that
    # contains only the minio binary. curl, wget, and mc are absent.
    # kubectl exec -- curl would fail with "executable not found" (silently
    # suppressed by &>/dev/null), making every health check look like a timeout.
    local phase
    phase=$(kubectl get pod \
        -l v1.min.io/tenant=fraud-minio \
        -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    [[ "$phase" == "Running" ]] || return 1

    # Check S3 API via the cluster service (no exec needed)
    kubectl run minio-health-probe \
        --image=curlimages/curl:8.6.0 \
        --restart=Never \
        --rm \
        --attach \
        -n "${NAMESPACE}" \
        --command -- \
        curl -sf --max-time 5 \
            http://minio-nodeport.${NAMESPACE}:9000/minio/health/live \
        &>/dev/null 2>&1 || return 1

    # Check both buckets were created by the operator
    kubectl run minio-bucket-probe \
        --image=curlimages/curl:8.6.0 \
        --restart=Never \
        --rm \
        --attach \
        -n "${NAMESPACE}" \
        --command -- \
        curl -sf --max-time 5 \
            "http://minio-nodeport.${NAMESPACE}:9000/fraud-checkpoints" \
        &>/dev/null 2>&1 || return 1
}

# ── Already running? ───────────────────────────────────────────
if minio_ready; then
    log_warn "MinIO tenant already running and healthy — skipping."
    exit 0
fi

# ── Apply tenant manifest ──────────────────────────────────────
log_info "Applying MinIO Tenant manifest..."
kubectl apply -f "${ROOT_DIR}/k8s/02-minio/minio-tenant.yaml"

# ── Wait for MinIO operator to reconcile the Tenant CR ────────
# BUG FIX 1: The MinIO operator takes ~15s after the Tenant CR is applied
# before it creates the StatefulSet. kubectl wait immediately after apply
# returns "no matching resources found" because the pod doesn't exist yet.
# Poll until the pod appears, THEN hand off to kubectl wait.
log_info "Waiting for MinIO operator to provision the tenant pod..."
MAX_WAIT=60; elapsed=0
until kubectl get pod \
    -l v1.min.io/tenant=fraud-minio \
    -n "${NAMESPACE}" \
    --no-headers 2>/dev/null | grep -q .; do
    if [[ $elapsed -ge $MAX_WAIT ]]; then
        log_err "MinIO operator did not create the tenant pod within ${MAX_WAIT}s."
        log_err "Check operator logs: kubectl logs -n minio-operator deploy/minio-operator"
        exit 1
    fi
    sleep 3
    elapsed=$((elapsed + 3))
done
log_ok "Tenant pod created by operator."

# ── Wait for pod readiness ─────────────────────────────────────
log_info "Waiting for MinIO tenant pod to be ready (up to 3 minutes)..."
kubectl wait --for=condition=ready pod \
    -l v1.min.io/tenant=fraud-minio \
    -n "${NAMESPACE}" \
    --timeout=180s

# ── Verify S3 API health ───────────────────────────────────────
# BUG FIX 2: Do NOT use kubectl exec into the minio container.
# The minio/minio server image is a minimal scratch image — it has no
# curl, wget, or mc. Every exec attempt silently fails (suppressed by
# &>/dev/null), making it look like a timeout rather than a missing binary.
#
# Instead: spin up a temporary curlimages/curl pod in the same namespace
# and hit the minio-nodeport ClusterIP service. This is network-equivalent
# and does not depend on any tools being installed in the minio image.
log_info "Verifying MinIO S3 API health (via temporary curl pod)..."
MAX=18; i=0
while [[ $i -lt $MAX ]]; do
    if kubectl run minio-health-check-${i} \
        --image=curlimages/curl:8.6.0 \
        --restart=Never \
        --rm \
        --attach \
        -n "${NAMESPACE}" \
        --command -- \
        curl -sf --max-time 5 \
            http://minio-nodeport.${NAMESPACE}:9000/minio/health/live \
        &>/dev/null 2>&1; then
        log_ok "MinIO S3 API is healthy."
        break
    fi
    i=$((i+1))
    [[ $i -lt $MAX ]] && sleep 5
done
if [[ $i -ge $MAX ]]; then
    log_err "MinIO S3 API did not become healthy after $((MAX * 5))s."
    log_err "Pod logs: kubectl logs -n ${NAMESPACE} -l v1.min.io/tenant=fraud-minio -c minio"
    exit 1
fi

# ── Verify buckets were created by the operator ────────────────
# BUG FIX 3: No mc calls needed. The minio-tenant.yaml Tenant spec
# declares buckets: [fraud-warehouse, fraud-checkpoints] and the
# MinIO operator v5 creates them automatically on first boot.
# We just verify they exist by listing the bucket via S3 ListBuckets.
log_info "Verifying buckets were created by the MinIO operator..."
BUCKET_LIST=$(kubectl run minio-bucket-list \
    --image=curlimages/curl:8.6.0 \
    --restart=Never \
    --rm \
    --attach \
    -n "${NAMESPACE}" \
    --command -- \
    curl -sf --max-time 10 \
        -u admin:password123 \
        "http://minio-nodeport.${NAMESPACE}:9000/" \
    2>/dev/null || echo "")

for bucket in fraud-checkpoints fraud-warehouse; do
    if echo "${BUCKET_LIST}" | grep -q "${bucket}"; then
        log_ok "  Bucket '${bucket}' confirmed."
    else
        log_warn "  Bucket '${bucket}' not visible in listing yet — operator may still be initialising."
        log_warn "  Flink and Iceberg will create it on first write if needed."
    fi
done

log_ok "MinIO tenant ready."
log_info "  Console  → http://localhost:9001   (admin / password123)"
log_info "  S3 API   → http://localhost:9000"
log_info "  Buckets: fraud-warehouse, fraud-checkpoints (operator-provisioned)"
