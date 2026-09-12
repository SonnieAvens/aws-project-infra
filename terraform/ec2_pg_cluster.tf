############################
# Latest Amazon Linux 2023 AMI
############################
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

############################
# Security Group
############################
resource "aws_security_group" "pg_cluster" {
  name        = "${var.project_name}-sg"
  description = "PostgreSQL cluster security group"
  vpc_id      = aws_vpc.main.id

  # SSH from internet (restrict to your IP in production)
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # PostgreSQL between cluster nodes and external clients
  ingress {
    description = "PostgreSQL"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Patroni REST API between cluster nodes
  ingress {
    description = "Patroni REST API (inter-node)"
    from_port   = 8008
    to_port     = 8008
    protocol    = "tcp"
    self        = true
  }

  # etcd between cluster nodes
  ingress {
    description = "etcd client (inter-node)"
    from_port   = 2379
    to_port     = 2380
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg" }
}

############################
# IAM Role — SSM + Secrets Manager access
############################
resource "aws_iam_role" "pg_cluster" {
  name = "${var.project_name}-ec2-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.pg_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "pg_cluster" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.pg_cluster.name
}

############################
# 3 EC2 Instances — PostgreSQL Cluster
# Node 0 = Primary | Nodes 1 & 2 = Replicas
# Distributed across 2 public subnets
############################
resource "aws_instance" "pg_cluster" {
  count                       = 3
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.pg_cluster_instance_type
  subnet_id                   = aws_subnet.public[count.index % 2].id
  vpc_security_group_ids      = [aws_security_group.pg_cluster.id]
  iam_instance_profile        = aws_iam_instance_profile.pg_cluster.name
  associate_public_ip_address = true
  key_name                    = var.ec2_key_name != "" ? var.ec2_key_name : null

  user_data = <<-EOF
    #!/bin/bash
    set -e
    dnf update -y
    dnf install -y postgresql17-server postgresql17 python3 python3-pip gcc python3-devel

    # Install Patroni with etcd support
    pip3 install patroni[etcd] psycopg2-binary

    # Set node identity
    echo "NODE_NAME=pg-node-${count.index}" >> /etc/environment
    echo "NODE_ROLE=${count.index == 0 ? "primary" : "replica"}" >> /etc/environment
    echo "CLUSTER_NAME=${var.project_name}" >> /etc/environment

    # Initialize PostgreSQL data directory
    /usr/bin/postgresql-setup --initdb || true
    chown -R postgres:postgres /var/lib/pgsql
  EOF

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-node-${count.index == 0 ? "primary" : "replica-${count.index}"}"
    Role = count.index == 0 ? "primary" : "replica"
  }
}
