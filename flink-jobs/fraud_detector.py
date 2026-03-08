"""
Flink Fraud Detection — Stateful Processing Functions

Each function below is a KeyedProcessFunction that runs per account_id,
maintaining state across events to detect behavioral anomalies.

Detection rules implemented:
  1. Single high-amount transaction
  2. Geo-velocity (same card, different country, within 30 minutes)
  3. Velocity (>10 transactions in a 5-minute window)
  4. Card testing (>5 transactions under $2 in 10 minutes)
  5. Unusual country (high-risk country list)
"""

import json
import logging
import math
from datetime import datetime, timezone
from typing import Iterator, List, Optional

from pyflink.common import Types
from pyflink.datastream.state import (   # FIX: pyflink.common.state does not exist
    ValueStateDescriptor,                      # in any PyFlink version. State descriptors
    ListStateDescriptor,                       # are in pyflink.datastream.state (1.15+).
    MapStateDescriptor,
)
from pyflink.datastream import RuntimeContext
from pyflink.datastream.functions import KeyedProcessFunction

log = logging.getLogger("fraud.flink")


# ─────────────────────────────────────────────────────────────
#  Constants
# ─────────────────────────────────────────────────────────────

HIGH_RISK_COUNTRIES = {"NG", "RO", "UA", "VN", "PK", "KP", "IR", "SY"}

VELOCITY_WINDOW_MS   = 5  * 60 * 1000   # 5-minute velocity window
CARD_TEST_WINDOW_MS  = 10 * 60 * 1000   # 10-minute card testing window
GEO_WINDOW_MS        = 30 * 60 * 1000   # 30-minute impossible travel window

HIGH_AMOUNT_THRESHOLD  = 2000.0    # single txn above this → suspicious
VELOCITY_THRESHOLD     = 10        # more than this in 5min → suspicious
CARD_TEST_AMOUNT       = 2.00      # transactions below this = card test
CARD_TEST_COUNT        = 5         # how many tiny txns trigger alert

EARTH_RADIUS_KM = 6371.0


# ─────────────────────────────────────────────────────────────
#  Haversine distance utility
# ─────────────────────────────────────────────────────────────

def haversine_km(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    """Returns great-circle distance in km between two lat/lon points."""
    dlat = math.radians(lat2 - lat1)
    dlon = math.radians(lon2 - lon1)
    a = (
        math.sin(dlat / 2) ** 2
        + math.cos(math.radians(lat1))
        * math.cos(math.radians(lat2))
        * math.sin(dlon / 2) ** 2
    )
    return EARTH_RADIUS_KM * 2 * math.asin(math.sqrt(a))


# ─────────────────────────────────────────────────────────────
#  Output record builder
# ─────────────────────────────────────────────────────────────

def build_alert(txn: dict, risk_score: float, reasons: List[str]) -> str:
    """Construct a fraud alert payload from a scored transaction."""
    return json.dumps({
        **txn,
        "risk_score":           round(risk_score, 3),
        "fraud_detected":       risk_score >= 0.5,
        "fraud_reasons":        reasons,
        "detection_timestamp":  int(datetime.now(timezone.utc).timestamp() * 1000),
        "detection_version":    "1.0.0",
    })


# ─────────────────────────────────────────────────────────────
#  Core Stateful Fraud Detector
# ─────────────────────────────────────────────────────────────

class FraudDetector(KeyedProcessFunction):
    """
    Per-account stateful fraud detector.
    Keyed by account_id so each account's state is isolated.

    State maintained:
      last_country     — country of most recent transaction
      last_lat/lon     — coordinates of most recent transaction
      last_timestamp   — epoch ms of most recent transaction
      recent_txns      — list of (timestamp_ms, amount) in last window
                         used for velocity + card-testing checks
    """

    def open(self, ctx: RuntimeContext):
        # Last seen location state
        self.last_country = ctx.get_state(
            ValueStateDescriptor("last_country", Types.STRING())
        )
        self.last_lat = ctx.get_state(
            ValueStateDescriptor("last_lat", Types.DOUBLE())
        )
        self.last_lon = ctx.get_state(
            ValueStateDescriptor("last_lon", Types.DOUBLE())
        )
        self.last_timestamp = ctx.get_state(
            ValueStateDescriptor("last_timestamp", Types.LONG())
        )

        # Rolling window: list of JSON strings {"ts": ..., "amount": ...}
        # Flink ListState only supports one type so we store serialised dicts
        self.recent_txns = ctx.get_list_state(
            ListStateDescriptor("recent_txns", Types.STRING())
        )

        # Running stats for the account
        self.txn_count_lifetime = ctx.get_state(
            ValueStateDescriptor("txn_count_lifetime", Types.LONG())
        )
        self.total_amount_lifetime = ctx.get_state(
            ValueStateDescriptor("total_amount_lifetime", Types.DOUBLE())
        )

    def process_element(self, raw: str, ctx: KeyedProcessFunction.Context) -> Iterator[str]:
        txn       = json.loads(raw)
        account   = txn["account_id"]
        amount    = txn["amount"]
        country   = txn["country"]
        lat       = txn["latitude"]
        lon       = txn["longitude"]
        ts        = txn["timestamp_ms"]

        risk_score = 0.0
        reasons: List[str] = []

        # ── Update lifetime counters ───────────────────────
        count_so_far = self.txn_count_lifetime.value() or 0
        total_so_far = self.total_amount_lifetime.value() or 0.0
        self.txn_count_lifetime.update(count_so_far + 1)
        self.total_amount_lifetime.update(total_so_far + amount)
        avg_amount = total_so_far / count_so_far if count_so_far > 0 else amount

        # ── Rule 1: High amount ────────────────────────────
        if amount >= HIGH_AMOUNT_THRESHOLD:
            score_contribution = min(0.4, (amount - HIGH_AMOUNT_THRESHOLD) / 10000)
            risk_score += score_contribution
            reasons.append(f"HIGH_AMOUNT:{amount:.2f}")

        # ── Rule 2: Deviation from personal average ────────
        if count_so_far >= 5 and amount > avg_amount * 5:
            risk_score += 0.2
            reasons.append(f"SPEND_DEVIATION:{amount:.2f}_vs_avg_{avg_amount:.2f}")

        # ── Rule 3: Unusual / high-risk country ───────────
        if country in HIGH_RISK_COUNTRIES:
            risk_score += 0.25
            reasons.append(f"HIGH_RISK_COUNTRY:{country}")

        # ── Rule 4: Geo-velocity (impossible travel) ──────
        last_country = self.last_country.value()
        last_ts      = self.last_timestamp.value() or 0
        last_lat_val = self.last_lat.value()
        last_lon_val = self.last_lon.value()

        if last_country and last_ts and last_lat_val is not None:
            time_diff_ms = ts - last_ts
            if time_diff_ms > 0 and last_country != country:
                distance_km = haversine_km(last_lat_val, last_lon_val, lat, lon)
                # Speed needed in km/h to cover this distance in the elapsed time
                hours_elapsed = time_diff_ms / (1000 * 3600)
                speed_kmh = distance_km / hours_elapsed if hours_elapsed > 0 else 0

                # Commercial aircraft max ~900 km/h
                if speed_kmh > 900 and time_diff_ms < GEO_WINDOW_MS:
                    risk_score += 0.6
                    reasons.append(
                        f"GEO_VELOCITY:{last_country}->{country} "
                        f"dist={distance_km:.0f}km "
                        f"time={time_diff_ms//60000}min "
                        f"implied_speed={speed_kmh:.0f}km/h"
                    )
                elif last_country in HIGH_RISK_COUNTRIES or country in HIGH_RISK_COUNTRIES:
                    if time_diff_ms < GEO_WINDOW_MS:
                        risk_score += 0.3
                        reasons.append(
                            f"CROSS_BORDER_RISK:{last_country}->{country}"
                        )

        # ── Rule 5: Transaction velocity ──────────────────
        # Prune old entries outside the window, then count
        cutoff = ts - VELOCITY_WINDOW_MS
        fresh_txns = []

        for entry_str in self.recent_txns.get() or []:
            entry = json.loads(entry_str)
            if entry["ts"] >= cutoff:
                fresh_txns.append(entry)

        velocity = len(fresh_txns)
        if velocity >= VELOCITY_THRESHOLD:
            risk_score += min(0.5, 0.1 * (velocity - VELOCITY_THRESHOLD + 1))
            reasons.append(f"VELOCITY:{velocity}_txns_in_5min")

        # ── Rule 6: Card testing detection ────────────────
        card_test_window_start = ts - CARD_TEST_WINDOW_MS
        tiny_txns = [
            e for e in fresh_txns
            if e["ts"] >= card_test_window_start and e["amount"] < CARD_TEST_AMOUNT
        ]
        if len(tiny_txns) >= CARD_TEST_COUNT:
            risk_score += 0.5
            reasons.append(
                f"CARD_TESTING:{len(tiny_txns)}_micro_txns_in_10min"
            )

        # ── Update state ───────────────────────────────────
        self.last_country.update(country)
        self.last_lat.update(lat)
        self.last_lon.update(lon)
        self.last_timestamp.update(ts)

        # Add current txn to recent window, keep fresh_txns pruned
        fresh_txns.append({"ts": ts, "amount": amount})
        self.recent_txns.clear()
        for e in fresh_txns[-50:]:     # cap at 50 entries to bound state size
            self.recent_txns.add(json.dumps(e))

        # Register a cleanup timer to expire state after 24 hours of inactivity
        ctx.timer_service().register_processing_time_timer(
            ts + 24 * 60 * 60 * 1000
        )

        # ── Emit scored transaction ────────────────────────
        # We emit ALL transactions (scored), not just fraud —
        # Flink downstream will branch into fraud-alerts and enriched-transactions
        txn["risk_score"]  = round(risk_score, 3)
        txn["fraud_detected"] = risk_score >= 0.5
        txn["fraud_reasons"]  = reasons
        txn["txn_count_lifetime"] = count_so_far + 1
        txn["avg_amount_lifetime"] = round(avg_amount, 2)
        txn["detection_ts"] = int(datetime.now(timezone.utc).timestamp() * 1000)

        yield json.dumps(txn)

    def on_timer(self, timestamp: int, ctx: KeyedProcessFunction.OnTimerContext):
        """Clean up state for inactive accounts to prevent state store bloat."""
        last_ts = self.last_timestamp.value() or 0
        if timestamp - last_ts >= 24 * 60 * 60 * 1000:
            self.last_country.clear()
            self.last_lat.clear()
            self.last_lon.clear()
            self.last_timestamp.clear()
            self.recent_txns.clear()
            # Keep lifetime counters — useful for long-term profiling