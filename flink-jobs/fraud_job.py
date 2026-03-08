"""
Fraud Detection Flink Job — Main Pipeline

Pipeline:
  Kafka [raw-transactions]
    → Watermark assignment
    → Key by account_id
    → FraudDetector (stateful, per-account)
    → Branch A: All scored txns → Kafka [enriched-transactions]
    → Branch B: Fraud only       → Kafka [fraud-alerts]
    → Branch C: All scored txns  → Iceberg [fraud_scores table]

Run locally:
    python fraud_job.py

Submit to Flink cluster:
    flink run -py fraud_job.py \
        --jarfile /opt/flink/lib/flink-connector-kafka-3.1.0-1.18.jar \
        --pyFiles fraud_detector.py
"""

import json
import logging
import os
import sys

from pyflink.common import (
    WatermarkStrategy,
    Duration,
    SimpleStringSchema,
    Types,
    Row,
)
from pyflink.datastream import (
    StreamExecutionEnvironment,
    CheckpointingMode,
    EmbeddedRocksDBStateBackend,  # FIX: correct import for RocksDB backend
)
from pyflink.datastream.connectors.kafka import (
    KafkaSource,
    KafkaOffsetsInitializer,
)
from pyflink.datastream.functions import KeyedProcessFunction, MapFunction
from pyflink.table import StreamTableEnvironment

from fraud_detector import FraudDetector

logging.basicConfig(
    level  = logging.INFO,
    format = "%(asctime)s [%(levelname)s] %(name)s — %(message)s",
)
log = logging.getLogger("fraud.job")


# ─────────────────────────────────────────────────────────────
#  Configuration (overridable via environment variables)
# ─────────────────────────────────────────────────────────────

# FIX: Default values corrected to actual k8s service names.
#
# Previous defaults used docker-compose names (kafka:29092, http://minio:9000)
# that do not exist as k8s services. These values are used when the env var
# is NOT provided by the fraud-detection-config ConfigMap or minio-credentials Secret.
#
# MINIO_ENDPOINT is particularly dangerous: setup_iceberg_catalog() calls
# CREATE DATABASE synchronously (before env.execute()), which writes an S3
# directory. If the endpoint is unreachable, the job throws immediately → exit 2.
#
# Service map (from kubectl get services -n fraud-detection):
#   Kafka bootstrap:  fraud-kafka-kafka-bootstrap.fraud-detection:9092
#   MinIO S3 API:     minio-nodeport.fraud-detection:9000  (NodePort 30000)
#   MinIO Console:    minio-nodeport.fraud-detection:9001  (NodePort 30001)
KAFKA_BROKERS          = os.getenv("KAFKA_BROKERS",
                             "fraud-kafka-kafka-bootstrap.fraud-detection:9092")
MINIO_ENDPOINT         = os.getenv("MINIO_ENDPOINT",
                             "http://minio-nodeport.fraud-detection:9000")
MINIO_ACCESS_KEY       = os.getenv("MINIO_ACCESS_KEY",    "admin")
MINIO_SECRET_KEY       = os.getenv("MINIO_SECRET_KEY",    "password123")
CHECKPOINT_DIR         = os.getenv("CHECKPOINT_DIR",      "s3://fraud-checkpoints/flink")
ICEBERG_WAREHOUSE      = os.getenv("ICEBERG_WAREHOUSE",   "s3://fraud-warehouse/iceberg")
CHECKPOINT_INTERVAL_MS = int(os.getenv("CHECKPOINT_INTERVAL_MS", "30000"))
# FIX: parallelism 1 for single-TM dev setup (1 TM × 2 slots, but 4 operators
# means parallelism 2 would split across slots leaving no room for recovery).
PARALLELISM            = int(os.getenv("PARALLELISM",     "1"))
ALLOWED_LATENESS_S     = int(os.getenv("ALLOWED_LATENESS_S", "10"))


# ─────────────────────────────────────────────────────────────
#  Row type for scored transactions
#  (matches Iceberg fraud_scores table schema exactly)
# ─────────────────────────────────────────────────────────────

SCORED_FIELD_NAMES = [
    "transaction_id", "account_id", "card_id", "amount", "currency",
    "merchant_name", "merchant_category", "country", "city",
    "latitude", "longitude", "timestamp_ms", "event_time",
    "is_fraud", "fraud_pattern", "risk_score", "fraud_detected",
    "fraud_reasons", "txn_count_lifetime", "avg_amount_lifetime",
    "detection_ts", "device_id", "ip_address", "session_id",
]

SCORED_FIELD_TYPES = [
    Types.STRING(),  Types.STRING(),  Types.STRING(),  Types.DOUBLE(),  Types.STRING(),
    Types.STRING(),  Types.STRING(),  Types.STRING(),  Types.STRING(),
    Types.DOUBLE(),  Types.DOUBLE(),  Types.LONG(),    Types.STRING(),
    Types.BOOLEAN(), Types.STRING(),  Types.DOUBLE(),  Types.BOOLEAN(),
    Types.BASIC_ARRAY(Types.STRING()), Types.LONG(),   Types.DOUBLE(),
    Types.LONG(),    Types.STRING(),  Types.STRING(),  Types.STRING(),
]

SCORED_ROW_TYPE = Types.ROW_NAMED(SCORED_FIELD_NAMES, SCORED_FIELD_TYPES)


# ─────────────────────────────────────────────────────────────
#  Helper functions
# ─────────────────────────────────────────────────────────────

class ParseScoredJson(MapFunction):
    """
    FIX: The original code had no view definition for 'fraud_input_view',
    causing the INSERT INTO SQL to fail with 'table not found'.

    This function converts each scored JSON string (output of FraudDetector)
    into a typed Row that the Table API can consume. The view is then created
    from the typed DataStream, making 'fraud_input_view' available for SQL.
    """
    def map(self, value: str) -> Row:
        import json as _json
        d = _json.loads(value)
        return Row(
            transaction_id      = str(d.get("transaction_id", "")),
            account_id          = str(d.get("account_id", "")),
            card_id             = str(d.get("card_id", "")),
            amount              = float(d.get("amount", 0.0)),
            currency            = str(d.get("currency", "")),
            merchant_name       = str(d.get("merchant_name", "")),
            merchant_category   = str(d.get("merchant_category", "")),
            country             = str(d.get("country", "")),
            city                = str(d.get("city", "")),
            latitude            = float(d.get("latitude", 0.0)),
            longitude           = float(d.get("longitude", 0.0)),
            timestamp_ms        = int(d.get("timestamp_ms", 0)),
            event_time          = str(d.get("event_time", "")),
            is_fraud            = bool(d.get("is_fraud", False)),
            fraud_pattern       = str(d.get("fraud_pattern", "")),
            risk_score          = float(d.get("risk_score", 0.0)),
            fraud_detected      = bool(d.get("fraud_detected", False)),
            fraud_reasons       = list(d.get("fraud_reasons", [])),
            txn_count_lifetime  = int(d.get("txn_count_lifetime", 0)),
            avg_amount_lifetime = float(d.get("avg_amount_lifetime", 0.0)),
            detection_ts        = int(d.get("detection_ts", 0)),
            device_id           = str(d.get("device_id", "")),
            ip_address          = str(d.get("ip_address", "")),
            session_id          = str(d.get("session_id", "")),
        )


# IsFraud and ToAlertPayload removed — fraud-alerts filtering and
# field projection now handled in SQL:
#   INSERT INTO fraud_alerts_sink
#   SELECT ... FROM fraud_input_view WHERE fraud_detected = true


# ─────────────────────────────────────────────────────────────
#  Watermark strategy
# ─────────────────────────────────────────────────────────────

def build_watermark_strategy() -> WatermarkStrategy:
    """
    Bounded out-of-orderness watermark:
      - Allows events up to ALLOWED_LATENESS_S seconds late before
        closing windows — important for mobile transactions that
        buffer offline and arrive in bursts.
    """
    return (
        WatermarkStrategy
        .for_bounded_out_of_orderness(Duration.of_seconds(ALLOWED_LATENESS_S))
        .with_timestamp_assigner(
            lambda event, _: json.loads(event).get("timestamp_ms", 0)
        )
    )


# ─────────────────────────────────────────────────────────────
#  Iceberg catalog + table setup
# ─────────────────────────────────────────────────────────────

def setup_iceberg_catalog(t_env: StreamTableEnvironment):
    """
    Register an Iceberg catalog using the REST catalog protocol.

    WHY REST CATALOG (not HadoopCatalog):
      HadoopCatalog stores metadata directly in the filesystem. Trino 435
      does not support reading from HadoopCatalog (iceberg.catalog.type=hadoop
      is not a valid Trino Iceberg connector type).

      The REST catalog (iceberg-rest-catalog service) is a shared catalog
      server that both Flink and Trino connect to. It stores catalog metadata
      in MinIO and uses S3FileIO for data files — same warehouse path as before.

    WAREHOUSE NOTE:
      Uses s3:// (not s3a://) because S3FileIO speaks native S3 API.
      s3a:// is for HadoopFileIO / Hadoop S3A connector.
      The REST catalog server also uses s3:// in its catalog.properties.
    """
    rest_catalog_uri = os.getenv(
        "ICEBERG_REST_CATALOG_URI",
        "http://iceberg-rest-catalog.fraud-detection:8181"
    )

    t_env.execute_sql(f"""
        CREATE CATALOG fraud_catalog WITH (
            'type'                 = 'iceberg',
            'catalog-type'         = 'rest',
            'uri'                  = '{rest_catalog_uri}',
            'warehouse'            = '{ICEBERG_WAREHOUSE}',
            'io-impl'              = 'org.apache.iceberg.aws.s3.S3FileIO',
            's3.endpoint'          = '{MINIO_ENDPOINT}',
            's3.access-key-id'     = '{MINIO_ACCESS_KEY}',
            's3.secret-access-key' = '{MINIO_SECRET_KEY}',
            's3.path-style-access' = 'true'
        )
    """)

    t_env.execute_sql("USE CATALOG fraud_catalog")
    t_env.execute_sql("CREATE DATABASE IF NOT EXISTS fraud_db")
    t_env.execute_sql("USE fraud_db")

    # Drop and recreate the table on each startup.
    #
    # WHY DROP BEFORE CREATE:
    #   CREATE TABLE IF NOT EXISTS silently skips if the table exists —
    #   including when it exists with a stale/broken schema from a previous
    #   crashed run. Dropping first ensures the schema is always correct.
    #   This is safe because the REST catalog is ephemeral (in-cluster),
    #   and the Flink job is the sole writer.
    #
    # WHY NO PARTITIONED BY (country):
    #   Iceberg UPSERT requires ALL partition fields to be in the equality
    #   key (the PRIMARY KEY). Our equality key is transaction_id only.
    #   With PARTITIONED BY (country), Iceberg cannot locate which partition
    #   contains the row to update without country in the key, so it raises:
    #     IllegalStateException: partition field 'country' should be included
    #     in equality fields: '[transaction_id]'
    #   Removing the partition clause resolves this.
    #
    # WHY NO write.upsert.enabled:
    #   Without partitioning, upsert is not meaningful for this pipeline.
    #   Fraud scores are append-only (each transaction scored once).
    #   Append mode (the default) is simpler and avoids equality-delete
    #   overhead.
    t_env.execute_sql("DROP TABLE IF EXISTS fraud_scores")

    t_env.execute_sql("""
        CREATE TABLE IF NOT EXISTS fraud_scores (
            transaction_id        STRING,
            account_id            STRING,
            card_id               STRING,
            amount                DOUBLE,
            currency              STRING,
            merchant_name         STRING,
            merchant_category     STRING,
            country               STRING,
            city                  STRING,
            latitude              DOUBLE,
            longitude             DOUBLE,
            timestamp_ms          BIGINT,
            event_time            STRING,
            is_fraud              BOOLEAN,
            fraud_pattern         STRING,
            risk_score            DOUBLE,
            fraud_detected        BOOLEAN,
            fraud_reasons         ARRAY<STRING>,
            txn_count_lifetime    BIGINT,
            avg_amount_lifetime   DOUBLE,
            detection_ts          BIGINT,
            device_id             STRING,
            ip_address            STRING,
            session_id            STRING,
            PRIMARY KEY (transaction_id) NOT ENFORCED
        )
        WITH (
            'format-version'                  = '2',
            'write.format.default'            = 'parquet',
            'write.parquet.compression-codec' = 'snappy',
            'write.metadata.metrics.default'  = 'full'
        )
    """)

    log.info("Iceberg catalog and fraud_scores table ready.")


# ─────────────────────────────────────────────────────────────
#  Main job
# ─────────────────────────────────────────────────────────────

def main():
    # ── 1. Environment setup ──────────────────────────────
    env = StreamExecutionEnvironment.get_execution_environment()
    env.set_parallelism(PARALLELISM)

    # Checkpointing: exactly-once, every 30 seconds
    env.enable_checkpointing(CHECKPOINT_INTERVAL_MS)
    env.get_checkpoint_config().set_checkpointing_mode(
        CheckpointingMode.EXACTLY_ONCE
    )
    env.get_checkpoint_config().set_min_pause_between_checkpoints(5000)
    env.get_checkpoint_config().set_checkpoint_timeout(60_000)
    env.get_checkpoint_config().set_max_concurrent_checkpoints(1)

    # FIX: set_state_backend_from_config({...}) does not exist in PyFlink.
    # Use EmbeddedRocksDBStateBackend directly. The cluster-level config
    # (state.checkpoints.dir, S3 endpoint, credentials) is already set via
    # FlinkDeployment.flinkConfiguration in flink-deployment.yaml — PyFlink
    # does not need to repeat those settings here.
    state_backend = EmbeddedRocksDBStateBackend(enable_incremental_checkpointing=True)
    env.set_state_backend(state_backend)

    # Table environment for Iceberg writes
    t_env = StreamTableEnvironment.create(env)
    setup_iceberg_catalog(t_env)

    # ── 2. Kafka Source ───────────────────────────────────
    kafka_source = (
        KafkaSource.builder()
        .set_bootstrap_servers(KAFKA_BROKERS)
        .set_topics("raw-transactions")
        .set_group_id("flink-fraud-detector-v1")
        .set_starting_offsets(KafkaOffsetsInitializer.earliest())
        .set_value_only_deserializer(SimpleStringSchema())
        .set_property("enable.auto.commit", "false")
        .set_property("max.poll.records",   "500")
        .build()
    )

    # ── 3. Source stream with watermarks ──────────────────
    raw_stream = (
        env
        .from_source(
            source             = kafka_source,
            watermark_strategy = build_watermark_strategy(),
            source_name        = "Kafka[raw-transactions]",
        )
        .name("kafka-source")
        .uid("kafka-source-uid")
    )

    # ── 4. Fraud detection (stateful, keyed by account_id) ─
    scored_stream = (
        raw_stream
        .key_by(
            lambda raw: json.loads(raw)["account_id"],
            key_type = Types.STRING(),
        )
        .process(FraudDetector(), output_type=Types.STRING())
        .name("fraud-detector")
        .uid("fraud-detector-uid")
    )

    # ── 5. Convert DataStream → Table view ───────────────
    # FIX (architectural): DataStream sinks added via .sink_to() are NOT
    # included when t_env.execute_sql("INSERT INTO ...") triggers execution.
    # Flink's Table API executor only traverses the path needed for the SQL
    # pipeline — DataStream sink branches are orphaned and never execute.
    #
    # Solution: convert ALL three sinks (enriched-transactions Kafka,
    # fraud-alerts Kafka, Iceberg) to Table API sinks, then execute via
    # StatementSet. StatementSet.execute() submits one unified job that
    # includes all three sinks AND the shared DataStream upstream.
    #
    # Execution DAG:
    #   KafkaSource → FraudDetector → ParseScoredJson → fraud_input_view
    #       ├── INSERT INTO enriched_transactions_sink  (Kafka, AT_LEAST_ONCE)
    #       ├── INSERT INTO fraud_alerts_sink           (Kafka, EXACTLY_ONCE, fraud only)
    #       └── INSERT INTO fraud_scores                (Iceberg)

    scored_rows = (
        scored_stream
        .map(ParseScoredJson(), output_type=SCORED_ROW_TYPE)
        .name("parse-scored-rows")
        .uid("parse-scored-rows-uid")
    )

    fraud_table = t_env.from_data_stream(scored_rows)
    t_env.create_temporary_view("fraud_input_view", fraud_table)

    # ── 5a. Kafka SQL sink: all enriched transactions ─────
    # Uses flink-connector-kafka which supports both DataStream and Table API.
    # All 24 scored fields emitted as JSON.
    t_env.execute_sql(f"""
        CREATE TEMPORARY TABLE enriched_transactions_sink (
            transaction_id      STRING,
            account_id          STRING,
            card_id             STRING,
            amount              DOUBLE,
            currency            STRING,
            merchant_name       STRING,
            merchant_category   STRING,
            country             STRING,
            city                STRING,
            latitude            DOUBLE,
            longitude           DOUBLE,
            timestamp_ms        BIGINT,
            event_time          STRING,
            is_fraud            BOOLEAN,
            fraud_pattern       STRING,
            risk_score          DOUBLE,
            fraud_detected      BOOLEAN,
            fraud_reasons       ARRAY<STRING>,
            txn_count_lifetime  BIGINT,
            avg_amount_lifetime DOUBLE,
            detection_ts        BIGINT,
            device_id           STRING,
            ip_address          STRING,
            session_id          STRING
        ) WITH (
            'connector'                    = 'kafka',
            'topic'                        = 'enriched-transactions',
            'properties.bootstrap.servers' = '{KAFKA_BROKERS}',
            'format'                       = 'json',
            'sink.delivery-guarantee'      = 'at-least-once'
        )
    """)

    # ── 5b. Kafka SQL sink: fraud alerts only (subset of fields) ──
    # Filtered in SQL with WHERE fraud_detected = true.
    #
    # DELIVERY GUARANTEE: at-least-once (NOT exactly-once).
    # Reason: exactly-once Kafka sinks use transactional producers that call
    # abortLingeringTransactions() in KafkaWriter.<init> on every restart.
    # In application mode, the TM JVM is REUSED across job restarts — the JMX
    # MBean from the previous producer (fraud-alerts-txn-0-1) is still
    # registered, causing InstanceAlreadyExistsException in the constructor,
    # which propagates through KafkaSink.createWriter() and fails the task
    # before processing a single record — creating an infinite restart loop.
    #
    # at-least-once is correct for fraud alerts: a duplicate alert is
    # preferable to a missed one. The consumer can deduplicate by transaction_id.
    t_env.execute_sql(f"""
        CREATE TEMPORARY TABLE fraud_alerts_sink (
            transaction_id    STRING,
            account_id        STRING,
            card_id           STRING,
            amount            DOUBLE,
            currency          STRING,
            merchant_name     STRING,
            merchant_category STRING,
            country           STRING,
            city              STRING,
            timestamp_ms      BIGINT,
            event_time        STRING,
            risk_score        DOUBLE,
            fraud_detected    BOOLEAN,
            fraud_reasons     ARRAY<STRING>,
            detection_ts      BIGINT
        ) WITH (
            'connector'                    = 'kafka',
            'topic'                        = 'fraud-alerts',
            'properties.bootstrap.servers' = '{KAFKA_BROKERS}',
            'format'                       = 'json',
            'sink.delivery-guarantee'      = 'at-least-once'
        )
    """)

    # ── 6. Execute all sinks via StatementSet (single job) ────────
    # StatementSet collects all INSERT statements then calls executeAsync()
    # ONCE on the shared env — submitting one unified job that includes
    # all three sink branches AND the shared DataStream upstream.
    stmt_set = t_env.create_statement_set()

    stmt_set.add_insert_sql("""
        INSERT INTO enriched_transactions_sink
        SELECT
            transaction_id, account_id, card_id,
            amount, currency, merchant_name, merchant_category,
            country, city, latitude, longitude,
            timestamp_ms, event_time,
            is_fraud, fraud_pattern, risk_score, fraud_detected, fraud_reasons,
            txn_count_lifetime, avg_amount_lifetime,
            detection_ts, device_id, ip_address, session_id
        FROM fraud_input_view
    """)

    stmt_set.add_insert_sql("""
        INSERT INTO fraud_alerts_sink
        SELECT
            transaction_id, account_id, card_id,
            amount, currency, merchant_name, merchant_category,
            country, city, timestamp_ms, event_time,
            risk_score, fraud_detected, fraud_reasons, detection_ts
        FROM fraud_input_view
        WHERE fraud_detected = true
    """)

    stmt_set.add_insert_sql("""
        INSERT INTO fraud_scores
        SELECT
            transaction_id, account_id, card_id,
            amount, currency, merchant_name, merchant_category,
            country, city, latitude, longitude,
            timestamp_ms, event_time,
            is_fraud, fraud_pattern, risk_score, fraud_detected, fraud_reasons,
            txn_count_lifetime, avg_amount_lifetime,
            detection_ts, device_id, ip_address, session_id
        FROM fraud_input_view
    """)

    stmt_set.execute()

    log.info("Fraud Detection Job submitted via StatementSet.")
    log.info(f"  Kafka brokers:       {KAFKA_BROKERS}")
    log.info(f"  Checkpoint dir:      {CHECKPOINT_DIR}")
    log.info(f"  Iceberg warehouse:   {ICEBERG_WAREHOUSE}")
    log.info(f"  Parallelism:         {PARALLELISM}")
    log.info(f"  Checkpoint interval: {CHECKPOINT_INTERVAL_MS}ms")
    log.info("  Sinks: enriched-transactions (Kafka), fraud-alerts (Kafka), fraud_scores (Iceberg)")


if __name__ == "__main__":
    main()