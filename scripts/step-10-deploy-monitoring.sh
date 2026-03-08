#!/usr/bin/env bash
# step-10-deploy-monitoring.sh
# Deploys: Prometheus (metrics), Grafana (dashboards), Trino (SQL over Iceberg).
# All services are exposed via NodePort to localhost.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
NAMESPACE="fraud-detection"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; NC='\033[0m'
log_info() { echo -e "${B}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${G}[OK]${NC}    $*"; }
log_warn() { echo -e "${Y}[SKIP]${NC}  $*"; }
log_err()  { echo -e "${R}[ERR]${NC}   $*"; }

monitoring_ready() {
    local grafana_phase prometheus_phase
    grafana_phase=$(kubectl get pod \
        -l app=grafana -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    prometheus_phase=$(kubectl get pod \
        -l app=prometheus -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    [[ "$grafana_phase" == "Running" && "$prometheus_phase" == "Running" ]]
}

# ── Already running? ───────────────────────────────────────────
if monitoring_ready; then
    log_warn "Monitoring stack already running — skipping."
    exit 0
fi

# ── Deploy Prometheus + Grafana ────────────────────────────────
log_info "Deploying Prometheus + Grafana..."
kubectl apply -f "${ROOT_DIR}/k8s/06-monitoring/monitoring.yaml"

# ── Verify Iceberg REST Catalog ────────────────────────────────
# The REST catalog is deployed in step-08 (Flink dependency).
# kubectl apply is idempotent — this is a no-op if already running,
# and a safety net if step-10 is run standalone.
log_info "Ensuring Iceberg REST catalog is deployed..."
kubectl apply -f "${ROOT_DIR}/k8s/04-flink/iceberg-rest-catalog.yaml"
kubectl wait --for=condition=available deployment/iceberg-rest-catalog     -n "${NAMESPACE}" --timeout=120s
log_ok "Iceberg REST catalog ready."

# ── Deploy Trino ───────────────────────────────────────────────
log_info "Deploying Trino..."
kubectl apply -f "${ROOT_DIR}/k8s/07-trino/trino.yaml"

# ── Wait for Grafana ───────────────────────────────────────────
log_info "Waiting for Grafana..."
kubectl wait --for=condition=available deployment/grafana \
    -n "${NAMESPACE}" --timeout=120s
log_ok "Grafana ready."

# ── Wait for Prometheus ────────────────────────────────────────
log_info "Waiting for Prometheus..."
kubectl wait --for=condition=available deployment/prometheus \
    -n "${NAMESPACE}" --timeout=120s
log_ok "Prometheus ready."

# ── Wait for Trino ─────────────────────────────────────────────
log_info "Waiting for Trino (downloads catalog config, takes ~60s)..."
kubectl wait --for=condition=available deployment/trino \
    -n "${NAMESPACE}" --timeout=180s
log_ok "Trino ready."

# ── Verify Prometheus is scraping ─────────────────────────────
log_info "Checking Prometheus targets..."
PROM_POD=$(kubectl get pod \
    -l app=prometheus -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [[ -n "$PROM_POD" ]]; then
    TARGET_COUNT=$(kubectl exec "${PROM_POD}" -n "${NAMESPACE}" -- \
        wget -qO- "http://localhost:9090/api/v1/targets" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); \
          print(len(d.get('data',{}).get('activeTargets',[])))" 2>/dev/null || echo "?")
    log_ok "Prometheus active targets: ${TARGET_COUNT}"
fi

log_ok "Monitoring stack deployed."
echo ""
log_info "  Grafana    → http://localhost:3000   (admin / admin)"
log_info "  Prometheus → http://localhost:9090"
log_info "  Trino SQL  → http://localhost:8083"
echo ""
log_info "  Useful Trino query:"
log_info "  SELECT * FROM iceberg.fraud_db.fraud_scores"
log_info "           WHERE fraud_detected=true LIMIT 20;"