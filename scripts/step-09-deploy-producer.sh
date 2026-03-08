#!/usr/bin/env bash
# step-09-deploy-producer.sh
# Deploys the Python transaction generator as a Kubernetes Deployment.
# The producer emits ~20 TPS to the raw-transactions Kafka topic,
# with periodic fraud pattern injection every 200 normal transactions.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="fraud-detection"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${B}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${G}[OK]${NC}    $*"; }
log_warn() { echo -e "${Y}[SKIP]${NC}  $*"; }
log_err()  { echo -e "${R}[ERR]${NC}   $*"; }

producer_ready() {
    # FIX: check deployment Available, not just pod.phase==Running.
    #
    # pod.phase==Running is true even during CrashLoopBackOff — the pod
    # oscillates between Running and waiting between crash cycles.
    # deployment.availableReplicas>=1 means the pod has passed its
    # readiness probe and is actually serving, which is a much stronger
    # signal that the producer is genuinely healthy.
    local available
    available=$(kubectl get deployment transaction-producer \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
    [[ "${available:-0}" -ge 1 ]] || return 1
}

# ── Already running? ───────────────────────────────────────────
if producer_ready; then
    log_warn "Transaction producer already running — skipping."
    exit 0
fi

# ── Pre-check: Kafka must be ready ────────────────────────────
log_info "Verifying Kafka is ready before deploying producer..."
KAFKA_READY=$(kubectl get kafka fraud-kafka \
    -n "${NAMESPACE}" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)

if [[ "$KAFKA_READY" != "True" ]]; then
    log_err "Kafka is not Ready. Run step 6 before step 9."
    exit 1
fi

# ── Deploy ─────────────────────────────────────────────────────
log_info "Deploying transaction producer..."
kubectl apply -f "${ROOT_DIR}/k8s/05-producer/producer-deployment.yaml"

log_info "Waiting for producer deployment to be available..."
kubectl wait --for=condition=available deployment/transaction-producer \
    -n "${NAMESPACE}" \
    --timeout=120s

# ── Verify it's producing ──────────────────────────────────────
log_info "Waiting 10 seconds then checking producer logs..."
sleep 10

PRODUCER_POD=$(kubectl get pod \
    -l app=transaction-producer \
    -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -n "$PRODUCER_POD" ]]; then
    log_info "Recent producer log output:"
    kubectl logs "${PRODUCER_POD}" -n "${NAMESPACE}" --tail=5 2>/dev/null || true
fi

# ── Quick Kafka message count check ───────────────────────────
KAFKA_POD=$(kubectl get pod \
    -l strimzi.io/name=fraud-kafka-kafka \
    -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -n "$KAFKA_POD" ]]; then
    log_info "Checking raw-transactions topic for messages..."
    sleep 5
    MSG_COUNT=$(kubectl exec "${KAFKA_POD}" -n "${NAMESPACE}" -- \
        bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
        --bootstrap-server localhost:9092 \
        --topic raw-transactions \
        --time -1 2>/dev/null \
        | awk -F: '{sum += $3} END {print sum}' || echo "0")
    if [[ "${MSG_COUNT:-0}" -gt 0 ]]; then
        log_ok "Messages flowing: ${MSG_COUNT} records in raw-transactions."
    else
        log_warn "No messages yet — producer may still be initialising (normal for first 30s)."
    fi
fi

log_ok "Transaction producer deployed."
log_info "  Producer pod: ${PRODUCER_POD}"
log_info "  Target TPS:   20"
log_info "  Accounts:     200 simulated accounts"
log_info "  Fraud rate:   2% base + periodic injection bursts"
