FROM flink:1.18.1-scala_2.12-java11

LABEL maintainer="fraud-detection-pipeline"
LABEL description="PyFlink fraud detection job — Kafka source, Iceberg sink, RocksDB state"

# ── Version pins ───────────────────────────────────────────────
ARG FLINK_VERSION=1.18.1
ARG PYFLINK_VERSION=1.18.1  # FIX: must match flink:1.18.1 base image — 1.18.0 causes py4j gateway protocol mismatch
ARG SCALA_VERSION=2.12
ARG KAFKA_CONNECTOR_VERSION=3.1.0-1.18
ARG ICEBERG_VERSION=1.5.2
ARG HADOOP_VERSION=3.3.4
ARG HADOOP_SHADED_GUAVA_VERSION=1.1.1
ARG COMMONS_CONFIG_VERSION=2.1.1
ARG COMMONS_LOGGING_VERSION=1.1.3
ARG COMMONS_BEANUTILS_VERSION=1.9.4
# commons-beanutils is a transitive dep of commons-configuration2.
# PropertiesConfiguration and BeanHelper in commons-configuration2 call
# org.apache.commons.beanutils.BeanUtils at runtime. Without this jar,
# any code path through configuration bean access throws ClassNotFoundException.
ARG WOODSTOX_VERSION=5.3.0
ARG STAX2_API_VERSION=4.2.1
ARG AWS_SDK_VERSION=1.12.262
# flink-connector-kafka 3.1.0 requires kafka-clients 3.4.0.
# The Flink base image does NOT include kafka-clients — it must be added
# explicitly alongside the connector jar.
ARG KAFKA_CLIENTS_VERSION=3.4.0

# ── Install Python + build tools, install PyFlink, then REMOVE build tools ──
#
# IMAGE SIZE FIX: gcc, g++, and librdkafka-dev are needed only during
# 'pip install apache-flink' (for C extension compilation). They are NOT
# needed at runtime. Previously installed in one RUN and never cleaned up —
# adding ~110MB permanently to every layer of the image.
#
# By putting install AND cleanup in the SAME RUN, Docker creates one layer
# whose net content has the tools absent. 'kind load' uses 'docker save'
# which serialises every layer — fewer/smaller layers = less data piped
# through 'docker exec <node> ctr import -', directly reducing load time.
#
# pip version note: flink:1.18.1 is Debian 11 (Bullseye). Bullseye ships
# pip 20.x which does NOT support --break-system-packages (added in pip 22.x).
# We upgrade to pip<23 which works cleanly on Bullseye without PEP 668 issues.
RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 \
        python3-dev \
        python3-pip \
        gcc \
        g++ \
        librdkafka-dev \
    && ln -sf /usr/bin/python3 /usr/bin/python \
    && pip3 install --no-cache-dir --upgrade "pip<23" \
    && pip3 install --no-cache-dir \
        apache-flink==${PYFLINK_VERSION} \
        confluent-kafka==2.3.0 \
        requests==2.31.0 \
    && apt-get purge -y --auto-remove gcc g++ python3-dev librdkafka-dev \
    && rm -rf /var/lib/apt/lists/* /tmp/* /root/.cache

# ── Download all connector JARs in ONE layer ──────────────────
#
# IMAGE SIZE FIX: Previously each JAR was a separate RUN curl — creating
# 4 individual layers. Each extra layer adds overhead to the tar stream
# that 'kind load' pipes into containerd via docker exec. Consolidating
# all downloads into one RUN reduces layer count from 4 to 1.
#
# aws-java-sdk-bundle alone is ~280MB. Combined with the base image and
# PyFlink (~400MB), the old image exceeded 1.5GB compressed — consistently
# timing out the 300s kind load budget on a resource-constrained laptop.
# These fixes bring the image down by ~110-150MB.
#
# ── DEFINITIVE JAR SET for Flink 1.18 + Iceberg 1.5.2 + HadoopCatalog + S3 ──
#
# Root cause of all previous ClassNotFoundErrors:
#   FlinkCatalogFactory.clusterHadoopConf() unconditionally calls new HdfsConfiguration()
#   for ALL Iceberg catalog types. This requires the FULL Hadoop dependency tree
#   to be present at the original (unshaded) package paths.
#
# Failed approaches:
#   hadoop-client-runtime alone  → shades everything under org.apache.hadoop.shaded.*
#                                   so original paths (e.g. conf.Configuration) are gone
#   hadoop-client-api + runtime  → hadoop-client-api does NOT contain Configuration;
#                                   it's just a thin interface jar
#   hadoop-common alone          → missing HdfsConfiguration, woodstox, commons-*, etc.
#   hadoop-common + hdfs-client  → missing woodstox XML parser, commons-*, etc.
#   hadoop-common + hdfs-client  → missing UserGroupInformation static init deps
#    + woodstox + stax2-api
#
# FINAL SOLUTION — complete transitive set confirmed by:
#   - decodableco/examples Flink+Iceberg+S3+MinIO production Dockerfiles
#   - rmoff.net Flink SQL + S3 deep-dive (Flink 1.18 specific)
#   - Iceberg official docs: "export HADOOP_CLASSPATH=$(hadoop classpath)"
#
# Hadoop core jars (unshaded — classes at original org.apache.hadoop.* paths):
#   hadoop-common         → Configuration, FileSystem, UserGroupInformation
#   hadoop-hdfs-client    → HdfsConfiguration (called by FlinkCatalogFactory)
#   hadoop-mapreduce-client-core → JobConf and MR input format classes used by Iceberg
#   hadoop-auth           → Kerberos/SPNEGO auth support (needed by UGI init)
#   hadoop-shaded-guava   → Hadoop's own guava shim (avoids conflict with Flink's guava)
#
# Hadoop XML / config parsing transitive deps:
#   commons-configuration2 → ReaderBasedXMLReader used by Configuration
#   commons-logging        → logging bridge used by commons-configuration2
#   woodstox-core 5.3.0    → StAX2 XML parser called when Configuration loads XML files
#   stax2-api              → woodstox API layer
#
# NOTE: woodstox-core 5.3.0 is used (not 6.x) — this is the version pinned by
#       hadoop-common 3.3.4 itself and confirmed working in production Flink setups.
WORKDIR /tmp/jars

RUN MAVEN="https://repo1.maven.org/maven2" \
    && curl -fsSL -o /opt/flink/lib/flink-connector-kafka-${KAFKA_CONNECTOR_VERSION}.jar \
        "${MAVEN}/org/apache/flink/flink-connector-kafka/${KAFKA_CONNECTOR_VERSION}/flink-connector-kafka-${KAFKA_CONNECTOR_VERSION}.jar" \
    && curl -fsSL -o /opt/flink/lib/kafka-clients-${KAFKA_CLIENTS_VERSION}.jar \
        "${MAVEN}/org/apache/kafka/kafka-clients/${KAFKA_CLIENTS_VERSION}/kafka-clients-${KAFKA_CLIENTS_VERSION}.jar" \
    && curl -fsSL -o /opt/flink/lib/iceberg-flink-runtime-1.18-${ICEBERG_VERSION}.jar \
        "${MAVEN}/org/apache/iceberg/iceberg-flink-runtime-1.18/${ICEBERG_VERSION}/iceberg-flink-runtime-1.18-${ICEBERG_VERSION}.jar" \
    \
    # iceberg-aws-bundle: provides AWS SDK v2 (software.amazon.awssdk.*) required
    # by S3FileIO (org.apache.iceberg.aws.s3.S3FileIO).
    # The iceberg-flink-runtime uber jar deliberately excludes AWS SDK v2 to avoid
    # bundling a 100MB+ dependency — it must be added separately.
    # Without this JAR the REST catalog fails at initialize() with:
    #   NoClassDefFoundError: software/amazon/awssdk/services/s3/model/S3Exception
    && curl -fsSL -o /opt/flink/lib/iceberg-aws-bundle-${ICEBERG_VERSION}.jar \
        "${MAVEN}/org/apache/iceberg/iceberg-aws-bundle/${ICEBERG_VERSION}/iceberg-aws-bundle-${ICEBERG_VERSION}.jar" \
    \
    # ── Hadoop core (unshaded, classes at original package paths) ──────────
    && curl -fsSL -o /opt/flink/lib/hadoop-common-${HADOOP_VERSION}.jar \
        "${MAVEN}/org/apache/hadoop/hadoop-common/${HADOOP_VERSION}/hadoop-common-${HADOOP_VERSION}.jar" \
    && curl -fsSL -o /opt/flink/lib/hadoop-hdfs-client-${HADOOP_VERSION}.jar \
        "${MAVEN}/org/apache/hadoop/hadoop-hdfs-client/${HADOOP_VERSION}/hadoop-hdfs-client-${HADOOP_VERSION}.jar" \
    && curl -fsSL -o /opt/flink/lib/hadoop-mapreduce-client-core-${HADOOP_VERSION}.jar \
        "${MAVEN}/org/apache/hadoop/hadoop-mapreduce-client-core/${HADOOP_VERSION}/hadoop-mapreduce-client-core-${HADOOP_VERSION}.jar" \
    && curl -fsSL -o /opt/flink/lib/hadoop-auth-${HADOOP_VERSION}.jar \
        "${MAVEN}/org/apache/hadoop/hadoop-auth/${HADOOP_VERSION}/hadoop-auth-${HADOOP_VERSION}.jar" \
    && curl -fsSL -o /opt/flink/lib/hadoop-shaded-guava-${HADOOP_SHADED_GUAVA_VERSION}.jar \
        "${MAVEN}/org/apache/hadoop/thirdparty/hadoop-shaded-guava/${HADOOP_SHADED_GUAVA_VERSION}/hadoop-shaded-guava-${HADOOP_SHADED_GUAVA_VERSION}.jar" \
    \
    # ── Hadoop XML / config parsing transitive deps ─────────────────────────
    && curl -fsSL -o /opt/flink/lib/commons-configuration2-${COMMONS_CONFIG_VERSION}.jar \
        "${MAVEN}/org/apache/commons/commons-configuration2/${COMMONS_CONFIG_VERSION}/commons-configuration2-${COMMONS_CONFIG_VERSION}.jar" \
    && curl -fsSL -o /opt/flink/lib/commons-logging-${COMMONS_LOGGING_VERSION}.jar \
        "${MAVEN}/commons-logging/commons-logging/${COMMONS_LOGGING_VERSION}/commons-logging-${COMMONS_LOGGING_VERSION}.jar" \
    && curl -fsSL -o /opt/flink/lib/commons-beanutils-${COMMONS_BEANUTILS_VERSION}.jar \
        "${MAVEN}/commons-beanutils/commons-beanutils/${COMMONS_BEANUTILS_VERSION}/commons-beanutils-${COMMONS_BEANUTILS_VERSION}.jar" \
    && curl -fsSL -o /opt/flink/lib/woodstox-core-${WOODSTOX_VERSION}.jar \
        "${MAVEN}/com/fasterxml/woodstox/woodstox-core/${WOODSTOX_VERSION}/woodstox-core-${WOODSTOX_VERSION}.jar" \
    && curl -fsSL -o /opt/flink/lib/stax2-api-${STAX2_API_VERSION}.jar \
        "${MAVEN}/org/codehaus/woodstox/stax2-api/${STAX2_API_VERSION}/stax2-api-${STAX2_API_VERSION}.jar" \
    \
    # ── AWS / S3 ────────────────────────────────────────────────────────────
    && curl -fsSL -o /opt/flink/lib/hadoop-aws-${HADOOP_VERSION}.jar \
        "${MAVEN}/org/apache/hadoop/hadoop-aws/${HADOOP_VERSION}/hadoop-aws-${HADOOP_VERSION}.jar" \
    && curl -fsSL -o /opt/flink/lib/aws-java-sdk-bundle-${AWS_SDK_VERSION}.jar \
        "${MAVEN}/com/amazonaws/aws-java-sdk-bundle/${AWS_SDK_VERSION}/aws-java-sdk-bundle-${AWS_SDK_VERSION}.jar" \
    \
    # ── Flink S3 filesystem plugin ──────────────────────────────────────────
    && mkdir -p /opt/flink/plugins/s3-fs-hadoop \
    && cp /opt/flink/opt/flink-s3-fs-hadoop-${FLINK_VERSION}.jar \
          /opt/flink/plugins/s3-fs-hadoop/ \
    && rm -rf /tmp/jars

# ── Hadoop S3A config — two-layer injection ──────────────────
#
# PROBLEM HISTORY:
#   Every approach relying on HADOOP_CONF_DIR env var failed because:
#   a) The Flink Kubernetes Operator intercepts HADOOP_CONF_DIR and overrides
#      the value — what we set is not what the JVM sees.
#   b) catalog 'hadoop.*' SQL properties go into a per-catalog Configuration
#      but Hadoop's FileSystem.get() caches by (scheme,authority,ugi) — NOT
#      by Configuration. A stale cached S3AFileSystem (created during Flink
#      startup, before HadoopCatalog runs) has no endpoint set and connects
#      to real AWS S3 → 403 Forbidden from amazonaws.com.
#   c) env.hadoop.conf.dir in flinkConfiguration only works if the path
#      already exists in the running container (requires image rebuild).
#
# SOLUTION — LAYER 1 (primary, bulletproof):
#   Bundle core-site.xml inside a JAR in /opt/flink/lib/.
#   Hadoop's Configuration class calls ClassLoader.getResource("core-site.xml")
#   at static init time, searching every JAR on the classpath. This fires
#   before ANY FileSystem.get() call — no timing dependency, no env var,
#   no operator interception, no ConfigMap.
#
# SOLUTION — LAYER 2 (belt-and-suspenders):
#   Also COPY to /opt/flink/hadoop-conf/ for env.hadoop.conf.dir fallback.
#
# core-site.xml includes fs.s3a.impl.disable.cache=true to prevent the
# FileSystem cache poisoning problem (stale wrong-endpoint instance).
RUN mkdir -p /opt/flink/hadoop-conf
COPY core-site.xml /opt/flink/hadoop-conf/core-site.xml

# Bundle core-site.xml into a JAR so Hadoop's classloader finds it automatically.
# Uses Python's stdlib zipfile — zip/jar commands are not in the base image.
# Single-line -c argument: Docker cannot misparse it as Dockerfile instructions.
RUN python3 -c "import zipfile; z=zipfile.ZipFile('/opt/flink/lib/hadoop-conf-bundle.jar','w',zipfile.ZIP_STORED); z.write('/opt/flink/hadoop-conf/core-site.xml','core-site.xml'); z.close(); print('hadoop-conf-bundle.jar created:', [i.filename for i in zipfile.ZipFile('/opt/flink/lib/hadoop-conf-bundle.jar').infolist()])"

# ── Flink configuration overrides ─────────────────────────────
RUN cat >> /opt/flink/conf/flink-conf.yaml <<'EOF'

# S3 / MinIO access (values overridden by env vars at runtime)
s3.endpoint: http://minio-nodeport.fraud-detection:9000  # FIX: fraud-minio svc doesn't exist; correct is minio-nodeport:9000
s3.access-key: admin
s3.secret-key: password123
s3.path.style.access: true

# RocksDB state backend
state.backend: rocksdb
state.backend.incremental: true

# WARNING: python.executable set here is NEVER USED AT RUNTIME.
# The Flink Kubernetes Operator mounts its generated ConfigMap over /opt/flink/conf,
# completely hiding this flink-conf.yaml. To set python.executable reliably, add it
# to flinkConfiguration in flink-deployment.yaml:
#   python.executable: /usr/bin/python3
# It is intentionally omitted from this file to avoid false confidence.
# PyFlink finds python3 via PATH lookup (/usr/bin/python3 is on PATH from the
# apt install + ln -sf above).
EOF

# ── Application source ────────────────────────────────────────
WORKDIR /opt/flink/jobs

COPY models.py         .
COPY fraud_detector.py .
COPY fraud_job.py      .

# ── Entrypoint ────────────────────────────────────────────────
CMD ["python3", "fraud_job.py"]