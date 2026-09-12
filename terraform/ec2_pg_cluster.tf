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

  # SSH + EC2 Instance Connect (us-east-1 range: 18.206.107.24/29)
  ingress {
    description = "SSH and EC2 Instance Connect"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0", "18.206.107.24/29"]
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

# Allow EC2 nodes to discover cluster peers by tag
resource "aws_iam_role_policy" "ec2_describe" {
  name = "${var.project_name}-ec2-describe"
  role = aws_iam_role.pg_cluster.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:DescribeInstances"]
      Resource = "*"
    }]
  })
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
    # Bootstrap v2 — install packages only, Patroni configured via SSM
    exec > /var/log/pg-bootstrap.log 2>&1

    echo "=== Starting bootstrap: node ${count.index} ==="

    dnf update -y
    dnf install -y postgresql17-server postgresql17 python3 python3-pip gcc python3-devel

    # Install etcd from GitHub releases (not in AL2023 repos)
    ETCD_VER=v3.5.13
    curl -fsSL https://github.com/etcd-io/etcd/releases/download/$${ETCD_VER}/etcd-$${ETCD_VER}-linux-amd64.tar.gz \
      | tar -xz -C /usr/local/bin --strip-components=1 etcd-$${ETCD_VER}-linux-amd64/etcd etcd-$${ETCD_VER}-linux-amd64/etcdctl

    # Install Patroni
    pip3 install patroni[etcd3] psycopg2-binary

    # Ensure SSM agent is running
    systemctl enable amazon-ssm-agent
    systemctl restart amazon-ssm-agent

    # Set node identity for reference
    echo "NODE_INDEX=${count.index}" >> /etc/environment
    echo "NODE_NAME=pg-node-${count.index}" >> /etc/environment
    echo "CLUSTER_NAME=${var.project_name}" >> /etc/environment
    echo "AWS_REGION=${var.aws_region}" >> /etc/environment

    echo "=== Bootstrap complete. Connect via SSM to configure Patroni. ==="
  EOF

  root_block_device {
    volume_size           = 50
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  # Force recreation when user_data changes so bootstrap script reruns
  user_data_replace_on_change = true

  tags = {
    Name = "${var.project_name}-node-${count.index == 0 ? "primary" : "replica-${count.index}"}"
    Role = count.index == 0 ? "primary" : "replica"
  }
}
