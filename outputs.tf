# ============================================================
#  outputs.tf
# ============================================================

output "instance_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.fraud_detection.public_ip
}

output "instance_id" {
  description = "EC2 instance ID — use this to start/stop from AWS Console"
  value       = aws_instance.fraud_detection.id
}

output "ssh_command" {
  description = "Ready-to-paste SSH command"
  value       = "ssh -i ${var.ssh_private_key_path} ubuntu@${aws_instance.fraud_detection.public_ip}"
}

output "bootstrap_log" {
  description = "Tail bootstrap progress after SSH"
  value       = "tail -f /var/log/fraud-detection-init.log"
}

output "service_urls" {
  description = "Browser URLs for each service once the pipeline is running"
  value = {
    kafka_ui        = "http://${aws_instance.fraud_detection.public_ip}:8080"
    schema_registry = "http://${aws_instance.fraud_detection.public_ip}:8081"
    flink_ui        = "http://${aws_instance.fraud_detection.public_ip}:8082"
    minio_console   = "http://${aws_instance.fraud_detection.public_ip}:9001"
    prometheus      = "http://${aws_instance.fraud_detection.public_ip}:9090"
    grafana         = "http://${aws_instance.fraud_detection.public_ip}:3000"
  }
}

output "stop_instance_command" {
  description = "Stop EC2 (halts billing for compute, keeps disk) — saves credit when not in use"
  value       = "aws ec2 stop-instances --instance-ids ${aws_instance.fraud_detection.id} --region ${var.aws_region}"
}

output "start_instance_command" {
  description = "Start EC2 again (note: public IP will change on restart)"
  value       = "aws ec2 start-instances --instance-ids ${aws_instance.fraud_detection.id} --region ${var.aws_region}"
}

output "destroy_command" {
  description = "Destroy everything — VPC, subnet, security group, instance, key pair"
  value       = "terraform destroy -auto-approve"
}
