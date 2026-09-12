############################
# Security Group — PostgreSQL Cluster
############################
resource "aws_security_group" "pg_cluster" {
  name        = "${var.project_name}-pg-cluster-sg"
  description = "Security group for PostgreSQL cluster nodes"
  vpc_id      = aws_vpc.main.id

  # PostgreSQL between cluster nodes (replication)
  ingress {
    description = "PostgreSQL replication between cluster nodes"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    self        = true
  }

  # PostgreSQL from app EC2
  ingress {
    description     = "PostgreSQL from app EC2"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  # PostgreSQL from Lambda
  ingress {
    description     = "PostgreSQL from Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  # SSH from app EC2 for management
  ingress {
    description     = "SSH from app EC2"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  # Patroni REST API between cluster nodes
  ingress {
    description = "Patroni REST API between cluster nodes"
    from_port   = 8008
    to_port     = 8008
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-pg-cluster-sg" }
}

############################
# IAM Role for PG Cluster EC2 (SSM access)
############################
resource "aws_iam_role" "pg_cluster" {
  name = "${var.project_name}-pg-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "pg_cluster_ssm" {
  role       = aws_iam_role.pg_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "pg_cluster_secrets" {
  role       = aws_iam_role.pg_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
}

resource "aws_iam_instance_profile" "pg_cluster" {
  name = "${var.project_name}-pg-cluster-profile"
  role = aws_iam_role.pg_cluster.name
}

############################
# 3 EC2 Instances — PostgreSQL Cluster
# Node 0 = Primary, Nodes 1 & 2 = Replicas
# Distributed across 2 private subnets
############################
resource "aws_instance" "pg_cluster" {
  count                  = 3
  ami                    = data.aws_ami.amazon_linux.id
  instance_type          = var.pg_cluster_instance_type
  subnet_id              = aws_subnet.private[count.index % 2].id
  vpc_security_group_ids = [aws_security_group.pg_cluster.id]
  iam_instance_profile   = aws_iam_instance_profile.pg_cluster.name
  key_name               = var.ec2_key_name != "" ? var.ec2_key_name : null

  user_data = <<-EOF
    #!/bin/bash
    set -e
    dnf update -y
    dnf install -y postgresql17-server postgresql17 python3 python3-pip

    # Install Patroni for HA clustering
    pip3 install patroni[etcd] boto3 psycopg2-binary

    # Initialize PostgreSQL data directory (primary node only handled by Patroni)
    export PGDATA=/var/lib/pgsql/17/data
    mkdir -p $PGDATA
    chown postgres:postgres $PGDATA

    # Tag this node
    NODE_ROLE="${count.index == 0 ? "primary" : "replica-${count.index}"}"
    echo "NODE_ROLE=$NODE_ROLE" >> /etc/environment
    echo "CLUSTER_NAME=${var.project_name}-pg-cluster" >> /etc/environment
    echo "NODE_NAME=pg-node-${count.index}" >> /etc/environment
  EOF

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.project_name}-pg-${count.index == 0 ? "primary" : "replica-${count.index}"}"
    Role = count.index == 0 ? "primary" : "replica"
  }
}
