"""
Transaction Generator — produces realistic credit card transactions
with configurable fraud patterns injected at controlled rates.

Fraud patterns simulated:
  1. High-amount fraud         — single large transaction
  2. Geo-velocity fraud        — same card in two countries within minutes
  3. Rapid succession          — 20+ transactions in under 2 minutes
  4. Card testing              — many tiny transactions ($0.01 - $2.00)
  5. Unusual country           — transaction from a high-risk country
"""

import random
import uuid
import time
import ipaddress
from datetime import datetime, timezone
from typing import Generator, List, Optional, Tuple
from dataclasses import dataclass

from models import (
    Transaction, Location,
    MerchantCategory, TransactionType, FraudPattern
)


# ─────────────────────────────────────────────────────────────
#  Reference data — realistic-looking seed data
# ─────────────────────────────────────────────────────────────

NORMAL_COUNTRIES: List[Tuple[str, str, float, float]] = [
    # (country_code, city, lat, lon)
    ("US", "New York",        40.7128,  -74.0060),
    ("US", "Los Angeles",     34.0522, -118.2437),
    ("US", "Chicago",         41.8781,  -87.6298),
    ("US", "Houston",         29.7604,  -95.3698),
    ("US", "Phoenix",         33.4484, -112.0740),
    ("UK", "London",          51.5074,   -0.1278),
    ("UK", "Manchester",      53.4808,   -2.2426),
    ("CA", "Toronto",         43.6532,  -79.3832),
    ("CA", "Vancouver",       49.2827, -123.1207),
    ("DE", "Berlin",          52.5200,   13.4050),
    ("FR", "Paris",           48.8566,    2.3522),
    ("AU", "Sydney",         -33.8688,  151.2093),
]

HIGH_RISK_COUNTRIES: List[Tuple[str, str, float, float]] = [
    ("NG", "Lagos",            6.5244,    3.3792),
    ("RO", "Bucharest",       44.4268,   26.1025),
    ("UA", "Kyiv",            50.4501,   30.5234),
    ("VN", "Ho Chi Minh",     10.8231,  106.6297),
    ("PK", "Karachi",         24.8607,   67.0011),
]

MERCHANTS: List[Tuple[str, str, str]] = [
    # (merchant_id, merchant_name, category)
    ("M001", "Whole Foods Market",     MerchantCategory.GROCERY),
    ("M002", "Shell Gas Station",      MerchantCategory.GAS_STATION),
    ("M003", "McDonald's",             MerchantCategory.RESTAURANT),
    ("M004", "Amazon.com",             MerchantCategory.ONLINE_RETAIL),
    ("M005", "Chase ATM",              MerchantCategory.ATM),
    ("M006", "Louis Vuitton",          MerchantCategory.LUXURY_GOODS),
    ("M007", "Delta Airlines",         MerchantCategory.TRAVEL),
    ("M008", "Best Buy",               MerchantCategory.ELECTRONICS),
    ("M009", "CVS Pharmacy",           MerchantCategory.PHARMACY),
    ("M010", "Netflix",                MerchantCategory.ENTERTAINMENT),
    ("M011", "Walmart",                MerchantCategory.GROCERY),
    ("M012", "ExxonMobil",             MerchantCategory.GAS_STATION),
    ("M013", "Starbucks",              MerchantCategory.RESTAURANT),
    ("M014", "Apple Store",            MerchantCategory.ELECTRONICS),
    ("M015", "Marriott Hotels",        MerchantCategory.TRAVEL),
    ("M016", "Rolex Dealer",           MerchantCategory.LUXURY_GOODS),
    ("M017", "Spotify",                MerchantCategory.ENTERTAINMENT),
    ("M018", "Walgreens",              MerchantCategory.PHARMACY),
    ("M019", "eBay",                   MerchantCategory.ONLINE_RETAIL),
    ("M020", "Costco",                 MerchantCategory.GROCERY),
]

# Typical spend ranges per category (min, max) in USD
CATEGORY_SPEND_RANGES = {
    MerchantCategory.GROCERY:       (15.0,   250.0),
    MerchantCategory.GAS_STATION:   (20.0,   120.0),
    MerchantCategory.RESTAURANT:    (8.0,    150.0),
    MerchantCategory.ONLINE_RETAIL: (10.0,   500.0),
    MerchantCategory.ATM:           (20.0,   500.0),
    MerchantCategory.LUXURY_GOODS:  (200.0, 5000.0),
    MerchantCategory.TRAVEL:        (150.0, 3000.0),
    MerchantCategory.ELECTRONICS:   (50.0,  2000.0),
    MerchantCategory.PHARMACY:      (5.0,    200.0),
    MerchantCategory.ENTERTAINMENT: (5.0,     50.0),
}


# ─────────────────────────────────────────────────────────────
#  Account registry — simulates a pool of accounts with
#  consistent home country / typical spend behaviour
# ─────────────────────────────────────────────────────────────

@dataclass
class AccountProfile:
    account_id:       str
    card_id:          str
    home_country:     str
    home_city:        str
    home_lat:         float
    home_lon:         float
    avg_txn_amount:   float    # personal baseline spend
    device_id:        str
    is_high_risk:     bool     # pre-flagged as potentially risky account


def build_account_pool(n: int = 200) -> List[AccountProfile]:
    accounts = []
    for i in range(n):
        country_info = random.choice(NORMAL_COUNTRIES)
        accounts.append(AccountProfile(
            account_id     = f"ACC_{i:05d}",
            card_id        = f"CARD_{uuid.uuid4().hex[:12].upper()}",
            home_country   = country_info[0],
            home_city      = country_info[1],
            home_lat       = country_info[2] + random.uniform(-0.5, 0.5),
            home_lon       = country_info[3] + random.uniform(-0.5, 0.5),
            avg_txn_amount = random.uniform(30.0, 300.0),
            device_id      = f"DEV_{uuid.uuid4().hex[:8].upper()}",
            is_high_risk   = random.random() < 0.05,  # 5% flagged accounts
        ))
    return accounts


# ─────────────────────────────────────────────────────────────
#  Core generator
# ─────────────────────────────────────────────────────────────

class TransactionGenerator:
    """
    Generates a stream of transactions with realistic distributions.

    fraud_rate:  overall fraction of transactions that are fraudulent
                 (default 2% mirrors real-world rates)
    tps:         target transactions per second (used by the producer
                 for sleep calculations, not enforced here)
    """

    def __init__(
        self,
        num_accounts: int   = 200,
        fraud_rate: float   = 0.02,
        seed: Optional[int] = None,
    ):
        if seed is not None:
            random.seed(seed)

        self.fraud_rate    = fraud_rate
        self.accounts      = build_account_pool(num_accounts)
        self.txn_counter   = 0

        # Track last transaction per account for geo-velocity fraud
        self._last_txn: dict = {}   # account_id → Transaction

    # ── Public interface ──────────────────────────────────

    def generate(self) -> Generator[Transaction, None, None]:
        """Infinite generator — yields one transaction at a time."""
        while True:
            account = random.choice(self.accounts)
            txn     = self._build_transaction(account)
            self._last_txn[account.account_id] = txn
            self.txn_counter += 1
            yield txn

    def generate_batch(self, n: int) -> List[Transaction]:
        gen = self.generate()
        return [next(gen) for _ in range(n)]

    # ── Fraud pattern injection ───────────────────────────

    def inject_geo_velocity_fraud(
        self, account: AccountProfile
    ) -> List[Transaction]:
        """
        Produce 2 transactions for same account in different countries
        within 5 minutes — physically impossible travel.
        """
        txns = []
        base_ts = self._now_ms()

        # First txn: home country, normal amount
        txn1 = self._normal_transaction(account, ts_ms=base_ts)
        txns.append(txn1)

        # Second txn: high-risk country, 3 minutes later
        risk_country = random.choice(HIGH_RISK_COUNTRIES)
        txn2 = self._fraud_transaction(
            account,
            ts_ms        = base_ts + (3 * 60 * 1000),  # +3 minutes
            pattern      = FraudPattern.GEO_VELOCITY,
            override_loc = Location(
                country   = risk_country[0],
                city      = risk_country[1],
                latitude  = risk_country[2],
                longitude = risk_country[3],
            ),
            amount = random.uniform(800.0, 4000.0),
        )
        txns.append(txn2)
        return txns

    def inject_card_testing_fraud(
        self, account: AccountProfile, n: int = 15
    ) -> List[Transaction]:
        """
        Rapid tiny transactions to verify a stolen card works
        before attempting a large purchase.
        """
        txns = []
        base_ts = self._now_ms()
        merchant = ("M019", "eBay", MerchantCategory.ONLINE_RETAIL)

        for i in range(n):
            txn = self._fraud_transaction(
                account,
                ts_ms   = base_ts + (i * 10_000),   # 10s apart
                pattern = FraudPattern.CARD_TESTING,
                amount  = round(random.uniform(0.01, 1.99), 2),
                merchant_override = merchant,
            )
            txns.append(txn)

        # Follow with a large transaction — the actual fraud
        txns.append(self._fraud_transaction(
            account,
            ts_ms   = base_ts + (n * 10_000) + 5_000,
            pattern = FraudPattern.HIGH_AMOUNT,
            amount  = round(random.uniform(2000.0, 8000.0), 2),
        ))
        return txns

    def inject_rapid_succession_fraud(
        self, account: AccountProfile, n: int = 25
    ) -> List[Transaction]:
        """Many transactions across different merchants in < 2 minutes."""
        txns    = []
        base_ts = self._now_ms()
        for i in range(n):
            txn = self._fraud_transaction(
                account,
                ts_ms   = base_ts + (i * 4_000),   # 4s apart
                pattern = FraudPattern.RAPID_SUCCESSION,
                amount  = round(random.uniform(50.0, 500.0), 2),
            )
            txns.append(txn)
        return txns

    # ── Private builders ──────────────────────────────────

    def _build_transaction(self, account: AccountProfile) -> Transaction:
        """Decide whether this transaction is fraud and build accordingly."""
        roll = random.random()

        if roll < self.fraud_rate:
            # Pick a random fraud pattern weighted by realism
            pattern = random.choices(
                [
                    FraudPattern.HIGH_AMOUNT,
                    FraudPattern.UNUSUAL_COUNTRY,
                    FraudPattern.GEO_VELOCITY,
                    FraudPattern.CARD_TESTING,
                    FraudPattern.RAPID_SUCCESSION,
                ],
                weights=[30, 30, 20, 10, 10],
                k=1
            )[0]
            return self._fraud_transaction(account, pattern=pattern)
        else:
            return self._normal_transaction(account)

    def _normal_transaction(
        self,
        account: AccountProfile,
        ts_ms: Optional[int] = None,
    ) -> Transaction:
        merchant    = random.choice(MERCHANTS)
        category    = merchant[2]
        spend_range = CATEGORY_SPEND_RANGES.get(category, (10.0, 200.0))
        amount      = round(
            random.gauss(
                mu    = (spend_range[0] + spend_range[1]) / 2,
                sigma = (spend_range[1] - spend_range[0]) / 4,
            ), 2
        )
        amount = max(spend_range[0], min(spend_range[1], amount))  # clamp

        # Occasionally travel a little from home location
        jitter     = random.uniform(-2.0, 2.0)
        use_home   = random.random() < 0.85
        if use_home:
            location = Location(
                country   = account.home_country,
                city      = account.home_city,
                latitude  = account.home_lat + jitter * 0.05,
                longitude = account.home_lon + jitter * 0.05,
            )
        else:
            c = random.choice(NORMAL_COUNTRIES)
            location = Location(
                country   = c[0], city = c[1],
                latitude  = c[2], longitude = c[3],
            )

        now_ms = ts_ms or self._now_ms()
        return Transaction(
            transaction_id    = str(uuid.uuid4()),
            account_id        = account.account_id,
            card_id           = account.card_id,
            amount            = amount,
            currency          = "USD",
            transaction_type  = TransactionType.PURCHASE,
            merchant_id       = merchant[0],
            merchant_name     = merchant[1],
            merchant_category = category,
            location          = location,
            timestamp_ms      = now_ms,
            event_time        = self._ms_to_iso(now_ms),
            is_fraud          = False,
            fraud_pattern     = FraudPattern.NONE,
            device_id         = account.device_id,
            ip_address        = self._random_ip(),
            session_id        = f"SES_{uuid.uuid4().hex[:16].upper()}",
        )

    def _fraud_transaction(
        self,
        account: AccountProfile,
        ts_ms: Optional[int]        = None,
        pattern: FraudPattern       = FraudPattern.HIGH_AMOUNT,
        override_loc: Optional[Location] = None,
        amount: Optional[float]     = None,
        merchant_override: Optional[Tuple] = None,
    ) -> Transaction:
        now_ms   = ts_ms or self._now_ms()
        merchant = merchant_override or random.choice(MERCHANTS)

        if amount is None:
            if pattern == FraudPattern.HIGH_AMOUNT:
                amount = round(random.uniform(2000.0, 9500.0), 2)
            elif pattern == FraudPattern.CARD_TESTING:
                amount = round(random.uniform(0.01, 1.99), 2)
            else:
                amount = round(random.uniform(500.0, 4000.0), 2)

        if override_loc:
            location = override_loc
        elif pattern in (FraudPattern.UNUSUAL_COUNTRY, FraudPattern.GEO_VELOCITY):
            c = random.choice(HIGH_RISK_COUNTRIES)
            location = Location(
                country=c[0], city=c[1], latitude=c[2], longitude=c[3]
            )
        else:
            location = Location(
                country   = account.home_country,
                city      = account.home_city,
                latitude  = account.home_lat,
                longitude = account.home_lon,
            )

        # Use a different device_id for account takeover simulation
        device = (
            f"DEV_{uuid.uuid4().hex[:8].upper()}"
            if pattern == FraudPattern.ACCOUNT_TAKEOVER
            else account.device_id
        )

        return Transaction(
            transaction_id    = str(uuid.uuid4()),
            account_id        = account.account_id,
            card_id           = account.card_id,
            amount            = amount,
            currency          = "USD",
            transaction_type  = TransactionType.PURCHASE,
            merchant_id       = merchant[0],
            merchant_name     = merchant[1],
            merchant_category = merchant[2],
            location          = location,
            timestamp_ms      = now_ms,
            event_time        = self._ms_to_iso(now_ms),
            is_fraud          = True,
            fraud_pattern     = pattern,
            device_id         = device,
            ip_address        = self._random_ip(suspicious=True),
            session_id        = f"SES_{uuid.uuid4().hex[:16].upper()}",
        )

    # ── Utilities ─────────────────────────────────────────

    @staticmethod
    def _now_ms() -> int:
        return int(datetime.now(timezone.utc).timestamp() * 1000)

    @staticmethod
    def _ms_to_iso(ms: int) -> str:
        return datetime.fromtimestamp(ms / 1000, tz=timezone.utc).isoformat()

    @staticmethod
    def _random_ip(suspicious: bool = False) -> str:
        if suspicious:
            # Suspicious: non-US ranges
            return f"{random.randint(1,254)}.{random.randint(1,254)}.{random.randint(1,254)}.{random.randint(1,254)}"
        return f"192.168.{random.randint(1,254)}.{random.randint(1,254)}"
