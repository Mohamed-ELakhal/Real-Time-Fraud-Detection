#!/usr/bin/env bash
# step-06-deploy-kafka.sh
# Deploys Kafka cluster (Strimzi KRaft), Schema Registry, and Kafka UI.
# Strimzi operator watches the Kafka + KafkaNodePool CRDs and builds
# out the combined controller+broker StatefulSet (no ZooKeeper).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="fraud-detection"

# FIX: removed duplicate B= line that had a typo (\033[0;34d instead of \033[0;34m).
# Having both lines was harmless (second overwrote first) but confusing.
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${B}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${G}[OK]${NC}    $*"; }
log_warn() { echo -e "${Y}[SKIP]${NC}  $*"; }
log_err()  { echo -e "${R}[ERR]${NC}   $*"; }

kafka_ready() {
    local ready
    ready=$(kubectl get kafka fraud-kafka \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [[ "$ready" == "True" ]]
}

schema_registry_ready() {
    # Check deployment is available AND /subjects endpoint actually responds.
    # A pod can be Running (container started) but not yet serving HTTP — the
    # /subjects check is the only reliable signal that SR is fully initialised.
    local avail
    avail=$(kubectl get deployment schema-registry \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
    [[ "${avail:-0}" -ge 1 ]] || return 1

    local sr_pod
    sr_pod=$(kubectl get pod -l app=schema-registry \
        -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -z "$sr_pod" ]] && return 1

    kubectl exec "${sr_pod}" -n "${NAMESPACE}" -- \
        curl -sf --max-time 5 http://localhost:8081/subjects &>/dev/null
}

step_fully_done() {
    kafka_ready || return 1
    # Verify topics were created (at least 4)
    local topic_count
    topic_count=$(kubectl get kafkatopics -n "${NAMESPACE}" \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [[ "${topic_count:-0}" -ge 4 ]] || return 1
    # Verify Schema Registry is actually serving requests
    schema_registry_ready || return 1
}

# ── Already fully done? ────────────────────────────────────────
# NOTE: We check ALL three conditions (Kafka + topics + SR) before skipping.
# Checking Kafka alone caused a false "done" on retry when SR was still
# starting — the script exited 0 without verifying SR, and the pipeline
# proceeded with a broken Schema Registry.
if step_fully_done; then
    log_warn "Kafka + topics + Schema Registry all Ready — skipping."
    exit 0
fi

# ── Deploy KafkaNodePool + Kafka CRDs ─────────────────────────
# kafka-cluster.yaml now contains:
#   - KafkaNodePool (combined controller+broker, 3 replicas)
#   - Kafka CR with KRaft annotations (no ZooKeeper)
#   - ConfigMap for JMX metrics
log_info "Applying KafkaNodePool + Kafka cluster manifests (KRaft mode)..."
kubectl apply -f "${ROOT_DIR}/k8s/03-kafka/kafka-cluster.yaml"

# ── Wait — Strimzi needs time to reconcile KRaft metadata ────
# KRaft bootstrap takes slightly longer than ZK on first run because
# the controller quorum must complete an initial leader election
# before brokers can register. Allow 6 minutes.
log_info "Waiting for Kafka cluster to be Ready (KRaft init, ~3–5 minutes)..."
kubectl wait kafka/fraud-kafka \
    --for=condition=Ready \
    -n "${NAMESPACE}" \
    --timeout=360s

log_ok "Kafka cluster Ready."

# ── Wait for entity operator ───────────────────────────────────
# FIX: The Kafka CR reaches Ready=True before the entity-operator pod
# (topic-operator + user-operator containers) have passed their readiness
# probes.  Proceeding immediately causes later steps to add I/O load
# (image builds, Flink deploy) while the user-operator is still trying
# to establish its first Kafka TLS connection — starving its health
# threads and triggering CrashLoopBackOff.
#
# Wait up to 3 minutes for the entity-operator deployment to be Available.
# If it never becomes Available we warn (not fail) — topics can still work
# even without a healthy entity-operator for the purposes of this demo.
log_info "Waiting for Kafka entity operator to become Available (up to 3 minutes)..."
if kubectl wait --for=condition=available deployment/fraud-kafka-entity-operator \
    -n "${NAMESPACE}" \
    --timeout=180s 2>/dev/null; then
    log_ok "Entity operator Available."
else
    log_warn "Entity operator did not reach Available in 180s."
    log_warn "user-operator may still be cycling — check logs:"
    log_warn "  kubectl logs -n ${NAMESPACE} deploy/fraud-kafka-entity-operator -c user-operator"
    log_warn "Continuing — Kafka topics will still be created via the CRD reconciler."
fi
log_info "Creating KafkaTopic CRDs + Schema Registry + Kafka UI..."
kubectl apply -f "${ROOT_DIR}/k8s/03-kafka/kafka-topics.yaml"

# ── Wait for Schema Registry ───────────────────────────────────
# Two-phase: (1) wait for Deployment Available, (2) poll /subjects.
# The Deployment Available condition fires once the container starts,
# but SR is still initialising its Kafka consumer group for several
# seconds after that. The /subjects check is the only reliable signal
# that SR is fully ready to serve requests.
log_info "Waiting for Schema Registry deployment to become Available..."
kubectl wait --for=condition=available deployment/schema-registry \
    -n "${NAMESPACE}" --timeout=120s
log_ok "Schema Registry rolled out."

log_info "Verifying Schema Registry /subjects endpoint..."
SR_POD=$(kubectl get pod -l app=schema-registry \
    -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
SR_OK=false
for i in $(seq 1 18); do   # 18 × 5s = 90s
    if kubectl exec "${SR_POD}" -n "${NAMESPACE}" -- \
           curl -sf --max-time 5 http://localhost:8081/subjects &>/dev/null; then
        SR_OK=true
        break
    fi
    log_info "  /subjects not ready yet (attempt ${i}/18) — retrying in 5s..."
    sleep 5
done

if ! $SR_OK; then
    log_err "Schema Registry /subjects did not respond after 90s."
    log_err "Check logs: kubectl logs -n ${NAMESPACE} deploy/schema-registry"
    exit 1
fi
log_ok "Schema Registry /subjects is responding."

# ── Verify broker count ───────────────────────────────────────
# With KRaft + KafkaNodePool (pool name "kafka"), pods are named
# fraud-kafka-kafka-{0,1,2} and labeled strimzi.io/name=fraud-kafka-kafka —
# same label as ZK mode, so this selector continues to work unchanged.
BROKER_COUNT=$(kubectl get pod \
    -l strimzi.io/name=fraud-kafka-kafka \
    -n "${NAMESPACE}" \
    --no-headers 2>/dev/null | wc -l | tr -d ' ')

log_ok "Kafka ready with ${BROKER_COUNT} combined controller+broker pod(s)."
log_info "  Kafka bootstrap:   fraud-kafka-kafka-bootstrap.${NAMESPACE}:9092"
log_info "  Schema Registry:   http://schema-registry.${NAMESPACE}:8081"
log_info "  Kafka UI:          http://localhost:8080"
log_info "  Mode:              KRaft (no ZooKeeper)"

# ── List created topics ────────────────────────────────────────
log_info "Waiting for topic CRDs to reconcile..."
sleep 10
TOPICS=$(kubectl get kafkatopics -n "${NAMESPACE}" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)
log_ok "Topics created: ${TOPICS}"