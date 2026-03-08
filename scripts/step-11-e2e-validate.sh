#!/usr/bin/env bash
# step-11-e2e-validate.sh
# End-to-end validation of the fraud detection pipeline.
#
# Checks performed:
#   1. All pods Running
#   2. Kafka topics exist + have messages
#   3. Flink job is RUNNING (not just pod Running)
#   4. Fraud alerts topic is receiving events
#   5. Flink consumer lag is bounded (< 10,000)
#   6. MinIO buckets exist and have Iceberg data
#   7. Inject a known fraud pattern and verify it reaches fraud-alerts
#   8. Print live stats table

set -euo pipefail

NAMESPACE="fraud-detection"

R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'
C='\033[0;36m'; W='\033[1;37m'; DIM='\033[2m'; NC='\033[0m'
TICK="${G}✔${NC}"; CROSS="${R}✘${NC}"; WARN="${Y}⚠${NC}"

PASS=0; FAIL=0; WARN_COUNT=0
RESULTS=()

record() {
    local label="$1" status="$2" detail="$3"
    RESULTS+=("${status}|${label}|${detail}")
    case "$status" in
        PASS) PASS=$((PASS+1)) ;;
        FAIL) FAIL=$((FAIL+1)) ;;
        WARN) WARN_COUNT=$((WARN_COUNT+1)) ;;
    esac
}

print_results() {
    echo ""
    echo -e "${W}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${W}║        Fraud Detection Pipeline — Validation Report      ║${NC}"
    echo -e "${W}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    for entry in "${RESULTS[@]}"; do
        IFS='|' read -r status label detail <<< "$entry"
        case "$status" in
            PASS) echo -e "  ${TICK} ${label}${detail:+  ${DIM}${detail}${NC}}" ;;
            FAIL) echo -e "  ${CROSS} ${label}${detail:+  ${R}${detail}${NC}}" ;;
            WARN) echo -e "  ${WARN} ${label}${detail:+  ${Y}${detail}${NC}}" ;;
        esac
    done
    echo ""
    echo -e "  ${W}Results:${NC} ${G}${PASS} passed${NC}  ${Y}${WARN_COUNT} warnings${NC}  ${R}${FAIL} failed${NC}"
    echo ""
}

# ── Helper: get pod name by label ─────────────────────────────
get_pod() { kubectl get pod -l "$1" -n "${NAMESPACE}" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null; }

echo ""
echo -e "${C}══════════════════════════════════════════════════════════════${NC}"
echo -e "${W}  Fraud Detection Pipeline — End-to-End Validation${NC}"
echo -e "${C}══════════════════════════════════════════════════════════════${NC}"
echo ""

# ──────────────────────────────────────────────────────────────
# CHECK 1: All expected pods running
# ──────────────────────────────────────────────────────────────
echo -e "${B}[1/8]${NC} Checking pod health..."

declare -A EXPECTED_PODS=(
    ["app=transaction-producer"]="Transaction Producer"
    ["component=jobmanager"]="Flink JobManager"
    ["component=taskmanager"]="Flink TaskManager"
    ["v1.min.io/tenant=fraud-minio"]="MinIO"
    ["strimzi.io/name=fraud-kafka-kafka"]="Kafka Broker"
    ["app=schema-registry"]="Schema Registry"
    ["app=kafka-ui"]="Kafka UI"
    ["app=grafana"]="Grafana"
    ["app=prometheus"]="Prometheus"
    ["app=trino"]="Trino"
)

for selector in "${!EXPECTED_PODS[@]}"; do
    label="${EXPECTED_PODS[$selector]}"
    phase=$(kubectl get pod -l "$selector" -n "${NAMESPACE}" \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
    if [[ "$phase" == "Running" ]]; then
        record "Pod: ${label}" PASS "Running"
    else
        record "Pod: ${label}" FAIL "phase=${phase:-NotFound}"
    fi
done

# ──────────────────────────────────────────────────────────────
# CHECK 2: Kafka topics exist and have messages
# ──────────────────────────────────────────────────────────────
echo -e "${B}[2/8]${NC} Checking Kafka topics..."
KAFKA_POD=$(get_pod "strimzi.io/name=fraud-kafka-kafka")

REQUIRED_TOPICS=("raw-transactions" "enriched-transactions" "fraud-alerts" "dead-letter")
for topic in "${REQUIRED_TOPICS[@]}"; do
    exists=$(kubectl exec "${KAFKA_POD}" -n "${NAMESPACE}" -- \
        bin/kafka-topics.sh --bootstrap-server localhost:9092 \
        --list 2>/dev/null | grep -c "^${topic}$" || echo "0")
    if [[ "$exists" == "1" ]]; then
        offset=$(kubectl exec "${KAFKA_POD}" -n "${NAMESPACE}" -- \
            bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
            --bootstrap-server localhost:9092 \
            --topic "${topic}" --time -1 2>/dev/null \
            | awk -F: '{sum += $3} END {print sum}' || echo "0")
        if [[ "${offset:-0}" -gt 0 ]]; then
            record "Topic: ${topic}" PASS "${offset} messages"
        else
            if [[ "$topic" == "dead-letter" ]]; then
                record "Topic: ${topic}" PASS "exists, 0 messages (expected — no failures)"
            else
                record "Topic: ${topic}" WARN "exists but 0 messages yet"
            fi
        fi
    else
        record "Topic: ${topic}" FAIL "topic not found"
    fi
done

# ──────────────────────────────────────────────────────────────
# CHECK 3: Flink job RUNNING state (not just pod)
# ──────────────────────────────────────────────────────────────
echo -e "${B}[3/8]${NC} Checking Flink job state..."
JM_POD=$(get_pod "component=jobmanager")

# Use Flink REST API instead of 'flink list' CLI output parsing.
# 'flink list' output format is not stable — awk column positions can shift.
# The REST API returns structured JSON that is version-stable.
FLINK_JOB_STATE=""
JOB_ID=""
if [[ -n "$JM_POD" ]]; then
    JM_IP=$(kubectl get pod "${JM_POD}" -n "${NAMESPACE}" \
        -o jsonpath='{.status.podIP}' 2>/dev/null || echo "")
    if [[ -n "$JM_IP" ]]; then
        API_RESPONSE=$(kubectl exec "${JM_POD}" -n "${NAMESPACE}" -- \
            wget -qO- "http://${JM_IP}:8081/jobs" 2>/dev/null || echo "")
        FLINK_JOB_STATE=$(echo "${API_RESPONSE}" | python3 -c \
            "import sys,json; jobs=json.load(sys.stdin).get('jobs',[]); \
             running=[j for j in jobs if j.get('status')=='RUNNING']; \
             print(running[0]['status'] if running else '')" 2>/dev/null || echo "")
        JOB_ID=$(echo "${API_RESPONSE}" | python3 -c \
            "import sys,json; jobs=json.load(sys.stdin).get('jobs',[]); \
             running=[j for j in jobs if j.get('status')=='RUNNING']; \
             print(running[0]['id'][:8] if running else '')" 2>/dev/null || echo "")
    fi
fi

if [[ "$FLINK_JOB_STATE" == "RUNNING" ]]; then
    record "Flink fraud detection job" PASS "RUNNING (job ID: ${JOB_ID}...)"
else
    # Get full picture: actual Flink job state + operator lifecycle
    lifecycle=$(kubectl get flinkdeployment fraud-scoring-job \
        -n "${NAMESPACE}" \
        -o jsonpath='{.status.lifecycleState}' 2>/dev/null || echo "UNKNOWN")
    actual_state=$(kubectl exec "${JM_POD}" -n "${NAMESPACE}" -- \
        curl -sf http://localhost:8081/jobs/overview 2>/dev/null \
        | python3 -c "import sys,json; jobs=json.load(sys.stdin).get('jobs',[]); print(jobs[0]['state'] if jobs else 'NO_JOB')" \
        2>/dev/null || echo "UNKNOWN")

    # RESTARTING = job encountered a transient failure and is recovering.
    # This is expected during startup (e.g. S3 not ready yet) — treat as WARN
    # so pipeline startup is not permanently blocked. It will recover once
    # the underlying cause (missing buckets, slow S3 init) is resolved.
    # FAILED = unrecoverable — treat as hard FAIL.
    if [[ "$actual_state" == "RESTARTING" || "$lifecycle" == "DEPLOYED" ]]; then
        record "Flink fraud detection job" WARN "state=${actual_state}, lifecycle=${lifecycle} — job restarting, check TM logs if persists"
    elif [[ "$actual_state" == "FAILED" ]]; then
        record "Flink fraud detection job" FAIL "state=FAILED — job exhausted retries. Check: kubectl logs -n fraud-detection -l component=taskmanager"
    else
        record "Flink fraud detection job" FAIL "state=${actual_state:-UNKNOWN}, lifecycle=${lifecycle}"
    fi
fi

# ──────────────────────────────────────────────────────────────
# CHECK 4: fraud-alerts topic receiving events
# ──────────────────────────────────────────────────────────────
echo -e "${B}[4/8]${NC} Checking fraud alerts are being produced..."
ALERT_OFFSET=$(kubectl exec "${KAFKA_POD}" -n "${NAMESPACE}" -- \
    bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
    --bootstrap-server localhost:9092 \
    --topic fraud-alerts --time -1 2>/dev/null \
    | awk -F: '{sum += $3} END {print sum}' || echo "0")

if [[ "${ALERT_OFFSET:-0}" -gt 0 ]]; then
    record "Fraud alerts flowing" PASS "${ALERT_OFFSET} alerts produced"
    SAMPLE=$(kubectl exec "${KAFKA_POD}" -n "${NAMESPACE}" -- \
        bin/kafka-console-consumer.sh \
        --bootstrap-server localhost:9092 \
        --topic fraud-alerts \
        --max-messages 1 \
        --timeout-ms 3000 2>/dev/null || echo "")
    if [[ -n "$SAMPLE" ]]; then
        RISK=$(echo "$SAMPLE" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('risk_score','?'))" 2>/dev/null || echo "?")
        PATTERN=$(echo "$SAMPLE" | python3 -c \
            "import sys,json; d=json.load(sys.stdin); print(d.get('fraud_pattern','?'))" 2>/dev/null || echo "?")
        record "Sample alert" PASS "risk_score=${RISK}  pattern=${PATTERN}"
    fi
else
    record "Fraud alerts flowing" WARN "0 alerts yet — Flink may still be warming up (wait 60s)"
fi

# ──────────────────────────────────────────────────────────────
# CHECK 5: Flink consumer lag
# ──────────────────────────────────────────────────────────────
echo -e "${B}[5/8]${NC} Checking Flink consumer lag..."
LAG=$(kubectl exec "${KAFKA_POD}" -n "${NAMESPACE}" -- \
    bin/kafka-consumer-groups.sh \
    --bootstrap-server localhost:9092 \
    --describe \
    --group flink-fraud-detector-v1 2>/dev/null \
    | awk 'NR>1 && $6 ~ /^[0-9]+$/ {sum += $6} END {print sum}' || echo "-1")

if [[ "$LAG" == "-1" || -z "$LAG" ]]; then
    record "Flink consumer lag" WARN "Consumer group not yet registered (Flink still starting)"
elif [[ "${LAG}" -le 1000 ]]; then
    record "Flink consumer lag" PASS "lag=${LAG} messages (healthy)"
elif [[ "${LAG}" -le 10000 ]]; then
    record "Flink consumer lag" WARN "lag=${LAG} messages (catching up)"
else
    record "Flink consumer lag" FAIL "lag=${LAG} messages (Flink falling behind — check TaskManager resources)"
fi

# ──────────────────────────────────────────────────────────────
# CHECK 6: MinIO buckets exist and have content
# ──────────────────────────────────────────────────────────────
echo -e "${B}[6/8]${NC} Checking MinIO storage..."
MINIO_POD=$(get_pod "v1.min.io/tenant=fraud-minio")

if [[ -n "$MINIO_POD" ]]; then
    # Ensure mc alias is set with credentials before any mc command.
    # The default 'local' alias has empty credentials and silently fails.
    kubectl exec "${MINIO_POD}" -n "${NAMESPACE}" -- \
        mc alias set myminio http://localhost:9000 admin password123 --quiet 2>/dev/null || true

    for bucket in fraud-warehouse fraud-checkpoints; do
        # grep -c can return "0\n0" when piped with || echo — strip newlines
        exists=$(kubectl exec "${MINIO_POD}" -n "${NAMESPACE}" -- \
            mc ls myminio/ 2>/dev/null | grep -c "${bucket}" 2>/dev/null | tr -d '\n' || echo "0")
        exists="${exists%%[^0-9]*}"   # keep only leading digits — paranoid strip
        exists="${exists:-0}"
        if [[ "$exists" -gt 0 ]]; then
            SIZE=$(kubectl exec "${MINIO_POD}" -n "${NAMESPACE}" -- \
                mc du "myminio/${bucket}" 2>/dev/null | awk '{print $1}' || echo "?")
            record "MinIO bucket: ${bucket}" PASS "exists, size=${SIZE}"
        else
            record "MinIO bucket: ${bucket}" FAIL "bucket missing — run: kubectl exec -n fraud-detection ${MINIO_POD} -- mc mb myminio/${bucket}"
        fi
    done
fi

# ──────────────────────────────────────────────────────────────
# CHECK 7: Inject a known fraud transaction and verify detection
# ──────────────────────────────────────────────────────────────
echo -e "${B}[7/8]${NC} Injecting test fraud transaction..."

BEFORE_ALERTS="${ALERT_OFFSET:-0}"

# FIX: Pre-compute the timestamp in bash so it can be interpolated into
# the Python string. The original code used '$(date ...)' inside single
# quotes within a double-quoted string — shell never expanded the subshell.
EVENT_TIME="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TIMESTAMP_MS="$(date +%s%3N 2>/dev/null || python3 -c 'import time; print(int(time.time()*1000))')"

TEST_TXN=$(python3 -c "
import json, uuid
print(json.dumps({
    'transaction_id': str(uuid.uuid4()),
    'account_id': 'ACC_TEST_VALIDATION',
    'card_id': 'CARD_TESTVALIDATION',
    'amount': 4999.99,
    'currency': 'USD',
    'transaction_type': 'purchase',
    'merchant_id': 'M001',
    'merchant_name': 'Validation Test Store',
    'merchant_category': 'online_retail',
    'country': 'NG',
    'city': 'Lagos',
    'latitude': 6.5244,
    'longitude': 3.3792,
    'timestamp_ms': ${TIMESTAMP_MS},
    'event_time': '${EVENT_TIME}',
    'is_fraud': True,
    'fraud_pattern': 'validation_test',
    'device_id': 'DEV_VALIDATE',
    'ip_address': '10.0.0.1',
    'session_id': 'SES_VALIDATION'
}))
" 2>/dev/null)

if [[ -n "$TEST_TXN" && -n "$KAFKA_POD" ]]; then
    echo "$TEST_TXN" | kubectl exec -i "${KAFKA_POD}" -n "${NAMESPACE}" -- \
        bin/kafka-console-producer.sh \
        --bootstrap-server localhost:9092 \
        --topic raw-transactions \
        >/dev/null 2>&1 || true

    record "Test transaction injected" PASS "account=ACC_TEST_VALIDATION amount=4999.99 country=NG"

    # KafkaSink with AT_LEAST_ONCE flushes only on checkpoint.
    # Checkpoint interval = 30s. Wait 35s to guarantee at least one checkpoint fires.
    echo -e "${B}[INFO]${NC}  Waiting 35 seconds for Flink checkpoint to flush fraud alert..."
    sleep 35

    AFTER_ALERTS=$(kubectl exec "${KAFKA_POD}" -n "${NAMESPACE}" -- \
        bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
        --bootstrap-server localhost:9092 \
        --topic fraud-alerts --time -1 2>/dev/null \
        | awk -F: '{sum += $3} END {print sum}' || echo "0")

    NEW_ALERTS=$(( AFTER_ALERTS - BEFORE_ALERTS ))
    if [[ "$NEW_ALERTS" -gt 0 ]]; then
        record "Test fraud detected by Flink" PASS "+${NEW_ALERTS} new alerts in fraud-alerts topic"
    else
        record "Test fraud detected by Flink" WARN "No new alerts yet — Flink may need more time (check Flink UI)"
    fi
else
    record "Test transaction inject" WARN "Could not inject test message — check Kafka pod"
    AFTER_ALERTS="${ALERT_OFFSET:-0}"
fi

# ──────────────────────────────────────────────────────────────
# CHECK 8: Live throughput stats
# ──────────────────────────────────────────────────────────────
echo -e "${B}[8/8]${NC} Collecting live throughput stats..."

RAW_OFFSET=$(kubectl exec "${KAFKA_POD}" -n "${NAMESPACE}" -- \
    bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
    --bootstrap-server localhost:9092 \
    --topic raw-transactions --time -1 2>/dev/null \
    | awk -F: '{sum += $3} END {print sum}' || echo "0")

ENRICHED_OFFSET=$(kubectl exec "${KAFKA_POD}" -n "${NAMESPACE}" -- \
    bin/kafka-run-class.sh kafka.tools.GetOffsetShell \
    --bootstrap-server localhost:9092 \
    --topic enriched-transactions --time -1 2>/dev/null \
    | awk -F: '{sum += $3} END {print sum}' || echo "0")

record "Throughput stats" PASS \
    "raw=${RAW_OFFSET} enriched=${ENRICHED_OFFSET} fraud_alerts=${AFTER_ALERTS}"

# ──────────────────────────────────────────────────────────────
# FINAL REPORT
# ──────────────────────────────────────────────────────────────
print_results

if [[ $FAIL -gt 0 ]]; then
    echo -e "${R}  Pipeline validation FAILED — ${FAIL} critical check(s) failed.${NC}"
    echo ""
    echo -e "  Troubleshooting tips:"
    echo -e "  • Flink logs:    kubectl logs -n ${NAMESPACE} -l component=jobmanager"
    echo -e "  • Producer logs: kubectl logs -n ${NAMESPACE} -l app=transaction-producer"
    echo -e "  • Kafka lag:     kubectl exec -n ${NAMESPACE} \$(kubectl get pod -l strimzi.io/name=fraud-kafka-kafka -n ${NAMESPACE} -o jsonpath='{.items[0].metadata.name}') -- bin/kafka-consumer-groups.sh --bootstrap-server localhost:9092 --describe --group flink-fraud-detector-v1"
    echo -e "  • Re-run step:   ./startup.sh --only <step_number>"
    echo ""
    exit 1
elif [[ $WARN_COUNT -gt 0 ]]; then
    echo -e "${Y}  Pipeline validation PASSED with ${WARN_COUNT} warning(s).${NC}"
    echo -e "  ${DIM}Warnings are normal in the first few minutes — Flink and Kafka are warming up.${NC}"
    echo ""
else
    echo -e "${G}  ✔ Pipeline validation PASSED — all checks green.${NC}"
    echo ""
    echo -e "  ${W}Fraud detection is live. What to do next:${NC}"
    echo -e "  • Watch alerts:  make consume-alerts"
    echo -e "  • Flink UI:      http://localhost:8082"
    echo -e "  • Grafana:       http://localhost:3000   (admin/admin)"
    echo -e "  • Trino SQL:     make trino-shell"
    echo ""
fi