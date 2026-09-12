variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project name used as prefix for all resource names"
  type        = string
  default     = "pg-cluster"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "pg_cluster_instance_type" {
  description = "EC2 instance type for PostgreSQL cluster nodes"
  type        = string
  default     = "t3.medium"
}

variable "ec2_key_name" {
  description = "Existing EC2 key pair name for SSH access (leave empty to use SSM only)"
  type        = string
  default     = ""
}
