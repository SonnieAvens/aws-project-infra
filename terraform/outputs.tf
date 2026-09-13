output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "blue_instance_id" {
  description = "Blue EC2 instance ID"
  value       = aws_instance.pg.id
}

output "blue_public_ip" {
  description = "Blue EC2 public IP address"
  value       = aws_instance.pg.public_ip
}

output "blue_ssh_command" {
  description = "SSH command to connect to blue instance"
  value       = "ssh -i pg-practice-key.pem ec2-user@${aws_instance.pg.public_ip}"
}

output "green_instance_id" {
  description = "Green EC2 instance ID"
  value       = aws_instance.pg_green.id
}

output "green_public_ip" {
  description = "Green EC2 public IP address"
  value       = aws_instance.pg_green.public_ip
}

output "green_ssh_command" {
  description = "SSH command to connect to green instance"
  value       = "ssh -i pg-practice-key.pem ec2-user@${aws_instance.pg_green.public_ip}"
}

output "get_ssh_key_command" {
  description = "Command to download the SSH private key"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.ssh_key.name} --region ${var.aws_region} --query SecretString --output text > pg-practice-key.pem && chmod 400 pg-practice-key.pem"
}

output "ssh_key_secret_name" {
  description = "Secrets Manager secret name holding the SSH private key"
  value       = aws_secretsmanager_secret.ssh_key.name
}
