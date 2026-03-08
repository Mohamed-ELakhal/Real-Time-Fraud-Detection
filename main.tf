# ============================================================
#  main.tf — AWS infrastructure for fraud detection pipeline
#
#  Resources created:
#    - VPC + Internet Gateway + Route Table
#    - Public subnet
#    - Security Group (SSH + all service ports)
#    - EC2 key pair (from your local public key)
#    - t3.xlarge EC2 instance (4 vCPU / 16 GB)
#    - Cloud-init: installs Docker, kind, kubectl, Helm on first boot
#
#  Cost:  ~$0.166/hr from your $100-$200 AWS free trial credit
#  Stop:  terraform destroy -auto-approve  (removes everything, stops billing)
# ============================================================

# ── Latest Ubuntu 22.04 LTS AMI (x86_64) ─────────────────────
# Canonical publishes official AMIs to all regions.
# This data source always resolves to the latest one in your region
# so you never need to hard-code an AMI ID.

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical's official AWS account

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# ── VPC ───────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = { Name = "${var.project_tag}-vpc", project = var.project_tag }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.project_tag}-igw", project = var.project_tag }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true

  tags = { Name = "${var.project_tag}-subnet", project = var.project_tag }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = { Name = "${var.project_tag}-rt", project = var.project_tag }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ── Security Group ────────────────────────────────────────────
# One ingress rule per service port — mirrors the kind NodePort
# mappings in kind-config.yaml exactly.

resource "aws_security_group" "fraud_detection" {
  name        = "${var.project_tag}-sg"
  description = "Fraud detection pipeline - SSH + service ports"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_tag}-sg", project = var.project_tag }

  # ── SSH ─────────────────────────────────────────────────────
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # ── Pipeline UIs and APIs ────────────────────────────────────
  ingress {
    description = "Kafka UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Schema Registry"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Flink Web UI"
    from_port   = 8082
    to_port     = 8082
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Trino"
    from_port   = 8083
    to_port     = 8083
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "MinIO S3 API"
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "MinIO Console"
    from_port   = 9001
    to_port     = 9001
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kafka External Bootstrap"
    from_port   = 9092
    to_port     = 9092
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Kafka broker NodePorts"
    from_port   = 30093
    to_port     = 30095
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # ── Egress: allow all outbound ───────────────────────────────
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ── SSH Key Pair ──────────────────────────────────────────────

resource "aws_key_pair" "fraud_detection" {
  key_name   = "${var.project_tag}-key"
  public_key = file(var.ssh_public_key_path)
  tags       = { project = var.project_tag }
}

# ── Cloud-init script ─────────────────────────────────────────
# Installs Docker, kind (amd64), kubectl (amd64), Helm on first boot.
# AWS Ubuntu AMIs do NOT have the OCI iptables DROP issue —
# no iptables flush needed. UFW is inactive by default.
# Progress logged to /var/log/fraud-detection-init.log

locals {
  cloud_init = <<-CLOUDINIT
    #!/usr/bin/env bash
    set -euo pipefail
    exec > >(tee -a /var/log/fraud-detection-init.log) 2>&1

    echo "======================================================"
    echo " Fraud Detection Pipeline — Bootstrap"
    echo " Instance: ${var.instance_type} | $(nproc) vCPU | $(free -h | awk '/^Mem:/{print $2}') RAM"
    echo " Started: $(date)"
    echo "======================================================"

    apt-get update -qq
    apt-get install -y --no-install-recommends \
        curl git python3 python3-pip ca-certificates \
        gnupg lsb-release apt-transport-https

    echo "[1/4] Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    usermod -aG docker ubuntu
    chmod 666 /var/run/docker.sock
    echo "[1/4] Docker: $(docker --version)"

    echo "[2/4] Installing kubectl..."
    K8S_VER=$(curl -sL https://dl.k8s.io/release/stable.txt)
    curl -sLo /usr/local/bin/kubectl \
        "https://dl.k8s.io/release/$${K8S_VER}/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl
    echo "[2/4] kubectl: $(kubectl version --client --short 2>/dev/null || true)"

    echo "[3/4] Installing kind..."
    curl -sLo /usr/local/bin/kind \
        "https://kind.sigs.k8s.io/dl/v0.22.0/kind-linux-amd64"
    chmod +x /usr/local/bin/kind
    echo "[3/4] kind: $(kind version)"

    echo "[4/4] Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
    echo "[4/4] Helm: $(helm version --short)"

    echo ""
    echo "======================================================"
    echo " Bootstrap complete: $(date)"
    echo " ssh -i <key> ubuntu@<PUBLIC_IP>"
    echo " git clone <repo> fraud-detector-project"
    echo " cd fraud-detector-project && ./startup.sh"
    echo "======================================================"
  CLOUDINIT
}

# ── EC2 Instance ──────────────────────────────────────────────

resource "aws_instance" "fraud_detection" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.fraud_detection.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.fraud_detection.id]

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    delete_on_termination = true
  }

  user_data = base64encode(local.cloud_init)

  # Prevent accidental termination from console
  disable_api_termination = false

  tags = {
    Name    = "${var.project_tag}-vm"
    project = var.project_tag
  }

  lifecycle {
    ignore_changes = [ami] # ignore AMI drift on re-applies
  }
}
