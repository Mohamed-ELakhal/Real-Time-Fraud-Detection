#!/usr/bin/env bash
# ============================================================
#  Fraud Detection Pipeline — startup.sh
#  One-command deployment with intelligent step detection.
#
#  Usage:
#    ./startup.sh                   # Full deploy from step 1 → 11
#    ./startup.sh --from 3          # Resume from Kind cluster creation
#    ./startup.sh --from 6          # Resume from Kafka (operators already up)
#    ./startup.sh --only 11         # Run only end-to-end validation
#    ./startup.sh --dry-run         # Show what would run, touch nothing
#    ./startup.sh --yes             # Non-interactive (CI/CD mode)
#    ./startup.sh --retries 5       # More retry attempts per step
#    ./startup.sh --help
# ============================================================

set +e

# ── ANSI colours ──────────────────────────────────────────────
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'
B='\033[0;34m'; C='\033[0;36m'; W='\033[1;37m'
DIM='\033[2m'; NC='\033[0m'
TICK="${G}✔${NC}"; CROSS="${R}✘${NC}"; SKIP="${Y}⊘${NC}"

# ── Project identity ──────────────────────────────────────────
PROJECT_NAME="Real-Time Fraud Detection Pipeline"
CLUSTER_NAME="fraud-detection"
NAMESPACE="fraud-detection"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/scripts" && pwd)"
STATE_FILE="/tmp/.fraud_detection_state"

# ── Defaults ──────────────────────────────────────────────────
FROM_STEP=1
ONLY_STEP=""
DRY_RUN=false
AUTO_YES=false
MAX_RETRIES=3
RETRY_DELAY=15

# ── Step registry ─────────────────────────────────────────────
declare -A STEP_LABEL STEP_SCRIPT

STEP_LABEL[1]="Install Prerequisites"
STEP_LABEL[2]="System Pre-flight Checks"
STEP_LABEL[3]="Create Kind Cluster"
STEP_LABEL[4]="Install Operators (Strimzi + Flink + MinIO)"
STEP_LABEL[5]="Deploy MinIO Tenant"
STEP_LABEL[6]="Deploy Kafka Cluster + Topics"
STEP_LABEL[7]="Build & Load Docker Images"
STEP_LABEL[8]="Deploy Flink Fraud Detection Job"
STEP_LABEL[9]="Deploy Transaction Producer"
STEP_LABEL[10]="Deploy Monitoring (Prometheus + Grafana + Trino)"
STEP_LABEL[11]="End-to-End Validation"

STEP_SCRIPT[1]="step-01-install-prerequisites.sh"
STEP_SCRIPT[2]="step-02-preflight-checks.sh"
STEP_SCRIPT[3]="step-03-create-cluster.sh"
STEP_SCRIPT[4]="step-04-install-operators.sh"
STEP_SCRIPT[5]="step-05-deploy-minio.sh"
STEP_SCRIPT[6]="step-06-deploy-kafka.sh"
STEP_SCRIPT[7]="step-07-build-images.sh"
STEP_SCRIPT[8]="step-08-deploy-flink.sh"
STEP_SCRIPT[9]="step-09-deploy-producer.sh"
STEP_SCRIPT[10]="step-10-deploy-monitoring.sh"
STEP_SCRIPT[11]="step-11-e2e-validate.sh"

STEPS=(1 2 3 4 5 6 7 8 9 10 11)

# ── Logging ───────────────────────────────────────────────────
log_info()  { echo -e "${B}[INFO]${NC}  $*"; }
log_ok()    { echo -e "${G}[OK]${NC}    $*"; }
log_warn()  { echo -e "${Y}[WARN]${NC}  $*"; }
log_err()   { echo -e "${R}[ERROR]${NC} $*"; }
log_step()  { echo -e "\n${W}╔══ Step $1 · ${STEP_LABEL[$1]} ══╗${NC}"; }
log_skip()  { echo -e "  ${SKIP} ${DIM}Step $1 — ${STEP_LABEL[$1]} — already complete, skipping${NC}"; }
separator() { echo -e "${DIM}──────────────────────────────────────────────────────────────${NC}"; }
big_sep()   { echo -e "\n${C}══════════════════════════════════════════════════════════════${NC}\n"; }

# ── Argument parsing ──────────────────────────────────────────
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --from|-f)     FROM_STEP="$2";  shift 2 ;;
            --only|-o)     ONLY_STEP="$2";  FROM_STEP="$2"; shift 2 ;;
            --dry-run|-n)  DRY_RUN=true;    shift ;;
            --yes|-y)      AUTO_YES=true;   shift ;;
            --retries)     MAX_RETRIES="$2"; shift 2 ;;
            --help|-h)     print_help; exit 0 ;;
            *)  log_err "Unknown argument: $1"; echo "Run with --help for usage."; exit 1 ;;
        esac
    done
}

print_help() {
    cat <<EOF

${W}${PROJECT_NAME} — startup.sh${NC}

${W}USAGE${NC}
  ./startup.sh [OPTIONS]

${W}OPTIONS${NC}
  --from STEP         Resume from this step (skips all steps before it)
  --only STEP         Run exactly one step and exit
  --dry-run           Show which steps would run without executing anything
  --yes               Non-interactive mode — no confirmation prompts (CI/CD)
  --retries N         Max automatic retries per step (default: ${MAX_RETRIES})
  --help              Show this message

${W}STEP NUMBERS${NC}
$(for s in "${STEPS[@]}"; do printf "  %2d  %s\n" "$s" "${STEP_LABEL[$s]}"; done)

${W}EXAMPLES${NC}
  ./startup.sh                    # Full deploy from scratch (step 1 → 11)
  ./startup.sh --from 3           # Skip tool install, resume from Kind cluster
  ./startup.sh --from 6           # Operators up — resume from Kafka
  ./startup.sh --from 8           # Images built — redeploy Flink job only onward
  ./startup.sh --only 11          # Re-run end-to-end validation only
  ./startup.sh --only 7           # Rebuild Docker images only
  ./startup.sh --dry-run          # Preview what would run (no changes)
  ./startup.sh --yes              # Fully automated, no prompts (CI/CD)
  ./startup.sh --yes --from 3     # Automated deploy, skip prerequisite install

${W}FAILURE RECOVERY${NC}
  When a step fails after ${MAX_RETRIES} retries, an interactive menu offers:
    1) Retry this step
    2) Skip and continue  (may break later steps)
    3) Abort and clean up everything deployed so far
    4) Abort and keep state (for manual debugging)

  In --yes mode, an unrecoverable failure causes immediate abort.

${W}NOTES${NC}
  • Each step checks the live system state before running.
    Running ./startup.sh twice on a fully deployed system is a no-op.
  • Steps 1–2 are safe to re-run: installed tools are detected and skipped.
  • Step 7 (image build) re-runs if images are not found in the kind cluster.

EOF
}

# ── Script file verification ──────────────────────────────────
check_scripts() {
    log_info "Verifying deployment scripts in: ${SCRIPTS_DIR}"
    local missing=()
    local steps_to_check=("${STEPS[@]}")
    [[ -n "$ONLY_STEP" ]] && steps_to_check=("$ONLY_STEP")

    for s in "${steps_to_check[@]}"; do
        [[ $s -lt $FROM_STEP ]] && continue
        local path="${SCRIPTS_DIR}/${STEP_SCRIPT[$s]}"
        if [[ ! -f "$path" ]]; then
            missing+=("${STEP_SCRIPT[$s]}")
        else
            chmod +x "$path"
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_err "Missing script files:"
        printf "  %s\n" "${missing[@]}"
        log_err "Ensure all scripts are present in: ${SCRIPTS_DIR}"
        return 1
    fi
    log_ok "All scripts present and executable."
}

# ── Per-step readiness checks ─────────────────────────────────
# Returns 0 = already done (skip), non-zero = needs to run.

is_done_1() {
    for cmd in docker kubectl helm kind curl python3; do
        command -v "$cmd" &>/dev/null || return 1
    done
    docker info &>/dev/null 2>&1 || return 1
}

is_done_2() {
    docker info &>/dev/null 2>&1 || return 1
    local ram_gb=0
    if [[ "$(uname -s)" == "Darwin" ]]; then
        ram_gb=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1024/1024/1024}')
    else
        ram_gb=$(awk '/MemAvailable/ {printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null)
    fi
    [[ "${ram_gb:-0}" -ge 6 ]] || return 1
    local disk_gb
    disk_gb=$(df -k "$HOME" 2>/dev/null | awk 'NR==2 {printf "%d", $4/1024/1024}')
    [[ "${disk_gb:-0}" -ge 8 ]] || return 1
}

is_done_3() {
    kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$" || return 1
    kubectl --context "kind-${CLUSTER_NAME}" cluster-info &>/dev/null || return 1
    kubectl get namespace "${NAMESPACE}" &>/dev/null || return 1
}

is_done_4() {
    # Strimzi
    kubectl get deployment strimzi-cluster-operator \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "^1$" || return 1
    # Flink operator
    kubectl get deployment flink-kubernetes-operator \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "^1$" || return 1
    # MinIO operator
    kubectl get deployment minio-operator \
        -n minio-operator \
        -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q "^1$" || return 1
}

is_done_5() {
    local phase
    phase=$(kubectl get pod \
        -l v1.min.io/tenant=fraud-minio \
        -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    [[ "$phase" == "Running" ]] || return 1
    # Also verify S3 API is healthy
    local pod
    pod=$(kubectl get pod \
        -l v1.min.io/tenant=fraud-minio \
        -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    kubectl exec "${pod}" -n "${NAMESPACE}" -- \
        curl -sf http://localhost:9000/minio/health/live &>/dev/null || return 1
}

is_done_6() {
    # Kafka cluster Ready
    local ready
    ready=$(kubectl get kafka fraud-kafka \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [[ "$ready" == "True" ]] || return 1
    # Topics created (at least 4)
    local topic_count
    topic_count=$(kubectl get kafkatopics -n "${NAMESPACE}" \
        --no-headers 2>/dev/null | wc -l | tr -d ' ')
    [[ "${topic_count:-0}" -ge 4 ]] || return 1
    # Schema Registry actually serving /subjects (not just pod Running)
    # A pod that is Running but still initialising will fail this check,
    # which correctly triggers step-06 to re-run and wait for SR.
    local sr_pod
    sr_pod=$(kubectl get pod -l app=schema-registry \
        -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -z "$sr_pod" ]] && return 1
    kubectl exec "${sr_pod}" -n "${NAMESPACE}" -- \
        curl -sf --max-time 5 http://localhost:8081/subjects &>/dev/null || return 1
}

is_done_7() {
    # Check images are loaded into all kind worker nodes
    local all_loaded=true
    for node in $(kind get nodes --name "${CLUSTER_NAME}" 2>/dev/null | grep worker); do
        docker exec "${node}" crictl images 2>/dev/null \
            | grep -q "fraud-detection/producer" || all_loaded=false
        docker exec "${node}" crictl images 2>/dev/null \
            | grep -q "fraud-detection/flink-jobs" || all_loaded=false
    done
    $all_loaded || return 1
}

is_done_8() {
    # FlinkDeployment must be STABLE (not just DEPLOYED).
    # DEPLOYED means the operator submitted the job; STABLE means the job
    # is confirmed running without errors. A CrashLoopBackOff JM can still
    # show DEPLOYED — we require STABLE to be sure.
    local state
    state=$(kubectl get flinkdeployment fraud-scoring-job \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.lifecycleState}' 2>/dev/null)
    [[ "$state" == "STABLE" ]] || return 1
    # JobManager must be Running with low restart count (not CrashLoopBackOff)
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
    # At least one TaskManager pod must be Running
    local tm_ready
    tm_ready=$(kubectl get pod \
        -l component=taskmanager \
        -n "${NAMESPACE}" \
        --no-headers 2>/dev/null | grep -c "Running" || echo "0")
    [[ "${tm_ready:-0}" -ge 1 ]] || return 1
}

is_done_9() {
    local phase
    phase=$(kubectl get pod \
        -l app=transaction-producer \
        -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    [[ "$phase" == "Running" ]] || return 1
    # Verify it's actually producing — raw-transactions should have messages
    local kafka_pod msg_count
    kafka_pod=$(kubectl get pod \
        -l strimzi.io/name=fraud-kafka-kafka \
        -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    [[ -z "$kafka_pod" ]] && return 1
    msg_count=$(kubectl exec "${kafka_pod}" -n "${NAMESPACE}" -- \
        bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
        --bootstrap-server localhost:9092 \
        --topic raw-transactions --time -1 2>/dev/null \
        | awk -F: '{sum += $3} END {print sum}' || echo "0")
    [[ "${msg_count:-0}" -gt 0 ]] || return 1
}

is_done_10() {
    local grafana_phase prometheus_phase
    grafana_phase=$(kubectl get pod \
        -l app=grafana -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    prometheus_phase=$(kubectl get pod \
        -l app=prometheus -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    [[ "$grafana_phase" == "Running" && "$prometheus_phase" == "Running" ]] || return 1
}

is_done_11() {
    # Validation is NOT a deployable resource — it checks live pipeline state.
    # Unlike steps 1–10 (which create persistent resources that stay created),
    # the pipeline health changes every run. Always return 1 (not done) so
    # startup.sh always executes the validation script rather than skipping it.
    return 1
}

step_is_already_done() {
    "is_done_${1}" 2>/dev/null
}

# ── Progress bar ──────────────────────────────────────────────
draw_progress() {
    local done_count="$1" total="$2"
    local pct=$(( done_count * 100 / total ))
    local filled=$(( done_count * 30 / total ))
    local bar=""
    for ((i=0; i<filled; i++));  do bar+="█"; done
    for ((i=filled; i<30; i++)); do bar+="░"; done
    echo -e "  ${G}[${bar}]${NC} ${pct}% (${done_count}/${total} steps)"
}

# ── Run a single step with retry + interactive failure handler ─
run_step() {
    local s="$1"
    local script="${SCRIPTS_DIR}/${STEP_SCRIPT[$s]}"
    local attempt=1

    log_step "$s"

    while [[ $attempt -le $MAX_RETRIES ]]; do
        if [[ $attempt -gt 1 ]]; then
            log_warn "Retry ${attempt}/${MAX_RETRIES} in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        fi

        if $DRY_RUN; then
            log_ok "[DRY-RUN] Would execute: $script"
            return 0
        fi

        bash "$script"
        local rc=$?

        if [[ $rc -eq 0 ]]; then
            echo "$s" >> "$STATE_FILE"
            log_ok "Step $s complete."
            return 0
        fi

        log_err "Step $s exited with code $rc (attempt ${attempt}/${MAX_RETRIES})"
        attempt=$((attempt + 1))
    done

    # All automatic retries exhausted
    if $AUTO_YES; then
        log_err "Step $s failed after ${MAX_RETRIES} attempts. Aborting (--yes mode)."
        return 1
    fi

    # Interactive recovery menu
    while true; do
        echo ""
        echo -e "${R}╔══ Step $s FAILED — ${STEP_LABEL[$s]} ══╗${NC}"
        echo -e "  Failed after ${MAX_RETRIES} automatic retry attempt(s)."
        echo ""
        echo -e "  ${W}1)${NC} Retry this step (fresh attempt pool)"
        echo -e "  ${W}2)${NC} Skip and continue ${R}(not recommended — may break later steps)${NC}"
        echo -e "  ${W}3)${NC} Abort and clean up everything deployed so far"
        echo -e "  ${W}4)${NC} Abort and keep current state (for manual debugging)"
        echo ""
        read -rp "  Choice [1-4]: " choice
        echo ""

        case "$choice" in
            1)
                attempt=1
                while [[ $attempt -le $MAX_RETRIES ]]; do
                    bash "$script" && {
                        echo "$s" >> "$STATE_FILE"
                        log_ok "Step $s complete."
                        return 0
                    }
                    attempt=$((attempt + 1))
                    [[ $attempt -le $MAX_RETRIES ]] && sleep "$RETRY_DELAY"
                done
                ;;
            2)
                log_warn "Skipping step $s. Downstream steps may fail."
                read -rp "  Confirm skip? (yes/no): " confirm
                [[ "$confirm" =~ ^[Yy][Ee][Ss]$ ]] && {
                    log_warn "Step $s skipped by user choice."
                    return 0
                }
                ;;
            3)
                log_info "Triggering cleanup of resources deployed so far..."
                local cleanup_script
                cleanup_script="$(dirname "${BASH_SOURCE[0]}")/cleanup.sh"
                if [[ -f "$cleanup_script" ]]; then
                    bash "$cleanup_script" --mode full --up-to-step "$s" --yes
                else
                    log_warn "cleanup.sh not found at $(dirname "${BASH_SOURCE[0]}")/cleanup.sh"
                    log_warn "Clean up manually with: kind delete cluster --name ${CLUSTER_NAME}"
                fi
                exit 1
                ;;
            4)
                log_warn "Aborting without cleanup. State preserved for debugging."
                log_info "Resume later with: ./startup.sh --from $s"
                exit 1
                ;;
            *)
                log_err "Invalid choice. Enter 1, 2, 3, or 4."
                ;;
        esac
    done
}

# ── Main deploy loop ──────────────────────────────────────────
deploy() {
    local start_ts; start_ts=$(date +%s)
    local steps_run=0 steps_skipped=0

    big_sep
    echo -e "${W}  ${PROJECT_NAME}${NC}"
    echo -e "${DIM}  Intelligent deployment — auto-detects completed steps${NC}"
    big_sep

    log_info "Scripts:    ${SCRIPTS_DIR}"
    log_info "Cluster:    ${CLUSTER_NAME}"
    log_info "Namespace:  ${NAMESPACE}"
    [[ -n "$ONLY_STEP" ]] && log_info "Only step:  ${ONLY_STEP}" \
                           || log_info "From step:  ${FROM_STEP}"
    $DRY_RUN && log_warn "DRY-RUN mode — no changes will be made."
    echo ""

    if ! $AUTO_YES && ! $DRY_RUN; then
        if [[ $FROM_STEP -le 1 ]]; then
            echo -e "  This will install required tools (if missing) and deploy"
            echo -e "  the full fraud detection pipeline end-to-end."
        fi
        echo -e "  ${DIM}Steps will be skipped if already complete.${NC}"
        echo ""
        read -rp "  Start deployment? (yes/no): " ans
        [[ "$ans" =~ ^[Yy][Ee][Ss]$ ]] || { log_info "Deployment cancelled."; exit 0; }
    fi

    > "$STATE_FILE"

    local effective_steps=("${STEPS[@]}")
    [[ -n "$ONLY_STEP" ]] && effective_steps=("$ONLY_STEP")

    local steps_to_run=()
    for s in "${effective_steps[@]}"; do
        [[ $s -lt $FROM_STEP ]] && continue
        steps_to_run+=("$s")
    done
    local total_to_run=${#steps_to_run[@]}

    echo ""
    log_info "Steps to evaluate: ${steps_to_run[*]}"
    separator

    local completed_so_far=0
    for s in "${steps_to_run[@]}"; do
        if step_is_already_done "$s"; then
            log_skip "$s"
            steps_skipped=$((steps_skipped + 1))
        else
            run_step "$s" || exit 1
            steps_run=$((steps_run + 1))
        fi
        completed_so_far=$((completed_so_far + 1))
        draw_progress "$completed_so_far" "$total_to_run"
    done

    local end_ts; end_ts=$(date +%s)
    local elapsed=$(( end_ts - start_ts ))
    local mins=$(( elapsed / 60 )) secs=$(( elapsed % 60 ))

    big_sep
    echo -e "${G}  ✔ ${W}${PROJECT_NAME} — Deployment Complete${NC}"
    echo ""
    log_ok "Duration:                  ${mins}m ${secs}s"
    log_ok "Steps executed:            ${steps_run}"
    log_ok "Steps skipped (done):      ${steps_skipped}"
    big_sep
}

# ── Post-deploy access summary ────────────────────────────────
show_summary() {
    $DRY_RUN && return
    [[ $FROM_STEP -gt 10 ]] && return

    local kafka_pod jm_pod minio_pod
    kafka_pod=$(kubectl get pod -l strimzi.io/name=fraud-kafka-kafka \
        -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    jm_pod=$(kubectl get pod -l component=jobmanager \
        -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

    echo ""
    echo -e "${W}╔══ Pipeline Health ══╗${NC}"
    echo ""

    # Kafka message counts
    if [[ -n "$kafka_pod" ]]; then
        for topic in raw-transactions enriched-transactions fraud-alerts; do
            count=$(kubectl exec "${kafka_pod}" -n "${NAMESPACE}" -- \
                bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
                --bootstrap-server localhost:9092 \
                --topic "${topic}" --time -1 2>/dev/null \
                | awk -F: '{sum += $3} END {print sum}' || echo "?")
            echo -e "  ${TICK} Kafka [${topic}]:  ${count} messages"
        done
    fi

    # Flink job state
    if [[ -n "$jm_pod" ]]; then
        flink_state=$(kubectl exec "${jm_pod}" -n "${NAMESPACE}" -- \
            flink list 2>/dev/null | grep -i "RUNNING" | awk '{print $6}' | head -1 || echo "?")
        flink_job_id=$(kubectl exec "${jm_pod}" -n "${NAMESPACE}" -- \
            flink list 2>/dev/null | grep -i "RUNNING" | awk '{print $4}' | head -1 || echo "?")
        echo -e "  ${TICK} Flink job:                  ${flink_state} (${flink_job_id})"
    fi

    # Consumer lag
    if [[ -n "$kafka_pod" ]]; then
        lag=$(kubectl exec "${kafka_pod}" -n "${NAMESPACE}" -- \
            bin/kafka-consumer-groups.sh \
            --bootstrap-server localhost:9092 \
            --describe --group flink-fraud-detector-v1 2>/dev/null \
            | awk 'NR>1 && $6 ~ /^[0-9]+$/ {sum += $6} END {print sum}' || echo "?")
        echo -e "  ${TICK} Flink consumer lag:         ${lag} messages"
    fi

    echo ""
    echo -e "${W}╔══ Access Points ══╗${NC}"
    echo ""
    echo -e "  ${C}Kafka UI${NC}       →  http://localhost:8080"
    echo -e "  ${C}Flink UI${NC}       →  http://localhost:8082"
    echo -e "  ${C}MinIO Console${NC}  →  http://localhost:9001   (admin / password123)"
    echo -e "  ${C}Grafana${NC}        →  http://localhost:3000   (admin / admin)"
    echo -e "  ${C}Trino SQL${NC}      →  http://localhost:8083"
    echo -e "  ${C}Prometheus${NC}     →  http://localhost:9090"
    echo ""
    echo -e "${W}╔══ Useful Commands ══╗${NC}"
    echo ""
    echo -e "  ${DIM}# Watch live fraud alerts${NC}"
    echo -e "  make consume-alerts"
    echo ""
    echo -e "  ${DIM}# Check Flink consumer lag${NC}"
    echo -e "  make consumer-lag"
    echo ""
    echo -e "  ${DIM}# Trigger safe Flink upgrade after rule changes${NC}"
    echo -e "  make redeploy"
    echo ""
    echo -e "  ${DIM}# Run end-to-end validation${NC}"
    echo -e "  ./startup.sh --only 11"
    echo ""
    echo -e "  ${DIM}# Light cleanup (keep cluster + PVCs)${NC}"
    echo -e "  ./cleanup.sh --mode light"
    echo ""
    echo -e "  ${DIM}# Full cleanup (destroy everything)${NC}"
    echo -e "  ./cleanup.sh --mode full"
    echo ""
    separator
}

# ── Entry point ───────────────────────────────────────────────
main() {
    parse_args "$@"

    # For steps 1 and 2 we can't assume kubectl/kind exist yet
    if [[ $FROM_STEP -ge 3 ]]; then
        local missing=()
        for cmd in docker kubectl helm kind curl python3; do
            command -v "$cmd" &>/dev/null || missing+=("$cmd")
        done
        if [[ ${#missing[@]} -gt 0 ]]; then
            log_err "Required tools missing: ${missing[*]}"
            log_err "Run from step 1 to install them: ./startup.sh --from 1"
            exit 1
        fi
        if ! docker info &>/dev/null 2>&1; then
            log_err "Docker daemon is not running."
            log_err "Start Docker, then re-run: ./startup.sh --from 2"
            exit 1
        fi
    fi

    check_scripts || exit 1
    deploy
    show_summary
}

main "$@"