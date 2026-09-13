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
# SSH Key Pair (auto-generated, private key in Secrets Manager)
############################
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "pg" {
  key_name   = "${var.project_name}-key"
  public_key = tls_private_key.ssh.public_key_openssh

  tags = { Name = "${var.project_name}-key" }
}

resource "aws_secretsmanager_secret" "ssh_key" {
  name                    = "${var.project_name}/ec2/ssh-private-key"
  description             = "SSH private key for ${var.project_name} EC2 instance"
  recovery_window_in_days = 0

  tags = { Name = "${var.project_name}-ssh-key" }
}

resource "aws_secretsmanager_secret_version" "ssh_key" {
  secret_id     = aws_secretsmanager_secret.ssh_key.id
  secret_string = tls_private_key.ssh.private_key_pem
}

############################
# Security Group
############################
resource "aws_security_group" "pg" {
  name        = "${var.project_name}-sg"
  description = "PostgreSQL practice instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "PostgreSQL"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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
# IAM Role for SSM access
############################
resource "aws_iam_role" "pg" {
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
  role       = aws_iam_role.pg.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "pg" {
  name = "${var.project_name}-ec2-profile"
  role = aws_iam_role.pg.name
}

############################
# EC2 — Blue (existing PostgreSQL instance)
############################
resource "aws_instance" "pg" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.pg.id]
  iam_instance_profile        = aws_iam_instance_profile.pg.name
  key_name                    = aws_key_pair.pg.key_name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    exec > /var/log/pg-bootstrap.log 2>&1
    echo "=== Installing PostgreSQL 17 ==="
    dnf install -y postgresql17-server postgresql17
    postgresql-setup --initdb
    systemctl enable postgresql
    systemctl start postgresql
    # Allow password auth and remote connections
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /var/lib/pgsql/data/postgresql.conf
    echo "host all all 0.0.0.0/0 md5" >> /var/lib/pgsql/data/pg_hba.conf
    systemctl restart postgresql
    echo "=== PostgreSQL 17 ready ==="
  EOF

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "${var.project_name}-blue" }
}

############################
# EC2 — Green (PostgreSQL 18 target instance)
############################
resource "aws_instance" "pg_green" {
  ami                         = data.aws_ami.amazon_linux.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.public[0].id
  vpc_security_group_ids      = [aws_security_group.pg.id]
  iam_instance_profile        = aws_iam_instance_profile.pg.name
  key_name                    = aws_key_pair.pg.key_name
  associate_public_ip_address = true
  user_data_replace_on_change = true

  user_data = <<-EOF
    #!/bin/bash
    exec > /var/log/pg-bootstrap.log 2>&1
    echo "=== Installing PostgreSQL 18 ==="
    dnf install -y postgresql18-server postgresql18
    postgresql-setup --initdb
    systemctl enable postgresql
    systemctl start postgresql
    # Allow password auth, remote connections, and logical replication
    sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '*'/" /var/lib/pgsql/data/postgresql.conf
    sed -i "s/#wal_level = replica/wal_level = logical/" /var/lib/pgsql/data/postgresql.conf
    sed -i 's/ident/md5/g; s/scram-sha-256/md5/g' /var/lib/pgsql/data/pg_hba.conf
    echo "host all all 0.0.0.0/0 md5" >> /var/lib/pgsql/data/pg_hba.conf
    echo "host replication all 0.0.0.0/0 md5" >> /var/lib/pgsql/data/pg_hba.conf
    systemctl restart postgresql
    echo "=== PostgreSQL 18 ready ==="
  EOF

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  tags = { Name = "${var.project_name}-green" }
}
