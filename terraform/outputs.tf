output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.pg.id
}

output "public_ip" {
  description = "EC2 public IP address"
  value       = aws_instance.pg.public_ip
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i pg-practice-key.pem ec2-user@${aws_instance.pg.public_ip}"
}

output "get_ssh_key_command" {
  description = "Command to download the SSH private key"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.ssh_key.name} --region ${var.aws_region} --query SecretString --output text > pg-practice-key.pem && chmod 400 pg-practice-key.pem"
}

output "ssh_key_secret_name" {
  description = "Secrets Manager secret name holding the SSH private key"
  value       = aws_secretsmanager_secret.ssh_key.name
}
