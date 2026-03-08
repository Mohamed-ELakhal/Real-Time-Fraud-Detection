# ============================================================
#  variables.tf
# ============================================================

# ── AWS Credentials ───────────────────────────────────────────
# Credentials are NOT defined here — they are read automatically from
# environment variables set by your AWS CLI configuration:
#   AWS_ACCESS_KEY_ID
#   AWS_SECRET_ACCESS_KEY
# Verify with: aws sts get-caller-identity

variable "aws_region" {
  description = "AWS region. Pick any — no region restrictions on free trial credits."
  type        = string
  default     = "eu-west-1"
  # Recommended regions (low latency from SA):
  #   eu-west-1      Ireland       ~120ms
  #   eu-central-1   Frankfurt     ~130ms
  #   me-south-1     Bahrain       ~30ms  (closest, but smaller capacity pool)
  #   me-central-1   UAE           ~40ms
}

# ── Instance ──────────────────────────────────────────────────
# t3.xlarge = 4 vCPU / 16 GB RAM / /bin/sh.166/hr
# 00 credit covers ~602 hrs (25 days 24/7)
# 00 credit covers ~1204 hrs (50 days 24/7)
# Stopping the instance when not in use = credit lasts months

variable "instance_type" {
  description = "EC2 instance type. t3.xlarge is the minimum for this pipeline."
  type        = string
  default     = "t3.xlarge"
  # Alternatives if t3 is unavailable in your region:
  #   t3a.xlarge  = AMD variant, ~10% cheaper (/bin/sh.150/hr)
  #   m6i.xlarge  = more consistent perf, /bin/sh.192/hr
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 100
}

# ── SSH ───────────────────────────────────────────────────────

variable "ssh_public_key_path" {
  description = "Path to your SSH public key"
  type        = string
}

variable "ssh_private_key_path" {
  description = "Path to SSH private key (used only in connection string output)"
  type        = string
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH. Use your-ip/32 for security."
  type        = string
  default     = "0.0.0.0/0"
}

# ── Tagging ───────────────────────────────────────────────────

variable "project_tag" {
  description = "Tag applied to all resources"
  type        = string
  default     = "fraud-detection"
}
