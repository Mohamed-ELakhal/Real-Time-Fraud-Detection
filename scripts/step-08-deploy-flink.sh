#!/usr/bin/env bash
# step-08-deploy-flink.sh
# Deploys the Flink fraud detection job via the FlinkDeployment CRD.
# The Flink Kubernetes Operator watches the CRD and manages:
#   - JobManager Deployment + Service
#   - TaskManager Deployments (2 replicas)
#   - RocksDB checkpoints to MinIO
#   - Automatic job restart on failure
#   - Savepoint-based upgrades

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="fraud-detection"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${B}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${G}[OK]${NC}    $*"; }
log_warn() { echo -e "${Y}[SKIP]${NC}  $*"; }
log_err()  { echo -e "${R}[ERR]${NC}   $*"; }

flink_job_ready() {
    # 1. FlinkDeployment must be STABLE (operator confirms job is healthy)
    local state
    state=$(kubectl get flinkdeployment fraud-scoring-job \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.lifecycleState}' 2>/dev/null)
    [[ "$state" == "STABLE" ]] || return 1

    # 2. JobManager pod must be Running AND not in a restart storm
    #    (CrashLoopBackOff pods briefly show phase=Running before crashing).
    #    We require restartCount < 3 to distinguish healthy from looping.
    local jm_phase jm_restarts
    jm_phase=$(kubectl get pod \
        -l component=jobmanager \
        -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    jm_restarts=$(kubectl get pod \
        -l component=jobmanager \
        -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
    [[ "$jm_phase" == "Running" ]] || return 1
    [[ "${jm_restarts:-99}" -lt 3 ]] || return 1

    # 3. At least one TaskManager pod must be Running and Ready
    local tm_ready
    tm_ready=$(kubectl get pod \
        -l component=taskmanager \
        -n "${NAMESPACE}" \
        --no-headers 2>/dev/null \
        | grep -c "Running" || echo "0")
    [[ "${tm_ready:-0}" -ge 1 ]] || return 1
}

# ── Already running? ───────────────────────────────────────────
# NOTE: We intentionally require ALL three conditions (STABLE state +
# healthy JM + at least one TM Running) before skipping. Checking only
# JM phase + DEPLOYED state caused false "done" when JM was in
# CrashLoopBackOff — it briefly shows Running on each restart, and the
# operator sets DEPLOYED even for a failing job.
if flink_job_ready; then
    log_ok "Flink job 'fraud-scoring-job' fully running — skipping."
    exit 0
fi

# ── Pre-check: MinIO must be available (checkpoint target) ────
log_info "Verifying MinIO is reachable..."
MINIO_POD=$(kubectl get pod \
    -l v1.min.io/tenant=fraud-minio \
    -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -z "$MINIO_POD" ]]; then
    log_err "MinIO pod not found. Run step 5 before step 8."
    exit 1
fi

# ── Create MinIO buckets ───────────────────────────────────────
# Both buckets MUST exist before Flink starts.
# If they don't exist:
#   - IcebergFilesCommitter fails on first commit → NoSuchBucket → task FAILED
#   - RocksDB checkpoint fails writing to s3://fraud-checkpoints/flink
# This causes an infinite restart loop (attempt #N) with no error in JM logs
# because the exception only appears in TM logs and the job never checkpoints.
#
# The MinIO pod has mc installed but the 'local' alias is NOT pre-configured.
# Strategy: configure alias explicitly, then create buckets.
# We use 'localhost:9000' from inside the pod — no network hops needed.
# 'mc mb --ignore-existing' exits 0 even if bucket already exists.
log_info "Creating MinIO buckets (fraud-warehouse, fraud-checkpoints)..."
# Step 1: configure mc alias pointing at the local MinIO instance
if ! kubectl exec "${MINIO_POD}" -n "${NAMESPACE}" -- \
        mc alias set myminio http://localhost:9000 admin password123 --quiet 2>/dev/null; then
    # Fallback: try with explicit env credentials
    kubectl exec "${MINIO_POD}" -n "${NAMESPACE}" -- \
        mc alias set myminio http://minio.fraud-detection.svc.cluster.local:9000 admin password123 --quiet 2>/dev/null || true
fi
# Step 2: create each bucket
for bucket in fraud-warehouse fraud-checkpoints; do
    if kubectl exec "${MINIO_POD}" -n "${NAMESPACE}" -- \
            mc mb --ignore-existing "myminio/${bucket}" 2>/dev/null; then
        log_ok "  Bucket '${bucket}' ready."
    else
        log_err "Failed to create MinIO bucket '${bucket}'."
        log_err "Debug: kubectl exec -n ${NAMESPACE} ${MINIO_POD} -- mc alias list"
        log_err "       kubectl exec -n ${NAMESPACE} ${MINIO_POD} -- mc mb myminio/${bucket}"
        exit 1
    fi
done

# ── Deploy Iceberg REST Catalog ────────────────────────────────
# The REST catalog MUST be running before the FlinkDeployment is applied.
# Flink calls GET /v1/config on the catalog during CREATE CATALOG at job
# startup — if the service is not resolvable, the job crashes immediately
# with UnknownHostException and enters CrashLoopBackOff.
# This service is also used by Trino (step-10) — kubectl apply is
# idempotent so step-10 will skip it if already running.
log_info "Applying Iceberg REST catalog..."
kubectl apply -f "${ROOT_DIR}/k8s/04-flink/iceberg-rest-catalog.yaml"

log_info "Waiting for Iceberg REST catalog to become Ready..."
# Phase 1: wait for pod to appear
REST_EXISTS=false
for i in $(seq 1 12); do   # 12 × 5s = 60s
    if kubectl get pod -l app=iceberg-rest-catalog -n "${NAMESPACE}"            -o name 2>/dev/null | grep -q .; then
        REST_EXISTS=true
        break
    fi
    log_info "  REST catalog pod not yet created (attempt ${i}/12) — waiting 5s..."
    sleep 5
done
if ! $REST_EXISTS; then
    log_err "Timeout: Iceberg REST catalog pod did not appear in 60s."
    exit 1
fi
# Phase 2: wait for readiness (readinessProbe: GET /v1/config)
if ! kubectl wait --for=condition=ready pod         -l app=iceberg-rest-catalog         -n "${NAMESPACE}"         --timeout=120s; then
    log_err "Iceberg REST catalog pod did not become Ready in 120s."
    log_err "Check logs: kubectl logs -n ${NAMESPACE} -l app=iceberg-rest-catalog"
    exit 1
fi
log_ok "Iceberg REST catalog ready."

# ── Apply Hadoop S3A ConfigMap ─────────────────────────────────
log_info "Applying Hadoop S3A ConfigMap..."
kubectl apply -f "${ROOT_DIR}/k8s/04-flink/hadoop-configmap.yaml"
log_ok "Hadoop ConfigMap applied."

# ── Apply FlinkDeployment CRD ──────────────────────────────────
log_info "Applying FlinkDeployment CRD..."
kubectl apply -f "${ROOT_DIR}/k8s/04-flink/flink-deployment.yaml"

# ── Wait for JobManager ────────────────────────────────────────
# Two-phase wait:
#   Phase 1: Poll until the pod EXISTS (operator reconcile time, up to 60s).
#            kubectl wait exits immediately with code 1 when no pods match
#            the selector — it does NOT wait for pods to appear.
#   Phase 2: kubectl wait for the Ready condition on the existing pod.
log_info "Waiting for Flink operator to create JobManager pod (phase 1/2)..."
JM_EXISTS=false
for i in $(seq 1 48); do   # 48 × 5s = 240s
    if kubectl get pod -l component=jobmanager -n "${NAMESPACE}" \
           -o name 2>/dev/null | grep -q .; then
        JM_EXISTS=true
        break
    fi
    log_info "  JM pod not yet created (attempt ${i}/24) — waiting 5s..."
    sleep 5
done
if ! $JM_EXISTS; then
    log_err "Timeout: operator did not create JobManager pod in 240s."
    log_err "Check operator logs: kubectl logs -n ${NAMESPACE} deploy/flink-kubernetes-operator"
    exit 1
fi

log_info "Waiting for JobManager pod to become Ready (phase 2/2)..."
if ! kubectl wait --for=condition=ready pod \
        -l component=jobmanager \
        -n "${NAMESPACE}" \
        --timeout=300s; then
    log_err "JobManager pod did not become Ready in 300s."
    log_err "Check JM logs: kubectl logs -n ${NAMESPACE} -l component=jobmanager"
    exit 1
fi
log_ok "JobManager pod is Ready."

# ── Wait for TaskManagers ──────────────────────────────────────
# Same two-phase pattern. TM pods are created by the operator after
# the JM is running, so we must wait for them to appear first.
log_info "Waiting for operator to create TaskManager pod(s) (phase 1/2)..."
TM_EXISTS=false
for i in $(seq 1 48); do   # 48 × 5s = 240s
    if kubectl get pod -l component=taskmanager -n "${NAMESPACE}" \
           -o name 2>/dev/null | grep -q .; then
        TM_EXISTS=true
        break
    fi
    log_info "  TM pod not yet created (attempt ${i}/24) — waiting 5s..."
    sleep 5
done
if ! $TM_EXISTS; then
    log_err "Timeout: operator did not create TaskManager pod in 240s."
    log_err "Check JM logs: kubectl logs -n ${NAMESPACE} -l component=jobmanager"
    exit 1
fi

log_info "Waiting for TaskManager pod(s) to become Ready (phase 2/2)..."
if ! kubectl wait --for=condition=ready pod \
        -l component=taskmanager \
        -n "${NAMESPACE}" \
        --timeout=300s; then
    log_err "TaskManager pod did not become Ready in 300s."
    log_err "Check TM logs: kubectl logs -n ${NAMESPACE} -l component=taskmanager"
    exit 1
fi
log_ok "TaskManager pod(s) Ready."

# ── Wait for FlinkDeployment to reach STABLE state ────────────
# STABLE (not just DEPLOYED) means Flink confirmed the job is RUNNING.
# DEPLOYED = operator submitted; STABLE = job confirmed running by Flink.
# On a loaded t3.xlarge the transition can take 60-120s after TM Ready.
log_info "Waiting for FlinkDeployment lifecycle to reach STABLE..."
MAX=60; i=0   # 60 x 5s = 300s
last_state=""
while [[ $i -lt $MAX ]]; do
    state=$(kubectl get flinkdeployment fraud-scoring-job \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.lifecycleState}' 2>/dev/null)
    if [[ "$state" == "STABLE" ]]; then
        log_ok "FlinkDeployment state: STABLE"
        break
    fi
    if [[ "$state" != "$last_state" ]]; then
        log_info "  FlinkDeployment state: ${state:-pending} -- waiting for STABLE..."
        last_state="$state"
    fi
    if [[ "$state" == "FAILED" || "$state" == "ROLLED_BACK" ]]; then
        log_err "FlinkDeployment reached terminal state: ${state}"
        log_err "Check JM logs: kubectl logs -n ${NAMESPACE} -l component=jobmanager --previous"
        exit 1
    fi
    i=$((i+1)); sleep 5
done

if [[ $i -ge $MAX ]]; then
    log_err "FlinkDeployment did not reach STABLE in $(( MAX * 5 ))s."
    log_err "Check logs: kubectl logs -n ${NAMESPACE} -l component=jobmanager"
    exit 1
fi

# ── Verify job is RUNNING via Flink REST API ──────────────────
# Curl the JM REST endpoint from inside the JM pod (no network ingress needed).
# Retry for up to 60s — job appears in REST API slightly after STABLE state.
log_info "Verifying fraud detection job is RUNNING via REST API..."
JM_POD=$(kubectl get pod \
    -l component=jobmanager \
    -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

JOB_RUNNING=false
for j in $(seq 1 12); do   # 12 x 5s = 60s
    RUNNING_COUNT=$(kubectl exec "${JM_POD}" -n "${NAMESPACE}" -- \
        curl -sf http://localhost:8081/jobs 2>/dev/null \
        | python3 -c \
          "import sys,json; d=json.load(sys.stdin); print(sum(1 for x in d.get('jobs',[]) if x.get('status')=='RUNNING'))" \
        2>/dev/null || echo "0")
    if [[ "${RUNNING_COUNT:-0}" -ge 1 ]]; then
        log_ok "Flink job confirmed RUNNING (${RUNNING_COUNT} job(s) running)."
        JOB_RUNNING=true
        break
    fi
    log_info "  Job not yet RUNNING (attempt ${j}/12) -- waiting 5s..."
    sleep 5
done

if ! $JOB_RUNNING; then
    log_warn "Could not confirm RUNNING via REST API -- job may still be initialising."
    log_warn "Check Flink UI: http://localhost:30082"
fi

log_ok "Flink deployment complete."
log_info "  Flink Web UI  --> http://localhost:30082"
log_info "  JobManager pod: ${JM_POD}"