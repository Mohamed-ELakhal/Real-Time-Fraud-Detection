FROM python:3.11-slim

LABEL maintainer="fraud-detection-pipeline"
LABEL description="Transaction producer — emits synthetic credit card events to Kafka"

# ── System dependencies ───────────────────────────────────────
# librdkafka is required by confluent-kafka Python binding
RUN apt-get update && apt-get install -y --no-install-recommends \
        gcc \
        g++ \
        librdkafka-dev \
    && rm -rf /var/lib/apt/lists/*

# ── Python dependencies ───────────────────────────────────────
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ── Application source ────────────────────────────────────────
# Copy all producer source files
COPY models.py    .
COPY generator.py .
COPY producer.py  .

# ── Runtime ───────────────────────────────────────────────────
# KAFKA_BROKERS is injected by the Kubernetes Deployment env block
ENV KAFKA_BROKERS="fraud-kafka-kafka-bootstrap.fraud-detection:9092"
ENV TPS="20"
ENV NUM_ACCOUNTS="200"
ENV FRAUD_RATE="0.02"

# Health: producer is healthy if the process is alive
HEALTHCHECK --interval=30s --timeout=10s --start-period=20s --retries=3 \
    CMD pgrep -f "python producer.py" || exit 1

CMD ["sh", "-c", \
     "python producer.py \
        --brokers  ${KAFKA_BROKERS} \
        --tps      ${TPS} \
        --accounts ${NUM_ACCOUNTS} \
        --fraud-rate ${FRAUD_RATE}"]

