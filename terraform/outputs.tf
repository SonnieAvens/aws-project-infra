output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "pg_cluster_public_ips" {
  description = "Public IPs of the PostgreSQL cluster nodes"
  value = {
    primary   = aws_instance.pg_cluster[0].public_ip
    replica_1 = aws_instance.pg_cluster[1].public_ip
    replica_2 = aws_instance.pg_cluster[2].public_ip
  }
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
  description = "Instance IDs"
  value       = aws_instance.pg_cluster[*].id
}

output "ssm_connect_commands" {
  description = "AWS SSM commands to connect to each node (no SSH key needed)"
  value = {
    primary   = "aws ssm start-session --target ${aws_instance.pg_cluster[0].id} --region ${var.aws_region}"
    replica_1 = "aws ssm start-session --target ${aws_instance.pg_cluster[1].id} --region ${var.aws_region}"
    replica_2 = "aws ssm start-session --target ${aws_instance.pg_cluster[2].id} --region ${var.aws_region}"
  }
}
