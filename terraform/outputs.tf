output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "Public subnet IDs"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet IDs"
  value       = aws_subnet.private[*].id
}

output "ec2_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.main.id
}

output "ec2_public_ip" {
  description = "EC2 public IP address"
  value       = aws_instance.main.public_ip
}

output "ec2_public_dns" {
  description = "EC2 public DNS"
  value       = aws_instance.main.public_dns
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = aws_db_instance.postgresql.endpoint
}

output "rds_port" {
  description = "RDS port"
  value       = aws_db_instance.postgresql.port
}

output "rds_db_name" {
  description = "RDS database name"
  value       = aws_db_instance.postgresql.db_name
}

output "pg_cluster_private_ips" {
  description = "Private IPs of the PostgreSQL cluster nodes"
  value = {
    primary   = aws_instance.pg_cluster[0].private_ip
    replica_1 = aws_instance.pg_cluster[1].private_ip
    replica_2 = aws_instance.pg_cluster[2].private_ip
  }
}

output "pg_cluster_instance_ids" {
  description = "Instance IDs of the PostgreSQL cluster nodes"
  value       = aws_instance.pg_cluster[*].id
}

output "rds_secret_arn" {
  description = "ARN of the Secrets Manager secret holding RDS credentials"
  value       = aws_secretsmanager_secret.rds.arn
}

output "rds_secret_name" {
  description = "Name of the Secrets Manager secret holding RDS credentials"
  value       = aws_secretsmanager_secret.rds.name
}

output "lambda_function_name" {
  description = "Lambda function name"
  value       = aws_lambda_function.list_resources.function_name
}

output "lambda_function_arn" {
  description = "Lambda function ARN"
  value       = aws_lambda_function.list_resources.arn
}
