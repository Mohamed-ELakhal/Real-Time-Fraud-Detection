# Real-Time Fraud Detection Pipeline

A production-grade, end-to-end streaming fraud detection system built on Apache Flink, Apache Kafka, Apache Iceberg, and MinIO — fully containerised on Kubernetes using a local [kind](https://kind.sigs.k8s.io/) cluster. The entire stack deploys with a single command.

---

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Tech Stack](#tech-stack)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Deployment Steps](#deployment-steps)
- [Project Structure](#project-structure)
- [Pipeline Deep Dive](#pipeline-deep-dive)
- [Fraud Detection Logic](#fraud-detection-logic)
- [Data Flow & Kafka Topics](#data-flow--kafka-topics)
- [Iceberg Storage](#iceberg-storage)
- [Observability](#observability)
- [Access Points](#access-points)
- [Validation](#validation)
- [Operational Commands](#operational-commands)
- [Failure Recovery](#failure-recovery)
- [Design Decisions](#design-decisions)
- [Cleanup](#cleanup)

---

## Overview

This pipeline ingests synthetic payment transactions from Kafka, scores them for fraud in real time using a stateful Apache Flink job, and fans the results out to three sinks simultaneously:

| Sink | Format | Purpose |
|---|---|---|
| `enriched-transactions` | Kafka JSON | All scored transactions for downstream consumers |
| `fraud-alerts` | Kafka JSON | Fraud-only subset for alerting / incident response |
| `fraud_scores` | Apache Iceberg (S3/MinIO) | Queryable analytical store via Trino SQL |

The transaction producer generates **20 transactions per second** across **200 simulated accounts**, with a **2% base fraud rate** and periodic injection bursts of targeted fraud patterns.

A full end-to-end validation suite (22 checks) verifies the pipeline health after every deployment.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          Kind Kubernetes Cluster                             │
│                         (fraud-detection namespace)                          │
│                                                                              │
│  ┌──────────────────┐                                                        │
│  │  Transaction     │  20 TPS · 200 accounts · 2% base fraud rate           │
│  │  Producer        │─────────────────────────────────────────┐             │
│  │  (producer/)     │                                         │             │
│  └──────────────────┘                                         ▼             │
│                                                    ┌─────────────────────┐  │
│                                                    │ Kafka               │  │
│                                                    │ [raw-transactions]  │  │
│                                                    └──────────┬──────────┘  │
│                                                               │             │
│                                                               ▼             │
│                                           ┌──────────────────────────────┐  │
│                                           │      Apache Flink 1.18       │  │
│                                           │   (JobManager + TaskManager) │  │
│                                           │                              │  │
│                                           │  KafkaSource                 │  │
│                                           │   → WatermarkStrategy        │  │
│                                           │   → keyBy(account_id)        │  │
│                                           │   → FraudDetector            │  │
│                                           │     (stateful, RocksDB)      │  │
│                                           │   → ParseScoredJson          │  │
│                                           │   → fraud_input_view         │  │
│                                           │                              │  │
│                                           │   StatementSet.execute()     │  │
│                                           └───┬──────────────┬───────────┘  │
│                  ┌────────────────────────────┤              │              │
│                  │                            │              │              │
│                  ▼                            ▼              ▼              │
│  ┌───────────────────────┐  ┌────────────────────┐  ┌───────────────────┐  │
│  │ Kafka                 │  │ Kafka              │  │ Iceberg REST      │  │
│  │ [enriched-            │  │ [fraud-alerts]     │  │ Catalog           │  │
│  │  transactions]        │  │ fraud only         │  │ (tabulario/       │  │
│  │ all records           │  │ (AT_LEAST_ONCE)    │  │  iceberg-rest)    │  │
│  │ (AT_LEAST_ONCE)       │  └────────────────────┘  └────────┬──────────┘  │
│  └───────────────────────┘                                   │ S3FileIO    │
│                                                               ▼             │
│                                                    ┌─────────────────────┐  │
│                                                    │ MinIO               │  │
│                                                    │ (S3-compatible)     │  │
│                                                    │                     │  │
│                                                    │ fraud-warehouse/    │  │
│                                                    │  iceberg/           │  │
│                                                    │   fraud_db/         │  │
│                                                    │    fraud_scores/    │  │
│                                                    │                     │  │
│                                                    │ fraud-checkpoints/  │  │
│                                                    │  flink/ (RocksDB)   │  │
│                                                    └──────────┬──────────┘  │
│                                                               │             │
│                                                               ▼             │
│                                                    ┌─────────────────────┐  │
│                                                    │ Trino               │  │
│                                                    │ (Iceberg connector) │  │
│                                                    │                     │  │
│                                                    │ SELECT * FROM       │  │
│                                                    │  iceberg.fraud_db   │  │
│                                                    │  .fraud_scores      │  │
│                                                    └─────────────────────┘  │
│                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────┐   │
│  │                       Observability Stack                            │   │
│  │  Prometheus · Grafana · Kafka UI · Schema Registry · MinIO Console  │   │
│  └──────────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Component | Technology | Version |
|---|---|---|
| Stream Processor | Apache Flink (PyFlink) | 1.18.1 |
| Message Broker | Apache Kafka (Strimzi Operator) | 3.4 |
| Table Format | Apache Iceberg (REST Catalog) | 1.5.2 |
| Object Storage | MinIO (S3-compatible) | Operator-managed |
| SQL Query Engine | Trino | Latest |
| State Backend | RocksDB (incremental checkpoints) | Embedded |
| Kubernetes | kind (Kubernetes-in-Docker) | Local |
| Flink Orchestration | Flink Kubernetes Operator | 1.x |
| Schema Registry | Confluent Schema Registry | Latest |
| Metrics | Prometheus + Grafana | Latest |
| Language | Python 3 (PyFlink) | 3.10 |
| Infrastructure | AWS EC2 (t3.xlarge) / Local Docker | — |

---

## Prerequisites

The deployment script auto-installs missing prerequisites on step 1. You need:

- **OS:** Linux (Ubuntu 22.04+ recommended) or macOS
- **RAM:** 8 GB minimum (16 GB recommended)
- **Disk:** 20 GB free
- **Docker:** Running daemon
- **Internet:** Required for image pulls on first deploy

Tools installed automatically by step 1 if missing: `kubectl`, `helm`, `kind`, `curl`, `python3`.

---

## Quick Start

```bash
git clone https://github.com/<your-org>/fraud-detection-pipeline.git
cd fraud-detection-pipeline
chmod +x startup.sh
./startup.sh
```

Full deployment takes approximately **10–15 minutes** on a fresh machine. The script is idempotent — running it again on a fully deployed system is a no-op.

---

## Deployment Steps

The `startup.sh` orchestrator runs 11 steps with automatic completion detection. Each step checks live system state before running — already-deployed resources are skipped automatically.

| Step | Name | What it does |
|---|---|---|
| 1 | Install Prerequisites | Installs `kubectl`, `helm`, `kind`, `curl`, `python3` if missing |
| 2 | System Pre-flight Checks | Validates RAM ≥ 6 GB, disk ≥ 8 GB, Docker running |
| 3 | Create Kind Cluster | Creates a local 3-node Kubernetes cluster named `fraud-detection` |
| 4 | Install Operators | Deploys Strimzi (Kafka), Flink Kubernetes Operator, MinIO Operator via Helm |
| 5 | Deploy MinIO Tenant | Provisions a MinIO tenant with `fraud-warehouse` and `fraud-checkpoints` buckets |
| 6 | Deploy Kafka Cluster + Topics | Deploys a Kafka cluster and creates all required topics |
| 7 | Build & Load Docker Images | Builds the PyFlink job image and loads it into all kind nodes |
| 8 | Deploy Flink Fraud Detection Job | Deploys the Iceberg REST catalog, FlinkDeployment, waits for STABLE |
| 9 | Deploy Transaction Producer | Deploys the synthetic transaction generator at 20 TPS |
| 10 | Deploy Monitoring | Deploys Prometheus, Grafana, Trino, and Schema Registry |
| 11 | End-to-End Validation | Runs 22 live health checks including a real fraud injection test |

### Selective Deployment

```bash
# Full deploy from scratch
./startup.sh

# Resume from a specific step (e.g. after a cluster already exists)
./startup.sh --from 6

# Redeploy the Flink job and everything after it
./startup.sh --from 8

# Run only the validation suite
./startup.sh --only 11

# Non-interactive mode for CI/CD
./startup.sh --yes

# Preview what would run without making any changes
./startup.sh --dry-run

# See all options
./startup.sh --help
```

---

## Project Structure

```
fraud-detection-pipeline/
├── startup.sh                        # One-command orchestrator (11 steps, idempotent)
├── cleanup.sh                        # Teardown: --mode light or --mode full
│
├── scripts/                          # One script per deployment step
│   ├── step-01-install-prerequisites.sh
│   ├── step-02-preflight-checks.sh
│   ├── step-03-create-cluster.sh
│   ├── step-04-install-operators.sh
│   ├── step-05-deploy-minio.sh
│   ├── step-06-deploy-kafka.sh
│   ├── step-07-build-images.sh
│   ├── step-08-deploy-flink.sh
│   ├── step-09-deploy-producer.sh
│   ├── step-10-deploy-monitoring.sh
│   └── step-11-e2e-validate.sh       # 22-check live validation suite
│
├── flink-jobs/                       # PyFlink image (fraud-detection/flink-jobs:latest)
│   ├── Dockerfile                    # Flink 1.18 + PyFlink + Iceberg AWS bundle + S3A
│   ├── fraud_job.py                  # Main pipeline: KafkaSource → 3 SQL sinks via StatementSet
│   ├── fraud_detector.py             # Stateful KeyedProcessFunction (per-account, RocksDB)
│   ├── models.py                     # Transaction / FraudScore data models
│   └── core-site.xml                 # Hadoop S3A config (bundled into image as JAR)
│
├── producer/                         # Transaction generator image (fraud-detection/producer:latest)
│   ├── Dockerfile
│   ├── producer.py                   # Kafka producer entrypoint (20 TPS, 200 accounts)
│   ├── generator.py                  # Synthetic transaction generator + fraud pattern injection
│   ├── models.py                     # Shared transaction schema
│   └── requirements.txt
│
└── k8s/                              # Kubernetes manifests, grouped by deployment step
    ├── 00-cluster/
    │   ├── kind-config.yaml          # 3-node kind cluster definition (1 control-plane + 2 workers)
    │   └── namespace.yaml            # Namespace + ServiceAccount + ClusterRole + RBAC + ConfigMap + Secret
    ├── 02-minio/
    │   └── minio-tenant.yaml         # MinIO Tenant CRD + credentials Secret + NodePort Service
    ├── 03-kafka/
    │   ├── kafka-cluster.yaml        # Strimzi KafkaNodePool + Kafka CRD (KRaft mode, no ZooKeeper)
    │   └── kafka-topics.yaml         # 5× KafkaTopic + Schema Registry Deployment/Service + Kafka UI Deployment/Service
    ├── 04-flink/
    │   ├── flink-deployment.yaml     # FlinkDeployment CRD + NodePort Service
    │   └── iceberg-rest-catalog.yaml # REST catalog Deployment + Service (CATALOG_* env vars, no ConfigFile)
    ├── 05-producer/
    │   └── producer-deployment.yaml  # Transaction producer Deployment
    ├── 06-monitoring/
    │   └── monitoring.yaml           # Prometheus + Grafana Deployments, Services, ConfigMaps, RBAC
    └── 07-trino/
        └── trino.yaml                # Trino Deployment + Service + catalog ConfigMap (Iceberg REST connector)
```

---

## Pipeline Deep Dive

### Flink Job: `fraud_job.py`

The Flink job is written in PyFlink and uses the **Table API with a StatementSet** for execution. All three output sinks are submitted in a single `stmt_set.execute()` call, which ensures they share the same execution graph and checkpoint cycle.

```
KafkaSource (raw-transactions)
  → WatermarkStrategy (bounded out-of-orderness, 10s)
  → keyBy(account_id)
  → FraudDetector (KeyedProcessFunction, RocksDB state)
  → ParseScoredJson (MapFunction → Row)
  → fraud_input_view (Table API view)
       │
       ├─→ INSERT INTO enriched_transactions_sink   ← all records, Kafka AT_LEAST_ONCE
       ├─→ INSERT INTO fraud_alerts_sink            ← WHERE fraud_detected = true, Kafka AT_LEAST_ONCE
       └─→ INSERT INTO fraud_scores                 ← all records, Iceberg via REST catalog
```

**Why StatementSet?** When Kafka sinks are built with the DataStream API (`sink_to()`), they register as independent DAG endpoints. The Table API executor traces the graph backwards from the Iceberg sink only — the DataStream branches are never submitted. `StatementSet.execute()` is the only way to submit multiple SQL sinks in a single unified execution graph.

**Why AT_LEAST_ONCE for Kafka sinks?** The `exactly-once` Kafka sink calls `abortLingeringTransactions()` inside `KafkaWriter.<init>()` on every restart attempt. In Flink application mode the TaskManager JVM is reused across job restarts — the JMX MBean from the previous attempt's transactional producer remains registered, causing `InstanceAlreadyExistsException` in the constructor on every subsequent attempt. This creates an infinite restart loop with zero records processed. `AT_LEAST_ONCE` eliminates this entirely; the consumer can deduplicate by `transaction_id` if needed.

### Checkpointing

```
Mode:              EXACTLY_ONCE
Interval:          30 seconds
State backend:     RocksDB (incremental)
Checkpoint dir:    s3://fraud-checkpoints/flink   (MinIO)
Savepoint dir:     s3://fraud-checkpoints/savepoints
Max concurrent:    1
Min pause:         5 seconds
Timeout:           60 seconds
```

### Iceberg REST Catalog

The REST catalog (`tabulario/iceberg-rest`) is configured entirely through `CATALOG_*` environment variables. The naming convention uses single underscores for dots and double underscores for hyphens:

```
CATALOG_WAREHOUSE=s3://fraud-warehouse/iceberg
CATALOG_IO__IMPL=org.apache.iceberg.aws.s3.S3FileIO
CATALOG_S3_ENDPOINT=http://minio-nodeport.fraud-detection:9000
CATALOG_S3_PATH__STYLE__ACCESS=true
```

> **Note:** `CATALOG_CONFIG_FILE` is silently ignored by this image — all configuration must be passed as environment variables.

---

## Fraud Detection Logic

The `FraudDetector` is a `KeyedProcessFunction` that maintains **per-account state** in RocksDB. It evaluates three fraud patterns on each transaction:

| Pattern | Trigger condition | Risk contribution |
|---|---|---|
| `high_amount` | Transaction amount exceeds account's statistical threshold | High |
| `geo_velocity` | Transactions from geographically distant locations within a short window | High |
| `unusual_country` | Transaction originates from a country not in account's known history | Medium |

Each pattern contributes to a composite `risk_score` (0.0–1.0). A transaction is marked `fraud_detected = true` when the score exceeds the configured threshold. The `fraud_reasons` field records which patterns fired.

The per-account state tracked in RocksDB includes: transaction history, known countries, and velocity windows — all keyed by `account_id` so each account's fraud model is independent and horizontally scalable.

---

## Data Flow & Kafka Topics

| Topic | Partitions | Content | Producer | Consumer |
|---|---|---|---|---|
| `raw-transactions` | 3 | Raw payment events (JSON) | Transaction Producer | Flink KafkaSource |
| `enriched-transactions` | 3 | All scored transactions with fraud flags | Flink | Downstream systems |
| `fraud-alerts` | 3 | Fraud-only events (compact payload) | Flink | Alerting / incident response |
| `dead-letter` | 1 | Failed / unprocessable messages | Flink error handler | Operations |

### Transaction Schema (raw)

```json
{
  "transaction_id": "uuid",
  "account_id":     "ACC_00174",
  "card_id":        "CARD_...",
  "amount":         249.99,
  "currency":       "USD",
  "merchant_name":  "...",
  "merchant_category": "online_retail",
  "country":        "US",
  "city":           "New York",
  "latitude":       40.7128,
  "longitude":      -74.0060,
  "timestamp_ms":   1709999999000,
  "event_time":     "2026-03-07T18:00:00Z",
  "device_id":      "DEV_...",
  "ip_address":     "...",
  "session_id":     "SES_..."
}
```

### Fraud Alert Schema (enriched subset)

```json
{
  "transaction_id":    "uuid",
  "account_id":        "ACC_00174",
  "amount":            4999.99,
  "country":           "NG",
  "risk_score":        0.94,
  "fraud_detected":    true,
  "fraud_reasons":     ["geo_velocity", "unusual_country"],
  "detection_ts":      1709999999000
}
```

---

## Iceberg Storage

All scored transactions are written to an Apache Iceberg table `fraud_catalog.fraud_db.fraud_scores` backed by MinIO object storage.

```
MinIO bucket layout:
  fraud-warehouse/
  └── iceberg/
      └── fraud_db/
          └── fraud_scores/
              ├── data/        ← Parquet data files (written by IcebergStreamWriter)
              └── metadata/    ← Iceberg snapshot metadata (JSON)

  fraud-checkpoints/
  └── flink/                   ← RocksDB incremental checkpoints
      └── savepoints/          ← Manual / periodic savepoints
```

### Querying with Trino

```sql
-- All recent fraud events
SELECT transaction_id, account_id, amount, country,
       risk_score, fraud_reasons, detection_ts
FROM iceberg.fraud_db.fraud_scores
WHERE fraud_detected = true
ORDER BY detection_ts DESC
LIMIT 20;

-- Fraud rate by country
SELECT country,
       COUNT(*) AS total,
       SUM(CASE WHEN fraud_detected THEN 1 ELSE 0 END) AS fraud_count,
       ROUND(AVG(risk_score), 3) AS avg_risk
FROM iceberg.fraud_db.fraud_scores
GROUP BY country
ORDER BY fraud_count DESC;

-- Account risk profile
SELECT account_id,
       COUNT(*) AS total_txns,
       SUM(CASE WHEN fraud_detected THEN 1 ELSE 0 END) AS fraud_txns,
       MAX(risk_score) AS peak_risk
FROM iceberg.fraud_db.fraud_scores
GROUP BY account_id
HAVING SUM(CASE WHEN fraud_detected THEN 1 ELSE 0 END) > 0;
```

---

## Observability

| Tool | Purpose | Default credentials |
|---|---|---|
| **Grafana** | Flink metrics dashboards (throughput, checkpoints, lag) | admin / admin |
| **Prometheus** | Metrics scraping from all 22 Flink + Kafka + MinIO targets | — |
| **Flink Web UI** | Job graph, vertex metrics, checkpoint history, flamegraphs | — |
| **Kafka UI** | Topic browser, consumer group lag, message inspector | — |
| **MinIO Console** | Bucket browser, object explorer, storage metrics | admin / password123 |

Prometheus scrapes the Flink TaskManager's PrometheusReporter on port `9249`. Key metrics exposed include checkpoint duration, checkpoint size, number of records processed per vertex, and operator backpressure.

---

## Access Points

After a successful deployment all UIs are exposed via NodePort on localhost:

| Interface | URL | Credentials |
|---|---|---|
| Kafka UI | http://localhost:8080 | — |
| Flink Web UI | http://localhost:8082 | — |
| MinIO Console | http://localhost:9001 | admin / password123 |
| Grafana | http://localhost:3000 | admin / admin |
| Trino UI | http://localhost:8083 | — |
| Prometheus | http://localhost:9090 | — |

---

## Validation

Step 11 runs a **22-check end-to-end validation suite** against the live running pipeline. It can be re-run at any time:

```bash
# Via startup.sh
./startup.sh --only 11

# Or directly (always executes regardless of prior state)
bash scripts/step-11-e2e-validate.sh
```

The 8 check categories and what they verify:

| # | Category | Checks |
|---|---|---|
| 1 | Pod health | All 10 expected pods are in Running phase |
| 2 | Kafka topics | All 4 topics exist and contain messages |
| 3 | Flink job state | Job is RUNNING via REST API (not just pod Running) |
| 4 | Fraud alerts | `fraud-alerts` topic is actively receiving events + sample payload |
| 5 | Consumer lag | Flink lag < 1,000 (healthy) / < 10,000 (catching up) / > 10,000 (FAIL) |
| 6 | MinIO storage | Both buckets exist and contain data (Iceberg snapshots + checkpoints) |
| 7 | **Live injection test** | Injects a known fraud transaction → waits 35s for checkpoint → verifies new alert appeared in `fraud-alerts` |
| 8 | Throughput stats | Prints live message counts across all three pipeline topics |

A passing run looks like:

```
╔══════════════════════════════════════════════════════════╗
║        Fraud Detection Pipeline — Validation Report      ║
╚══════════════════════════════════════════════════════════╝

  ✔ Pod: Flink JobManager         Running
  ✔ Pod: Flink TaskManager        Running
  ✔ Pod: Kafka Broker             Running
  ... (10 pod checks)
  ✔ Topic: raw-transactions       19,629 messages
  ✔ Topic: enriched-transactions  19,466 messages
  ✔ Topic: fraud-alerts           16,831 messages
  ✔ Topic: dead-letter            exists, 0 messages (expected)
  ✔ Flink fraud detection job     RUNNING (job ID: 1687ef55...)
  ✔ Fraud alerts flowing          16,831 alerts produced
  ✔ Flink consumer lag            lag=672 messages (healthy)
  ✔ MinIO bucket: fraud-warehouse         exists, size=3.1MiB
  ✔ MinIO bucket: fraud-checkpoints       exists, size=794KiB
  ✔ Test transaction injected     account=ACC_TEST_VALIDATION amount=4999.99 country=NG
  ✔ Test fraud detected by Flink  +1369 new alerts in fraud-alerts topic
  ✔ Throughput stats              raw=19629 enriched=19466 fraud_alerts=16831

  Results: 22 passed  0 warnings  0 failed

  ✔ Pipeline validation PASSED — all checks green.
```

---

## Operational Commands

```bash
# Watch live fraud alerts streaming from Kafka
kubectl exec -n fraud-detection \
  $(kubectl get pod -l strimzi.io/name=fraud-kafka-kafka -n fraud-detection \
    -o jsonpath='{.items[0].metadata.name}') \
  -- bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 \
  --topic fraud-alerts

# Check Flink consumer lag
kubectl exec -n fraud-detection \
  $(kubectl get pod -l strimzi.io/name=fraud-kafka-kafka -n fraud-detection \
    -o jsonpath='{.items[0].metadata.name}') \
  -- bin/kafka-consumer-groups.sh \
  --bootstrap-server localhost:9092 \
  --describe --group flink-fraud-detector-v1

# Restart the Flink job (e.g. after changing fraud_job.py)
cd flink-jobs
docker build -t fraud-detection/flink-jobs:latest .
kind load docker-image fraud-detection/flink-jobs:latest --name fraud-detection
kubectl delete flinkdeployment fraud-scoring-job -n fraud-detection
bash scripts/step-08-deploy-flink.sh

# View Flink TaskManager logs (most useful for debugging)
kubectl logs -n fraud-detection -l component=taskmanager --follow

# View Flink JobManager logs
kubectl logs -n fraud-detection -l component=jobmanager --follow

# Check Iceberg REST catalog logs
kubectl logs -n fraud-detection -l app=iceberg-rest-catalog --tail=30

# Check all pod statuses
kubectl get pods -n fraud-detection

# Check FlinkDeployment lifecycle state
kubectl get flinkdeployment fraud-scoring-job -n fraud-detection \
  -o jsonpath='{.status.lifecycleState}{"\n"}'

# Open Trino shell for SQL queries
kubectl exec -it -n fraud-detection \
  $(kubectl get pod -l app=trino -n fraud-detection \
    -o jsonpath='{.items[0].metadata.name}') \
  -- trino --catalog iceberg --schema fraud_db
```

---

## Failure Recovery

When a deployment step fails after the automatic retry pool is exhausted, an interactive recovery menu is presented:

```
╔══ Step 8 FAILED — Deploy Flink Fraud Detection Job ══╗
  Failed after 3 automatic retry attempt(s).

  1) Retry this step (fresh attempt pool)
  2) Skip and continue  (not recommended — may break later steps)
  3) Abort and clean up everything deployed so far
  4) Abort and keep current state (for manual debugging)
```

In `--yes` (CI/CD) mode, an unrecoverable failure causes immediate abort with exit code 1.

To resume after manual debugging:

```bash
./startup.sh --from <failed-step-number>
```

### Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| Flink job stuck in RESTARTING | Kafka sinks clash on JMX MBean across restarts | Ensure `sink.delivery-guarantee = at-least-once` (not `exactly-once`) |
| `IcebergFilesCommitter` fails with S3 URI error | REST catalog warehouse defaults to `/tmp` | All catalog config must be `CATALOG_*` env vars — `CATALOG_CONFIG_FILE` is silently ignored |
| Flink job graph has only 4 vertices (missing Kafka sinks) | DataStream `sink_to()` branches excluded from Table API execution | Use `StatementSet` with `add_insert_sql()` for all sinks |
| `enriched-transactions` topic has 0 messages | Checkpoints never completed because MinIO buckets didn't exist | Buckets must be pre-created before Flink deployment |
| TM pod takes >2 minutes to appear | Normal on resource-constrained nodes | Timeout in step-08 is set to 240s (48 × 5s attempts) |

---

## Design Decisions

**PyFlink over Java Flink** — The fraud scoring model is Python-native. PyFlink allows the stateful processing function to be written in pure Python while still running inside a JVM-based Flink cluster. The Python worker communicates with the JVM via Apache Beam's gRPC protocol (embedded in PyFlink).

**Table API + StatementSet over DataStream sinks** — Table API `StatementSet` is the only mechanism that submits multiple SQL INSERT statements as a single unified job graph. DataStream `sink_to()` branches register as isolated DAG endpoints that the Table API executor ignores when tracing the graph backwards from the primary sink.

**Iceberg over raw Parquet on S3** — Iceberg provides snapshot isolation, schema evolution, and time-travel queries without any additional infrastructure. Trino can query current and historical snapshots directly using the REST catalog.

**RocksDB state backend** — Per-account fraud state is unbounded in size as new accounts are added. RocksDB spills to local disk and checkpoints incrementally to S3, avoiding JVM heap pressure that would occur with the hashmap (in-memory) backend.

**MinIO over AWS S3** — The pipeline uses S3-compatible APIs throughout (`S3FileIO`, `S3AFileSystem`). Swapping MinIO for real AWS S3 requires only changing three environment variables (`MINIO_ENDPOINT`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) — the rest of the pipeline is unchanged.

**Kind over managed Kubernetes** — A local kind cluster removes AWS cost and network dependencies for development and CI. The entire stack runs on a single EC2 instance (t3.xlarge, 16 GB RAM). The same manifests deploy to any CNCF-conformant cluster without modification.

---

## Cleanup

```bash
# Light cleanup — removes jobs and deployments, keeps cluster and PVCs
./cleanup.sh --mode light

# Full cleanup — destroys the kind cluster and all data
./cleanup.sh --mode full

# Manual cluster destruction
kind delete cluster --name fraud-detection
```

---

## License

MIT