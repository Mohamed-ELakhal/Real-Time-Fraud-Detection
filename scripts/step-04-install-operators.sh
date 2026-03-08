#!/usr/bin/env bash
# step-04-install-operators.sh
# Installs Strimzi (Kafka), Flink Kubernetes Operator, and MinIO Operator.
#
# Strimzi is installed via raw manifest (not Helm) with namespace substitution
# via sed — this avoids the RoleBinding conflict that Helm triggers when any
# prior install attempt left behind cluster-scoped RBAC resources.
#
# BUG FIX (env var conflict):
#   The Strimzi 0.41.0 manifest already sets STRIMZI_LEADER_ELECTION_LEASE_NAMESPACE
#   and STRIMZI_LEADER_ELECTION_IDENTITY via valueFrom.fieldRef (downward API).
#   Using `kubectl set env` to add a `value:` field on top of an existing `valueFrom:`
#   creates an invalid deployment spec (K8s forbids both fields simultaneously).
#   On retry, `kubectl apply` of the manifest tries to restore `valueFrom:` but the
#   field manager conflict causes: "valueFrom: may not be specified when value is not empty".
#   Fix: never use kubectl set env on these already-correctly-configured env vars.
#   Only STRIMZI_FEATURE_GATES (a new env var) is injected via kubectl set env.
#
# KRAFT SUPPORT:
#   Adds STRIMZI_FEATURE_GATES=+UseKRaft so the operator manages KRaft-mode
#   Kafka clusters. KafkaNodePools graduated to STABLE in Strimzi 0.41.0 —
#   it is always-on and must NOT be listed as a feature gate (the operator
#   throws InvalidConfigurationException: "Unknown feature gate KafkaNodePools").

set -euo pipefail

NAMESPACE="fraud-detection"
STRIMZI_VERSION="0.41.0"
FLINK_OPERATOR_VERSION="1.8.0"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${B}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${G}[OK]${NC}    $*"; }
log_warn() { echo -e "${Y}[SKIP]${NC}  $*"; }
log_err()  { echo -e "${R}[ERR]${NC}   $*"; }

# ── 1. Strimzi (manifest install, not Helm) ────────────────────

strimzi_ready() {
    kubectl get deployment strimzi-cluster-operator \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "^1$"
}

if strimzi_ready; then
    log_warn "Strimzi operator already running — skipping."
else
    log_info "Cleaning up any stale Strimzi cluster-scoped RBAC..."
    kubectl get clusterrolebinding -o name 2>/dev/null \
        | grep strimzi \
        | xargs kubectl delete --ignore-not-found=true 2>/dev/null || true
    kubectl get clusterrole -o name 2>/dev/null \
        | grep strimzi \
        | xargs kubectl delete --ignore-not-found=true 2>/dev/null || true
    log_ok "Stale Strimzi RBAC cleared."

    # ── CRITICAL: delete the deployment itself if it exists in a broken state.
    # On retry, a previous `kubectl set env` may have left the deployment with
    # both `value:` and `valueFrom:` on the same env var — which is invalid and
    # causes `kubectl apply` to fail with "may not be specified when value is not empty".
    # Deleting the deployment lets the manifest create it cleanly.
    if kubectl get deployment strimzi-cluster-operator -n "${NAMESPACE}" &>/dev/null 2>&1; then
        log_info "Removing existing Strimzi deployment (may be in invalid state from previous attempt)..."
        kubectl delete deployment strimzi-cluster-operator \
            -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
        log_ok "Existing deployment removed."
    fi

    MANIFEST_URL="https://github.com/strimzi/strimzi-kafka-operator/releases/download/${STRIMZI_VERSION}/strimzi-cluster-operator-${STRIMZI_VERSION}.yaml"
    MANIFEST_FILE="/tmp/strimzi-${STRIMZI_VERSION}.yaml"

    log_info "Downloading Strimzi v${STRIMZI_VERSION} manifest..."
    if ! curl -fsSL --max-time 60 -o "${MANIFEST_FILE}" "${MANIFEST_URL}" 2>/dev/null; then
        if [[ ! -f "${MANIFEST_FILE}" ]]; then
            log_err "Cannot download Strimzi manifest and no cache found. Check network."
            exit 1
        fi
        log_warn "Network unavailable — using cached manifest."
    fi
    log_ok "Manifest ready."

    log_info "Applying Strimzi manifest into namespace '${NAMESPACE}'..."
    # sed substitutes the 'myproject' placeholder in every ClusterRoleBinding
    # subject so the service account reference points to our namespace.
    sed "s/namespace: myproject/namespace: ${NAMESPACE}/g" "${MANIFEST_FILE}" | \
        kubectl apply -f - -n "${NAMESPACE}"
    log_ok "Strimzi manifest applied."

    log_info "Adding Lease RBAC (not included in the default Strimzi manifest)..."
    kubectl apply -f - <<YAML
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: strimzi-lease-operator
  namespace: ${NAMESPACE}
rules:
  - apiGroups: ["coordination.k8s.io"]
    resources: ["leases"]
    verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: strimzi-lease-operator
  namespace: ${NAMESPACE}
subjects:
  - kind: ServiceAccount
    name: strimzi-cluster-operator
    namespace: ${NAMESPACE}
roleRef:
  kind: Role
  name: strimzi-lease-operator
  apiGroup: rbac.authorization.k8s.io
YAML
    log_ok "Lease RBAC created."

    # ── Enable KRaft feature gates ─────────────────────────────
    # The Strimzi 0.41.0 manifest already sets the following env vars correctly
    # via the downward API (valueFrom.fieldRef) — DO NOT override with kubectl set env:
    #   STRIMZI_LEADER_ELECTION_LEASE_NAMESPACE → resolves to metadata.namespace
    #   STRIMZI_LEADER_ELECTION_IDENTITY        → resolves to metadata.name (POD_NAME)
    #   POD_NAME                                → resolves to metadata.name
    #
    # We only add STRIMZI_FEATURE_GATES, which is a genuinely new env var.
    # KafkaNodePools is stable in 0.41.0 — always-on, NOT listed as a gate.
    # UseKRaft is still a proper feature gate in 0.41.0 (graduates in 0.42.0).
    log_info "Enabling KRaft feature gate..."
    kubectl set env deployment/strimzi-cluster-operator \
        -n "${NAMESPACE}" \
        STRIMZI_FEATURE_GATES="+UseKRaft"
    log_ok "Feature gate enabled: +UseKRaft"

    log_info "Waiting for Strimzi operator to be ready (up to 3 minutes)..."
    kubectl rollout status deployment/strimzi-cluster-operator \
        -n "${NAMESPACE}" --timeout=180s

    # FIX: Raise the Strimzi operator memory limit from the manifest default of
    # 384Mi to 512Mi. At 384Mi the JVM heap is so constrained that GC pauses
    # make the /healthy and /ready HTTP endpoints intermittently unresponsive,
    # triggering the liveness probe and causing CrashLoopBackOff — even though
    # the operator process itself is fine (exits with code 0 on probe kill).
    log_info "Patching Strimzi operator memory limit to 512Mi (384Mi causes GC probe failures)..."
    kubectl patch deployment strimzi-cluster-operator \
        -n "${NAMESPACE}" \
        --type=json \
        -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/memory","value":"512Mi"},{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/memory","value":"512Mi"}]' \
        && log_ok "Memory limit patched to 512Mi." \
        || log_warn "Memory patch skipped (may already be correct)."

    # FIX: 15s was too short. On a loaded node the operator needs time to:
    # (1) bind its HTTP port, (2) acquire the Lease, (3) pass the readiness
    # probe. 45s gives enough headroom without being excessive.
    log_info "Waiting 45s for operator to acquire leader election lease and pass health probes..."
    sleep 45

    # Spot-check RBAC
    log_info "Verifying Strimzi RBAC..."
    kubectl auth can-i list kafkas \
        --as="system:serviceaccount:${NAMESPACE}:strimzi-cluster-operator" \
        -n "${NAMESPACE}" &>/dev/null \
        && log_ok "Can list Kafka CRs." \
        || log_warn "Cannot list Kafka CRs — RBAC may still be propagating."

    kubectl auth can-i get leases \
        --as="system:serviceaccount:${NAMESPACE}:strimzi-cluster-operator" \
        -n "${NAMESPACE}" &>/dev/null \
        && log_ok "Can manage Leases." \
        || log_warn "Cannot manage Leases."

    log_ok "Strimzi operator ready."
fi

# ── 2. Flink Kubernetes Operator ──────────────────────────────
flink_op_ready() {
    kubectl get deployment flink-kubernetes-operator \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "^1$"
}

if flink_op_ready; then
    log_warn "Flink Kubernetes Operator already running — skipping."
else
    FLINK_REPO_ALIAS="flink-operator-repo-${FLINK_OPERATOR_VERSION}"
    FLINK_REPO_URL="https://archive.apache.org/dist/flink/flink-kubernetes-operator-${FLINK_OPERATOR_VERSION}/"

    log_info "Adding Flink operator Helm repo (archive.apache.org)..."
    helm repo add "${FLINK_REPO_ALIAS}" "${FLINK_REPO_URL}" --force-update
    helm repo update "${FLINK_REPO_ALIAS}"

    log_info "Installing Flink Kubernetes Operator v${FLINK_OPERATOR_VERSION}..."
    # FIX: set explicit resource requests=limits to give the operator
    # Guaranteed QoS class. Without this it is BestEffort — the first
    # pod evicted when any node comes under memory pressure.
    # On a 16 GB laptop this caused exit 143 (SIGTERM from OOM killer)
    # repeatedly, making flink_op_ready() report 0 ready replicas and
    # triggering endless retries that consumed even more memory.
    helm upgrade --install flink-kubernetes-operator \
        "${FLINK_REPO_ALIAS}/flink-kubernetes-operator" \
        --namespace "${NAMESPACE}" \
        --set webhook.create=false \
        --set "operatorPod.resources.requests.memory=512Mi" \
        --set "operatorPod.resources.limits.memory=512Mi" \
        --set "operatorPod.resources.requests.cpu=250m" \
        --set "operatorPod.resources.limits.cpu=1" \
        --wait \
        --timeout 5m

    log_info "Waiting for Flink operator to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=flink-kubernetes-operator \
        -n "${NAMESPACE}" \
        --timeout=120s

    log_ok "Flink Kubernetes Operator ready."
fi

# ── 3. MinIO Operator ──────────────────────────────────────────
minio_op_ready() {
    kubectl get deployment minio-operator \
        -n minio-operator \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "^1$"
}

if minio_op_ready; then
    log_warn "MinIO Operator already running — skipping."
else
    log_info "Adding MinIO operator Helm repo..."
    helm repo add minio-operator https://operator.min.io/ --force-update 2>/dev/null

    log_info "Installing MinIO Operator..."
    helm upgrade --install minio-operator minio-operator/operator \
        --namespace minio-operator \
        --create-namespace \
        --wait \
        --timeout 5m

    log_info "Waiting for MinIO operator to be ready..."
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=operator \
        -n minio-operator \
        --timeout=120s

    log_ok "MinIO Operator ready."
fi

# ── Final summary ──────────────────────────────────────────────
echo ""
log_info "Operator status:"
kubectl get deployment strimzi-cluster-operator  -n "${NAMESPACE}"  --no-headers 2>/dev/null || true
kubectl get deployment flink-kubernetes-operator -n "${NAMESPACE}"  --no-headers 2>/dev/null || true
kubectl get deployment minio-operator            -n minio-operator  --no-headers 2>/dev/null || true
log_ok "All operators installed."
