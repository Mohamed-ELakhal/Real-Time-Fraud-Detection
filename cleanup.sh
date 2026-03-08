#!/usr/bin/env bash
# ============================================================
#  Fraud Detection Pipeline — cleanup.sh
#  Smart teardown with light, full, and step-targeted modes.
# ============================================================

set +e

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'
TICK="${G}✔${NC}"; SKIP="${Y}⊘${NC}"; CROSS="${R}✘${NC}"

PROJECT_NAME="Real-Time Fraud Detection Pipeline"
CLUSTER_NAME="fraud-detection"
NAMESPACE="fraud-detection"

MODE=""
AUTO_YES=false
UP_TO_STEP=11
TIMEOUT_NS=120

log_info() { echo -e "${B}[INFO]${NC}  $*"; }
log_ok()   { echo -e "${G}[OK]${NC}    $*"; }
log_warn() { echo -e "${Y}[SKIP]${NC}  $*"; }
log_err()  { echo -e "${R}[ERR]${NC}   $*"; }
log_sec()  { echo -e "\n${W}── $* ──${NC}"; }
separator(){ echo -e "${DIM}──────────────────────────────────────────────────────────────${NC}"; }
big_sep()  { echo -e "\n${C}══════════════════════════════════════════════════════════════${NC}\n"; }

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode|-m)       MODE="$2";         shift 2 ;;
            --up-to-step)    UP_TO_STEP="$2";   shift 2 ;;
            --yes|-y)        AUTO_YES=true;      shift   ;;
            --help|-h)       print_help; exit 0          ;;
            *)  log_err "Unknown argument: $1"; echo "Run --help for usage."; exit 1 ;;
        esac
    done
}

print_help() {
    cat <<EOF

${W}${PROJECT_NAME} — cleanup.sh${NC}

${W}MODES${NC}
  light   Remove all Kubernetes workloads while preserving the Kind
          cluster, all PVCs, and cluster-scoped CRDs/ClusterRoles.

  full    Destroy everything: all workloads, namespaces, PVCs, CRDs,
          ClusterRoles, and the Kind cluster itself.

${W}USAGE${NC}
  ./cleanup.sh                          Interactive menu
  ./cleanup.sh --mode light             Remove services, keep cluster and PVCs
  ./cleanup.sh --mode full              Full teardown (destructive)
  ./cleanup.sh --mode full --yes        Non-interactive full teardown
  ./cleanup.sh --up-to-step 8          Tear down from Flink downward
  ./cleanup.sh --help

${W}STEP MAP${NC} (cleanup runs highest → lowest)
  11  E2E Validation         (no K8s resources to clean)
  10  Monitoring             (Prometheus + Grafana + Trino)
   9  Transaction Producer
   8  Flink Job              (FlinkDeployment CRD)
   7  Docker Images          (removed from kind nodes)
   6  Kafka Cluster          (Kafka CRD + Topics + Schema Registry + UI)
   5  MinIO Tenant           (Tenant CRD + buckets)
   4  Operators              (Strimzi + Flink Operator + MinIO Operator)
   3  Kind Cluster           (full mode only)
   2  Pre-flight             (no K8s resources)
   1  Prerequisites          (tools NOT removed)

EOF
}

interactive_menu() {
    big_sep
    echo -e "${W}  ${PROJECT_NAME} — Cleanup${NC}"
    big_sep

    echo -e "  Choose a cleanup mode:\n"
    echo -e "  ${W}1)${NC} ${C}Light${NC} — remove all services, keep Kind cluster and PVCs"
    echo -e "       ${DIM}Faster redeploy: images cached, storage survives (~5–10 min)${NC}"
    echo ""
    echo -e "  ${W}2)${NC} ${R}Full${NC}  — destroy everything including the Kind cluster"
    echo -e "       ${DIM}Complete reset. Redeploy takes ~40–60 min (fresh pulls).${NC}"
    echo ""
    echo -e "  ${W}3)${NC} Partial — tear down from a specific step downward"
    echo ""
    echo -e "  ${W}4)${NC} Exit without cleaning"
    echo ""
    read -rp "  Choice [1-4]: " choice
    echo ""

    case "$choice" in
        1) MODE="light" ;;
        2)
            MODE="full"
            echo -e "${R}  ⚠ This permanently destroys the Kind cluster and ALL data.${NC}"
            read -rp "  Type 'destroy' to confirm: " confirm
            [[ "$confirm" == "destroy" ]] || { log_info "Aborted."; exit 0; }
            ;;
        3)
            echo -e "\n  Step numbers (cleanup runs downward from chosen step):"
            printf "    %2d  %s\n" \
                10 "Monitoring (Prometheus + Grafana + Trino)" \
                9  "Transaction Producer" \
                8  "Flink Job" \
                6  "Kafka Cluster + Topics" \
                5  "MinIO Tenant" \
                4  "Operators (Strimzi + Flink + MinIO)" \
                3  "Kind Cluster"
            echo ""
            read -rp "  Clean up from step [3-11]: " UP_TO_STEP
            [[ "$UP_TO_STEP" =~ ^[0-9]+$ ]] && \
            [[ $UP_TO_STEP -ge 3 ]] && \
            [[ $UP_TO_STEP -le 11 ]] || { log_err "Invalid step."; exit 1; }
            echo ""
            echo -e "  Mode for this partial cleanup:"
            echo -e "  ${W}1)${NC} Light  (keep cluster + PVCs)"
            echo -e "  ${W}2)${NC} Full   (delete PVCs in scope too)"
            read -rp "  Choice [1/2]: " mmode
            [[ "$mmode" == "2" ]] && MODE="full" || MODE="light"
            ;;
        4) log_info "Cleanup cancelled."; exit 0 ;;
        *) log_err "Invalid choice."; exit 1 ;;
    esac
}

ns_exists()           { kubectl get namespace "$1" &>/dev/null; }
resource_exists()     { kubectl get "$1" "$2" ${3:+-n "$3"} &>/dev/null; }
helm_release_exists() { helm list -n "$2" 2>/dev/null | grep -q "^$1"; }
cluster_exists()      { kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; }

safe_delete() {
    local res="$1" name="$2" ns="$3"
    local ns_flag=(); [[ -n "$ns" ]] && ns_flag=(-n "$ns")
    if resource_exists "$res" "$name" "$ns"; then
        log_info "Deleting ${res}/${name}${ns:+ in $ns}..."
        kubectl delete "$res" "$name" "${ns_flag[@]}" \
            --ignore-not-found=true --timeout=90s 2>&1 | grep -v "NotFound" || true
        log_ok "Deleted ${res}/${name}."
    else
        log_warn "${res}/${name}${ns:+ in $ns} — not found, skipped."
    fi
}

safe_delete_namespace() {
    local ns="$1"
    if ns_exists "$ns"; then
        log_info "Deleting namespace '${ns}'..."
        kubectl delete namespace "$ns" --ignore-not-found=true 2>&1 | grep -v "NotFound" || true
        local t=0
        while ns_exists "$ns" && [[ $t -lt $TIMEOUT_NS ]]; do sleep 2; t=$((t+2)); done
        if ns_exists "$ns"; then
            log_warn "Namespace '${ns}' still terminating after ${TIMEOUT_NS}s."
        else
            log_ok "Namespace '${ns}' deleted."
        fi
    else
        log_warn "Namespace '${ns}' — not found, skipped."
    fi
}

safe_delete_pvcs() {
    local ns="$1" selector="${2:-}"
    ns_exists "$ns" || { log_warn "Namespace '${ns}' not found — skipping PVC cleanup."; return; }
    local sel_flag=(); [[ -n "$selector" ]] && sel_flag=(-l "$selector")
    local pvcs
    pvcs=$(kubectl get pvc -n "$ns" "${sel_flag[@]}" \
        -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    if [[ -z "$pvcs" ]]; then
        log_warn "No PVCs found in '${ns}'${selector:+ matching $selector} — skipped."; return
    fi
    for pvc in $pvcs; do
        log_info "Deleting PVC ${pvc} in ${ns}..."
        kubectl delete pvc "$pvc" -n "$ns" --ignore-not-found=true --timeout=60s 2>&1 \
            | grep -v "NotFound" || true
    done
    log_ok "PVCs deleted in '${ns}'."
}

safe_delete_cluster_resources() {
    local res_type="$1" label_substr="$2"
    local items
    items=$(kubectl get "${res_type}" -o name 2>/dev/null \
        | grep "${label_substr}" || echo "")
    if [[ -z "$items" ]]; then
        log_warn "No ${res_type} matching '${label_substr}' — skipped."
        return
    fi
    echo "$items" | xargs -r kubectl delete --ignore-not-found=true --timeout=60s \
        2>&1 | grep -v "NotFound" || true
    log_ok "Deleted ${res_type} matching '${label_substr}'."
}

clean_steps_1_2() {
    log_sec "Steps 1–2 — Prerequisites + Pre-flight"
    log_warn "System tools (docker, kubectl, helm, kind) are NEVER removed automatically."
    echo ""
}

clean_monitoring() {
    log_sec "Step 10 — Monitoring (Prometheus + Grafana + Trino)"
    ns_exists "${NAMESPACE}" || { log_warn "Namespace not found — skipped."; echo ""; return; }

    for dep in grafana prometheus trino; do
        safe_delete "deployment" "$dep" "${NAMESPACE}"
    done
    for svc in grafana prometheus trino; do
        safe_delete "service" "$svc" "${NAMESPACE}"
    done
    safe_delete "configmap" "prometheus-config"               "${NAMESPACE}"
    safe_delete "configmap" "grafana-datasources"             "${NAMESPACE}"
    safe_delete "configmap" "grafana-dashboards-provisioning" "${NAMESPACE}"
    safe_delete "configmap" "trino-catalog-config"            "${NAMESPACE}"

    for dep in grafana prometheus trino; do
        kubectl wait --for=delete pod -l "app=${dep}" \
            -n "${NAMESPACE}" --timeout=60s 2>&1 | grep -v "no matching" || true
    done
    echo ""
}

clean_producer() {
    log_sec "Step 9 — Transaction Producer"
    ns_exists "${NAMESPACE}" || { log_warn "Namespace not found — skipped."; echo ""; return; }
    safe_delete "deployment" "transaction-producer" "${NAMESPACE}"
    kubectl wait --for=delete pod -l app=transaction-producer \
        -n "${NAMESPACE}" --timeout=60s 2>&1 | grep -v "no matching" || true
    echo ""
}

clean_flink_job() {
    log_sec "Step 8 — Flink Fraud Detection Job"
    ns_exists "${NAMESPACE}" || { log_warn "Namespace not found — skipped."; echo ""; return; }

    if resource_exists "flinkdeployment" "fraud-scoring-job" "${NAMESPACE}"; then
        log_info "Deleting FlinkDeployment (operator will perform graceful shutdown)..."
        kubectl delete flinkdeployment fraud-scoring-job \
            -n "${NAMESPACE}" --timeout=120s 2>&1 | grep -v "NotFound" || true
        log_ok "FlinkDeployment deleted."
    else
        log_warn "FlinkDeployment 'fraud-scoring-job' not found — skipped."
    fi

    kubectl wait --for=delete pod -l component=jobmanager \
        -n "${NAMESPACE}" --timeout=90s 2>&1 | grep -v "no matching" || true
    kubectl wait --for=delete pod -l component=taskmanager \
        -n "${NAMESPACE}" --timeout=90s 2>&1 | grep -v "no matching" || true

    if [[ "$MODE" == "full" ]]; then
        local minio_pod
        minio_pod=$(kubectl get pod -l v1.min.io/tenant=fraud-minio \
            -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
        if [[ -n "$minio_pod" ]]; then
            kubectl exec "${minio_pod}" -n "${NAMESPACE}" -- \
                mc rm --recursive --force local/fraud-checkpoints/ 2>/dev/null || true
            log_ok "Flink checkpoints cleared from MinIO."
        fi
    else
        log_warn "[light] Keeping Flink checkpoints in MinIO fraud-checkpoints bucket."
    fi
    echo ""
}

clean_images() {
    log_sec "Step 7 — Docker Images (kind nodes)"
    if [[ "$MODE" == "full" ]]; then
        for node in $(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null); do
            log_info "Removing fraud-detection images from node: ${node}..."
            for img in "fraud-detection/producer" "fraud-detection/flink-jobs"; do
                image_id=$(docker exec "${node}" crictl images 2>/dev/null \
                    | grep "$img" | awk '{print $3}' | head -1 || echo "")
                if [[ -n "$image_id" ]]; then
                    docker exec "${node}" crictl rmi "$image_id" 2>/dev/null || true
                    log_ok "  Removed ${img} from ${node}."
                else
                    log_warn "  ${img} not found on ${node}."
                fi
            done
        done
    else
        log_warn "[light] Keeping Docker images in kind cluster (speeds up redeploy)."
    fi
    echo ""
}

clean_kafka() {
    log_sec "Step 6 — Kafka Cluster + Topics + Schema Registry + UI"
    ns_exists "${NAMESPACE}" || { log_warn "Namespace not found — skipped."; echo ""; return; }

    for dep in kafka-ui schema-registry; do
        safe_delete "deployment" "$dep" "${NAMESPACE}"
        safe_delete "service"    "$dep" "${NAMESPACE}"
    done

    local topics
    topics=$(kubectl get kafkatopic -n "${NAMESPACE}" -o name 2>/dev/null || echo "")
    if [[ -n "$topics" ]]; then
        log_info "Deleting KafkaTopic CRDs..."
        echo "$topics" | xargs -r kubectl delete -n "${NAMESPACE}" \
            --ignore-not-found=true --timeout=60s 2>&1 | grep -v "NotFound" || true
        log_ok "Kafka topics deleted."
    else
        log_warn "No KafkaTopic CRDs found."
    fi

    safe_delete "kafka" "fraud-kafka" "${NAMESPACE}"

    kubectl wait --for=delete pod -l strimzi.io/cluster=fraud-kafka \
        -n "${NAMESPACE}" --timeout=120s 2>&1 | grep -v "no matching" || true

    if [[ "$MODE" == "full" ]]; then
        safe_delete_pvcs "${NAMESPACE}" "strimzi.io/cluster=fraud-kafka"
        safe_delete "configmap" "kafka-metrics-config" "${NAMESPACE}"
    else
        log_warn "[light] Keeping Kafka PVCs."
    fi
    echo ""
}

clean_minio() {
    log_sec "Step 5 — MinIO Tenant"
    ns_exists "${NAMESPACE}" || { log_warn "Namespace not found — skipped."; echo ""; return; }

    safe_delete "tenant"  "fraud-minio"    "${NAMESPACE}"
    safe_delete "service" "minio-nodeport" "${NAMESPACE}"

    kubectl wait --for=delete pod -l v1.min.io/tenant=fraud-minio \
        -n "${NAMESPACE}" --timeout=90s 2>&1 | grep -v "no matching" || true

    if [[ "$MODE" == "full" ]]; then
        safe_delete_pvcs "${NAMESPACE}" "v1.min.io/tenant=fraud-minio"
        log_ok "MinIO PVCs deleted."
    else
        log_warn "[light] Keeping MinIO PVCs."
    fi
    echo ""
}

clean_operators() {
    log_sec "Step 4 — Operators (Strimzi + Flink K8s + MinIO)"

    # ── Strimzi (manifest-installed, NOT Helm) ─────────────────
    # Strimzi is installed via raw manifest + kubectl apply, not Helm,
    # so helm_release_exists will always return false. Use kubectl instead.
    if kubectl get deployment strimzi-cluster-operator \
            -n "${NAMESPACE}" &>/dev/null; then
        log_info "Removing Strimzi operator (manifest-installed)..."
        # Delete the deployment directly; CRDs cleaned up below in full mode
        kubectl delete deployment strimzi-cluster-operator \
            -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
        # Also clean up Strimzi RBAC that the manifest created
        kubectl get clusterrolebinding -o name 2>/dev/null \
            | grep strimzi \
            | xargs kubectl delete --ignore-not-found=true 2>/dev/null || true
        kubectl get clusterrole -o name 2>/dev/null \
            | grep strimzi \
            | xargs kubectl delete --ignore-not-found=true 2>/dev/null || true
        kubectl delete role strimzi-lease-operator \
            -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
        kubectl delete rolebinding strimzi-lease-operator \
            -n "${NAMESPACE}" --ignore-not-found=true 2>/dev/null || true
        log_ok "Strimzi operator removed."
    else
        log_warn "Strimzi operator not found — skipped."
    fi

    # ── Flink operator (Helm-installed) ───────────────────────
    if helm_release_exists "flink-kubernetes-operator" "${NAMESPACE}"; then
        log_info "Uninstalling Flink Kubernetes Operator..."
        helm uninstall flink-kubernetes-operator -n "${NAMESPACE}" --wait 2>/dev/null || true
        log_ok "Flink operator uninstalled."
    else
        log_warn "Flink operator Helm release not found — skipped."
    fi

    # ── MinIO operator (Helm-installed) ───────────────────────
    if helm_release_exists "minio-operator" "minio-operator"; then
        log_info "Uninstalling MinIO Operator..."
        helm uninstall minio-operator -n minio-operator --wait 2>/dev/null || true
        log_ok "MinIO operator uninstalled."
    else
        log_warn "MinIO operator Helm release not found — skipped."
    fi

    if [[ "$MODE" == "full" ]]; then
        log_info "Removing cluster-scoped Strimzi CRDs..."
        safe_delete_cluster_resources "crd" "kafka.strimzi.io"
        safe_delete_cluster_resources "crd" "strimzi.io"

        log_info "Removing cluster-scoped Flink resources..."
        safe_delete_cluster_resources "clusterrolebinding" "flink"
        safe_delete_cluster_resources "clusterrole"        "flink"
        safe_delete_cluster_resources "crd"                "flink.apache.org"

        log_info "Removing cluster-scoped MinIO resources..."
        safe_delete_cluster_resources "crd" "minio.min.io"

        safe_delete_namespace "minio-operator"
    else
        log_warn "[light] Keeping CRDs and ClusterRoles."
    fi
    echo ""
}

clean_kind_cluster() {
    log_sec "Step 3 — Kind Cluster"
    if cluster_exists; then
        log_info "Deleting Kind cluster '${CLUSTER_NAME}'..."
        kind delete cluster --name "${CLUSTER_NAME}" 2>&1 || true
        log_ok "Kind cluster '${CLUSTER_NAME}' deleted."
    else
        log_warn "Kind cluster '${CLUSTER_NAME}' not found — skipped."
    fi
    echo ""
}

run_cleanup() {
    local mode_label
    [[ "$MODE" == "full" ]] && mode_label="${R}FULL${NC}" || mode_label="${Y}LIGHT${NC}"

    big_sep
    echo -e "${W}  ${PROJECT_NAME} — Cleanup (${mode_label}${W})${NC}"
    big_sep

    local start_ts; start_ts=$(date +%s)

    [[ $UP_TO_STEP -ge 1 ]] && clean_steps_1_2

    [[ $UP_TO_STEP -ge 11 ]] && {
        log_sec "Step 11 — E2E Validation"
        log_warn "No K8s resources to clean for validation step."
        echo ""
    }

    [[ $UP_TO_STEP -ge 10 ]] && clean_monitoring
    [[ $UP_TO_STEP -ge 9  ]] && clean_producer
    [[ $UP_TO_STEP -ge 8  ]] && clean_flink_job
    [[ $UP_TO_STEP -ge 7  ]] && clean_images
    [[ $UP_TO_STEP -ge 6  ]] && clean_kafka
    [[ $UP_TO_STEP -ge 5  ]] && clean_minio
    [[ $UP_TO_STEP -ge 4  ]] && clean_operators

    if [[ $UP_TO_STEP -ge 3 ]]; then
        if [[ "$MODE" == "full" ]]; then
            clean_kind_cluster
        else
            log_sec "Step 3 — Kind Cluster"
            log_warn "[light] Kind cluster '${CLUSTER_NAME}' preserved."
            echo -e "  ${DIM}Fast redeploy:${NC}"
            echo -e "  ./startup.sh --from 5   ${DIM}# redeploy MinIO onward${NC}"
            echo -e "  ./startup.sh --from 6   ${DIM}# redeploy Kafka onward${NC}"
            echo ""
        fi
    fi

    local end_ts; end_ts=$(date +%s)
    local elapsed=$(( end_ts - start_ts ))
    local mins=$(( elapsed / 60 )) secs=$(( elapsed % 60 ))

    big_sep
    if [[ "$MODE" == "full" ]]; then
        echo -e "${G}  ✔ Full cleanup complete — ${mins}m ${secs}s${NC}"
        echo ""
        echo -e "  ${W}./startup.sh${NC}           ${DIM}# full redeploy from scratch${NC}"
        echo -e "  ${W}./startup.sh --from 3${NC}  ${DIM}# skip tool install${NC}"
    else
        echo -e "${G}  ✔ Light cleanup complete — ${mins}m ${secs}s${NC}"
        echo ""
        echo -e "  ${W}./startup.sh --from 4${NC}  ${DIM}# reinstall operators onward${NC}"
        echo -e "  ${W}./startup.sh --from 6${NC}  ${DIM}# redeploy Kafka onward${NC}"
        echo -e "  ${W}./startup.sh --from 8${NC}  ${DIM}# redeploy Flink + producer + monitoring${NC}"
    fi
    big_sep
}

main() {
    parse_args "$@"
    [[ -z "$MODE" ]] && interactive_menu
    [[ "$MODE" == "light" || "$MODE" == "full" ]] || {
        log_err "Invalid mode: '${MODE}'. Use 'light' or 'full'."; exit 1
    }

    if ! $AUTO_YES; then
        echo ""
        echo -e "  Mode:       ${W}${MODE^^}${NC}"
        echo -e "  Up-to-step: ${W}${UP_TO_STEP}${NC}"
        [[ "$MODE" == "full" ]] && \
            echo -e "  ${R}⚠ This will permanently delete the Kind cluster and all data volumes.${NC}"
        echo ""
        read -rp "  Proceed? (yes/no): " confirm
        [[ "$confirm" =~ ^[Yy][Ee][Ss]$ ]] || { log_info "Aborted."; exit 0; }
    fi

    run_cleanup
}

main "$@"
