"""
Kafka Producer — emits transaction events to the raw-transactions topic.

Features:
  - Configurable TPS (transactions per second)
  - Periodic fraud pattern injection on a schedule
  - Delivery confirmation + dead-letter queue for failed messages
  - Live stats printed to console every 10 seconds
  - Graceful shutdown on SIGINT / SIGTERM

Usage:
    python producer.py                          # defaults
    python producer.py --tps 50 --accounts 500
    python producer.py --tps 10 --fraud-rate 0.05
"""

import argparse
import json
import logging
import random          # FIX: was at bottom of file — caused NameError when
                       # _maybe_inject_fraud_burst() called random.choice()
                       # before the import was reached.
import signal
import sys
import time
import threading
from collections import defaultdict
from datetime import datetime
from typing import Optional

from confluent_kafka import Producer, KafkaException
from confluent_kafka.admin import AdminClient, NewTopic

from generator import TransactionGenerator
from models import Transaction

# ─────────────────────────────────────────────────────────────
#  Logging
# ─────────────────────────────────────────────────────────────

logging.basicConfig(
    level  = logging.INFO,
    format = "%(asctime)s [%(levelname)s] %(name)s — %(message)s",
    datefmt= "%Y-%m-%dT%H:%M:%S",
)
log = logging.getLogger("fraud.producer")


# ─────────────────────────────────────────────────────────────
#  Kafka topic definitions
# ─────────────────────────────────────────────────────────────

TOPICS = {
    "raw-transactions": {
        "num_partitions":      6,     # keyed by account_id
        "replication_factor":  1,     # single broker in local dev
        "config": {
            "retention.ms":         str(7 * 24 * 60 * 60 * 1000),  # 7 days
            "compression.type":     "lz4",
            "max.message.bytes":    str(1_000_000),
        }
    },
    "fraud-alerts": {
        "num_partitions":     3,
        "replication_factor": 1,
        "config": {
            "retention.ms": str(30 * 24 * 60 * 60 * 1000),  # 30 days
        }
    },
    "enriched-transactions": {
        "num_partitions":     6,
        "replication_factor": 1,
        "config": {},
    },
    "dead-letter": {
        "num_partitions":     1,
        "replication_factor": 1,
        "config": {
            "retention.ms": str(7 * 24 * 60 * 60 * 1000),
        }
    },
}


# ─────────────────────────────────────────────────────────────
#  Metrics
# ─────────────────────────────────────────────────────────────

class ProducerMetrics:
    def __init__(self):
        self.produced_total    = 0
        self.produced_fraud    = 0
        self.produced_normal   = 0
        self.delivery_success  = 0
        self.delivery_failed   = 0
        self.bytes_produced    = 0
        self.pattern_counts    = defaultdict(int)
        self._lock             = threading.Lock()

    def record(self, txn: Transaction, msg_bytes: int):
        with self._lock:
            self.produced_total += 1
            self.bytes_produced += msg_bytes
            if txn.is_fraud:
                self.produced_fraud += 1
                self.pattern_counts[txn.fraud_pattern] += 1
            else:
                self.produced_normal += 1

    def on_delivery_success(self):
        with self._lock:
            self.delivery_success += 1

    def on_delivery_failure(self):
        with self._lock:
            self.delivery_failed += 1

    def summary(self) -> str:
        with self._lock:
            rate = (self.produced_fraud / self.produced_total * 100
                    if self.produced_total else 0)
            mb   = self.bytes_produced / (1024 * 1024)
            return (
                f"Total={self.produced_total:,}  "
                f"Fraud={self.produced_fraud:,} ({rate:.1f}%)  "
                f"Normal={self.produced_normal:,}  "
                f"Delivered={self.delivery_success:,}  "
                f"Failed={self.delivery_failed:,}  "
                f"MB={mb:.2f}"
            )


# ─────────────────────────────────────────────────────────────
#  Topic setup
# ─────────────────────────────────────────────────────────────

def ensure_topics(bootstrap_servers: str):
    """Create topics if they don't already exist."""
    admin  = AdminClient({"bootstrap.servers": bootstrap_servers})
    existing = set(admin.list_topics(timeout=10).topics.keys())

    to_create = [
        NewTopic(
            name,
            num_partitions     = cfg["num_partitions"],
            replication_factor = cfg["replication_factor"],
            config             = cfg["config"],
        )
        for name, cfg in TOPICS.items()
        if name not in existing
    ]

    if not to_create:
        log.info("All Kafka topics already exist.")
        return

    results = admin.create_topics(to_create)
    for topic, future in results.items():
        try:
            future.result()
            log.info(f"Created topic: {topic}")
        except KafkaException as e:
            log.warning(f"Topic creation skipped ({topic}): {e}")


# ─────────────────────────────────────────────────────────────
#  Main producer class
# ─────────────────────────────────────────────────────────────

class FraudDetectionProducer:
    def __init__(
        self,
        bootstrap_servers: str  = "localhost:9092",
        tps: float              = 20.0,
        num_accounts: int       = 200,
        fraud_rate: float       = 0.02,
    ):
        self.tps         = tps
        self.sleep_per_txn = 1.0 / tps if tps > 0 else 0
        self.metrics     = ProducerMetrics()
        self.running     = True
        self.bs          = bootstrap_servers

        # Kafka producer config
        self.producer = Producer({
            "bootstrap.servers":            bootstrap_servers,
            "acks":                         "all",        # wait for all replicas
            "retries":                      3,
            "retry.backoff.ms":             500,
            "linger.ms":                    5,            # small batching window
            "batch.size":                   65536,        # 64KB batch
            "compression.type":             "lz4",
            "queue.buffering.max.messages": 100_000,
            "queue.buffering.max.kbytes":   65536,
            "enable.idempotence":           True,         # exactly-once delivery
        })

        self.generator = TransactionGenerator(
            num_accounts = num_accounts,
            fraud_rate   = fraud_rate,
        )

        # Fraud injection schedule (every N normal transactions)
        self._fraud_injection_counter = 0
        self._fraud_injection_every   = 200   # inject a burst every 200 txns

        # Register shutdown handlers
        signal.signal(signal.SIGINT,  self._shutdown)
        signal.signal(signal.SIGTERM, self._shutdown)

        log.info(
            f"Producer ready | brokers={bootstrap_servers} "
            f"tps={tps} accounts={num_accounts} fraud_rate={fraud_rate}"
        )

    # ── Delivery callback ─────────────────────────────────

    def _delivery_callback(self, err, msg):
        if err:
            log.error(f"Delivery failed for {msg.key()}: {err}")
            self.metrics.on_delivery_failure()
            # Send to dead-letter topic
            self.producer.produce(
                "dead-letter",
                key   = msg.key(),
                value = msg.value(),
            )
        else:
            self.metrics.on_delivery_success()

    # ── Emit a single transaction ─────────────────────────

    def emit(self, txn: Transaction, topic: str = "raw-transactions"):
        payload = txn.to_json()
        payload_bytes = payload.encode("utf-8")

        self.producer.produce(
            topic    = topic,
            key      = txn.account_id,   # partition by account_id
            value    = payload_bytes,
            headers  = {
                "fraud_pattern": txn.fraud_pattern,
                "source":        "transaction-generator",
                "schema_version":"1.0",
            },
            on_delivery = self._delivery_callback,
        )
        self.metrics.record(txn, len(payload_bytes))

        # Non-blocking poll to trigger delivery callbacks
        self.producer.poll(0)

    # ── Fraud burst injection ─────────────────────────────

    def _maybe_inject_fraud_burst(self):
        """
        Periodically inject a burst of a specific fraud pattern
        to ensure Flink has interesting events to detect.
        random is imported at module level (top of file) — available here.
        """
        account = random.choice(self.generator.accounts)
        pattern_roll = random.random()

        if pattern_roll < 0.33:
            log.warning(
                f"[FRAUD INJECTION] geo_velocity attack on {account.account_id}"
            )
            for txn in self.generator.inject_geo_velocity_fraud(account):
                self.emit(txn)

        elif pattern_roll < 0.66:
            log.warning(
                f"[FRAUD INJECTION] card_testing attack on {account.account_id}"
            )
            for txn in self.generator.inject_card_testing_fraud(account):
                self.emit(txn)

        else:
            log.warning(
                f"[FRAUD INJECTION] rapid_succession attack on {account.account_id}"
            )
            for txn in self.generator.inject_rapid_succession_fraud(account):
                self.emit(txn)

    # ── Stats printer ─────────────────────────────────────

    def _start_stats_printer(self):
        def _print():
            while self.running:
                time.sleep(10)
                log.info(f"[STATS] {self.metrics.summary()}")
                patterns = dict(self.metrics.pattern_counts)
                if patterns:
                    log.info(f"[PATTERNS] {patterns}")
        t = threading.Thread(target=_print, daemon=True)
        t.start()

    # ── Main run loop ─────────────────────────────────────

    def run(self):
        log.info("Starting transaction stream...")
        self._start_stats_printer()
        gen = self.generator.generate()

        while self.running:
            loop_start = time.monotonic()

            txn = next(gen)
            self.emit(txn)

            # Inject fraud burst on schedule
            self._fraud_injection_counter += 1
            if self._fraud_injection_counter >= self._fraud_injection_every:
                self._maybe_inject_fraud_burst()
                self._fraud_injection_counter = 0

            # Throttle to target TPS
            elapsed = time.monotonic() - loop_start
            sleep   = self.sleep_per_txn - elapsed
            if sleep > 0:
                time.sleep(sleep)

        self._flush()

    def _flush(self):
        log.info("Flushing remaining messages...")
        remaining = self.producer.flush(timeout=30)
        if remaining > 0:
            log.warning(f"{remaining} messages not delivered after flush.")
        log.info(f"Shutdown complete. Final stats: {self.metrics.summary()}")

    def _shutdown(self, signum, frame):
        log.info(f"Received signal {signum}, shutting down gracefully...")
        self.running = False


# ─────────────────────────────────────────────────────────────
#  CLI entry point
# ─────────────────────────────────────────────────────────────

def parse_args():
    p = argparse.ArgumentParser(description="Fraud Detection Transaction Producer")
    p.add_argument("--brokers",     default="localhost:9092", help="Kafka bootstrap servers")
    p.add_argument("--tps",         type=float, default=20.0, help="Target transactions per second")
    p.add_argument("--accounts",    type=int,   default=200,  help="Number of simulated accounts")
    p.add_argument("--fraud-rate",  type=float, default=0.02, help="Fraction of fraudulent transactions (0-1)")
    p.add_argument("--setup-topics",action="store_true",      help="Create Kafka topics then exit")
    return p.parse_args()


def main():
    args = parse_args()

    log.info(f"Connecting to Kafka at {args.brokers}...")
    ensure_topics(args.brokers)

    if args.setup_topics:
        log.info("Topics created. Exiting (--setup-topics flag).")
        sys.exit(0)

    producer = FraudDetectionProducer(
        bootstrap_servers = args.brokers,
        tps               = args.tps,
        num_accounts      = args.accounts,
        fraud_rate        = args.fraud_rate,
    )
    producer.run()


if __name__ == "__main__":
    main()
