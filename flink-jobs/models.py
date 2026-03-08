"""
Data models for fraud detection transactions.
Using dataclasses for clean structure + easy serialization.
"""

from dataclasses import dataclass, field, asdict
from typing import Optional
from enum import Enum
import json


class MerchantCategory(str, Enum):
    GROCERY        = "grocery"
    GAS_STATION    = "gas_station"
    RESTAURANT     = "restaurant"
    ONLINE_RETAIL  = "online_retail"
    ATM            = "atm"
    LUXURY_GOODS   = "luxury_goods"
    TRAVEL         = "travel"
    ELECTRONICS    = "electronics"
    PHARMACY       = "pharmacy"
    ENTERTAINMENT  = "entertainment"


class TransactionType(str, Enum):
    PURCHASE       = "purchase"
    WITHDRAWAL     = "withdrawal"
    TRANSFER       = "transfer"
    REFUND         = "refund"


class FraudPattern(str, Enum):
    NONE              = "none"
    HIGH_AMOUNT       = "high_amount"
    GEO_VELOCITY      = "geo_velocity"       # used in 2 countries within short time
    RAPID_SUCCESSION  = "rapid_succession"   # many txns in minutes
    UNUSUAL_COUNTRY   = "unusual_country"
    CARD_TESTING      = "card_testing"       # many small txns to test card
    ACCOUNT_TAKEOVER  = "account_takeover"   # new device + high amount


@dataclass
class Location:
    country:    str
    city:       str
    latitude:   float
    longitude:  float


@dataclass
class Transaction:
    transaction_id:     str
    account_id:         str
    card_id:            str
    amount:             float
    currency:           str
    transaction_type:   str
    merchant_id:        str
    merchant_name:      str
    merchant_category:  str
    location:           Location
    timestamp_ms:       int          # epoch milliseconds
    event_time:         str          # ISO8601 string for readability
    is_fraud:           bool         # ground truth label
    fraud_pattern:      str          # which pattern triggered fraud
    device_id:          str
    ip_address:         str
    session_id:         str

    def to_dict(self) -> dict:
        d = asdict(self)
        # Flatten location into top-level fields for easier Flink processing
        loc = d.pop("location")
        d["country"]   = loc["country"]
        d["city"]      = loc["city"]
        d["latitude"]  = loc["latitude"]
        d["longitude"] = loc["longitude"]
        return d

    def to_json(self) -> str:
        return json.dumps(self.to_dict())


# Avro schema — used with Schema Registry for strong typing
TRANSACTION_AVRO_SCHEMA = """
{
  "type": "record",
  "name": "Transaction",
  "namespace": "com.frauddetection",
  "fields": [
    {"name": "transaction_id",    "type": "string"},
    {"name": "account_id",        "type": "string"},
    {"name": "card_id",           "type": "string"},
    {"name": "amount",            "type": "double"},
    {"name": "currency",          "type": "string"},
    {"name": "transaction_type",  "type": "string"},
    {"name": "merchant_id",       "type": "string"},
    {"name": "merchant_name",     "type": "string"},
    {"name": "merchant_category", "type": "string"},
    {"name": "country",           "type": "string"},
    {"name": "city",              "type": "string"},
    {"name": "latitude",          "type": "double"},
    {"name": "longitude",         "type": "double"},
    {"name": "timestamp_ms",      "type": "long"},
    {"name": "event_time",        "type": "string"},
    {"name": "is_fraud",          "type": "boolean"},
    {"name": "fraud_pattern",     "type": "string"},
    {"name": "device_id",         "type": "string"},
    {"name": "ip_address",        "type": "string"},
    {"name": "session_id",        "type": "string"}
  ]
}
"""
